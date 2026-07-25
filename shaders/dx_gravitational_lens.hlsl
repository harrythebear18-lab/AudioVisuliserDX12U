// Mode 42: Gravitational Lens Observatory — black hole with audio-driven accretion disk
// You orbit a black hole. Spacetime lensing distorts background stars.
// Each band = a ring of the accretion disk (bass=inner, treble=outer).
// Kick = gravitational wave ripple. THD = disk turbulence.
// Phase = relativistic jet alignment. Beat = orbital pulse.
// LUFS = disk brightness. Crest = disk edge sharpness.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define N_RINGS 12

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

struct AccretionRing {
    float radius;
    float energy;
    float gate;
    float freqFrac;
    float3 color;
};

void computeRings(out AccretionRing rings[N_RINGS], float bands[8], float dspBands[8],
                  float kickSurge, float beatPulse, float stereoBal, float crest, float thd,
                  float transient, float envelope, float section, AudioData a)
{
    [unroll] for (int n = 0; n < N_RINGS; n++)
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

        rings[n].radius = lerp(0.8, 3.5, float(n) / float(N_RINGS - 1));

        float h = energy * (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
        h += transient * lerp(0.05, 0.2, bt) * gate;
        h += envelope * lerp(0.08, 0.03, bt) * gate;
        h += section * 0.05 * gate;
        h += (band < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;
        h *= gate;

        rings[n].energy = clamp(h, 0.0, 1.5);
        rings[n].gate = gate;
        rings[n].freqFrac = bt;

        float3 c = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        c = lerp(c, lerp(a.brainCol, a.brainCol2, bt), 0.3);
        // Hot inner rings = white-orange, cool outer = blue
        if (band < 2) c = lerp(c, float3(1.0, 0.6, 0.2), 0.3);
        rings[n].color = c;
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

    AccretionRing rings[N_RINGS];
    computeRings(rings, bands, dspBands, kickSurge, beatPulse, a.stereoBal, crest, thd,
                 transientAmt, envelope, a.section, a);

    // ── Camera — orbit the black hole ──
    float FOV = 0.6;
    float camAng = a.section * 0.8 + a.stereoBal * 0.2 + Time * 0.03 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 5.0, 2.0 + a.stereoDiff * 0.1, cos(camAng) * 5.0);
    float3 camTarget = float3(0, 0, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Background — starfield with gravitational lensing ──
    float3 col = float3(0.001, 0.001, 0.004) * silence;

    // Gravitational lensing — distort starfield near black hole
    float lensR = r;
    float eventHorizon = 0.15;
    if (r > eventHorizon) {
        // Bend light rays around black hole
        float bend = 0.3 / (r * r + 0.1);
        float2 lensP = p * (1.0 + bend);
        col += starfield(uv + lensP * 0.1, a) * 0.04;
    }

    // Event horizon — pure black disc
    if (r < eventHorizon) {
        col = float3(0, 0, 0);
    } else {
        // Photon sphere — bright ring at 1.5x event horizon
        float photonR = eventHorizon * 1.5;
        float photonDist = abs(r - photonR);
        col += float3(1.0, 0.8, 0.5) * exp(-photonDist * photonDist * 200.0) * 0.3 * silence;
    }

    // ── Accretion disk — project rings as ellipses ──
    [loop] for (int n = 0; n < N_RINGS; n++) {
        if (rings[n].gate < 0.01) continue;

        // Disk is in XZ plane — project as ellipse
        float3 diskCenter = float3(0, 0, 0);
        float3 toDisk = diskCenter - camPos;
        float diskDepth = dot(toDisk, fwd);
        if (diskDepth < 0.1) continue;
        float2 scrDisk = float2(dot(toDisk, right) / (diskDepth * FOV), dot(toDisk, up) / (diskDepth * FOV));

        // Ellipse parameters — tilted disk
        float ringScreenR = rings[n].radius / (diskDepth * FOV);
        float yScale = abs(fwd.y) * 0.5 + 0.1;  // tilt factor

        // Sample multiple points around the ring
        [loop] for (int seg = 0; seg < 12; seg++) {
            float segAng = float(seg) / 12.0 * PI * 2.0 + Time * (0.5 + rings[n].freqFrac * 0.5) * a.motSpeed;

            // 3D position on ring
            float3 ringPos = float3(cos(segAng) * rings[n].radius, 0, sin(segAng) * rings[n].radius);
            // THD turbulence
            ringPos.y += thd * fbm2_4(float2(segAng * 3.0, Time * 2.0)) * 0.2;

            float3 toRing = ringPos - camPos;
            float ringDepth = dot(toRing, fwd);
            if (ringDepth < 0.1) continue;
            float2 scrRing = float2(dot(toRing, right) / (ringDepth * FOV), dot(toRing, up) / (ringDepth * FOV));
            float scrDist = length(p - scrRing);

            // Doppler beaming — approaching side brighter
            float doppler = 1.0 + sin(segAng + camAng) * 0.5;
            doppler = clamp(doppler, 0.3, 2.0);

            float segSize = 0.008 / max(ringDepth * 0.15, 0.3);
            float segGlow = exp(-scrDist * scrDist / (segSize * segSize * 0.3));

            float intensity = rings[n].energy * doppler * (1.0 + lufs * 0.2);
            float depthFade = exp(-ringDepth * 0.05);

            col += rings[n].color * segGlow * intensity * depthFade * 0.6 * silence;
        }
    }

    // ── Relativistic jets — phase coherence aligned ──
    if (phaseCoh > 0.3) {
        float3 jetDir = float3(0, 1, 0);
        float3 jetPos = float3(0, 2.0, 0);
        float3 toJet = jetPos - camPos;
        float jetDepth = dot(toJet, fwd);
        if (jetDepth > 0.1) {
            float2 scrJet = float2(dot(toJet, right) / (jetDepth * FOV), dot(toJet, up) / (jetDepth * FOV));
            float jetDist = length(p - scrJet);
            float jetGlow = exp(-jetDist * jetDist * 20.0) * phaseCoh * 0.1;
            col += a.brainCol3 * jetGlow * silence;
        }
    }

    // ── Kick — gravitational wave ripple ──
    if (kickSurge > 0.05) {
        float gwR = a.beatPhase * 0.8;
        float gwDist = abs(r - gwR);
        col += a.brainCol * exp(-gwDist * gwDist * 30.0) * kickSurge * 0.15 * silence;
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
