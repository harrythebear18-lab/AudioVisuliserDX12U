// Mode 33: Fluid Dynamics — SDF heightfield liquid with curl-noise advection
// A dark reflective liquid surface with 24 audio-driven wave sources (3 per band).
// Bass = large swells/tidal waves, mids = vortex ripples/standing waves,
// highs = capillary turbulence/surface jitter. Beat = pressure wave ring.
// Kick = central eruption. Transient = surface disruption/splash.
// DSP: LUFS→surface level, crest→wave sharpness, THD→roughness, phase→symmetry.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define N_WAVES 24
#define MARCH_STEPS 64

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

struct WaveSource {
    float2 pos;
    float amplitude;
    float wavelength;
    float sharpness;
    float energy;
    float gate;
    float freqFrac;
};

void computeWaves(out WaveSource waves[N_WAVES], float bands[8], float dspBands[8],
                  float kickSurge, float beatPulse, float stereoBal, float crest, float thd,
                  float transient, float envelope, float section)
{
    [unroll] for (int n = 0; n < N_WAVES; n++)
    {
        int band = n / 3;
        int sub = n % 3;
        float bt = float(band) / float(N_COMP - 1);

        float rawEnergy = bands[band] + dspBands[band] * 0.12;
        float energy = (band < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
        float gate = smoothstep(0.02, 0.08, rawEnergy);

        // Spectrum L/R — stereo spatial positioning
        float freqU = bandFreq[band];
        float lE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.166), 0).r;
        float rE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.833), 0).r;
        float stereoEnergy = max(lE, rE);
        energy = max(energy, stereoEnergy * 0.5);
        gate = max(gate, smoothstep(0.02, 0.08, stereoEnergy));
        float panMod = (lE - rE) * 0.5; // -1=left, +1=right

        // Radial distribution — each band gets a ring
        float ringInner = 0.3 + float(band) * 0.4;
        float ringOuter = ringInner + 0.3;
        float ang = float(sub) * (PI * 2.0 / 3.0) + float(band) * 0.7 + stereoBal * 0.4 + panMod * 0.3;
        float rad = lerp(ringInner, ringOuter, 0.5);
        waves[n].pos = float2(cos(ang) * rad, sin(ang) * rad);

        // Wavelength — bass = long, highs = short
        waves[n].wavelength = lerp(3.0, 0.4, bt);

        // Sharpness — crest sharpens, highs are sharper
        float sharp = lerp(15.0, 40.0, bt) + crest * 10.0 - thd * 3.0;
        waves[n].sharpness = max(sharp, 8.0);

        // Staggered beat breathing
        float h = energy * (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
        h += transient * lerp(0.05, 0.2, bt) * gate;
        h += envelope * lerp(0.08, 0.03, bt) * gate;
        h += section * 0.05 * gate;
        h += (band < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;
        h *= gate;

        waves[n].amplitude = clamp(h, 0.0, 1.5);
        waves[n].energy = energy;
        waves[n].gate = gate;
        waves[n].freqFrac = bt;
    }
}

// Heightfield — wave sources + curl noise + ripples
float fluidHeight(float2 xz, WaveSource waves[N_WAVES], float poolR,
                  float beatPulse, float beatPhase, float transient, float envelope,
                  float kickSurge, float lufs, float thd, float silence)
{
    float r = length(xz);
    if (r > poolR) return -1.0;

    // Base surface — LUFS additive
    float surface = (0.02 + lufs * 0.02) * silence;

    // Envelope breathing
    surface += envelope * 0.015 * sin(beatPhase * PI * 2.0) * silence;

    // 24 wave sources — radial ripples
    [unroll] for (int n = 0; n < N_WAVES; n++) {
        if (waves[n].gate < 0.01) continue;

        float d = length(xz - waves[n].pos);
        float wl = waves[n].wavelength;
        float amp = waves[n].amplitude;

        // Radial wave — exp falloff from source
        float wave = amp * exp(-d * d * waves[n].sharpness * 0.01);
        wave *= sin(d * (2.0 * PI / wl) - Time * 3.0 * (1.0 + waves[n].freqFrac));
        surface += wave * 0.15;
    }

    // Curl noise advection — bass-driven large-scale flow
    float2 flowUV = xz * 0.5 + float2(Time * 0.2, Time * 0.15);
    float2 flow = curlN(float3(flowUV, 0)).xy;
    surface += (flow.x + flow.y) * 0.03 * silence;

    // FBM turbulence — mids + highs
    float2 turbUV = xz * 2.0 + float2(Time * 0.5, Time * 0.3);
    surface += fbm2_4(turbUV) * 0.04 * silence * (1.0 + thd * 0.5);

    // Beat ripple rings
    float ringPhase = beatPhase * PI * 2.0;
    surface += beatPulse * 0.04 * sin(r * 6.0 - ringPhase * 3.0) * smoothstep(poolR, 0.0, r) * silence;

    // Kick — central eruption
    surface += kickSurge * 0.08 * exp(-r * r * 3.0) * silence;

    // Transient — surface jitter
    if (transient > 0.02)
        surface += transient * 0.025 * sin(xz.x * 25.0 + xz.y * 22.0 + beatPhase * 30.0) * smoothstep(poolR, 0.0, r) * silence;

    // Envelope — global swell
    surface += envelope * 0.012 * smoothstep(poolR, 0.0, r) * silence;

    // Pool edge — curve down
    surface -= smoothstep(poolR * 0.6, poolR, r) * 0.2;

    return surface;
}

float fluidSDF(float3 p, WaveSource waves[N_WAVES], float poolR,
               float beatPulse, float beatPhase, float transient, float envelope,
               float kickSurge, float lufs, float thd, float silence)
{
    float h = fluidHeight(p.xz, waves, poolR, beatPulse, beatPhase, transient, envelope, kickSurge, lufs, thd, silence);
    return p.y - h;
}

float3 fluidNormal(float3 p, WaveSource waves[N_WAVES], float poolR,
                   float beatPulse, float beatPhase, float transient, float envelope,
                   float kickSurge, float lufs, float thd, float silence)
{
    float eps = 0.008;
    return normalize(float3(
        fluidSDF(p + float3(eps, 0, 0), waves, poolR, beatPulse, beatPhase, transient, envelope, kickSurge, lufs, thd, silence)
          - fluidSDF(p - float3(eps, 0, 0), waves, poolR, beatPulse, beatPhase, transient, envelope, kickSurge, lufs, thd, silence),
        2.0 * eps,
        fluidSDF(p + float3(0, 0, eps), waves, poolR, beatPulse, beatPhase, transient, envelope, kickSurge, lufs, thd, silence)
          - fluidSDF(p - float3(0, 0, eps), waves, poolR, beatPulse, beatPhase, transient, envelope, kickSurge, lufs, thd, silence)
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

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    float dspBands[8] = { DspBand0, DspBand1, DspBand2, DspBand3, DspBand4, DspBand5, DspBand6, DspBand7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;
    float phrase = phrasePulse(a);

    WaveSource waves[N_WAVES];
    computeWaves(waves, bands, dspBands, kickSurge, beatPulse, a.stereoBal, crest, thd,
                 transientAmt, envelope, a.section);

    float poolR = 3.6 + lufs * 0.08;

    // ── Camera — 3/4 angle looking down at pool ──
    float camAng = a.section * 0.8 + a.stereoBal * 0.2 + Time * 0.03 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 3.5, 2.3, cos(camAng) * 3.5);
    float3 camTarget = float3(0.0, 0.15, 0.0);
    float3 rd = cameraRay(camPos, camTarget, float2(-p.x, -p.y), 0.38);

    // ── Background — dark room ──
    float3 col = float3(0.001, 0.001, 0.003) * silence;
    col += starfield(uv, a) * 0.005;

    // ── Raymarch to surface ──
    float t = 0.05;
    float marchGlow = 0.0;
    bool hit = false;

    [loop] for (int i = 0; i < MARCH_STEPS; i++) {
        float3 sp = camPos + rd * t;
        float d = fluidSDF(sp, waves, poolR, beatPulse, a.beatPhase, transientAmt, envelope,
                           kickSurge, lufs, thd, silence);
        marchGlow += 0.008 / (1.0 + d * d * 50.0);
        if (d < 0.003) { hit = true; break; }
        t += d * 0.5;
        if (t > 5.0) break;
    }

    if (hit) {
        float3 hp = camPos + rd * t;
        float3 n = fluidNormal(hp, waves, poolR, beatPulse, a.beatPhase, transientAmt, envelope,
                               kickSurge, lufs, thd, silence);
        float3 vDir = normalize(camPos - hp);

        // ── Liquid shading — dark glossy with colored dye ──
        float fres = pow(1.0 - max(dot(n, vDir), 0.0), 5.0);

        // Key lights
        float3 lDir = normalize(float3(0.4, 0.8, 0.5));
        float3 lDir2 = normalize(float3(-0.5 + a.stereoBal * 0.3, 0.6, 0.3));
        float diff = max(dot(n, lDir), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
        float spec = pow(max(dot(reflect(-lDir, n), vDir), 0.0), 80.0);
        float spec2 = pow(max(dot(reflect(-lDir2, n), vDir), 0.0), 60.0) * 0.5;

        // Height determines dye concentration
        float heightFrac = clamp(hp.y * 1.5, 0.0, 1.0);

        // Dark liquid base → colored dye at wave peaks
        float3 darkFluid = float3(0.02, 0.015, 0.04);
        float3 dyeCol = lerp(a.brainCol, a.brainCol2, heightFrac);
        dyeCol = lerp(dyeCol, hsv(a.hueBase + heightFrac * a.hueRange, 0.6 * a.satur, 0.9), 0.3);
        float3 hotPeak = lerp(dyeCol, a.brainCol3, pow(heightFrac, 3.0) * 0.5);

        float3 baseCol = lerp(darkFluid, hotPeak, smoothstep(0.02, 0.3, hp.y));
        baseCol = lerp(baseCol, dyeCol, 0.2);

        // Phase coherence tint
        baseCol = lerp(baseCol, baseCol.gbr, phaseCoh * 0.03);

        // Lighting
        float3 litCol = baseCol * (diff + diff2) * (0.3 + a.brightness * 0.3 + a.dynamic * 0.2);
        litCol += float3(0.9, 0.85, 0.8) * (spec + spec2) * (0.5 + a.dynLight * 0.7);
        litCol += lerp(baseCol, hotPeak, 0.5) * fres * (0.4 + envelope * 0.4 + a.glow * 0.2);

        // Wave peak glow — emissive
        float peakGlow = smoothstep(0.1, 0.5, hp.y);
        litCol += hotPeak * peakGlow * (0.1 + envelope * 0.4) * silence;

        // Kick eruption glow
        litCol += float3(1.0, 0.4, 0.08) * kickSurge * peakGlow * 0.4 * silence;

        // Transient speckle
        if (transientAmt > 0.02)
            litCol += float3(1.0, 0.85, 0.6) * transientAmt * peakGlow * 0.2 * silence;

        // Beat pulse
        litCol += hotPeak * beatPulse * peakGlow * 0.08 * silence;

        // ColorPulse
        litCol += a.brainCol3 * a.colorPulse * peakGlow * 0.025 * silence;

        // Dynamic light boost
        litCol *= (0.6 + a.dynamic * 0.4);
        litCol += hotPeak * a.punch * peakGlow * 0.05 * silence;

        col = blendScreen(col, litCol);
    }

    // ── Subsurface glow ──
    col += a.brainCol * marchGlow * (0.015 + a.glow * 0.02) * (0.5 + envelope * 0.5) * silence;

    // ── Beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.025 * silence;

    // ── Kick flash ──
    col += float3(1.0, 0.5, 0.1) * kickSurge * 0.05 * exp(-r * r * 5.0) * silence;

    // ── Transient pop ──
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.025 * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.02 * silence;

    // ── Energy + punch ──
    col += a.brainCol2 * a.energy * 0.015 * silence;
    col += a.brainCol * a.punch * 0.015 * silence;

    // ── Beat anticipation ──
    col += a.brainCol * a.beatAnt * 0.01 * exp(-r * 2.0) * silence;

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays — surface mode ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── HDR limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.14) col *= 1.14 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
