// Mode 44: Cymatic Resonance Chamber — 3D Chladni patterns on parallel surfaces
// Multiple vibrating surfaces at different depths show Chladni nodal patterns.
// Each band = a different resonance frequency on a different surface.
// Kick = surface impact. Transient = pattern rearrangement.
// Beat = standing wave pulse. LUFS = surface brightness. Crest = pattern sharpness.
// THD = surface noise. Phase = pattern symmetry. Stereo = L/R surface tilt.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define N_SURFACES 8
#define GRID_N 8

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

struct CymaticSurface {
    float zDepth;
    float yOffset;
    float frequency;
    float amplitude;
    float gate;
    float freqFrac;
    float3 color;
};

void computeSurfaces(out CymaticSurface surfaces[N_SURFACES], float bands[8], float dspBands[8],
                     float kickSurge, float beatPulse, float stereoBal, float crest, float thd,
                     float transient, float envelope, float section, AudioData a)
{
    [unroll] for (int n = 0; n < N_SURFACES; n++)
    {
        float bt = float(n) / float(N_COMP - 1);

        float rawEnergy = bands[n] + dspBands[n] * 0.12;
        float energy = (n < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
        float gate = smoothstep(0.02, 0.08, rawEnergy);

        // Spectrum L/R — stereo spatial positioning
        float freqU = bandFreq[n];
        float lE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.166), 0).r;
        float rE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.833), 0).r;
        float stereoEnergy = max(lE, rE);
        energy = max(energy, stereoEnergy * 0.5);
        gate = max(gate, smoothstep(0.02, 0.08, stereoEnergy));
        float panMod = (lE - rE) * 0.5;

        surfaces[n].zDepth = lerp(-3.0, 0.5, bt);
        surfaces[n].frequency = lerp(2.0, 16.0, bt) * (1.0 + a.tempo * 0.2);
        // Vertical breathing — driven by brain frequency/volume/energy fields
        // Per-band energy drives frequency-specific displacement (each surface = one band)
        // a.energy = overall energy, a.overall = volume, a.envelope = dynamics envelope
        // a.brightness = spectral brightness, a.punch = transient punch, a.glow = ambient glow
        float bandVol = bands[n] + dspBands[n] * 0.12; // raw band volume with DSP additive
        float bandEnergy = (n < 4) ? pow(bandVol, 0.5) : bandVol; // perceptual loudness curve
        
        // Slow breathing from envelope + energy (the "alive" feeling)
        surfaces[n].yOffset = sin(Time * (0.4 + bt * 1.5) + bt * PI) * (0.2 + a.envelope * 0.5) * gate;
        // Per-band frequency dispersion — each surface rises with its own band volume
        surfaces[n].yOffset += bandEnergy * lerp(0.6, 0.2, bt) * gate;
        // Overall volume lifts all surfaces (a.overall = master volume)
        surfaces[n].yOffset += a.overall * 0.3 * gate;
        // Energy adds upward push (a.energy = perceived energy)
        surfaces[n].yOffset += a.energy * lerp(0.4, 0.1, bt) * gate;
        // Punch = sharp upward kick on transients (a.punch)
        surfaces[n].yOffset += a.punch * lerp(0.3, 0.05, bt) * gate;
        // Glow = ambient baseline lift (a.glow)
        surfaces[n].yOffset += a.glow * 0.1 * gate;
        // Beat pushes surfaces up, phase-linked
        surfaces[n].yOffset += beatPulse * lerp(0.25, 0.05, bt) * exp(-a.beatPhase * 2.0) * gate;
        // Kick pulls bass surfaces down (impact compression)
        surfaces[n].yOffset -= kickSurge * lerp(0.35, 0.0, bt) * gate;
        // Brightness adds high-freq surface lift
        surfaces[n].yOffset += a.brightness * lerp(0.0, 0.2, bt) * gate;

        float h = energy * (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
        h += transient * lerp(0.05, 0.2, bt) * gate;
        h += envelope * lerp(0.08, 0.03, bt) * gate;
        h += section * 0.05 * gate;
        h += (n < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;
        h *= gate;

        surfaces[n].amplitude = clamp(h, 0.0, 1.5);
        surfaces[n].gate = gate;
        surfaces[n].freqFrac = bt;

        float3 c = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        c = lerp(c, lerp(a.brainCol, a.brainCol2, bt), 0.3);
        surfaces[n].color = c;
    }
}

// Chladni pattern — nodal lines where particles collect
float chladniPattern(float2 uv, float freq, float phase)
{
    float x = uv.x * PI * freq;
    float y = uv.y * PI * freq;
    // Classic Chladni: sin(nx)sin(my) - sin(mx)sin(ny) = 0 at nodal lines
    float n = freq;
    float m = freq * 0.7 + 1.0;
    float pattern = sin(n * x + phase) * sin(m * y) - sin(m * x) * sin(n * y + phase);
    return abs(pattern);
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

    CymaticSurface surfaces[N_SURFACES];
    computeSurfaces(surfaces, bands, dspBands, kickSurge, beatPulse, a.stereoBal, crest, thd,
                    transientAmt, envelope, a.section, a);

    // ── Camera — looking into the chamber from front ──
    float FOV = 0.65;
    float camAng = a.section * 0.3 + a.stereoBal * 0.15 + Time * 0.02 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 1.5, 0.5 + a.stereoDiff * 0.05, 3.0);
    float3 camTarget = float3(0, 0, -1.5);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Background — dark resonance chamber ──
    float3 col = float3(0.001, 0.001, 0.004) * silence;
    col += starfield(uv, a) * 0.003;

    // ── Cymatic surfaces — parallel planes at different depths ──
    [loop] for (int s = 0; s < N_SURFACES; s++) {
        if (surfaces[s].gate < 0.01) continue;

        float3 surfCenter = float3(0, surfaces[s].yOffset, surfaces[s].zDepth);
        float3 toSurf = surfCenter - camPos;
        float surfDepth = dot(toSurf, fwd);
        if (surfDepth < 0.1) continue;
        float2 scrSurf = float2(dot(toSurf, right) / (surfDepth * FOV), dot(toSurf, up) / (surfDepth * FOV));

        // Surface size in screen space
        float surfSize = 2.5 / (surfDepth * FOV);

        // Grid of particles on surface showing Chladni pattern
        [loop] for (int gx = 0; gx <= GRID_N; gx++) {
            [loop] for (int gy = 0; gy <= GRID_N; gy++) {
                float2 gridUV = float2(float(gx), float(gy)) / float(GRID_N) - 0.5;
                gridUV *= 4.0;  // surface spans -2 to 2

                // Chladni pattern value — phase shifts vertically with audio
                float vertPhase = Time * 0.5 + surfaces[s].freqFrac * PI;
                vertPhase += surfaces[s].yOffset * 2.0; // vertical breathing shifts pattern
                vertPhase += a.beatPhase * surfaces[s].freqFrac * 3.0; // beat propagates through surfaces
                float pattern = chladniPattern(gridUV, surfaces[s].frequency, vertPhase);

                // Particles collect at nodal lines (pattern ≈ 0)
                float nodal = exp(-pattern * pattern * 5.0 * (1.0 + crest * 0.5));

                // THD — surface noise
                nodal *= (1.0 - thd * 0.3 * hash21(gridUV * 50.0 + Time * 10.0));

                // Kick — surface impact displaces particles
                float impactDist = length(gridUV);
                nodal += kickSurge * exp(-impactDist * impactDist * 3.0) * 0.3;

                // Transient — pattern rearrangement
                nodal *= (1.0 - transientAmt * 0.2 * sin(gridUV.x * 20.0 + Time * 30.0));

                if (nodal < 0.01) continue;

                // 3D position on surface — with vertical breathing offset
                float3 particlePos = float3(gridUV.x, gridUV.y + surfaces[s].yOffset, surfaces[s].zDepth);
                // Stereo tilt
                particlePos.y += a.stereoBal * 0.1 * gridUV.x;
                // Vertical wave dispersion — particles ripple vertically with band energy
                particlePos.y += sin(gridUV.x * 3.0 + Time * 2.0 + surfaces[s].freqFrac * PI) * surfaces[s].amplitude * 0.15;

                float3 toPart = particlePos - camPos;
                float partDepth = dot(toPart, fwd);
                if (partDepth < 0.1) continue;
                float2 scrPart = float2(dot(toPart, right) / (partDepth * FOV), dot(toPart, up) / (partDepth * FOV));
                float scrDist = length(p - scrPart);

                float ptSize = 0.01 / max(partDepth * 0.15, 0.3);
                float coreGlow = exp(-scrDist * scrDist / (ptSize * ptSize * 0.1));
                float midGlow = exp(-scrDist * scrDist / (ptSize * ptSize * 0.5));

                float intensity = nodal * surfaces[s].amplitude * (1.0 + lufs * 0.3);
                float depthFade = exp(-partDepth * 0.06);

                col += surfaces[s].color * coreGlow * intensity * depthFade * 0.8 * silence;
                col += surfaces[s].color * midGlow * intensity * depthFade * 0.3 * silence;
            }
        }

        // Surface frame — edge glow
        float2 frameDist = abs(p - scrSurf);
        float frameEdge = max(abs(frameDist.x - surfSize), abs(frameDist.y - surfSize));
        col += surfaces[s].color * exp(-frameEdge * frameEdge * 50.0) * surfaces[s].amplitude * 0.02 * silence;
    }

    // ── Beat — standing wave pulse ──
    col += a.brainCol * beatPulse * exp(-a.beatPhase * 4.0) * 0.03 * silence;

    // ── Kick flash ──
    col += a.brainCol3 * kickSurge * 0.05 * exp(-r * r * 5.0) * silence;

    // ── Transient pop ──
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.025 * silence;

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
    if (maxC > 1.14) col *= 1.14 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
