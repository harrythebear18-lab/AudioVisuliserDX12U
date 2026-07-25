// Mode 46: Acoustic Particle Hologram — GPU particles forming 3D audio shapes
// A particle cloud that arranges into frequency surfaces, dissolves on transients,
// and reforms on beats. Stereo = particle distribution L/R.
// Profile = shape personality (diffuse vs compact). Beat = particle convergence.
// Kick = explosion outward. Transient = dissolution + reformation.
// LUFS = particle brightness. Crest = particle focus. THD = particle jitter.

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

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

struct Particle {
    float3 pos;
    float3 vel;
    float energy;
    float gate;
    float freqFrac;
    float3 color;
};

void computeParticles(out Particle particles[N_PARTICLES], float bands[8], float dspBands[8],
                      float kickSurge, float beatPulse, float stereoBal, float stereoWid,
                      float crest, float thd, float transient, float envelope, float section,
                      float phaseCoh, AudioData a)
{
    [unroll] for (int n = 0; n < N_PARTICLES; n++)
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

        // Target position — arranged on a frequency surface
        // Each band forms a ring at different radius and height
        float ringR = lerp(0.5, 3.0, bt) * (1.0 + a.stereoWid * 0.2);
        float ringAng = float(sub) / 3.0 * PI * 2.0 + Time * 0.3 * (0.5 + bt) * a.motSpeed + stereoBal * 0.3 + panMod * 0.4;
        float ringY = lerp(-1.5, 1.5, bt);

        float3 targetPos = float3(cos(ringAng) * ringR, ringY, sin(ringAng) * ringR);

        // Transient — dissolution: scatter particles
        float dissolve = transient * 2.0;
        float3 scatter = float3(
            hash11(float(n) * 7.3 + Time * 10.0) - 0.5,
            hash11(float(n) * 13.7 + Time * 8.0) - 0.5,
            hash11(float(n) * 21.1 + Time * 12.0) - 0.5
        ) * dissolve;

        // Kick — explosion outward
        float3 explode = normalize(targetPos + float3(0.01, 0, 0)) * kickSurge * 1.5;

        // Beat — convergence pulse toward target
        float converge = beatPulse * exp(-a.beatPhase * 4.0);

        // Final position — lerp between scattered and target
        float3 finalPos = lerp(targetPos + scatter, targetPos, converge);
        finalPos += explode * (1.0 - converge);

        // THD jitter
        finalPos += float3(
            thd * (hash11(float(n) * 5.1 + Time * 20.0) - 0.5) * 0.1,
            thd * (hash11(float(n) * 9.3 + Time * 18.0) - 0.5) * 0.1,
            thd * (hash11(float(n) * 17.5 + Time * 22.0) - 0.5) * 0.1
        );

        // Envelope breathing
        finalPos *= (1.0 + envelope * 0.1 * sin(Time * 2.0 + float(n)));

        particles[n].pos = finalPos;
        particles[n].vel = (targetPos - finalPos) * converge;
        particles[n].energy = energy * gate;
        particles[n].gate = gate;
        particles[n].freqFrac = bt;

        float3 c = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        c = lerp(c, lerp(a.brainCol, a.brainCol2, bt), 0.3);
        particles[n].color = c;
    }
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

    Particle particles[N_PARTICLES];
    computeParticles(particles, bands, dspBands, kickSurge, beatPulse, a.stereoBal, a.stereoWid,
                     crest, thd, transientAmt, envelope, a.section, phaseCoh, a);

    // ── Camera — inside the particle cloud ──
    float FOV = 0.75;
    float camAng = a.section * 0.5 + a.stereoBal * 0.2 + Time * 0.02 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 2.0, 0.5 + a.stereoDiff * 0.1, cos(camAng) * 2.0);
    float3 camTarget = float3(0, 0, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Background — dark hologram space ──
    float3 col = float3(0.001, 0.001, 0.004) * silence;
    col += starfield(uv, a) * 0.005;

    // ── Project particles ──
    float2 scrPos[N_PARTICLES];
    float scrDepth[N_PARTICLES];

    [unroll] for (int n = 0; n < N_PARTICLES; n++) {
        float3 toP = particles[n].pos - camPos;
        scrDepth[n] = dot(toP, fwd);
        if (scrDepth[n] < 0.1) { scrPos[n] = float2(999, 999); scrDepth[n] = 0.0; continue; }
        scrPos[n] = float2(dot(toP, right) / (scrDepth[n] * FOV), dot(toP, up) / (scrDepth[n] * FOV));
    }

    // ── Particle trails — connect to nearest neighbor in same band ──
    [loop] for (int i = 0; i < N_PARTICLES; i++) {
        if (particles[i].gate < 0.01 || scrDepth[i] < 0.1) continue;

        // Connect to next particle in same band (sub+1)
        int band = i / 3;
        int nextIdx = (band * 3) + ((i % 3) + 1) % 3;
        if (particles[nextIdx].gate < 0.01 || scrDepth[nextIdx] < 0.1) continue;

        float2 ab = scrPos[nextIdx] - scrPos[i];
        float t = clamp(dot(p - scrPos[i], ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
        float2 closest = scrPos[i] + ab * t;
        float trailDist = length(p - closest);
        float trailWidth = 0.002 + particles[i].energy * 0.003;
        float trailGlow = exp(-trailDist * trailDist / (trailWidth * trailWidth));

        float3 trailCol = lerp(particles[i].color, particles[nextIdx].color, 0.5);
        float avgDepth = (scrDepth[i] + scrDepth[nextIdx]) * 0.5;
        float depthFade = exp(-avgDepth * 0.08);
        float trailInt = (particles[i].energy + particles[nextIdx].energy) * 0.5 * (1.0 + lufs * 0.15);

        col += trailCol * trailGlow * trailInt * depthFade * 0.08 * silence;
    }

    // ── Particles — glowing points with multi-layer glow ──
    [loop] for (int m = 0; m < N_PARTICLES; m++) {
        if (particles[m].gate < 0.01 || scrDepth[m] < 0.1) continue;

        float scrDist = length(p - scrPos[m]);
        float sz = (0.015 + particles[m].energy * 0.04) / max(scrDepth[m] * 0.15, 0.3) * 3.0;

        float coreGlow = exp(-scrDist * scrDist / (sz * sz * 0.08));
        float midGlow = exp(-scrDist * scrDist / (sz * sz * 0.8));
        float haloGlow = exp(-scrDist * scrDist / (sz * sz * 5.0));

        float intensity = particles[m].energy * (1.0 + lufs * 0.2);
        float depthFade = exp(-scrDepth[m] * 0.08);

        // Crest focuses particles — sharper cores
        float focus = lerp(0.5, 1.5, crest);

        col += float3(0.9, 0.95, 1.0) * coreGlow * intensity * focus * depthFade * 1.5 * silence;
        col += particles[m].color * midGlow * intensity * depthFade * 0.7 * silence;
        col += particles[m].color * haloGlow * intensity * depthFade * 0.15 * silence;
    }

    // ── Beat — convergence flash ──
    col += a.brainCol * beatPulse * exp(-a.beatPhase * 4.0) * 0.03 * silence;

    // ── Kick — explosion flash ──
    col += float3(1.0, 0.6, 0.2) * kickSurge * 0.08 * exp(-r * r * 3.0) * silence;

    // ── Transient — dissolution shimmer ──
    if (transientAmt > 0.02) {
        float shimmer = transientAmt * hash21(p * 100.0 + Time * 40.0) * 0.04;
        col += a.brainCol3 * shimmer * silence;
    }

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
