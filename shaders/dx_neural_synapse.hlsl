// Mode 38: Neural Synapse Storm — immersive 3D neural network
// Adopted to Spatial Pipeline: 48 SpEmitters as neurons with hemisphere split.
// L/R emitters = left/right hemisphere. Phase coherence = hemisphere synchronization.
// Beat = action potential cascade. Kick = neurotransmitter flood.
// Transient = synaptic firing burst. Envelope = baseline neural activity.
// DSP: LUFS→neuron brightness, crest→synapse sharpness, THD→neural noise, phase→hemisphere sync.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"
#include "include/spatial_pipeline.hlsl"

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — inside the brain, slowly rotating ──
    float camAng = a.section * 0.5 + a.stereoBal * 0.2 + Time * 0.02 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 1.5, 0.5 + a.stereoDiff * 0.1, cos(camAng) * 1.5);
    SpCamera cam = spCamera(camPos, float3(0, 0, 0), 0.75);

    // ── Background — dark neural space ──
    float3 col = float3(0.002, 0.001, 0.006) * silence;
    col += starfield(uv, a) * 0.005;

    // ── Compute 48 neural emitters — hemisphere split ──
    // 8 bands × 3 sub-freq × L/R = 48 (L=left hemisphere, R=right hemisphere)
    SpEmitter emit[SP_NUM_OBJ];
    spComputeEmitters(emit, bands, a, cam, lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // Override positions for neural hemisphere layout
    [unroll] for (int n = 0; n < SP_NUM_OBJ; n++) {
        int band = n / 6;
        int sub = n % 6;
        int hemi = sub % 2;  // 0=left, 1=right
        float bt = float(band) / float(SP_N_BANDS - 1);

        float hemiSign = (hemi == 0) ? -1.0 : 1.0;
        float xBase = hemiSign * (0.8 + a.stereoWid * 0.4);
        float ang = float(sub / 2) * PI + float(band) * 0.5 + a.stereoBal * 0.3;
        float radius = 0.5 + float(band) * 0.3;
        float yLevel = lerp(-1.5, 1.5, bt);

        emit[n].worldPos = float3(
            xBase + cos(ang) * radius * 0.3,
            yLevel + sin(float(n) * 2.3) * 0.3,
            sin(ang) * radius
        );
        emit[n].side = hemi;
        emit[n].depth = spDepth(emit[n].worldPos, cam);
        emit[n].screenPos = spProject(emit[n].worldPos, cam);
        emit[n].screenSize = (0.015 + emit[n].intensity * 0.04) / max(emit[n].depth * 0.15, 0.3) * 3.0;

        // Hemisphere color tint
        if (hemi == 0) emit[n].color = lerp(emit[n].color, float3(1.0, 0.7, 0.5), 0.1);
        else emit[n].color = lerp(emit[n].color, float3(0.5, 0.7, 1.0), 0.1);
    }

    // ── Synapses — culled connection links ──
    [loop] for (int f = 0; f < SP_NUM_OBJ; f++) {
        if (emit[f].active < 0.01 || emit[f].depth < 0.1) continue;
        [loop] for (int g = f + 1; g < SP_NUM_OBJ; g++) {
            if (emit[g].active < 0.01 || emit[g].depth < 0.1) continue;

            float3 dist3 = emit[f].worldPos - emit[g].worldPos;
            float synDist3 = length(dist3);
            if (synDist3 > 1.5) continue;

            float strength = 1.0 / (synDist3 + 0.1);
            if (emit[f].side != emit[g].side) strength *= phaseCoh;

            // Culled line distance
            float2 ab = emit[g].screenPos - emit[f].screenPos;
            float t2 = saturate(dot(p - emit[f].screenPos, ab) / max(dot(ab, ab), 0.0001));
            float2 closest = emit[f].screenPos + ab * t2;
            float2 lineDiff = p - closest;
            float lineDist2 = dot(lineDiff, lineDiff);
            if (lineDist2 > 0.015) continue;

            float lineDist = sqrt(lineDist2);
            float axonWidth = 0.002 + strength * 0.003;
            float axonGlow = exp(-lineDist * lineDist / (axonWidth * axonWidth));

            float3 synCol = lerp(emit[f].color, emit[g].color, 0.5);
            float avgDepth = (emit[f].depth + emit[g].depth) * 0.5;
            float depthFade = exp(-avgDepth * 0.08);

            col += synCol * axonGlow * strength * depthFade * 0.15 * silence;

            // Signal pulse traveling along axon
            float2 sigPoint = lerp(emit[f].screenPos, emit[g].screenPos, a.beatPhase);
            float sigDist = length(p - sigPoint);
            col += float3(0.9, 0.95, 1.0) * exp(-sigDist * sigDist * 80.0) * beatPulse * strength * depthFade * 0.5 * silence;

            // Kick — neurotransmitter flood
            col += synCol * axonGlow * kickSurge * strength * depthFade * 0.3 * silence;
        }
    }

    // ── Neurons — fused glow via spEmitGlow ──
    [loop] for (int m = 0; m < SP_NUM_OBJ; m++) {
        if (emit[m].active < 0.01 || emit[m].depth < 0.1) continue;
        float depthFade = exp(-emit[m].depth * 0.08);

        // Firing neuron — white-hot flash on beat
        float firing = beatPulse * emit[m].active * exp(-a.beatPhase * 4.0);
        float savedInt = emit[m].intensity;
        emit[m].intensity = savedInt + firing * 2.0;

        col += spEmitGlow(p, emit[m], lufs, crest, beatPulse, a.beatPhase,
                          kickSurge, transientAmt, silence) * depthFade;

        emit[m].intensity = savedInt;

        // Dendrite halo — THD noise
        float dendNoise = thd * hash21(emit[m].screenPos * 50.0 + Time * 10.0) * 0.02;
        col += emit[m].color * dendNoise * depthFade * silence;
    }

    // ── Hemisphere divider — phase coherence indicator ──
    if (phaseCoh > 0.6) {
        float divider = exp(-p.x * p.x * 50.0) * (phaseCoh - 0.6) * 0.03;
        col += float3(0.4, 0.6, 0.5) * divider * silence;
    }

    // ── Mode-specific overlays ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.025 * silence;
    col += a.brainCol3 * kickSurge * 0.05 * exp(-r * r * 5.0) * silence;
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.025 * silence;
    col += a.brainCol3 * a.colorPulse * 0.02 * silence;
    col += a.brainCol2 * a.energy * 0.015 * silence;
    col += a.brainCol * a.punch * 0.015 * silence;
    col += a.brainCol * a.beatAnt * 0.01 * exp(-r * 2.0) * silence;

    col *= (0.3 + a.gated * 0.7);
    col += standardOverlays(p, r, a) * 0.02;

    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;
    return float4(col, 1.0);
}
