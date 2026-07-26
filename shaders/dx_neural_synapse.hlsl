// Mode 38: Neural Synapse Storm — immersive 3D neural network
// 16 neurons (8 bands × 2 hemispheres) with synapse connections.
// L/R emitters = left/right hemisphere. Phase coherence = hemisphere sync.
// Beat = action potential cascade. Kick = neurotransmitter flood.
// Transient = synaptic firing burst. Envelope = baseline neural activity.
// DSP: LUFS→neuron brightness, crest→synapse sharpness, THD→neural noise, phase→sync.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_NEURONS 16

struct Neuron {
    float3 worldPos;
    float2 screenPos;
    float depth;
    float screenSize;
    float intensity;
    float active;
    int hemi;
    int band;
    float3 color;
};

float2 projectSimple(float3 worldPos, float3 camPos, float3 fwd, float3 right, float3 up, float fov)
{
    float3 toObj = worldPos - camPos;
    float depth = dot(toObj, fwd);
    if (depth < 0.01) depth = 0.01;
    return float2(dot(toObj, right) / (depth * fov), dot(toObj, up) / (depth * fov));
}

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
    float dspBands[8] = { DspBand0, DspBand1, DspBand2, DspBand3, DspBand4, DspBand5, DspBand6, DspBand7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — inside the brain, stable ──
    float FOV = 0.75;
    float camAng = a.section * 0.5 + a.stereoBal * 0.2;
    float3 camPos = float3(sin(camAng) * 1.5, 0.5 + a.stereoDiff * 0.1, cos(camAng) * 1.5);
    float3 camTarget = float3(0, 0, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Background — dark neural space ──
    float3 col = float3(0.002, 0.001, 0.006) * silence;
    col += starfield(uv, a) * 0.005;

    // ── Compute 16 neurons — 8 bands × 2 hemispheres ──
    Neuron neurons[N_NEURONS];
    int activeIdx[N_NEURONS];
    int nActive = 0;

    [unroll] for (int bi = 0; bi < 8; bi++) {
        float bt = float(bi) / 7.0;
        float rawEnergy = bands[bi] + dspBands[bi] * 0.12;
        float energy = (bi < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
        float gate = smoothstep(0.02, 0.08, rawEnergy);

        // Enrich with brain dynamics
        float amp = energy * gate;
        amp += a.beatAnt * (0.5 + bt * 0.5) * 0.15;
        amp += a.tempoPulse * lerp(0.1, 0.05, bt);
        amp += a.punch * smoothstep(2.0, 0.0, float(bi)) * 0.3;
        amp += a.glow * 0.05;
        amp += a.dynamic * lerp(0.08, 0.03, bt);
        amp += sin(a.phraseBeat * PI * 2.0 + float(bi) * 0.3) * 0.1 + 0.1;
        amp *= (1.0 - a.calmMode * 0.5);
        amp *= (0.7 + a.brightness * 0.3) * a.barScale;
        amp *= (1.0 + lufs * 0.2);

        float3 bandCol = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        bandCol = lerp(bandCol, lerp(a.brainCol, a.brainCol2, bt), 0.3);

        [unroll] for (int hi = 0; hi < 2; hi++) {
            int idx = bi * 2 + hi;
            float hemiSign = (hi == 0) ? -1.0 : 1.0;
            float xBase = hemiSign * (0.8 + a.stereoWid * 0.4);
            float ang = float(bi) * 0.7 + a.stereoBal * 0.3 + (hi == 0 ? 0.0 : PI);
            float radius = 0.5 + float(bi) * 0.2;
            float yLevel = lerp(-1.2, 1.2, bt);

            neurons[idx].worldPos = float3(
                xBase + cos(ang) * radius * 0.3,
                yLevel + sin(float(idx) * 2.3) * 0.3,
                sin(ang) * radius
            );
            neurons[idx].depth = dot(neurons[idx].worldPos - camPos, fwd);
            neurons[idx].screenPos = projectSimple(neurons[idx].worldPos, camPos, fwd, right, up, FOV);
            neurons[idx].screenSize = (0.015 + amp * 0.04) / max(neurons[idx].depth * 0.15, 0.3) * 3.0;
            neurons[idx].intensity = clamp(amp, 0.0, 1.5);
            neurons[idx].active = gate;
            neurons[idx].hemi = hi;
            neurons[idx].band = bi;

            // Hemisphere color tint
            float3 nCol = bandCol;
            if (hi == 0) nCol = lerp(nCol, float3(1.0, 0.7, 0.5), 0.15);
            else nCol = lerp(nCol, float3(0.5, 0.7, 1.0), 0.15);
            neurons[idx].color = nCol;

            if (gate >= 0.01 && neurons[idx].depth >= 0.1) {
                activeIdx[nActive] = idx;
                nActive++;
            }
        }
    }

    // ── Synapses — max 2 connections per neuron ──
    [loop] for (int f = 0; f < nActive; f++) {
        int fi = activeIdx[f];

        float2 fpDiff = p - neurons[fi].screenPos;
        float fpDist2 = dot(fpDiff, fpDiff);
        float fpCull = neurons[fi].screenSize * neurons[fi].screenSize * 100.0 + 0.15;
        if (fpDist2 > fpCull) continue;

        int connections = 0;
        [loop] for (int g = f + 1; g < nActive && connections < 2; g++) {
            int gi = activeIdx[g];

            float2 ab = neurons[gi].screenPos - neurons[fi].screenPos;
            float abLen2 = dot(ab, ab);
            if (abLen2 > 0.15) continue;

            float3 dist3 = neurons[fi].worldPos - neurons[gi].worldPos;
            float synDist3 = length(dist3);
            if (synDist3 > 1.8) continue;

            float strength = 1.0 / (synDist3 + 0.1);
            if (neurons[fi].hemi != neurons[gi].hemi) strength *= phaseCoh;

            float t2 = saturate(dot(p - neurons[fi].screenPos, ab) / max(abLen2, 0.0001));
            float2 closest = neurons[fi].screenPos + ab * t2;
            float2 lineDiff = p - closest;
            float lineDist2 = dot(lineDiff, lineDiff);
            if (lineDist2 > 0.01) continue;

            connections++;

            float lineDist = sqrt(lineDist2);
            float axonWidth = 0.002 + strength * 0.003;
            float axonGlow = exp(-lineDist * lineDist / (axonWidth * axonWidth));

            float3 synCol = lerp(neurons[fi].color, neurons[gi].color, 0.5);
            float avgDepth = (neurons[fi].depth + neurons[gi].depth) * 0.5;
            float depthFade = exp(-avgDepth * 0.08);

            col += synCol * axonGlow * strength * depthFade * 0.15 * silence;

            // Signal pulse traveling along axon
            float2 sigPoint = lerp(neurons[fi].screenPos, neurons[gi].screenPos, a.beatPhase);
            float sigDist = length(p - sigPoint);
            col += float3(0.9, 0.95, 1.0) * exp(-sigDist * sigDist * 80.0) * beatPulse * strength * depthFade * 0.5 * silence;

            // Kick — neurotransmitter flood
            col += synCol * axonGlow * kickSurge * strength * depthFade * 0.3 * silence;
        }
    }

    // ── Neurons — glowing dots ──
    [loop] for (int m = 0; m < N_NEURONS; m++) {
        if (neurons[m].active < 0.01 || neurons[m].depth < 0.1) continue;
        float depthFade = exp(-neurons[m].depth * 0.08);

        // Firing neuron — white-hot flash on beat
        float firing = beatPulse * neurons[m].active * exp(-a.beatPhase * 4.0);
        float intensity = neurons[m].intensity + firing * 2.0;

        float scrDist = length(p - neurons[m].screenPos);
        float sz = neurons[m].screenSize;
        float coreGlow = exp(-scrDist * scrDist / (sz * sz * 0.1));
        float midGlow = exp(-scrDist * scrDist / (sz * sz * 0.8));
        float haloGlow = exp(-scrDist * scrDist / (sz * sz * 5.0));

        col += float3(0.9, 0.95, 1.0) * coreGlow * intensity * depthFade * 0.4 * silence;
        col += neurons[m].color * midGlow * intensity * depthFade * 0.3 * silence;
        col += neurons[m].color * haloGlow * intensity * depthFade * 0.08 * silence;

        // Dendrite halo — THD noise
        float dendNoise = thd * hash21(neurons[m].screenPos * 50.0 + Time * 10.0) * 0.02;
        col += neurons[m].color * dendNoise * depthFade * silence;
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
