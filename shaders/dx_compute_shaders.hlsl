// Mode 23: Acoustic Ferrofluid Pool — SDF heightfield with metallic shading
//
// A dark reflective ferrofluid surface with spikes rising from it.
// 24 spikes (3 per band) drive a heightfield SDF. Between spikes the surface
// is smooth and dark — that's the fluid. Spikes are sharp cones with
// blackbody glow at tips. Metallic Fresnel reflections, specular highlights.
// Bass = tall central spikes, mids = medium, highs = fine surface texture.
// Beat = expanding ripple rings across surface, kick = central eruption,
// transient = surface jitter. Stereo = asymmetric spike positions.
// DSP: LUFS→surface level, crest→spike sharpness, THD→roughness, phase→symmetry.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define N_SPIKES 24
#define MARCH_STEPS 64

struct Spike {
    float2 pos;
    float height;
    float sharpness;
    float energy;
};

// 24 spikes — 3 per band, well-separated
void computeSpikes(out Spike spikes[N_SPIKES], float bands[8], float dspBands[8],
                   float kickSurge, float beatPulse, float stereoBal, float crest, float thd,
                   float transient, float envelope, float section)
{
    [unroll] for (int n = 0; n < N_SPIKES; n++)
    {
        int band = n / 3;  // 3 spikes per band, sequential assignment
        int sub = n % 3;
        float bt = float(band) / float(N_COMP - 1);

        // Each band gets a distinct radial zone — no overlap between bands
        // b0: 0.3-0.6, b1: 0.7-1.0, b2: 1.1-1.4, b3: 1.5-1.8, b4: 1.9-2.2,
        // b5: 2.3-2.6, b6: 2.7-3.0, b7: 3.1-3.4
        float ringInner = 0.3 + float(band) * 0.4;
        float ringOuter = ringInner + 0.3;
        // 3 spikes per band spread across their ring at 120° + band offset
        float ang = float(sub) * (PI * 2.0 / 3.0) + float(band) * 0.7 + stereoBal * 0.4;
        float rad = lerp(ringInner, ringOuter, 0.5);
        spikes[n].pos = float2(cos(ang) * rad, sin(ang) * rad);

        float rawEnergy = bands[band] + dspBands[band] * 0.12;
        // Compressor on lower bands (b0-b3): pow tames peaks
        // Highs (b4-b7) stay linear
        float energy = (band < 4) ? pow(rawEnergy, 0.5) : rawEnergy;

        // Noise gate — spikes flat when band is quiet
        float gate = smoothstep(0.02, 0.08, rawEnergy);

        // Height — staggered multipliers per band for visual variety
        // Bass: moderate, mids: responsive, highs: sharp
        float bandScale = lerp(1.0, 0.8, bt);  // bass slightly taller
        float h = (band < 4) ? energy * lerp(1.2, 0.12, bt) : energy * energy * lerp(1.2, 0.12, bt);
        h += (band < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;
        // Beat breathing — staggered: bass less, highs more
        h *= (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
        // Additives gated and staggered — lower values, more for highs
        h += transient * lerp(0.05, 0.2, bt) * gate;
        h += envelope * lerp(0.08, 0.03, bt) * gate;
        h += section * 0.05 * gate;
        // Apply noise gate to overall height
        h *= gate;
        spikes[n].height = clamp(h, 0.0, 1.5);

        // Very sharp falloff — keeps spikes thin and separated
        float sharp = lerp(15.0, 40.0, bt) + crest * 10.0 - thd * 3.0;
        spikes[n].sharpness = max(sharp, 8.0);
        spikes[n].energy = energy;
    }
}

// Heightfield — smooth surface + spikes + ripples
float poolHeight(float2 xz, Spike spikes[N_SPIKES], float poolR,
                 float beatPulse, float beatPhase, float transient, float envelope,
                 float kickSurge, float lufs, float silence)
{
    float r = length(xz);
    if (r > poolR) return -1.0;

    // Base surface level — flat, LUFS additive, gated by silence
    float surface = (0.02 + lufs * 0.02) * silence;

    // Envelope breathing — very subtle
    surface += envelope * 0.015 * sin(beatPhase * PI * 2.0) * silence;

    // Spikes — sharp cones rising from surface
    [unroll] for (int n = 0; n < N_SPIKES; n++)
    {
        if (spikes[n].height < 0.01) continue;

        float d = length(xz - spikes[n].pos);
        float spikeH = spikes[n].height;
        float sharp = spikes[n].sharpness;

        // Cone profile — exp falloff, sharp
        float profile = spikeH * exp(-d * d * sharp);
        surface += profile;
    }

    // Beat ripple rings — staggered lower
    float ringPhase = beatPhase * PI * 2.0;
    surface += beatPulse * 0.04 * sin(r * 6.0 - ringPhase * 3.0) * smoothstep(poolR, 0.0, r) * silence;

    // Kick — central bulge, lower
    surface += kickSurge * 0.06 * exp(-r * r * 3.0) * silence;

    // Transient — surface jitter, lower
    if (transient > 0.02)
        surface += transient * 0.025 * sin(xz.x * 25.0 + xz.y * 22.0 + beatPhase * 30.0) * smoothstep(poolR, 0.0, r) * silence;

    // Envelope — global surface swell, lower
    surface += envelope * 0.012 * smoothstep(poolR, 0.0, r) * silence;

    // Pool edge — curve down into basin
    surface -= smoothstep(poolR * 0.6, poolR, r) * 0.2;

    return surface;
}

// SDF — distance to heightfield surface
float poolSDF(float3 p, Spike spikes[N_SPIKES], float poolR,
              float beatPulse, float beatPhase, float transient, float envelope,
              float kickSurge, float lufs, float silence)
{
    float h = poolHeight(p.xz, spikes, poolR, beatPulse, beatPhase, transient, envelope, kickSurge, lufs, silence);
    return p.y - h;
}

// Normal via finite differences
float3 poolNormal(float3 p, Spike spikes[N_SPIKES], float poolR,
                  float beatPulse, float beatPhase, float transient, float envelope,
                  float kickSurge, float lufs, float silence)
{
    float eps = 0.008;
    return normalize(float3(
        poolSDF(p + float3(eps, 0, 0), spikes, poolR, beatPulse, beatPhase, transient, envelope, kickSurge, lufs, silence)
          - poolSDF(p - float3(eps, 0, 0), spikes, poolR, beatPulse, beatPhase, transient, envelope, kickSurge, lufs, silence),
        2.0 * eps,
        poolSDF(p + float3(0, 0, eps), spikes, poolR, beatPulse, beatPhase, transient, envelope, kickSurge, lufs, silence)
          - poolSDF(p - float3(0, 0, eps), spikes, poolR, beatPulse, beatPhase, transient, envelope, kickSurge, lufs, silence)
    ));
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();

    // ── Background — dark room ──
    float3 col = float3(0.001, 0.001, 0.003) * silence;
    col += starfield(uv, a) * 0.005;

    // ── Camera — 3/4 angle looking down at pool ──
    float camAng = a.stereoBal * 0.15;
    float3 camPos = float3(sin(camAng) * 3.5, 2.3, cos(camAng) * 3.5);
    float3 camTarget = float3(0.0, 0.15, 0.0);
    float3 rd = cameraRay(camPos, camTarget, float2(-p.x, -p.y), 0.38);

    // ── Audio ──
    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    float dspBands[8] = { DspBand0, DspBand1, DspBand2, DspBand3, DspBand4, DspBand5, DspBand6, DspBand7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;
    float phrase = phrasePulse(a);

    Spike spikes[N_SPIKES];
    computeSpikes(spikes, bands, dspBands, kickSurge, beatPulse, a.stereoBal, crest, thd,
                  transientAmt, envelope, a.section);

    float poolR = 3.6 + lufs * 0.08;

    // ── Raymarch to surface ──
    float t = 0.05;
    float marchGlow = 0.0;
    bool hit = false;

    [loop] for (int i = 0; i < MARCH_STEPS; i++)
    {
        float3 sp = camPos + rd * t;
        float d = poolSDF(sp, spikes, poolR, beatPulse, a.beatPhase, transientAmt, envelope, kickSurge, lufs, silence);
        marchGlow += 0.008 / (1.0 + d * d * 50.0);
        if (d < 0.003) { hit = true; break; }
        t += d * 0.5;
        if (t > 5.0) break;
    }

    if (hit)
    {
        float3 hp = camPos + rd * t;
        float3 n = poolNormal(hp, spikes, poolR, beatPulse, a.beatPhase, transientAmt, envelope, kickSurge, lufs, silence);
        float3 vDir = normalize(camPos - hp);

        // ── Metallic ferrofluid shading ──
        // Ferrofluid is dark, glossy, metallic — high Fresnel, sharp specular
        float fres = pow(1.0 - max(dot(n, vDir), 0.0), 5.0);

        // Key light from upper left
        float3 lDir = normalize(float3(0.4, 0.8, 0.5));
        float3 lDir2 = normalize(float3(-0.5 + a.stereoBal * 0.3, 0.6, 0.3));
        float diff = max(dot(n, lDir), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
        float spec = pow(max(dot(reflect(-lDir, n), vDir), 0.0), 80.0);
        float spec2 = pow(max(dot(reflect(-lDir2, n), vDir), 0.0), 60.0) * 0.5;

        // Height determines temperature — spikes glow, surface stays dark
        float heightFrac = clamp(hp.y * 1.5, 0.0, 1.0);
        // Dark metallic base → glowing spike tips
        float3 darkFluid = float3(0.02, 0.02, 0.03);
        float3 hotTip = lerp(float3(0.6, 0.1, 0.03), float3(1.0, 0.5, 0.1), heightFrac);
        hotTip = lerp(hotTip, float3(1.0, 0.9, 0.7), pow(heightFrac, 3.0));

        // Brain color blend
        float3 brain = lerp(a.brainCol, a.brainCol2, heightFrac);
        float3 baseCol = lerp(darkFluid, hotTip, smoothstep(0.05, 0.4, hp.y));
        baseCol = lerp(baseCol, brain, 0.15);

        // Phase coherence tint
        baseCol = lerp(baseCol, baseCol.gbr, phaseCoh * 0.03);

        // Lighting — dark metallic with bright specular, dynamic at full vol
        float3 litCol = baseCol * (diff + diff2) * (0.3 + a.brightness * 0.3 + a.dynamic * 0.2);
        litCol += float3(0.9, 0.85, 0.8) * (spec + spec2) * (0.5 + a.dynLight * 0.7);
        // Fresnel — bright rim on spike edges, dark on flat surface
        litCol += lerp(baseCol, hotTip, 0.5) * fres * (0.4 + envelope * 0.4 + a.glow * 0.2);

        // Spike tip glow — emissive, fades to transparent at peaks
        float tipGlow = smoothstep(0.2, 0.7, hp.y);
        float tipAlpha = 1.0 - smoothstep(0.8, 1.3, hp.y) * 0.5;
        litCol *= tipAlpha;
        // Envelope glow — staggered lower
        litCol += hotTip * tipGlow * (0.1 + envelope * 0.4) * silence;

        // Kick eruption glow — lower
        litCol += float3(1.0, 0.4, 0.08) * kickSurge * tipGlow * 0.4 * silence;

        // Transient speckle — lower, staggered for highs
        if (transientAmt > 0.02)
            litCol += float3(1.0, 0.85, 0.6) * transientAmt * tipGlow * 0.2 * silence;

        // Beat pulse — lower
        litCol += hotTip * beatPulse * tipGlow * 0.08 * silence;

        // ColorPulse — lower
        litCol += a.brainCol3 * a.colorPulse * tipGlow * 0.025 * silence;

        // Dynamic light boost — staggered
        litCol *= (0.6 + a.dynamic * 0.4);
        // Punch — lower
        litCol += hotTip * a.punch * tipGlow * 0.05 * silence;

        col = blendScreen(col, litCol);
    }

    // ── Subsurface glow — lower ──
    col += a.brainCol * marchGlow * (0.015 + a.glow * 0.02) * (0.5 + envelope * 0.5) * silence;

    // ── Beat ring — lower ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.025 * silence;

    // ── Kick flash — lower ──
    col += float3(1.0, 0.5, 0.1) * kickSurge * 0.05 * exp(-r * r * 5.0) * silence;

    // ── Transient pop — lower ──
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.025 * silence;

    // ── ColorPulse — lower ──
    col += a.brainCol3 * a.colorPulse * 0.02 * silence;

    // ── Full volume energy boost — lower ──
    col += a.brainCol2 * a.energy * 0.015 * silence;
    col += a.brainCol * a.punch * 0.015 * silence;

    col += standardOverlays(p, r, a) * 0.02;

    // ── Brightness limiter — let dynamics breathe, only cap extreme peaks ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.5) col *= 1.5 / maxC;

    return float4(col, 1.0);
}
