// Mode 31: Space Plasma Field — volumetric plasma torus with EM field math
// Lorentz force F = q(E + v×B), cyclotron motion, synchrotron emission.
// 24 charged particles (3 per band) orbit toroidal field lines.
// Bass = containment pressure/pinch, mids = magnetic field strength/cyclotron,
// highs = turbulence/synchrotron emission. Beat = magnetic reconnection.
// Kick = containment collapse. Transient = particle scatter.
// DSP: LUFS→emission, crest→field sharpness, THD→turbulence, phase→coherence.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define N_PARTICLES 24
#define MAX_STEPS 48

struct Particle {
    float3 pos;
    float energy;
    float gate;
    float freqFrac;
};

void computeParticles(out Particle parts[N_PARTICLES], float bands[8], float dspBands[8],
                      float kickSurge, float beatPulse, float stereoBal, float stereoWid, float crest, float thd,
                      float transient, float envelope, float section)
{
    [unroll] for (int n = 0; n < N_PARTICLES; n++)
    {
        int band = n / 3;
        int sub = n % 3;
        float bt = float(band) / float(N_COMP - 1);

        float rawEnergy = bands[band] + dspBands[band] * 0.12;
        float energy = (band < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
        float gate = smoothstep(0.02, 0.08, rawEnergy);

        // Torus coordinates — 3 particles per band at 120° offset
        float torAng = float(sub) * (PI * 2.0 / 3.0) + float(band) * 0.7 + stereoBal * 0.4;
        float polAng = float(band) * 0.5 + Time * 0.3 * (0.5 + bt * 0.5);

        // Bass pinches torus radius
        float R = 1.2 + stereoWid * 0.3;
        float rr = 0.5 + bands[0] * 0.15 + bands[1] * 0.1;

        // Cyclotron frequency — mids drive field strength
        float B = 3.0 + bands[2] * 2.0 + bands[3] * 1.5;
        float omegaC = B * (1.0 + crest * 0.3);
        polAng += sin(torAng * omegaC + Time * 2.0) * 0.3;

        parts[n].pos = float3(
            (R + rr * cos(polAng)) * cos(torAng),
            rr * sin(polAng),
            (R + rr * cos(polAng)) * sin(torAng)
        );

        // Staggered beat breathing — bass less, highs more
        float h = energy * (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
        // Staggered transient — bass less, highs more
        h += transient * lerp(0.05, 0.2, bt) * gate;
        h += envelope * lerp(0.08, 0.03, bt) * gate;
        h += section * 0.05 * gate;
        // Kick surge on bass
        h += (band < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;
        h *= gate;

        parts[n].energy = clamp(h, 0.0, 1.5);
        parts[n].gate = gate;
        parts[n].freqFrac = bt;
    }
}

// Plasma density field — volumetric
float plasmaDensity(float3 p, Particle parts[N_PARTICLES], float bands[8],
                    float beatPulse, float kickSurge, float transient, float envelope,
                    float lufs, float crest, float thd, float phaseCoh, float silence)
{
    float density = 0.0;

    // Toroidal containment — Gaussian falloff from torus surface
    float R = 1.2;
    float2 toroidal = float2(length(p.xz) - R, p.y);
    float dist = length(toroidal);
    float containment = exp(-dist * dist * (3.0 + bands[0] * 2.0)) * silence;

    // Cyclotron modulation — particles spiral along field lines
    float poloidal = atan2(p.y, length(p.xz) - R);
    float toroidalAng = atan2(p.z, p.x);
    float B = 3.0 + bands[2] * 2.0 + bands[3] * 1.5;
    float cyclotron = sin(poloidal * B + Time * 2.0 + toroidalAng * 3.0);
    density = containment * (0.6 + cyclotron * 0.3);

    // Turbulence — highs drive eddy formation
    float3 turbPos = p * 2.0 + float3(Time * 0.5, 0, Time * 0.3);
    density += fbm3_4(turbPos) * (bands[4] * 0.4 + bands[5] * 0.3) * (1.0 + thd * 0.5) * containment;

    // Per-particle glow contribution
    [unroll] for (int n = 0; n < N_PARTICLES; n++)
    {
        if (parts[n].gate < 0.01) continue;
        float pd = length(p - parts[n].pos);
        density += exp(-pd * pd * 8.0) * parts[n].energy * 0.3;
    }

    // Beat — magnetic reconnection event
    density += beatPulse * exp(-dist * 2.0) * abs(sin(toroidalAng * 4.0 + Time * 8.0)) * 0.3 * silence;

    // Kick — containment collapse
    density += kickSurge * exp(-dist * 4.0) * 0.5 * silence;

    // Phase coherence — coherent plasma has tighter field lines
    density *= lerp(0.6, 1.2, phaseCoh);

    // LUFS additive
    density *= (1.0 + lufs * 0.2);

    // Noise gate
    density *= smoothstep(0.002, 0.02, density);

    return density;
}

float3 plasmaColor(float3 p, float density, float bands[8], AudioData a, float lufs)
{
    // Temperature from high bands (particle energy)
    float energy = bands[6] * 0.4 + bands[7] * 0.3 + a.envelope * 0.3;
    float temp = 0.3 + energy * 0.7;

    float3 hotColor = float3(0.4, 0.6, 1.0);
    float3 warmColor = float3(1.0, 0.5, 0.2);
    float3 coolColor = float3(0.8, 0.2, 0.3);

    float3 col = lerp(coolColor, warmColor, smoothstep(0.2, 0.5, temp));
    col = lerp(col, hotColor, smoothstep(0.5, 0.9, temp));

    // Brain palette blend
    float toroidalAng = atan2(p.z, p.x);
    float freqFrac = (toroidalAng + PI) / (2.0 * PI);
    col = lerp(col, hsv(a.hueBase + freqFrac * a.hueRange, 0.6 * a.satur, 0.9), 0.3);
    col = lerp(col, a.brainCol, 0.2);
    col = lerp(col, a.brainCol2, bands[3] * 0.2);

    // Emission
    col *= density * (0.4 + energy * 1.5) * (1.0 + lufs * 0.2);

    return col;
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

    Particle parts[N_PARTICLES];
    computeParticles(parts, bands, dspBands, kickSurge, beatPulse, a.stereoBal, a.stereoWid, crest, thd,
                     transientAmt, envelope, a.section);

    // ── Camera — section-driven orbit ──
    float FOV = 0.6;
    float camAng = a.section * 0.8 + a.stereoBal * 0.2 + Time * 0.03 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 3.5, 0.8 + a.stereoDiff * 0.15, cos(camAng) * 3.5);
    float3 camTarget = float3(a.stereoBal * 0.2, 0, 0);
    float3 rd = cameraRay(camPos, camTarget, float2(-p.x, -p.y), FOV);

    // ── Background — deep space ──
    float3 col = float3(0.002, 0.001, 0.008) * silence;
    col += starfield(uv, a) * 0.03;
    col += godRays(p, r, a) * 0.05 * silence;

    // ── Volumetric raymarch through plasma ──
    float t = 0.15;
    float3 accum = float3(0, 0, 0);
    float transmittance = 1.0;
    float stepSize = 0.08;

    [loop] for (int i = 0; i < MAX_STEPS; i++) {
        float3 sp = camPos + rd * t;
        if (length(sp) > 3.0) break;

        float density = plasmaDensity(sp, parts, bands, beatPulse, kickSurge, transientAmt,
                                       envelope, lufs, crest, thd, phaseCoh, silence);
        density *= smoothstep(0.002, 0.02, density);

        if (density > 0.003) {
            float3 pointCol = plasmaColor(sp, density, bands, a, lufs);
            float depthFog = exp(-t * 0.08);
            float emission = density * (0.5 + a.brightness * 0.3) * depthFog;

            float sigma = density * 0.15 + 0.02;
            transmittance *= exp(-sigma * stepSize);

            accum += pointCol * emission * transmittance;
        }
        t += stepSize;
    }

    col += accum * silence;

    // ── Per-particle projected glow ──
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    [unroll] for (int j = 0; j < N_PARTICLES; j++) {
        if (parts[j].gate < 0.01) continue;
        float3 toObj = parts[j].pos - camPos;
        float depth = dot(toObj, fwd);
        if (depth < 0.1) continue;
        float2 scr = float2(dot(toObj, right) / (depth * FOV), dot(toObj, up) / (depth * FOV));
        float scrDist = length(p - scr);

        float pSize = 0.015 + parts[j].energy * 0.04;
        float pGlow = exp(-scrDist * scrDist / (pSize * pSize));

        float3 pCol = lerp(a.brainCol, a.brainCol2, parts[j].freqFrac);
        pCol = lerp(pCol, hsv(a.hueBase + parts[j].freqFrac * a.hueRange, 0.6 * a.satur, 0.9), 0.3);
        pCol *= parts[j].energy * (1.0 + lufs * 0.15);

        float depthFade = exp(-depth * 0.15);
        col += pCol * pGlow * depthFade * 0.5 * silence;
    }

    // ── Beat ring — expanding, not center flash ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.025 * silence;

    // ── Kick flash ──
    col += a.brainCol2 * kickSurge * 0.05 * exp(-r * r * 5.0) * silence;

    // ── Transient pop ──
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.025 * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.02 * silence;

    // ── Energy + punch ──
    col += a.brainCol2 * a.energy * 0.015 * silence;
    col += a.brainCol * a.punch * 0.015 * silence;

    // ── Beat anticipation — pre-beat tension ──
    col += a.brainCol * a.beatAnt * 0.01 * exp(-r * 2.0) * silence;

    // ── Dynamic range — quiet passages dark ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── HDR limiter — dark volumetric mode ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
