// Mode 8: Spectrum Helix — 3D horizontal particle flow
//
// Discrete glowing particles in 3D space, flowing horizontally with audio-driven
// motion. Each particle samples its own frequency bin via audioSimElement for
// true per-particle audio reactivity. Camera at slight angle gives depth.
// Particles bunch on beat, surge on kick, scatter on transient, shift color
// with section. Time*motSpeed drives continuous flow, beatPhase for rhythmic.
//
// Audio brain → physics mapping (exclusive roles):
//   b0 Sub      → particle mass / core density
//   b1 Bass     → particle size
//   b2 LMid     → flow turbulence (curl strength)
//   b3 Mid      → vertical spread
//   b4 HMid     → swirl / angular displacement
//   b5 Pres     → hot core brightness
//   b6 Bril     → micro-glint particles
//   b7 Air      → edge dissipation
//   stereoBal   → flow direction + camera drift
//   leftEn/rightEn → independent L/R particle emission
//   beat        → coherent compression
//   kick        → forward surge impulse
//   transient   → scatter disruption
//   section     → color regime shift
//   envelope    → overall emission gain
//
// DSP additive:
//   LUFS  → emission intensity
//   Crest → particle sharpness
//   THD   → position jitter
//   Phase → flow symmetry
//
// Uses audioSimElement for per-particle spectrum sampling. No applyPostFX.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_PARTICLES 64

// Project a 3D point to screen space via camera
float2 project3D(float3 worldPos, float3 camPos, float3 fwd, float3 right, float3 up, float fov, out float depth)
{
    float3 rel = worldPos - camPos;
    depth = dot(rel, fwd);
    if (depth < 0.01) depth = 0.01;
    return float2(dot(rel, right) / (depth * fov), dot(rel, up) / (depth * fov));
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

    // ── Audio brain → physical parameters ──
    float bassMass = (pow(a.b0, 0.5) + pow(a.b1, 0.5)) * 0.5;
    bassMass *= (1.0 + lufs * 0.2);
    float particleSize = 0.015 + a.b1 * 0.03 + bassMass * 0.01;

    // Flow speed — Time*motSpeed for continuous motion (like good modes)
    float flowTime = Time * (0.3 + a.motSpeed * 0.4);
    // Stereo balance = flow direction
    float flowX = a.stereoBal * 0.5 + 0.05;

    // Mid = vertical spread
    float vSpread = 0.5 + a.b3 * 0.7;

    // HMid = turbulence
    float turbStrength = a.b4 * 0.4 + thd * 0.15;

    // Beat = compression
    float beatCompress = a.beat * a.tempoConf;

    // Kick = forward surge
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);

    // ── Background — dark void with smooth gradient (no fbm noise to avoid tearing) ──
    float3 col = float3(0.002, 0.001, 0.005) * silence;
    col += starfield(uv, a) * 0.008;
    // Smooth radial gradient — no floor/frac discontinuities
    float bgGrad = exp(-r * r * 0.8);
    col += lerp(a.brainCol, a.brainCol2, bgGrad) * bgGrad * 0.01 * (0.25 + a.envelope) * silence;

    // ── Camera — slight 3/4 angle, stereo drift ──
    float camAng = a.stereoBal * 0.08 + a.section * 0.04;
    float3 camPos = float3(sin(camAng) * 2.5, 0.3, cos(camAng) * 2.5);
    float3 camTarget = float3(0.0, 0.0, 0.0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);
    float fov = 0.4;

    // ── 3D particle flow — each particle gets its own frequency bin ──
    [loop] for (int i = 0; i < N_PARTICLES; i++)
    {
        float fi = float(i) / float(N_PARTICLES - 1);

        // Per-particle audio data — each particle samples its own frequency
        AudioElement e = audioSimElement(i, N_PARTICLES, a);

        // Noise gate — particles flat when their band is quiet
        float gate = smoothstep(0.02, 0.08, e.amplitude);
        if (gate < 0.01) continue;

        // Compressor — bass bands tamed, highs linear
        float bandAmp = (e.freqFrac < 0.5) ? pow(e.amplitude, 0.5) : e.amplitude;
        bandAmp *= gate;

        // Base 3D position — distributed in a volume
        // Y: vertical spread (frequency height), Z: depth, X: horizontal flow
        float baseY = (e.freqFrac - 0.5) * 2.0 * vSpread;
        float baseZ = (hash11(float(i) * 11.7) - 0.5) * 1.6;

        // Horizontal spread — each particle at a different X position across screen
        float baseX = (hash11(float(i) * 13.1) - 0.5) * 3.0;

        // Stereo pan offset — L/R pan drives horizontal position
        baseX += e.pan * a.stereoWid * 0.8;

        // Horizontal flow drift — smooth sideways motion, no teleport
        baseX += sin(flowTime * (0.3 + e.freqFrac * 0.4) + hash11(float(i) * 7.7) * 6.28) * 0.4 * flowX;

        // Beat compression — particles spread apart slightly on beat
        baseX *= (1.0 + beatCompress * 0.1);

        // Kick surge — push particles in flow direction
        baseX += flowX * kickSurge * 0.25;

        // Cheap turbulence — sin/cos swirl instead of curlN (saves 6 vnoise calls/particle)
        float3 swirl = float3(
            sin(baseY * 2.0 + flowTime * 0.8 + fi * 6.28),
            cos(baseZ * 2.0 + flowTime * 0.6 + fi * 4.71),
            sin(baseX * 2.0 + flowTime * 0.7 + fi * 3.14)
        );
        float3 partPos = float3(baseX, baseY, baseZ) + swirl * turbStrength * 0.12;

        // Transient scatter — per-particle random displacement
        partPos += float3(e.transientScatter, e.transientScatter * 0.7, e.transientScatter * 0.5);

        // THD jitter — quantized time to avoid per-frame position jumps
        float jitterTime = floor(flowTime * 3.0);
        partPos += float3(
            (hash11(float(i) * 17.3 + jitterTime) - 0.5),
            (hash11(float(i) * 19.7 + jitterTime) - 0.5),
            (hash11(float(i) * 23.1 + jitterTime) - 0.5)
        ) * thd * 0.025;

        // Project to screen with perspective
        float depth;
        float2 scr = project3D(partPos, camPos, fwd, right, up, fov, depth);

        // Distance from pixel to projected particle
        float dist = length(p - scr);

        // Perspective size — closer = bigger
        float size = particleSize * (1.0 + bandAmp * 0.6 + kickSurge * 0.4) / max(depth * 0.4, 0.3);
        size /= (1.0 + crest * 0.25);

        // Gaussian glow
        float glow = exp(-dist * dist / max(size * size, 0.000001));
        float core = exp(-dist * dist / max(size * size * 0.15, 0.000001));

        // Depth attenuation
        float depthFade = exp(-depth * 0.08);

        // Color — frequency position + brain colors + section regime
        float hue = a.hueBase + e.freqFrac * a.hueRange + a.section * 0.03;
        float3 partCol = hsv(hue, 0.7 * a.satur, 1.0);
        partCol = lerp(partCol, lerp(a.brainCol, a.brainCol2, e.freqFrac), 0.3);
        // Phase coherence tint
        partCol = lerp(partCol, partCol.gbr, phaseCoh * 0.02);

        // L/R stereo emission — particles on left/right weighted by channel energy
        float stereoWeight = (partPos.x > 0.0) ? e.ampR : e.ampL;
        float emission = bandAmp * (0.5 + stereoWeight * 0.5);

        // Brightness — intensity + LUFS + envelope (like good modes)
        float brightness = e.intensity * (0.5 + lufs * 0.3) * (0.6 + a.envelope * 0.5);
        brightness *= depthFade;
        brightness *= (1.0 + kickSurge * 1.0);

        // Air (b7) — dissipation at edges
        float airFade = 1.0 - a.b7 * smoothstep(0.02, 0.08, a.b7) * 0.12 * smoothstep(0.8, 1.5, abs(baseX));
        brightness *= airFade;

        col += partCol * glow * brightness * 0.2 * silence;
        col += partCol * core * brightness * 0.5 * silence;

        // Presence (b5) — hot core
        float presBright = a.b5 * smoothstep(0.02, 0.08, a.b5);
        if (presBright > 0.01)
        {
            col += float3(0.9, 0.92, 1.0) * core * bandAmp * presBright * 0.15 * silence;
        }

        // Brilliance (b6) — micro-glints
        float brillEnergy = a.b6 * smoothstep(0.02, 0.08, a.b6);
        if (brillEnergy > 0.01)
        {
            float glintSize = size * 0.25;
            float glint = exp(-dist * dist / max(glintSize * glintSize, 0.000001));
            col += partCol * glint * brillEnergy * 0.1 * silence;
        }
    }

    // ── Beat ring — expanding radial pulse ──
    float beatPulseAmt = a.beat * a.tempoConf;
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulseAmt * 0.02 * silence;

    // ── Kick flash ──
    col += float3(1.0, 0.5, 0.1) * kickSurge * 0.03 * exp(-r * r * 4.0) * silence;

    // ── Transient — scatter burst ──
    if (a.transient > 0.02)
    {
        [unroll] for (int s = 0; s < 6; s++)
        {
            float sa = hash11(float(s) * 7.3 + a.beatPhase * 10.0) * PI * 2.0;
            float sr = 0.2 + hash11(float(s) * 11.7) * 0.35;
            float2 sparkPos = float2(cos(sa), sin(sa)) * sr;
            float sparkDist = length(p - sparkPos);
            float sparkGlow = exp(-sparkDist * sparkDist * 250.0);
            col += float3(1.0, 0.9, 0.7) * sparkGlow * a.transient * 0.04 * silence;
        }
    }

    // ── Envelope swell ──
    col += a.brainCol2 * a.envelope * 0.01 * exp(-r * 2.0) * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.012 * silence;

    // ── Energy + punch ──
    col += a.brainCol * a.energy * 0.008 * silence;
    col += a.brainCol2 * a.punch * 0.008 * silence;

    // ── Smooth overlays — no frac() teleport (replaces standardOverlays) ──
    {
        float t = Time * (0.3 + a.dynamic * 1.5 + a.profBass * 0.5);
        // Smooth beat wave — sin instead of frac
        float swR = (sin(t * 0.25) * 0.5 + 0.5) * 1.8;
        float sw = exp(-abs(r - swR) * 16.0) * a.beat * 0.12 * a.tempoConf;
        col += hsv(a.hueCenter + 0.1, 0.6, 1.0) * sw * 0.02 * silence;
        // Smooth kick ring
        float kickR = (sin(t * 0.5) * 0.5 + 0.5) * 1.5 + 0.3;
        float kickRing = exp(-abs(r - kickR) * 20.0) * a.kick * 0.05 * a.kickConf;
        col += hsv(a.hueCenter, 0.3, 1.0) * kickRing * 0.02 * silence;
        // Ambient glow
        col += hsv(a.hueCenter, 0.2, 0.3) * smoothstep(1.0, 0.3, r) * (0.01 + a.atmos * 0.04) * a.ambActive * 0.01 * silence;
        // Phrase pulse
        col *= (1.0 + sin(a.phraseBeat / 16.0 * 3.14159) * 0.06 * a.energy);
        // Global brightness
        col *= (0.3 + a.gated * 0.8 + a.brightness * 0.15);
    }

    // ── HDR brightness limiter — 5% below max ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 0.95) col *= 0.95 / maxC;

    return float4(col, 1.0);
}
