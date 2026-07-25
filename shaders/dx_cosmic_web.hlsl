// Mode 37: Cosmic Web — 3D dark matter filament network
// Immersive 360° cosmic structure: 24 galaxy cluster nodes (3 per band) at golden-ratio
// positions with visible filaments. You drift through the web.
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

#define PI 3.14159265
#define PHI 1.618
#define N_COMP 8
#define N_NODES 24

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

struct GalaxyNode {
    float3 pos;
    float energy;
    float gate;
    float freqFrac;
    float3 color;
};

void computeNodes(out GalaxyNode nodes[N_NODES], float bands[8], float dspBands[8],
                  float kickSurge, float beatPulse, float stereoBal, float stereoWid,
                  float crest, float thd, float transient, float envelope, float section,
                  float phaseCoh, AudioData a)
{
    [unroll] for (int n = 0; n < N_NODES; n++)
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

        // Golden ratio 3D distribution — VR: you're inside the sphere
        float t = float(n) / float(N_NODES);
        float phi = acos(1.0 - 2.0 * t);
        float theta = float(n) * PHI * PI * 2.0 + stereoBal * 0.4 + panMod * 0.3;
        float radius = 2.0 + sin(float(n) * 1.7) * 0.5;

        // Stereo width stretches the web along X
        float stretchX = 1.0 + stereoWid * 0.4;

        nodes[n].pos = float3(
            radius * sin(phi) * cos(theta) * stretchX,
            radius * cos(phi),
            radius * sin(phi) * sin(theta)
        );

        // Staggered beat breathing
        float h = energy * (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
        h += transient * lerp(0.05, 0.2, bt) * gate;
        h += envelope * lerp(0.08, 0.03, bt) * gate;
        h += section * 0.05 * gate;
        h += (band < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;
        h *= gate;

        nodes[n].energy = clamp(h, 0.0, 1.5);
        nodes[n].gate = gate;
        nodes[n].freqFrac = bt;

        // Color — frequency-positioned with brain palette
        float3 c = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        c = lerp(c, lerp(a.brainCol, a.brainCol2, bt), 0.3);
        nodes[n].color = c;
    }
}

float distToSegment2D(float2 p, float2 a, float2 b, out float2 closest)
{
    float2 ab = b - a;
    float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
    closest = a + ab * t;
    return length(p - closest);
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

    GalaxyNode nodes[N_NODES];
    computeNodes(nodes, bands, dspBands, kickSurge, beatPulse, a.stereoBal, a.stereoWid,
                 crest, thd, transientAmt, envelope, a.section, phaseCoh, a);

    // ── Camera — drifting through the web, VR-friendly 360° ──
    float FOV = 0.7;
    float camAng = a.section * 0.8 + a.stereoBal * 0.2 + Time * 0.03 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 4.0, 1.0 + a.stereoDiff * 0.15, cos(camAng) * 4.0);
    float3 camTarget = float3(0, 0, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Background — deep cosmic void with CMB ──
    float3 col = float3(0.001, 0.001, 0.005) * silence;
    col += starfield(uv, a) * 0.04;
    col += godRays(p, r, a) * 0.04 * silence;

    // Cosmic microwave background — subtle noise
    float cmb = fbm2_4(uv * 8.0) * 0.005 * (1.0 + lufs * 0.1);
    col += float3(0.1, 0.05, 0.15) * cmb * silence;

    // ── Project all nodes to screen space ──
    float2 scrPos[N_NODES];
    float scrDepth[N_NODES];
    float nodeSize[N_NODES];

    [unroll] for (int n = 0; n < N_NODES; n++) {
        float3 toNode = nodes[n].pos - camPos;
        scrDepth[n] = dot(toNode, fwd);
        if (scrDepth[n] < 0.1) { scrPos[n] = float2(999, 999); scrDepth[n] = 0.0; nodeSize[n] = 0.0; continue; }
        scrPos[n] = float2(dot(toNode, right) / (scrDepth[n] * FOV), dot(toNode, up) / (scrDepth[n] * FOV));
        float sz = 0.02 + nodes[n].energy * 0.06;
        if (n < 12) sz *= 1.5;
        nodeSize[n] = sz / max(scrDepth[n] * 0.15, 0.3) * 3.0;
    }

    // ── Filaments — connect nearby nodes with visible lines ──
    [loop] for (int f = 0; f < N_NODES; f++) {
        if (nodes[f].gate < 0.01 || scrDepth[f] < 0.1) continue;

        [loop] for (int g = f + 1; g < N_NODES; g++) {
            if (nodes[g].gate < 0.01 || scrDepth[g] < 0.1) continue;

            float3 a_pos = nodes[f].pos;
            float3 b_pos = nodes[g].pos;
            float filLen = length(a_pos - b_pos);
            if (filLen > 2.5) continue;

            // Filament intensity — product of connected nodes, inverse distance
            float filIntensity = nodes[f].energy * nodes[g].energy / (filLen * 0.5 + 0.1);
            // Phase coherence = filament alignment
            filIntensity *= lerp(0.5, 1.3, phaseCoh);
            filIntensity *= (1.0 + lufs * 0.15);
            // Stereo width stretches filaments
            filIntensity *= (0.8 + a.stereoWid * 0.3);

            // THD — peculiar velocity turbulence
            float turb = fbm2_4(scrPos[f] * 20.0 + Time * 2.0) * thd * 0.1;

            float2 closest;
            float filDist = distToSegment2D(p, scrPos[f], scrPos[g], closest);
            float filWidth = 0.003 + filIntensity * 0.01;
            float filGlow = exp(-filDist * filDist / (filWidth * filWidth));

            // Core line + halo
            float coreGlow = exp(-filDist * filDist / (filWidth * filWidth * 0.15));
            float haloGlow = exp(-filDist * filDist / (filWidth * filWidth * 6.0));

            // Color — blend of connected nodes
            float3 filCol = lerp(nodes[f].color, nodes[g].color, 0.5);

            float avgDepth = (scrDepth[f] + scrDepth[g]) * 0.5;
            float depthFade = exp(-avgDepth * 0.1);

            col += filCol * coreGlow * filIntensity * depthFade * 0.8 * silence;
            col += filCol * haloGlow * filIntensity * depthFade * 0.15 * silence;

            // Beat — shockwave along filament
            col += filCol * beatPulse * filGlow * exp(-a.beatPhase * 4.0) * 0.15 * silence;
        }
    }

    // ── Nodes — glowing galaxy clusters with multi-layer glow ──
    [loop] for (int m = 0; m < N_NODES; m++) {
        if (nodes[m].gate < 0.01 || scrDepth[m] < 0.1) continue;

        float scrDist = length(p - scrPos[m]);
        float sz = nodeSize[m];

        // Multi-layer glow: core + mid + halo
        float coreGlow = exp(-scrDist * scrDist / (sz * sz * 0.08));
        float midGlow = exp(-scrDist * scrDist / (sz * sz * 0.8));
        float haloGlow = exp(-scrDist * scrDist / (sz * sz * 6.0));

        float intensity = nodes[m].energy * (1.0 + lufs * 0.2);
        float depthFade = exp(-scrDepth[m] * 0.1);

        // White-hot core
        col += float3(0.9, 0.95, 1.0) * coreGlow * intensity * depthFade * 2.0 * silence;
        // Colored body
        col += nodes[m].color * midGlow * intensity * depthFade * 1.0 * silence;
        // Soft halo
        col += nodes[m].color * haloGlow * intensity * depthFade * 0.3 * silence;

        // Kick — supernova event at selected node
        int supernovaNode = int(a.beatPhase * float(N_NODES)) % N_NODES;
        if (m == supernovaNode && kickSurge > 0.1) {
            float shellR = a.beatPhase * 0.4;
            float shell = exp(-abs(scrDist - shellR) * 12.0) * kickSurge * 0.5;
            col += nodes[m].color * shell * silence;
            col += float3(1.0, 0.9, 0.7) * coreGlow * kickSurge * 3.0 * silence;
            float snHalo = exp(-scrDist * scrDist / (sz * sz * (6.0 + kickSurge * 20.0)));
            col += nodes[m].color * snHalo * kickSurge * 0.5 * silence;
        }
    }

    // ── Transient — gravitational perturbation ──
    float perturb = transientAmt * fbm2_4(p * 10.0 + Time * 5.0) * 0.04;
    col += a.brainCol3 * perturb * silence;

    // ── High-band shimmer — distant galaxies ──
    float shimmer = (bands[6] + bands[7]) * hash21(p * 100.0 + Time * 20.0) * 0.015;
    col += float3(0.7, 0.8, 1.0) * shimmer * silence;

    // ── Beat ring ──
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
