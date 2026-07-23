// ============================================================================
// HUD 9: Acoustic Wavefront Propagator (dx_heartbeat.hlsl)
// DX12U Layer 0 — 3D expanding spherical wavefronts from 24 golden-ratio
// distributed acoustic sources. Each source emits expanding phase fronts
// rendered as thin projected ring outlines in 3D perspective. Where
// wavefronts from multiple sources overlap, constructive interference
// produces bright intersection arcs; destructive gaps create dark lanes.
//
// This is a true 3D wave propagation phenomenon — not particles, not a
// heightfield, not volumetric fog. The silhouette is layered concentric
// shells and interference rings expanding through space.
//
// Audio mapping (exclusive roles per DX12U_VISUALIZATION_RULES.md):
//   b0 Sub      → wavefront amplitude / expansion speed (low freq = slow, massive)
//   b1 Bass     → source radius scale / wavefront thickness
//   b2 LMid     → source angular distribution (topology of emitter placement)
//   b3 Mid      → wavefront count / emission rate
//   b4 HMid     → wavefront sharpness / ring definition
//   b5 Pres     → interference brightness (constructive overlap glow)
//   b6 Bril     → micro-ripple detail on wavefront surfaces
//   b7 Air      → high-frequency wavefront dissipation / edge fade
//   stereoBal   → camera orbit direction + source lateral bias
//   stereoWid   → source spread asymmetry
//   beat        → coherent global pulse — all sources fire simultaneously
//   kick        → impulsive point-source burst from dominant band source
//   transient   → wavefront rupture / scatter — breaks clean rings into shards
//   section     → emission regime unlock (more wavefronts in higher sections)
//   envelope    → overall emission gain
//   domBand     → highlighted source (brightest emitter)
//
// DSP additive: LUFS→emission boost, crest→ring sharpness, THD→wavefront
//               roughness, phase→interference coherence.
//
// HDR output to shared pipeline. No local postfx or tonemapping.
// ============================================================================

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define PHI 1.61803399
#define N_SOURCES 24
#define N_WAVES 5    // max concurrent wavefronts per source (section-gated)

// Golden ratio sphere distribution — Fibonacci lattice
float3 goldenSpherePos(int i, int total, float radius)
{
    float fi = float(i) + 0.5;
    float ft = float(total);
    float phi = acos(1.0 - 2.0 * fi / ft);
    float theta = PI * (1.0 + PHI) * fi;
    return float3(
        sin(phi) * cos(theta) * radius,
        sin(phi) * sin(theta) * radius,
        cos(phi) * radius
    );
}

// Project a 3D point to screen space
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

    // ── DSP additive ──
    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();

    // ── Audio brain → wave propagation parameters ──
    float bassMass = pow(a.b0, 0.5) * (1.0 + lufs * 0.2);
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;

    // Wavefront dynamics — each band has an exclusive physical role
    float expandSpeed = 0.35 + a.b0 * 0.5 + a.motSpeed * 0.15;      // b0: sub drives expansion
    float sourceRadius = 0.6 + a.b1 * 0.4 * bassMass;                // b1: bass drives source sphere size
    float angularSpread = 0.8 + a.b2 * 0.4;                          // b2: low-mid drives topology
    int activeWaves = clamp(int(2 + a.b3 * 3.0 + a.section * 0.5), 2, N_WAVES); // b3: mid drives wave count
    float ringSharpness = 80.0 + a.b4 * 120.0 + crest * 60.0;        // b4: high-mid drives sharpness
    float interferenceGlow = a.b5 * smoothstep(0.02, 0.08, a.b5);    // b5: presence drives overlap
    float microRipple = a.b6 * smoothstep(0.02, 0.08, a.b6);         // b6: brilliance drives micro-ripple
    float airDissip = a.b7 * smoothstep(0.02, 0.08, a.b7);           // b7: air drives edge fade

    // ── Background — deep void with subtle gradient ──
    float3 col = float3(0.001, 0.001, 0.004) * silence;
    col += starfield(uv, a) * 0.012;
    float bgGrad = exp(-r * r * 0.6);
    col += lerp(a.brainCol, a.brainCol2, bgGrad) * bgGrad * 0.006 * (0.2 + a.envelope) * silence;

    // ── Camera — section-driven orbit, stereo drift per pipeline rules ──
    float camAng = a.section * 0.8 + Time * 0.03 * a.motSpeed + a.stereoBal * 0.2;
    float3 camPos = float3(sin(camAng) * 4.5, 1.2 + a.stereoDiff * 0.15, cos(camAng) * 4.5);
    float3 camTarget = float3(0.0, 0.0, 0.0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);
    float fov = 0.5;

    // ── Wavefront rendering — per-source, no arrays ──
    // Each source computes its 3D position, projects to screen, then renders
    // its expanding wavefront rings. No stored arrays — everything on the fly.
    float waveTime = Time * expandSpeed;

    [loop] for (int s = 0; s < N_SOURCES; s++)
    {
        AudioElement e = audioSimElement(s, N_SOURCES, a);
        float gate = smoothstep(0.02, 0.08, e.amplitude);
        if (gate < 0.01) continue;

        float amp = e.amplitude * gate;
        float bandAmp = (e.freqFrac < 0.4) ? pow(amp, 0.5) : amp;

        // ── Source 3D position — golden ratio sphere + audio displacement ──
        // Cf = (Dx * PI) / PHI — golden ratio frequency compression for radius
        float Cf = (e.freqFrac * PI) / PHI;
        float srcRad = sourceRadius * angularSpread + Cf * 0.12;
        float3 srcPos = goldenSpherePos(s, N_SOURCES, srcRad);

        // Audio-driven displacement
        srcPos.x += e.pan * a.stereoWid * 0.35;
        srcPos.y += (e.freqFrac - 0.5) * a.b2 * 0.3;  // b2: vertical spread
        srcPos += float3(e.transientScatter, e.transientScatter * 0.6, e.transientScatter * 0.4);

        // THD jitter on source position
        float jt = floor(waveTime * 4.0);
        srcPos += float3(
            (hash11(float(s) * 17.3 + jt) - 0.5),
            (hash11(float(s) * 19.7 + jt) - 0.5),
            (hash11(float(s) * 23.1 + jt) - 0.5)
        ) * thd * 0.03;

        // Phase coherence — mono sources cluster, stereo sources spread
        srcPos.x += (1.0 - phaseCoh) * sin(float(s) * 2.4 + waveTime * 0.2) * 0.12 * a.stereoWid;

        // ── Project source to screen space ──
        float srcDepth;
        float2 sp = project3D(srcPos, camPos, fwd, right, up, fov, srcDepth);
        if (srcDepth < 0.15) continue;

        float depthFade = exp(-srcDepth * 0.05);

        // ── Source color ──
        float hue = a.hueBase + e.freqFrac * a.hueRange + a.section * 0.03;
        float3 srcCol = hsv(hue, 0.75 * a.satur, 1.0);
        srcCol = lerp(srcCol, lerp(a.brainCol, a.brainCol2, e.freqFrac), 0.35);
        srcCol = lerp(srcCol, srcCol.gbr, phaseCoh * 0.02);

        // Dominant band highlight
        float domHighlight = smoothstep(0.7, 0.95, 1.0 - abs(e.freqFrac - a.domBand / 7.0));
        srcCol = lerp(srcCol, float3(1.0, 0.95, 0.85), domHighlight * 0.2);

        // ── Source point glow ──
        float srcDist = length(p - sp);
        float srcGlow = exp(-srcDist * srcDist * 400.0) * amp;
        float srcCore = exp(-srcDist * srcDist * 3000.0) * amp;
        col += srcCol * srcGlow * 0.12 * depthFade * silence;
        col += srcCol * srcCore * 0.35 * depthFade * silence;

        // Presence (b5) — hot core on dominant sources
        if (interferenceGlow > 0.01)
            col += float3(0.9, 0.92, 1.0) * srcCore * interferenceGlow * domHighlight * 0.2 * silence;

        // ── Expanding wavefronts ──
        // Each wavefront is a 3D spherical shell expanding from the source.
        // Projected to 2D, it appears as a thin ring (the sphere silhouette).
        // We render the ring as a sharp Gaussian profile around the projected radius.

        float2 toP = p - sp;
        float distToCenter = length(toP);
        float angle = atan2(toP.y, toP.x);

        [loop] for (int w = 0; w < activeWaves; w++)
        {
            // Wavefront phase — each wave at a different expansion stage
            float wPhase = frac(waveTime * (0.4 + e.freqFrac * 0.6) + float(w) / float(activeWaves) + float(s) * 0.03);
            float waveRadius3D = wPhase * 3.0;  // 3D radius in world units

            // Projected ring radius (perspective)
            float R_proj = waveRadius3D / (srcDepth * fov);

            // Skip if ring is too small or too large to be visible
            if (R_proj < 0.005 || R_proj > 3.0) continue;

            // Wavefront amplitude fades as it expands (1/r energy spreading)
            float waveFade = (1.0 - wPhase) * (1.0 - wPhase) / (1.0 + wPhase * 0.5);
            waveFade *= 1.0 - airDissip * smoothstep(0.4, 1.0, wPhase);  // b7: air dissipation

            // Angular deformation — wavefronts aren't perfect spheres
            // Low frequencies deform slowly, high frequencies ripple fast
            float deformFreq = 2.0 + e.freqFrac * 4.0;
            float deform = sin(angle * deformFreq + waveTime * (0.5 + e.freqFrac) + float(s) * 1.3) * 0.015;
            deform += sin(angle * (deformFreq * 2.0) + waveTime * 0.8) * microRipple * 0.008;  // b6: micro-ripple

            // Transient disruption — breaks rings into angular shards
            float transientBreak = 1.0;
            if (transientAmt > 0.02)
            {
                float breakSeed = hash11(float(s * 31 + w * 17) + floor(waveTime * 6.0));
                float breakAngle = frac(breakSeed) * 2.0 * PI;
                float angleDiff = abs(atan2(sin(angle - breakAngle), cos(angle - breakAngle)));
                transientBreak = 1.0 - transientAmt * smoothstep(0.6, 0.0, angleDiff) * step(0.6, breakSeed);
            }

            // Distance to ring outline (with deformation)
            float distToRing = abs(distToCenter - R_proj - deform * R_proj);

            // Ring glow — sharp Gaussian profile
            float ringGlow = exp(-distToRing * distToRing * ringSharpness) * waveFade * transientBreak;

            // Beat synchronization — wavefronts brighten when aligned with beat phase
            float beatSync = exp(-abs(wPhase - a.beatPhase) * 5.0) * beatPulse;

            // Kick impulse — bass sources emit a large fast wavefront on kick
            float kickWave = 0.0;
            if (e.freqFrac < 0.35 && kickSurge > 0.01)
            {
                float kickR3D = a.beatPhase * 3.5;
                float kickR_proj = kickR3D / (srcDepth * fov);
                float kickDist = abs(distToCenter - kickR_proj);
                kickWave = exp(-kickDist * kickDist * 100.0) * kickSurge * (1.0 - e.freqFrac);
            }

            // Brightness composition
            float brightness = bandAmp * waveFade * (0.35 + beatSync * 0.65) * (1.0 + lufs * 0.25);
            brightness *= depthFade;
            brightness *= (0.5 + a.envelope * 0.5);
            brightness *= (0.3 + a.gated * 0.8 + a.brightness * 0.15);

            // Accumulate ring color
            col += srcCol * ringGlow * brightness * 0.18 * silence;

            // Kick wavefront — warm impulse color
            if (kickWave > 0.001)
                col += float3(1.0, 0.55, 0.15) * kickWave * 0.12 * silence;

            // Brilliance (b6) — micro-glints on ring edges
            if (microRipple > 0.01 && ringGlow > 0.01)
            {
                float glintHash = hash11(float(s * 53 + w * 29) + angle * 8.0 + floor(waveTime * 10.0));
                float glint = step(0.93, glintHash) * ringGlow * microRipple;
                col += float3(0.85, 0.9, 1.0) * glint * 0.08 * silence;
            }
        }
    }

    // ── Interference field — constructive overlap glow ──
    // Where multiple wavefronts overlap, add a soft bloom of interference color
    // This is naturally produced by the additive accumulation above, but we
    // enhance it with a presence-driven (b5) boost on bright pixels
    if (interferenceGlow > 0.01)
    {
        float maxC = max(col.r, max(col.g, col.b));
        float interferenceMask = smoothstep(0.15, 0.5, maxC);
        col += a.brainCol3 * interferenceMask * interferenceGlow * 0.04 * silence;
    }

    // ── Global beat ring — expanding pulse from center ──
    float globalRingDist = abs(r - a.beatPhase * 0.9);
    col += a.brainCol * exp(-globalRingDist * globalRingDist * 45.0) * beatPulse * 0.015 * silence;

    // ── Kick flash ──
    col += float3(1.0, 0.5, 0.1) * kickSurge * 0.025 * exp(-r * r * 4.0) * silence;

    // ── Transient scatter ──
    if (transientAmt > 0.02)
    {
        [unroll] for (int sp2 = 0; sp2 < 6; sp2++)
        {
            float sa = hash11(float(sp2) * 7.3 + a.beatPhase * 10.0) * PI * 2.0;
            float sr = 0.2 + hash11(float(sp2) * 11.7) * 0.4;
            float2 sparkPos = float2(cos(sa), sin(sa)) * sr;
            float sparkDist = length(p - sparkPos);
            float sparkGlow = exp(-sparkDist * sparkDist * 350.0);
            col += float3(1.0, 0.9, 0.7) * sparkGlow * transientAmt * 0.03 * silence;
        }
    }

    // ── Envelope swell ──
    col += a.brainCol2 * a.envelope * 0.008 * exp(-r * 2.0) * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.01 * silence;

    // ── Energy + punch ──
    col += a.brainCol * a.energy * 0.006 * silence;
    col += a.brainCol2 * a.punch * 0.006 * silence;

    // ── Smooth overlays — no frac() teleport ──
    {
        float t = Time * (0.3 + a.dynamic * 1.5 + a.profBass * 0.5);
        float swR = (sin(t * 0.25) * 0.5 + 0.5) * 1.8;
        float sw = exp(-abs(r - swR) * 16.0) * a.beat * 0.12 * a.tempoConf;
        col += hsv(a.hueCenter + 0.1, 0.6, 1.0) * sw * 0.015 * silence;
        float kickR = (sin(t * 0.5) * 0.5 + 0.5) * 1.5 + 0.3;
        float kickRing = exp(-abs(r - kickR) * 20.0) * a.kick * 0.05 * a.kickConf;
        col += hsv(a.hueCenter, 0.3, 1.0) * kickRing * 0.015 * silence;
        col += hsv(a.hueCenter, 0.2, 0.3) * smoothstep(1.0, 0.3, r) * (0.01 + a.atmos * 0.04) * a.ambActive * 0.008 * silence;
        col *= (1.0 + sin(a.phraseBeat / 16.0 * 3.14159) * 0.06 * a.energy);
    }

    // ── HDR brightness limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    return float4(col, 1.0);
}
