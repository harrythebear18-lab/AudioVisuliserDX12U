// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 36: Spatial Audio Sonar — 360° immersive 3D sonar display
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_RADIAL.
//
// 48 emitters (8 bands × 3 sub × L/R) placed on radial rings at varying depths.
// You are at the center of a spatial audio field. Emitters are sonar pings.
// Concentric range rings per band. History scrolls outward — older energy fades.
// Beat = omnidirectional sonar ping. Kick = central eruption.
// Transient = surface disruption.
//
// World: grid floor as water surface, fog density 0.04, dark ambient.
// Camera: above looking down at 45°, FOV 0.5 (VR: head pose from OpenXR).
// Visual: projected emitter pings with multi-layer glow, range rings, depth-faded.
//
// DSP: LUFS→field brightness, crest→edge sharpness, THD→positional jitter, phase→L/R coherence.
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define MAX_RADIUS 4.0
#define N_DEPTH 4

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
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

    // ── Camera — VR head pose or desktop above looking down ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.5;
        float camAng = a.section * 0.5 + a.stereoBal * 0.2 + Time * 0.02 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 1.5, 3.5, cos(camAng) * 1.5);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder: RADIAL profile ──
    SeParams params = seParams(SE_PROFILE_RADIAL);
    params.widthScale = 3.0;
    params.heightScale = 2.0;
    params.depthScale = 3.0;
    params.jitterAmt = 0.1 + thd * 0.2;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.04, float3(0.005, 0.008, 0.012), -1.5, 0.0, 0.0);
    world.gridIntensity = 0.02;
    world.ambientLevel = 0.003;
    world.ambientColor = float3(0.01, 0.02, 0.03);
    seApplyWorldFog(emit, world);

    // ── Background — dark sonar room + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.008;

    // ── Concentric range rings — one per band ──
    [unroll] for (int band = 0; band < SE_N_BANDS; band++) {
        float bt = float(band) / float(SE_N_BANDS - 1);
        float ringRadius = lerp(0.5, MAX_RADIUS, bt);

        // Project ring center (origin)
        float3 toCenter = float3(0, 0, 0) - cam.pos;
        float centerDepth = dot(toCenter, cam.fwd);
        if (centerDepth < 0.1) continue;
        float2 scrCenter = float2(dot(toCenter, cam.right) / (centerDepth * cam.fov),
                                  dot(toCenter, cam.up) / (centerDepth * cam.fov));

        float ringScreenR = ringRadius / (centerDepth * cam.fov);
        float ringDist = abs(length(p - scrCenter) - ringScreenR);

        float ringWidth = 0.002 + bands[band] * 0.005;
        float ringGlow = exp(-ringDist * ringDist / (ringWidth * ringWidth));

        float3 ringCol = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        ringCol = lerp(ringCol, lerp(a.brainCol, a.brainCol2, bt), 0.3);

        float ringInt = bands[band] * (1.0 + lufs * 0.2) * (0.5 + envelope * 0.5);
        ringInt *= smoothstep(0.02, 0.08, bands[band]);

        col += ringCol * ringGlow * ringInt * 0.12 * silence;

        // Cardinal dots
        [unroll] for (int card = 0; card < 4; card++) {
            float cardAng = float(card) * PI * 0.5;
            float3 dotPos = float3(cos(cardAng) * ringRadius, 0, sin(cardAng) * ringRadius);
            float3 toDot = dotPos - cam.pos;
            float dotDepth = dot(toDot, cam.fwd);
            if (dotDepth < 0.1) continue;
            float2 scrDot = float2(dot(toDot, cam.right) / (dotDepth * cam.fov),
                                   dot(toDot, cam.up) / (dotDepth * cam.fov));
            float dotDist = length(p - scrDot);
            float dotGlow = exp(-dotDist * dotDist * 200.0);
            col += ringCol * dotGlow * ringInt * 0.25 * silence;
        }
    }

    // ── Sonar pings — emitter positions with history scroll ──
    [loop] for (int n = 0; n < SE_NUM_OBJ; n++) {
        if (emit[n].active < 0.01) continue;
        if (emit[n].intensity < 0.05) continue;

        float bandFrac = float(emit[n].bandIdx) / 7.0;
        float baseRadius = lerp(0.5, MAX_RADIUS, bandFrac);

        [loop] for (int depth = 0; depth < N_DEPTH; depth++) {
            float timeOffset = float(depth) / float(N_DEPTH - 1);
            float decay = exp(-timeOffset * 2.5);

            // History scrolls outward from emitter position
            float3 pingPos = emit[n].worldPos * (1.0 + timeOffset * 0.3);
            pingPos.y = emit[n].intensity * decay * 1.2;

            // Project to screen
            float3 toPing = pingPos - cam.pos;
            float pingDepth = dot(toPing, cam.fwd);
            if (pingDepth < 0.1) continue;
            float2 scrPing = float2(dot(toPing, cam.right) / (pingDepth * cam.fov),
                                    dot(toPing, cam.up) / (pingDepth * cam.fov));
            float scrDist = length(p - scrPing);

            float pingSize = 0.015 + emit[n].intensity * decay * 0.04;
            pingSize /= max(pingDepth * 0.15, 0.3);
            float coreGlow = exp(-scrDist * scrDist / (pingSize * pingSize * 0.1));
            float midGlow = exp(-scrDist * scrDist / (pingSize * pingSize * 0.8));
            float haloGlow = exp(-scrDist * scrDist / (pingSize * pingSize * 5.0));

            float3 pingCol = emit[n].color;
            pingCol = lerp(pingCol, a.brainCol2, timeOffset * 0.6);

            float intensity = emit[n].intensity * decay * (1.0 + lufs * 0.2);
            float depthFade = exp(-pingDepth * world.fogDensity);

            col += float3(0.9, 0.95, 1.0) * coreGlow * intensity * depthFade * 0.25 * silence;
            col += pingCol * midGlow * intensity * depthFade * 0.15 * silence;
            col += pingCol * haloGlow * intensity * depthFade * 0.04 * silence;
        }
    }

    // ── Beat — omnidirectional sonar ping from center ──
    {
        float3 toCenter = float3(0, 0, 0) - cam.pos;
        float centerDepth = dot(toCenter, cam.fwd);
        if (centerDepth > 0.1) {
            float2 scrCenter = float2(dot(toCenter, cam.right) / (centerDepth * cam.fov),
                                      dot(toCenter, cam.up) / (centerDepth * cam.fov));
            float centerScreenR = 1.0 / (centerDepth * cam.fov);
            float pingRadius = a.beatPhase * centerScreenR * 0.8;
            float pingDist = abs(length(p - scrCenter) - pingRadius);
            float pingWidth = 0.005;
            float pingGlow = exp(-pingDist * pingDist / (pingWidth * pingWidth));
            col += a.brainCol * pingGlow * beatPulse * exp(-a.beatPhase * 3.0) * 0.1 * silence;
            float ping2Radius = pingRadius + a.stereoDiff * centerScreenR * 0.1;
            float ping2Dist = abs(length(p - scrCenter) - ping2Radius);
            float ping2Glow = exp(-ping2Dist * ping2Dist / (pingWidth * pingWidth));
            col += a.brainCol2 * ping2Glow * beatPulse * exp(-a.beatPhase * 3.0) * 0.05 * silence;
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

    // ── Kick — central eruption ──
    col += float3(1.0, 0.5, 0.1) * exp(-r * r * 3.0) * kickSurge * 0.08 * silence;

    // ── Phase coherence indicator — center line ──
    if (phaseCoh > 0.5) {
        float phaseLine = exp(-p.x * p.x * 30.0) * (phaseCoh - 0.5) * 0.03;
        col += float3(0.3, 0.5, 0.4) * phaseLine * silence;
    }

    // ── Transient — surface disruption ──
    float splash = transientAmt * hash21(p * 50.0 + Time * 30.0) * 0.03;
    col += a.brainCol3 * splash * silence;

    // ── Mode-specific overlays — subtle ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;
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
