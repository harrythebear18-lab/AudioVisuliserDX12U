// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 39: Neural Synapse Storm — immersive 3D neural network
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_HEMISPHERE.
//
// 48 emitters (8 bands × 3 sub × L/R) placed in hemispheres.
// L/R emitters = left/right hemisphere. Phase coherence = hemisphere sync.
// Synapse connections between nearby emitters on screen.
// Beat = action potential cascade. Kick = neurotransmitter flood.
// Transient = synaptic firing burst. Envelope = baseline neural activity.
//
// World: grid floor for depth grounding, fog density 0.08 (thick), dark ambient.
// Camera: inside the brain, FOV 0.75 (VR: head pose from OpenXR).
// Visual: glowing neuron dots at emitter positions + axon lines between nearby pairs.
//
// DSP: LUFS→neuron brightness, crest→synapse sharpness, THD→neural noise, phase→sync.
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    // ── DSP additive ──
    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();
    float phaseCorr = phaseCoherence();

    // ── Audio dynamics ──
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — VR head pose or desktop inside the brain ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.75;
        float camAng = a.section * 0.5 + a.stereoBal * 0.2;
        float3 camPos = float3(sin(camAng) * 1.5, 0.5 + a.stereoDiff * 0.1, cos(camAng) * 1.5);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder: HEMISPHERE profile ──
    SeParams params = seParams(SE_PROFILE_HEMISPHERE);
    params.widthScale = 2.0;
    params.heightScale = 2.0;
    params.depthScale = 2.0;
    params.jitterAmt = 0.2 + thd * 0.3;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.08, float3(0.01, 0.005, 0.02), -1.5, 0.0, 0.0);
    world.gridIntensity = 0.02;
    world.ambientLevel = 0.003;
    world.ambientColor = float3(0.02, 0.01, 0.04);
    seApplyWorldFog(emit, world);

    // ── Background — dark neural space + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.005;

    // ── Synapses — connections between nearby active emitters ──
    // Limit to L↔R pairs within same band + adjacent band cross-links
    [loop] for (int band = 0; band < SE_N_BANDS; band++) {
        [loop] for (int sub = 0; sub < SE_N_SUB; sub++) {
            int li = band * SE_N_SUB * 2 + sub * 2;
            int ri = band * SE_N_SUB * 2 + sub * 2 + 1;

            if (emit[li].active < 0.01 || emit[ri].active < 0.01) continue;
            if (emit[li].depth < 0.1 || emit[ri].depth < 0.1) continue;

            float2 ab = emit[ri].screenPos - emit[li].screenPos;
            float abLen2 = dot(ab, ab);
            if (abLen2 > 0.25) continue;

            float strength = 1.0 / (sqrt(abLen2) + 0.1);
            // Cross-hemisphere links modulated by phase coherence
            strength *= phaseCoh;

            float t2 = saturate(dot(p - emit[li].screenPos, ab) / max(abLen2, 0.0001));
            float2 closest = emit[li].screenPos + ab * t2;
            float2 lineDiff = p - closest;
            float lineDist2 = dot(lineDiff, lineDiff);
            if (lineDist2 > 0.01) continue;

            float lineDist = sqrt(lineDist2);
            float axonWidth = 0.002 + strength * 0.003;
            float axonGlow = exp(-lineDist * lineDist / (axonWidth * axonWidth));

            float3 synCol = lerp(emit[li].color, emit[ri].color, 0.5);
            float avgDepth = (emit[li].depth + emit[ri].depth) * 0.5;
            float depthFade = exp(-avgDepth * world.fogDensity);

            col += synCol * axonGlow * strength * depthFade * 0.06 * silence;

            // Signal pulse traveling along axon
            float2 sigPoint = lerp(emit[li].screenPos, emit[ri].screenPos, a.beatPhase);
            float sigDist = length(p - sigPoint);
            col += float3(0.9, 0.95, 1.0) * exp(-sigDist * sigDist * 80.0) * beatPulse * strength * depthFade * 0.15 * silence;

            // Kick — neurotransmitter flood
            col += synCol * axonGlow * kickSurge * strength * depthFade * 0.08 * silence;
        }

        // Adjacent band cross-links (within same hemisphere)
        if (band < SE_N_BANDS - 1) {
            [loop] for (int sub = 0; sub < SE_N_SUB; sub++) {
                int li = band * SE_N_SUB * 2 + sub * 2;
                int ri = (band + 1) * SE_N_SUB * 2 + sub * 2;

                if (emit[li].active < 0.01 || emit[ri].active < 0.01) continue;
                if (emit[li].depth < 0.1 || emit[ri].depth < 0.1) continue;

                float2 ab = emit[ri].screenPos - emit[li].screenPos;
                float abLen2 = dot(ab, ab);
                if (abLen2 > 0.2) continue;

                float strength = 1.0 / (sqrt(abLen2) + 0.1);
                float t2 = saturate(dot(p - emit[li].screenPos, ab) / max(abLen2, 0.0001));
                float2 closest = emit[li].screenPos + ab * t2;
                float2 lineDiff = p - closest;
                float lineDist2 = dot(lineDiff, lineDiff);
                if (lineDist2 > 0.008) continue;

                float lineDist = sqrt(lineDist2);
                float axonWidth = 0.0015 + strength * 0.002;
                float axonGlow = exp(-lineDist * lineDist / (axonWidth * axonWidth));

                float3 synCol = lerp(emit[li].color, emit[ri].color, 0.5);
                float avgDepth = (emit[li].depth + emit[ri].depth) * 0.5;
                float depthFade = exp(-avgDepth * world.fogDensity);

                col += synCol * axonGlow * strength * depthFade * 0.04 * silence;
            }
        }
    }

    // ── Emitter glow — depth-aware, VR or desktop ──
    if (VR_ACTIVE) {
        float3 headPos = float3(VRHeadPos.xyz);
        [loop] for (int j = 0; j < SE_NUM_OBJ; j++) {
            if (emit[j].active < 0.01 || emit[j].depth < 0.1) continue;
            col += seEmitGlowVR(p, emit[j], world, headPos, silence);
        }
    } else {
        [loop] for (int j = 0; j < SE_NUM_OBJ; j++) {
            if (emit[j].active < 0.01 || emit[j].depth < 0.1) continue;
            col += seEmitGlowDepth(p, emit[j], world, lufs, crest, beatPulse,
                                   a.beatPhase, kickSurge, transientAmt, silence);
        }
    }

    // ── L↔R links ──
    [loop] for (int lb = 0; lb < SE_N_BANDS; lb++) {
        col += seLinkLR(p, emit, lb, phaseCorr, phaseCoh, silence);
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Dendrite noise — THD-driven shimmer on active emitters ──
    [loop] for (int n = 0; n < SE_NUM_OBJ; n++) {
        if (emit[n].active < 0.01 || emit[n].depth < 0.1) continue;
        float dendNoise = thd * hash21(emit[n].screenPos * 50.0 + Time * 10.0) * 0.015;
        col += emit[n].color * dendNoise * emit[n].depthFog * silence;
    }

    // ── Hemisphere divider — phase coherence indicator ──
    if (phaseCoh > 0.6) {
        float divider = exp(-p.x * p.x * 50.0) * (phaseCoh - 0.6) * 0.025;
        col += float3(0.4, 0.6, 0.5) * divider * silence;
    }

    // ── Mode-specific overlays — subtle ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;
    col += a.brainCol3 * kickSurge * 0.04 * exp(-r * r * 5.0) * silence;
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.02 * silence;
    col += a.brainCol3 * a.colorPulse * 0.015 * silence;
    col += a.brainCol2 * a.energy * 0.01 * silence;
    col += a.brainCol * a.punch * 0.01 * silence;
    col += a.brainCol * a.beatAnt * 0.008 * exp(-r * 2.0) * silence;

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02;

        // ── Active-emitter normalization — busy music doesn't stack brighter ──
    col *= sqrt(16.0 / seActiveCount(emit));
    // ── Soft tone mapping (Reinhard) — no hard clamp, preserves color ──
    col = softReinhard(col);

    col *= silence;
    return float4(col, 1.0);
}
