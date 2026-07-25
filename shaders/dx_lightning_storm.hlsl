// Mode 34: Lightning Storm — dielectric breakdown arcs
// Stepped leader propagation, branching probability, return stroke.
// 24 bolts (3 per band) with jagged paths. Bass = cloud density/storm intensity,
// mids = leader stepping/branch formation, highs = arc flicker/corona discharge.
// Beat = main strike flash. Kick = return stroke. Transient = cloud-to-cloud arcs.
// DSP: LUFS→flash intensity, crest→arc sharpness, THD→branch chaos, phase→arc coherence.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define N_BOLTS 24
#define MAX_SEGMENTS 12

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

struct Bolt {
    float2 start;
    float2 end;
    float jaggedness;
    float width;
    float energy;
    float gate;
    float freqFrac;
    float3 color;
};

float boltHash(float n) { return frac(sin(n * 43758.5453) * 1.0); }

void computeBolts(out Bolt bolts[N_BOLTS], float bands[8], float dspBands[8],
                  float kickSurge, float beatPulse, float stereoBal, float crest, float thd,
                  float transient, float envelope, float section, float phaseCoh, AudioData a)
{
    [unroll] for (int n = 0; n < N_BOLTS; n++)
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
        float panMod = (lE - rE) * 0.5;

        // Bolt start — top of screen, distributed across
        float xStart = (float(n) / float(N_BOLTS) - 0.5) * 4.0 + stereoBal * 0.4 + panMod * 0.5;
        bolts[n].start = float2(xStart, 1.8);

        // Bolt end — ground level with offset
        bolts[n].end = float2(xStart + (boltHash(float(n) * 13.7) - 0.5) * 1.0, -1.2);

        // Jaggedness — mids + THD drive path irregularity
        float jag = 0.3 + bands[2] * 0.3 + bands[3] * 0.2 + thd * 0.4;
        jag *= lerp(1.5, 0.5, phaseCoh);  // phase coherence = straighter
        bolts[n].jaggedness = jag;

        // Width — bass bolts wider, crest sharpens
        float w = 0.008 + energy * 0.015;
        if (band < 4) w *= 1.5;
        w *= (1.0 + crest * 0.3);
        bolts[n].width = w;

        // Staggered beat breathing
        float h = energy * (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
        h += transient * lerp(0.05, 0.2, bt) * gate;
        h += envelope * lerp(0.08, 0.03, bt) * gate;
        h += section * 0.05 * gate;
        h += (band < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;
        h *= gate;

        bolts[n].energy = clamp(h, 0.0, 1.5);
        bolts[n].gate = gate;
        bolts[n].freqFrac = bt;

        // Color — white-blue core with brain palette outer glow
        float3 c = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        c = lerp(c, lerp(a.brainCol, a.brainCol2, bt), 0.3);
        bolts[n].color = c;
    }
}

// Stepped leader path — jagged vertical path with horizontal jitter
float2 boltPath(float2 start, float2 end, float t, float jaggedness, float seed)
{
    float2 dir = end - start;
    float len = length(dir);
    float2 ndir = dir / max(len, 0.001);
    float2 perp = float2(-ndir.y, ndir.x);

    float2 pos = lerp(start, end, t);

    float jitter = 0.0;
    jitter += (boltHash(seed + t * 8.0) - 0.5) * jaggedness;
    jitter += (boltHash(seed + t * 16.0 + 3.7) - 0.5) * jaggedness * 0.5;
    jitter += (boltHash(seed + t * 32.0 + 7.3) - 0.5) * jaggedness * 0.25;

    float branchProb = boltHash(seed + floor(t * 6.0));
    if (branchProb > 0.7) jitter += (branchProb - 0.7) * 3.0 * jaggedness;

    pos += perp * jitter * len * 0.15;
    return pos;
}

float distToBolt(float2 p, float2 start, float2 end, float jaggedness, float seed, float width)
{
    float minDist = 1e10;
    [unroll] for (int i = 0; i <= MAX_SEGMENTS; i++) {
        float t = float(i) / float(MAX_SEGMENTS);
        float2 bp = boltPath(start, end, t, jaggedness, seed);
        minDist = min(minDist, length(p - bp));
    }
    return minDist;
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

    Bolt bolts[N_BOLTS];
    computeBolts(bolts, bands, dspBands, kickSurge, beatPulse, a.stereoBal, crest, thd,
                 transientAmt, envelope, a.section, phaseCoh, a);

    // ── Background — stormy sky with bass-driven clouds ──
    float2 cloudUV = p * 1.5 + float2(Time * 0.05 * a.motSpeed, Time * 0.03);
    float clouds = fbm2_4(cloudUV) * (0.3 + bands[0] * 0.4 + bands[1] * 0.3);
    clouds *= smoothstep(0.3, 0.8, clouds);

    float3 cloudCol = lerp(float3(0.01, 0.01, 0.03), float3(0.05, 0.04, 0.08), clouds);
    cloudCol += a.brainCol * clouds * 0.15 * (1.0 + lufs * 0.15);
    float3 col = cloudCol * silence;

    col += starfield(uv, a) * 0.01;
    col += godRays(p, r, a) * 0.04 * silence;

    // ── Lightning bolts ──
    [unroll] for (int i = 0; i < N_BOLTS; i++) {
        if (bolts[i].gate < 0.01) continue;

        float dist = distToBolt(p, bolts[i].start, bolts[i].end, bolts[i].jaggedness,
                                float(i) * 7.3, bolts[i].width);

        float arcIntensity = exp(-dist * dist / (bolts[i].width * bolts[i].width));

        // Flicker — high-band driven
        float flicker = 0.7 + 0.3 * sin(Time * 30.0 + float(i) * 13.0) * (bands[6] + bands[7]);
        arcIntensity *= flicker;

        // LUFS boost
        arcIntensity *= (1.0 + lufs * 0.2);

        // White-blue core + brain palette glow
        float3 coreCol = float3(0.9, 0.95, 1.0);
        float3 boltCol = coreCol * arcIntensity * 2.0 + bolts[i].color * arcIntensity * 0.5;
        boltCol *= bolts[i].energy;

        col += boltCol * silence;

        // Diffraction sparks at bolt end
        float2 beamEnd = bolts[i].end;
        float endDist = length(p - beamEnd);
        float sparkIntensity = exp(-endDist * endDist * 100.0) * (bands[6] + bands[7]) * bolts[i].gate * 0.3;
        col += bolts[i].color * sparkIntensity * 2.0 * silence;
    }

    // ── Beat — main strike flash ──
    col += float3(0.3, 0.35, 0.5) * beatPulse * exp(-a.beatPhase * 4.0) * 0.15 * silence;

    // ── Kick — return stroke flash ──
    col += float3(0.5, 0.55, 0.7) * kickSurge * exp(-r * 0.5) * 0.3 * silence;

    // ── Transient — cloud-to-cloud discharges ──
    float c2c = transientAmt * fbm2_4(p * 3.0 + Time * 2.0) * 0.08;
    col += a.brainCol3 * c2c * silence;

    // ── Corona discharge — high-band shimmer ──
    float corona = (bands[6] + bands[7]) * hash21(p * 200.0 + Time * 50.0) * 0.03;
    col += float3(0.6, 0.7, 1.0) * corona * silence;

    // ── Beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.025 * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.02 * silence;

    // ── Energy + punch ──
    col += a.brainCol2 * a.energy * 0.015 * silence;
    col += a.brainCol * a.punch * 0.015 * silence;

    // ── Beat anticipation ──
    col += a.brainCol * a.beatAnt * 0.01 * exp(-r * 2.0) * silence;

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── HDR limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
