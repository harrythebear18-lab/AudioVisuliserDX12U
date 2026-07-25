// Mode 36: Spatial Audio Sonar — 360° immersive 3D sonar display
// You are at the center of a spatial audio field. Each of the 8 bands creates a
// concentric ring at a different radius. Sound sources are positioned by:
//   X axis = stereo balance (L = left, R = right)
//   Z axis = frequency band depth (bass near, treble far)
//   Y axis = energy height
// History scrolls outward — older energy fades at the edges.
// Stereo width expands the field. Phase correlation aligns L/R symmetry.
// Beat = omnidirectional sonar ping. Kick = central eruption.
// Transient = surface disruption. LUFS → overall field brightness.
// Crest → edge sharpness. THD → positional jitter. Phase → L/R coherence.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define N_ANGLES 8
#define N_DEPTH 6
#define MAX_RADIUS 4.0

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

struct SonarPing {
    float2 dir;       // normalized direction in XZ plane
    float angle;      // angle around the circle
    float energy;
    float gate;
    float freqFrac;
    float3 color;
};

void computeSonarPings(out SonarPing pings[N_COMP * N_ANGLES], float bands[8], float dspBands[8],
                       float kickSurge, float beatPulse, float stereoBal, float stereoWid,
                       float crest, float thd, float transient, float envelope, float section,
                       float phaseCoh, float leftEn, float rightEn, AudioData a)
{
    [unroll] for (int band = 0; band < N_COMP; band++)
    {
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

        // Per-band color
        float3 c = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        c = lerp(c, lerp(a.brainCol, a.brainCol2, bt), 0.3);

        [unroll] for (int ang = 0; ang < N_ANGLES; ang++)
        {
            int idx = band * N_ANGLES + ang;
            float angleFrac = float(ang) / float(N_ANGLES);
            float angle = angleFrac * PI * 2.0;

            // Stereo positioning — L/R energy modulates angular distribution
            // Left energy biases toward left (angle ~ PI), right toward right (angle ~ 0)
            float lBias = lE * max(0.0, -cos(angle));   // spectrum L drives left half
            float rBias = rE * max(0.0, cos(angle));    // spectrum R drives right half
            float stereoMod = lBias + rBias;

            // Stereo balance shifts the whole field
            angle += stereoBal * 0.3;

            // Phase coherence — high phase = symmetric, low = asymmetric
            float asymmetry = (1.0 - phaseCoh) * sin(angle * 3.0 + Time * 0.5) * 0.15;
            angle += asymmetry;

            // THD jitter
            angle += thd * hash11(float(ang) * 7.3 + float(band) * 13.7 + Time * 20.0) * 0.05;

            pings[idx].dir = float2(cos(angle), sin(angle));
            pings[idx].angle = angle;

            // Staggered beat breathing
            float h = energy * (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
            h += transient * lerp(0.05, 0.2, bt) * gate;
            h += envelope * lerp(0.08, 0.03, bt) * gate;
            h += section * 0.05 * gate;
            h += (band < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;

            // Stereo modulation — energy boosted where stereo field is active
            h *= (0.7 + stereoMod * 0.6);

            // Stereo width expands energy distribution
            h *= (0.8 + stereoWid * 0.4);

            h *= gate;

            pings[idx].energy = clamp(h, 0.0, 1.5);
            pings[idx].gate = gate;
            pings[idx].freqFrac = bt;
            pings[idx].color = c;
        }
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

    SonarPing pings[N_COMP * N_ANGLES];
    computeSonarPings(pings, bands, dspBands, kickSurge, beatPulse, a.stereoBal, a.stereoWid,
                      crest, thd, transientAmt, envelope, a.section, phaseCoh, a.leftEn, a.rightEn, a);

    // ── Camera — top-down with slight tilt, you are at the center ──
    float FOV = 0.75;
    float camAng = a.section * 0.5 + a.stereoBal * 0.2 + Time * 0.02 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 1.5, 3.5, cos(camAng) * 1.5);
    float3 camTarget = float3(0, 0, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Background — dark sonar room ──
    float3 col = float3(0.001, 0.002, 0.004) * silence;
    col += starfield(uv, a) * 0.008;

    // ── Concentric range rings — one per band ──
    [unroll] for (int band = 0; band < N_COMP; band++) {
        float bt = float(band) / float(N_COMP - 1);
        float ringRadius = lerp(0.5, MAX_RADIUS, bt);

        // Project ring center (origin) — it's always at world 0,0,0
        float3 ringCenter = float3(0, 0, 0);
        float3 toCenter = ringCenter - camPos;
        float centerDepth = dot(toCenter, fwd);
        if (centerDepth < 0.1) continue;
        float2 scrCenter = float2(dot(toCenter, right) / (centerDepth * FOV), dot(toCenter, up) / (centerDepth * FOV));

        // Ring projection — approximate as circle in screen space
        float ringScreenR = ringRadius / (centerDepth * FOV);
        float ringDist = abs(length(p - scrCenter) - ringScreenR);

        // Ring line
        float ringWidth = 0.002 + bands[band] * 0.005;
        float ringGlow = exp(-ringDist * ringDist / (ringWidth * ringWidth));

        // Ring color
        float3 ringCol = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        ringCol = lerp(ringCol, lerp(a.brainCol, a.brainCol2, bt), 0.3);

        // Ring intensity — band energy + LUFS
        float ringInt = bands[band] * (1.0 + lufs * 0.2) * (0.5 + envelope * 0.5);
        ringInt *= smoothstep(0.02, 0.08, bands[band]);

        col += ringCol * ringGlow * ringInt * 0.15 * silence;

        // Ring label dots at cardinal positions
        [unroll] for (int card = 0; card < 4; card++) {
            float cardAng = float(card) * PI * 0.5;
            float3 dotPos = float3(cos(cardAng) * ringRadius, 0, sin(cardAng) * ringRadius);
            float3 toDot = dotPos - camPos;
            float dotDepth = dot(toDot, fwd);
            if (dotDepth < 0.1) continue;
            float2 scrDot = float2(dot(toDot, right) / (dotDepth * FOV), dot(toDot, up) / (dotDepth * FOV));
            float dotDist = length(p - scrDot);
            float dotGlow = exp(-dotDist * dotDist * 200.0);
            col += ringCol * dotGlow * ringInt * 0.3 * silence;
        }
    }

    // ── Sonar pings — 3D positioned energy sources with history ──
    [loop] for (int band2 = 0; band2 < N_COMP; band2++) {
        float bt = float(band2) / float(N_COMP - 1);
        float baseRadius = lerp(0.5, MAX_RADIUS, bt);

        [loop] for (int ang2 = 0; ang2 < N_ANGLES; ang2++) {
            int idx = band2 * N_ANGLES + ang2;
            if (pings[idx].gate < 0.01) continue;

            [loop] for (int depth = 0; depth < N_DEPTH; depth++) {
                float timeOffset = float(depth) / float(N_DEPTH - 1);
                // History scrolls outward
                float histRadius = baseRadius + timeOffset * (MAX_RADIUS - baseRadius) * 0.5;
                // Decay with distance
                float decay = exp(-timeOffset * 2.5);

                // 3D position
                float3 pingPos = float3(
                    pings[idx].dir.x * histRadius,
                    pings[idx].energy * decay * 1.2,
                    pings[idx].dir.y * histRadius
                );

                // Project to screen
                float3 toPing = pingPos - camPos;
                float pingDepth = dot(toPing, fwd);
                if (pingDepth < 0.1) continue;
                float2 scrPing = float2(dot(toPing, right) / (pingDepth * FOV), dot(toPing, up) / (pingDepth * FOV));
                float scrDist = length(p - scrPing);

                // Ping glow — multi-layer
                float pingSize = 0.015 + pings[idx].energy * decay * 0.04;
                pingSize /= max(pingDepth * 0.15, 0.3);
                float coreGlow = exp(-scrDist * scrDist / (pingSize * pingSize * 0.1));
                float midGlow = exp(-scrDist * scrDist / (pingSize * pingSize * 0.8));
                float haloGlow = exp(-scrDist * scrDist / (pingSize * pingSize * 5.0));

                // Color — older = dimmer, shift to secondary
                float3 pingCol = pings[idx].color;
                pingCol = lerp(pingCol, a.brainCol2, timeOffset * 0.6);

                float intensity = pings[idx].energy * decay * (1.0 + lufs * 0.2);
                float depthFade = exp(-pingDepth * 0.06);

                // White-hot core
                col += float3(0.9, 0.95, 1.0) * coreGlow * intensity * depthFade * 1.5 * silence;
                // Colored body
                col += pingCol * midGlow * intensity * depthFade * 0.8 * silence;
                // Soft halo
                col += pingCol * haloGlow * intensity * depthFade * 0.2 * silence;
            }
        }
    }

    // ── Beat — omnidirectional sonar ping expanding from center ──
    {
        float3 centerPos = float3(0, 0, 0);
        float3 toCenter = centerPos - camPos;
        float centerDepth = dot(toCenter, fwd);
        if (centerDepth > 0.1) {
            float2 scrCenter = float2(dot(toCenter, right) / (centerDepth * FOV), dot(toCenter, up) / (centerDepth * FOV));
            float centerScreenR = 1.0 / (centerDepth * FOV);
            float pingRadius = a.beatPhase * centerScreenR * 0.8;
            float pingDist = abs(length(p - scrCenter) - pingRadius);
            float pingWidth = 0.005;
            float pingGlow = exp(-pingDist * pingDist / (pingWidth * pingWidth));
            col += a.brainCol * pingGlow * beatPulse * exp(-a.beatPhase * 3.0) * 0.3 * silence;
            // Second ring — stereo-diff delayed
            float ping2Radius = a.beatPhase * centerScreenR * 0.8 + a.stereoDiff * centerScreenR * 0.1;
            float ping2Dist = abs(length(p - scrCenter) - ping2Radius);
            float ping2Glow = exp(-ping2Dist * ping2Dist / (pingWidth * pingWidth));
            col += a.brainCol2 * ping2Glow * beatPulse * exp(-a.beatPhase * 3.0) * 0.15 * silence;
        }
    }

    // ── Kick — central eruption ──
    col += float3(1.0, 0.5, 0.1) * exp(-r * r * 3.0) * kickSurge * 0.25 * silence;

    // ── Stereo indicator — L/R energy bars at edges ──
    {
        float3 lBarPos = float3(-2.5, a.leftEn * 1.5, 0);
        float3 rBarPos = float3(2.5, a.rightEn * 1.5, 0);
        // Left bar
        float3 toL = lBarPos - camPos;
        float lDepth = dot(toL, fwd);
        if (lDepth > 0.1) {
            float2 scrL = float2(dot(toL, right) / (lDepth * FOV), dot(toL, up) / (lDepth * FOV));
            float lDist = length(p - scrL);
            col += a.brainCol * exp(-lDist * lDist * 50.0) * a.leftEn * 0.15 * silence;
        }
        // Right bar
        float3 toR = rBarPos - camPos;
        float rDepth = dot(toR, fwd);
        if (rDepth > 0.1) {
            float2 scrR = float2(dot(toR, right) / (rDepth * FOV), dot(toR, up) / (rDepth * FOV));
            float rDist = length(p - scrR);
            col += a.brainCol2 * exp(-rDist * rDist * 50.0) * a.rightEn * 0.15 * silence;
        }
    }

    // ── Phase coherence indicator — center line ──
    if (phaseCoh > 0.5) {
        float phaseLine = exp(-p.x * p.x * 30.0) * (phaseCoh - 0.5) * 0.04;
        col += float3(0.3, 0.5, 0.4) * phaseLine * silence;
    }

    // ── Transient — surface disruption ──
    float splash = transientAmt * hash21(p * 50.0 + Time * 30.0) * 0.04;
    col += a.brainCol3 * splash * silence;

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

    // ── Standard overlays — surface mode ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── HDR limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.14) col *= 1.14 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
