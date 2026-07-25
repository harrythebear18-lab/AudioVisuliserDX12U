// Mode 37: Cosmic Web — 3D dark matter filament network
// Adopted to Spatial Pipeline architecture: 48 SpEmitters on golden-ratio sphere.
// Bass = node mass/luminosity, mids = filament connectivity, highs = micro-filaments/shimmer.
// Stereo balance = web rotation, stereo width = filament stretch.
// Phase correlation = filament alignment/coherence. Beat = cosmic shockwave.
// Kick = supernova. Transient = gravitational perturbation.
// DSP: LUFS→node emission, crest→filament sharpness, THD→peculiar velocities, phase→alignment.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"
#include "include/spatial_pipeline.hlsl"

#define PHI 1.618

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

    // ── Camera — drifting through the web, VR-friendly 360° ──
    float camAng = a.section * 0.8 + a.stereoBal * 0.2 + Time * 0.03 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 4.0, 1.0 + a.stereoDiff * 0.15, cos(camAng) * 4.0);
    SpCamera cam = spCamera(camPos, float3(0, 0, 0), 0.7);

    // ── Background — deep cosmic void with CMB ──
    float3 col = float3(0.001, 0.001, 0.005) * silence;
    col += starfield(uv, a) * 0.04;
    col += godRays(p, r, a) * 0.04 * silence;

    float cmb = fbm2_4(uv * 8.0) * 0.005 * (1.0 + lufs * 0.1);
    col += float3(0.1, 0.05, 0.15) * cmb * silence;

    // ── Compute 48 spatial emitters on golden-ratio sphere ──
    SpEmitter emit[SP_NUM_OBJ];
    float stretchX = 1.0 + a.stereoWid * 0.4;

    [unroll] for (int n = 0; n < SP_NUM_OBJ; n++) {
        int band = n / 6;  // 8 bands × 6 nodes per band
        int sub = n % 6;
        float bt = float(band) / float(SP_N_BANDS - 1);

        float rawEnergy = bands[band];
        float energy = (band < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
        float gate = smoothstep(0.02, 0.08, rawEnergy);

        // Spectrum L/R
        float freqU = spBandFreq[band];
        float lE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.166), 0).r;
        float rE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.833), 0).r;
        float stereoEnergy = max(lE, rE);
        energy = max(energy, stereoEnergy * 0.5);
        gate = max(gate, smoothstep(0.02, 0.08, stereoEnergy));
        float panMod = (lE - rE) * 0.5;

        // Golden ratio 3D distribution
        float t = float(n) / float(SP_NUM_OBJ);
        float phi = acos(1.0 - 2.0 * t);
        float theta = float(n) * PHI * PI * 2.0 + a.stereoBal * 0.4 + panMod * 0.3;
        float radius = 2.0 + sin(float(n) * 1.7) * 0.5;

        emit[n].worldPos = float3(
            radius * sin(phi) * cos(theta) * stretchX,
            radius * cos(phi),
            radius * sin(phi) * sin(theta)
        );

        // Energy with beat/transient/envelope
        float h = energy * (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
        h += transientAmt * lerp(0.05, 0.2, bt) * gate;
        h += envelope * lerp(0.08, 0.03, bt) * gate;
        h += a.section * 0.05 * gate;
        h += (band < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;
        h *= gate;

        emit[n].intensity = clamp(h, 0.0, 1.5);
        emit[n].active = gate;
        emit[n].bandIdx = band;
        emit[n].side = sub % 2;
        emit[n].subIdx = sub / 2;
        emit[n].wavePhase = Time * (1.5 + bt * 6.0) + float(n) * 0.3;

        float3 c = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        c = lerp(c, lerp(a.brainCol, a.brainCol2, bt), 0.3);
        emit[n].color = c;

        emit[n].depth = spDepth(emit[n].worldPos, cam);
        emit[n].screenPos = spProject(emit[n].worldPos, cam);
        float sz = 0.02 + emit[n].intensity * 0.06;
        if (n < 24) sz *= 1.5;
        emit[n].screenSize = sz / max(emit[n].depth * 0.15, 0.3) * 3.0;
    }

    // ── Filaments — connect nearby emitters (culled) ──
    [loop] for (int f = 0; f < SP_NUM_OBJ; f++) {
        if (emit[f].active < 0.01 || emit[f].depth < 0.1) continue;
        [loop] for (int g = f + 1; g < SP_NUM_OBJ; g++) {
            if (emit[g].active < 0.01 || emit[g].depth < 0.1) continue;

            float3 a_pos = emit[f].worldPos;
            float3 b_pos = emit[g].worldPos;
            float filLen = length(a_pos - b_pos);
            if (filLen > 2.5) continue;

            float filIntensity = emit[f].intensity * emit[g].intensity / (filLen * 0.5 + 0.1);
            filIntensity *= lerp(0.5, 1.3, phaseCoh);
            filIntensity *= (1.0 + lufs * 0.15);
            filIntensity *= (0.8 + a.stereoWid * 0.3);

            // Culled line distance
            float2 ab = emit[g].screenPos - emit[f].screenPos;
            float t2 = saturate(dot(p - emit[f].screenPos, ab) / max(dot(ab, ab), 0.0001));
            float2 closest = emit[f].screenPos + ab * t2;
            float2 lineDiff = p - closest;
            float lineDist2 = dot(lineDiff, lineDiff);
            if (lineDist2 > 0.02) continue;

            float lineDist = sqrt(lineDist2);
            float filWidth = 0.003 + filIntensity * 0.01;
            float coreGlow = exp(-lineDist * lineDist / (filWidth * filWidth * 0.15));
            float haloGlow = exp(-lineDist * lineDist / (filWidth * filWidth * 6.0));

            float3 filCol = lerp(emit[f].color, emit[g].color, 0.5);
            float avgDepth = (emit[f].depth + emit[g].depth) * 0.5;
            float depthFade = exp(-avgDepth * 0.1);

            col += filCol * coreGlow * filIntensity * depthFade * 0.8 * silence;
            col += filCol * haloGlow * filIntensity * depthFade * 0.15 * silence;
            col += filCol * beatPulse * exp(-lineDist * lineDist / (filWidth * filWidth)) * exp(-a.beatPhase * 4.0) * 0.15 * silence;
        }
    }

    // ── Nodes — fused glow via spEmitGlow with distance culling ──
    [loop] for (int m = 0; m < SP_NUM_OBJ; m++) {
        if (emit[m].active < 0.01 || emit[m].depth < 0.1) continue;
        float depthFade = exp(-emit[m].depth * 0.1);
        col += spEmitGlow(p, emit[m], lufs, crest, beatPulse, a.beatPhase,
                          kickSurge, transientAmt, silence) * depthFade;

        // Supernova event at selected node
        int supernovaNode = int(a.beatPhase * float(SP_NUM_OBJ)) % SP_NUM_OBJ;
        if (m == supernovaNode && kickSurge > 0.1) {
            float scrDist = length(p - emit[m].screenPos);
            float sz = emit[m].screenSize;
            float shellR = a.beatPhase * 0.4;
            float shell = exp(-abs(scrDist - shellR) * 12.0) * kickSurge * 0.5;
            col += emit[m].color * shell * silence;
            col += float3(1.0, 0.9, 0.7) * exp(-scrDist * scrDist / (sz * sz * 0.08)) * kickSurge * 3.0 * silence;
        }
    }

    // ── Mode-specific overlays ──
    float perturb = transientAmt * fbm2_4(p * 10.0 + Time * 5.0) * 0.04;
    col += a.brainCol3 * perturb * silence;

    float shimmer = (bands[6] + bands[7]) * hash21(p * 100.0 + Time * 20.0) * 0.015;
    col += float3(0.7, 0.8, 1.0) * shimmer * silence;

    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.025 * silence;
    col += a.brainCol2 * kickSurge * 0.05 * exp(-r * r * 5.0) * silence;
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.025 * silence;
    col += a.brainCol3 * a.colorPulse * 0.02 * silence;
    col += a.brainCol2 * a.energy * 0.015 * silence;
    col += a.brainCol * a.punch * 0.015 * silence;
    col += a.brainCol * a.beatAnt * 0.01 * exp(-r * 2.0) * silence;

    col *= (0.3 + a.gated * 0.7);
    col += standardOverlays(p, r, a) * 0.02;

    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.14) col *= 1.14 / maxC;

    col *= silence;
    return float4(col, 1.0);
}
