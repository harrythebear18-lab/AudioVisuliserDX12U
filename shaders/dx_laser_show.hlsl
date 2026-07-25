// Mode 38: Laser Show — concert laser beams with coherent propagation
// 24 beams (3 per band) with atmospheric scattering and diffraction patterns.
// Bass = beam width/sweep speed/haze density, mids = crossing patterns/geometric shapes,
// highs = diffraction sparks/fine dot projections. Beat = strobe burst.
// Kick = beam convergence/explosion. Transient = beam flicker/color shift.
// DSP: LUFS→beam intensity, crest→beam edge sharpness, THD→jitter, phase→coherence.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define N_BEAMS 24

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

struct LaserBeam {
    float2 origin;
    float angle;
    float width;
    float length;
    float energy;
    float gate;
    float freqFrac;
    float3 color;
};

void computeBeams(out LaserBeam beams[N_BEAMS], float bands[8], float dspBands[8],
                  float kickSurge, float beatPulse, float stereoBal, float crest, float thd,
                  float transient, float envelope, float section, float phaseCoh, AudioData a)
{
    [unroll] for (int n = 0; n < N_BEAMS; n++)
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

        // Beam origin — from top of venue
        beams[n].origin = float2(
            (float(n) / float(N_BEAMS) - 0.5) * 4.0 + stereoBal * 0.4 + panMod * 0.5,
            1.8
        );

        // Beam angle — audio-driven sweep
        float baseAngle = -PI * 0.5 + sin(Time * 0.5 * a.motSpeed + float(n) * 0.5) * 0.3;
        // Mids create crossing patterns
        baseAngle += sin(Time * 1.2 * a.motSpeed + float(n) * PI * 0.3) * (bands[2] + bands[3]) * 0.5 * 0.4;
        // Highs add fine modulation
        baseAngle += sin(Time * 3.0 * a.motSpeed + float(n) * 1.7) * (bands[4] + bands[5]) * 0.3 * 0.2;
        // THD jitter
        baseAngle += thd * hash11(float(n) * 7.3 + Time * 20.0) * 0.05;

        // Kick convergence — all beams angle toward center
        float2 toCenter = float2(0, 0) - beams[n].origin;
        float centerAngle = atan2(toCenter.y, toCenter.x);
        baseAngle = lerp(baseAngle, centerAngle, kickSurge * 0.8);

        beams[n].angle = baseAngle;

        // Width — bass beams wider, crest sharpens
        float w = 0.005 + energy * 0.015;
        if (band < 4) w *= 1.5;
        w *= (1.0 + crest * 0.2);
        beams[n].width = w;
        beams[n].length = 6.0;

        // Staggered beat breathing
        float h = energy * (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
        h += transient * lerp(0.05, 0.2, bt) * gate;
        h += envelope * lerp(0.08, 0.03, bt) * gate;
        h += section * 0.05 * gate;
        h += (band < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;
        h *= gate;

        beams[n].energy = clamp(h, 0.0, 1.5);
        beams[n].gate = gate;
        beams[n].freqFrac = bt;

        // Color — frequency-positioned laser colors
        float3 c = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        c = lerp(c, lerp(a.brainCol, a.brainCol2, bt), 0.25);
        // Section-driven palette shift
        if (int(a.section) % 3 == 1) c = lerp(c, a.brainCol3, 0.3);
        beams[n].color = c;
    }
}

// Beam intensity at screen position
float beamIntensity(float2 p, float2 origin, float angle, float width, float length, float intensity)
{
    float2 dir = float2(cos(angle), sin(angle));
    float2 perp = float2(-dir.y, dir.x);

    float along = dot(p - origin, dir);
    if (along < 0.0 || along > length) return 0.0;

    float perpDist = abs(dot(p - origin, perp));
    float beam = exp(-perpDist * perpDist / (width * width));
    beam *= exp(-along * 0.15);  // atmospheric scattering

    return beam * intensity;
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

    LaserBeam beams[N_BEAMS];
    computeBeams(beams, bands, dspBands, kickSurge, beatPulse, a.stereoBal, crest, thd,
                 transientAmt, envelope, a.section, phaseCoh, a);

    // ── Background — dark venue with atmospheric haze ──
    float haze = fbm2_4(p * 2.0 + float2(Time * 0.1 * a.motSpeed, 0)) * (0.1 + bands[0] * 0.2 + bands[1] * 0.15);
    float3 col = float3(0.003, 0.002, 0.008) * silence;
    col += float3(0.02, 0.01, 0.04) * haze * silence;
    col += starfield(uv, a) * 0.008;

    // ── Laser beams ──
    [unroll] for (int i = 0; i < N_BEAMS; i++) {
        if (beams[i].gate < 0.01) continue;

        float intensity = beamIntensity(p, beams[i].origin, beams[i].angle,
                                        beams[i].width, beams[i].length, beams[i].energy);
        intensity *= lerp(0.6, 1.3, phaseCoh);  // phase coherence
        intensity *= (1.0 + lufs * 0.2);

        col += beams[i].color * intensity * 1.5 * silence;

        // Diffraction sparks at beam end — high-band driven
        float2 beamEnd = beams[i].origin + float2(cos(beams[i].angle), sin(beams[i].angle)) * beams[i].length;
        float endDist = length(p - beamEnd);
        float sparkIntensity = exp(-endDist * endDist * 100.0) * (bands[6] + bands[7]) * beams[i].gate * 0.3;
        col += beams[i].color * sparkIntensity * 2.0 * silence;
    }

    // ── Beat — strobe burst ──
    col += float3(0.3, 0.3, 0.4) * beatPulse * exp(-a.beatPhase * 5.0) * 0.1 * silence;

    // ── Kick — beam explosion flash ──
    col += a.brainCol3 * exp(-r * r * 3.0) * kickSurge * 0.3 * silence;

    // ── Transient — beam flicker ──
    float flicker = transientAmt * hash21(p * 30.0 + Time * 40.0) * 0.06;
    col += a.brainCol2 * flicker * silence;

    // ── High-band diffraction sparkle ──
    float sparkle = (bands[6] + bands[7]) * hash21(p * 200.0 + Time * 60.0) * 0.02;
    col += float3(0.8, 0.9, 1.0) * sparkle * silence;

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
