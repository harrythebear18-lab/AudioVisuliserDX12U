// HUD 38: Resonance Field — 4D wave interference from psychoacoustic sources
// VR Layer mode. Sound waves propagate from 16 psychoacoustic 3D source positions.
// Spherical wavefronts from each source interfere in screen space.
// Constructive = bright antinodes, destructive = dark nodes.
//
// Audio mapping:
//   b0-b1 Sub/Bass    → large slow wavefronts, low elevation, close, high amplitude
//   b2-b3 Low-mid/Mid → medium wavefronts, mid elevation, mid distance
//   b4-b5 HMid/Pres   → smaller wavefronts, high elevation, far
//   b6-b7 Brill/Air   → fine ripples, very high, far, atmospheric
//   Stereo L/R        → azimuth positioning (HRTF-inspired)
//   Beat              → coherent phase compression
//   Kick              → bass amplitude burst
//   Transient         → wavefront rupture (scattering)
//
// DSP additive: LUFS→density, crest→sharpness, THD→turbulence, phase→L/R coherence.
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_SRC 16  // 8 bands × 2 sides

struct WaveSrc {
    float2 screenPos;
    float depth;
    float intensity;
    float active;
    float bandIdx;
    float3 color;
    float screenSize;
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

    // ── Camera — listener inside the field, stable ──
    float FOV = 1.2;
    float camAng = a.section * 0.3 + a.stereoBal * 0.2;
    float3 camPos = float3(sin(camAng) * 2.0, 1.2 + a.stereoDiff * 0.1, cos(camAng) * 3.5);
    float3 camTarget = float3(0, 0, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Compute 16 wave sources — 8 bands × 2 sides ──
    WaveSrc src[N_SRC];
    [unroll] for (int bi = 0; bi < 8; bi++) {
        float bt = float(bi) / 7.0;
        float rawEnergy = bands[bi] + dspBands[bi] * 0.12;
        float energy = (bi < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
        float gate = smoothstep(0.02, 0.08, rawEnergy);

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
        if (bi <= 1) amp += kickSurge * 0.4;

        float3 bandCol = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        bandCol = lerp(bandCol, lerp(a.brainCol, a.brainCol2, bt), 0.3);

        [unroll] for (int si = 0; si < 2; si++) {
            int idx = bi * 2 + si;
            float sideSign = (si == 0) ? -1.0 : 1.0;

            // 3D position — azimuth from stereo, elevation from frequency
            float azimuth = sideSign * (0.3 + a.stereoWid * 0.3) + a.stereoBal * 0.2;
            float elevation = lerp(-0.3, 0.8, bt);
            float dist = lerp(2.0, 5.0, bt);

            float3 worldPos = float3(
                sin(azimuth) * dist,
                elevation * 2.0,
                cos(azimuth) * dist
            );

            src[idx].depth = dot(worldPos - camPos, fwd);
            src[idx].screenPos = projectSimple(worldPos, camPos, fwd, right, up, FOV);
            src[idx].intensity = clamp(amp, 0.0, 1.5);
            src[idx].active = gate;
            src[idx].bandIdx = float(bi);
            src[idx].color = bandCol;
            src[idx].screenSize = (0.015 + amp * 0.04) / max(src[idx].depth * 0.15, 0.3) * 3.0;
        }
    }

    // ── Background ──
    float3 col = float3(0.002, 0.002, 0.006) * silence;
    col += starfield(uv, a) * 0.005;

    // ── Wave interference field — sum waves from all active sources ──
    float waveTime = Time * 1.2 + a.beatPhase * PI * 2.0;
    float beatCompress = 1.0 - beatPulse * 0.12;

    float fieldVal = 0.0;
    float3 fieldCol = float3(0, 0, 0);
    float weightSum = 0.0;

    [loop] for (int j = 0; j < N_SRC; j++) {
        if (src[j].active < 0.01) continue;

        float2 diff = p - src[j].screenPos;
        float scrDist2 = dot(diff, diff);

        float bt = src[j].bandIdx / 7.0;
        float influenceR = lerp(0.8, 0.3, bt) * (0.5 + src[j].intensity * 0.8);
        float inflR2 = influenceR * influenceR;
        if (scrDist2 > inflR2) continue;

        float scrDist = sqrt(scrDist2);
        float waveFreq = lerp(2.0, 10.0, bt) * beatCompress;
        float amp = src[j].intensity;
        float depthFog = exp(-src[j].depth * 0.06);
        float depthPhase = src[j].depth * 1.5;
        float wave = sin(scrDist * waveFreq * 10.0 - waveTime + depthPhase + float(j) * 0.1) * amp;
        float falloff = exp(-scrDist2 / (inflR2 * 0.3));
        wave *= (1.0 + crest * 0.3) * falloff * depthFog;

        fieldVal += wave;
        fieldCol += src[j].color * abs(wave);
        weightSum += abs(wave);
    }

    if (weightSum > 0.001) fieldCol /= weightSum;

    float density = abs(fieldVal) * 0.12;
    density += thd * hash11(r * 17.3 + Time * 3.0) * density * 0.06;
    density += transientAmt * hash21(p * 30.0 + Time * 8.0) * 0.015;
    density += envelope * 0.004;

    float gate = smoothstep(0.002, 0.012, density);
    float decayGate = max(envelope, a.gated * 0.3);
    density *= gate * decayGate;

    float3 emission = fieldCol * density * (1.0 + lufs * 0.15);
    emission *= (1.0 + beatPulse * 0.08);
    col += emission * silence;

    // ── Source cores — bright points at source positions ──
    [loop] for (int k = 0; k < N_SRC; k++) {
        if (src[k].active < 0.01) continue;
        float2 diff = p - src[k].screenPos;
        float d2 = dot(diff, diff);
        float s = src[k].screenSize;
        if (d2 > s * s * 25.0) continue;

        float depthFog = exp(-src[k].depth * 0.06);
        float core = exp(-d2 / (s * s * 0.5)) * src[k].intensity * depthFog;
        col += src[k].color * core * 0.15 * silence;
    }

    // ── Listener focal point ──
    float2 listenerPos = projectSimple(float3(0, 0, 0), camPos, fwd, right, up, FOV);
    float listenDist = length(p - listenerPos);
    float focalDecay = max(envelope, a.gated * 0.25);
    col += a.brainCol * exp(-listenDist * listenDist * 120.0) * 0.04 * focalDecay * silence;
    col += a.brainCol2 * exp(-abs(listenDist - a.beatPhase * 0.1) * 35.0) * beatPulse * 0.04 * focalDecay * silence;

    // ── Mode-specific overlays ──
    col += a.brainCol3 * kickSurge * 0.012 * exp(-r * r * 5.0) * silence;
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.008 * silence;
    col += a.brainCol3 * a.colorPulse * 0.006 * silence;
    col += a.brainCol2 * a.energy * 0.005 * silence;
    col += a.brainCol * a.beatAnt * 0.004 * exp(-r * 2.0) * silence;

    col *= (0.3 + a.gated * 0.7);
    col += standardOverlays(p, r, a) * 0.008;

    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;
    return float4(col, 1.0);
}
