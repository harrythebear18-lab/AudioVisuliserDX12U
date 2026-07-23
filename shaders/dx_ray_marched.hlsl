// ============================================================================
// HUD 11: Spectrum Kaleidoscope (dx_ray_marched.hlsl)
// DX12U Layer 0 — 3D kaleidoscopic fractal with audio-driven fold symmetry,
// per-band orbit trap coloring, and DSP-modulated surface detail.
//
// The fractal is a kaleidoscopic IFS (iterative function system) with N-fold
// radial symmetry. Each iteration samples a different frequency band for orbit
// trap coloring. The fold scale, rotation, and displacement are all driven by
// exclusive audio brain band roles.
//
// Audio mapping (exclusive roles per DX12U_VISUALIZATION_RULES.md):
//   b0 Sub      → fold scale power (fractal complexity / recursion depth)
//   b1 Bass     → fold explosion amplitude (kick-driven burst)
//   b2 LMid     → vertical fold asymmetry (Y-axis warp)
//   b3 Mid      → kaleidoscopic fold count (symmetry order)
//   b4 HMid     → surface specular sharpness / fresnel power
//   b5 Pres     → orbit trap emission brightness (hot core glow)
//   b6 Bril     → high-frequency surface detail / micro-displacement
//   b7 Air      → atmospheric fade / depth haze
//   stereoBal   → camera orbit direction + light position bias
//   beat        → camera zoom pulse + fractal emission flash
//   kick        → fold scale explosion (sudden complexity burst)
//   transient   → dimensional glitch (random domain displacement)
//   section     → fold count unlock (more symmetry in higher sections)
//   envelope    → overall emission gain
//
// DSP additive: LUFS→emission boost, crest→specular sharpness, THD→glitch
//               displacement magnitude, phase→rotation coherence.
//
// HDR output to shared pipeline. No local postfx, tonemapping, or bloom.
// ============================================================================

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define KALEIDO_ITER 8
#define MARCH_STEPS 48

// 8 brain band frequency centers in spectrum texture U coordinate
static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

// ── Kaleidoscopic IFS SDF ──
// 8 iterations, each driven by its own brain band. Band energy shapes the
// fold scale, rotation, displacement, and Y-warp for that iteration — so
// each frequency band visibly sculpts a different layer of the fractal.
float kaleidoSDF(float3 p, AudioData a, float time, float foldCount,
                 float glitchAmt, out float3 trapCol)
{
    float3 z = p;
    float dr = 1.0;
    trapCol = float3(0.0, 0.0, 0.0);

    float foldAngle = 2.0 * PI / foldCount;

    // Brain bands — each drives one iteration
    // Apply gain curve to boost low-volume sensitivity: sqrt expands quiet signals
    float rawBands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    float bands[8];
    [unroll] for (int g = 0; g < 8; g++)
    {
        // sqrt gives 2x boost at 0.25, 3x at 0.11, etc — makes quiet audio visible
        float v = max(rawBands[g], 0.0);
        bands[g] = pow(sqrt(v), 0.5);  // double-compound sqrt: v^0.25
    }

    // L/R stereo split per band
    float bal = a.stereoBal;
    float leftFrac = clamp(0.5 - bal * 0.3, 0.1, 0.9);
    float rightFrac = 1.0 - leftFrac;

    [unroll] for (int i = 0; i < 6; i++)
    {
        float bandVal = bands[i];

        // Per-band fold scale
        float bandFold = 1.1 + bandVal * 1.0 + a.kick * a.kickConf * 0.4 * (i < 2 ? 1.0 : 0.0);

        // Per-band rotation
        float bandRot = time * (0.02 + bandVal * 0.15) * (i % 2 == 0 ? 1.0 : -1.0);
        float2 bandRotC = float2(cos(bandRot), sin(bandRot));

        // Per-band displacement — skip when quiet
        if (bandVal > 0.01)
        {
            z += float3(
                sin(time * 0.7 + float(i) * 0.9) * bandVal * 0.12,
                cos(time * 0.5 + float(i) * 1.3) * bandVal * 0.10,
                sin(time * 0.6 + float(i) * 1.7) * bandVal * 0.12
            );
        }

        // Kaleidoscopic fold
        float ang = atan2(z.z, z.x);
        float rad = length(z.xz);
        ang = abs(fmod(ang, foldAngle)) - foldAngle * 0.5;
        z.xz = float2(cos(ang), sin(ang)) * rad;

        // Box fold with per-band Y-warp
        z = abs(z);
        z.y += bandVal * 0.6 * sin(z.x * 3.0 + time * 0.5 + float(i));
        z -= 1.0;

        // Per-band rotation
        z.xz = float2(z.x * bandRotC.x - z.z * bandRotC.y, z.x * bandRotC.y + z.z * bandRotC.x);

        // High bands (b4-b5) add micro-displacement
        if (i >= 4 && bandVal > 0.01)
        {
            z += float3(
                sin(z.y * (10.0 + float(i) * 3.0) + time * 2.0),
                cos(z.z * (12.0 + float(i) * 2.0) + time * 1.7),
                sin(z.x * (14.0 + float(i) * 2.0) + time * 2.3)
            ) * bandVal * 0.02;
        }

        // Transient glitch
        if (glitchAmt > 0.02)
        {
            z += float3(
                sin(z.y * 25.0 + time * 18.0 + float(i)) * glitchAmt * 0.03,
                cos(z.z * 22.0 + time * 15.0 + float(i)) * glitchAmt * 0.025,
                sin(z.x * 28.0 + time * 12.0 + float(i)) * glitchAmt * 0.03
            );
        }

        // Scale and offset — per-band fold scale
        z = z * bandFold + p;
        dr = dr * abs(bandFold) + 1.0;

        // Orbit trap — band-specific color with L/R stereo tint
        float specL = bandVal * leftFrac;
        float specR = bandVal * rightFrac;
        float bandHue = a.hueBase + float(i) / 7.0 * a.hueRange + a.section * 0.03;
        float trapWeight = 1.0 / (1.0 + dot(z, z) * 0.08);

        float3 tc = hsv(bandHue, 0.85 * a.satur, 0.15 + bandVal * 1.0);
        // L/R stereo tint: left=cool, right=warm
        tc = lerp(tc, tc * float3(0.7, 0.85, 1.3), specL * 0.2);
        tc = lerp(tc, tc * float3(1.3, 0.85, 0.7), specR * 0.2);
        trapCol += tc * trapWeight;
    }

    return length(z) / abs(dr);
}

// ── Surface normal via tetrahedral gradient ──
float3 calcNormal(float3 p, AudioData a, float time, float foldCount,
                  float glitchAmt)
{
    float eps = 0.0008;
    float3 dummy;
    float2 h = float2(1.0, -1.0) * 0.5773 * eps;
    return normalize(
        h.xyy * kaleidoSDF(p + h.xyy, a, time, foldCount, glitchAmt, dummy) +
        h.yyx * kaleidoSDF(p + h.yyx, a, time, foldCount, glitchAmt, dummy) +
        h.yxy * kaleidoSDF(p + h.yxy, a, time, foldCount, glitchAmt, dummy) +
        h.xxx * kaleidoSDF(p + h.xxx, a, time, foldCount, glitchAmt, dummy)
    );
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

    // ── Audio brain → fractal parameters ──
    // Bands now drive geometry inside the SDF per-iteration. These control global fractal properties.
    float foldCount = lerp(4.0, 8.0, a.b3) + a.section * 0.5;          // b3: mid drives symmetry order
    foldCount = clamp(foldCount, 3.0, 10.0);
    float fresnelPower = 2.0 + a.b4 * 3.0 + crest * 2.0;               // b4: high-mid + crest → fresnel
    float trapEmission = a.b5 * smoothstep(0.02, 0.08, a.b5);          // b5: presence drives trap glow
    float airFade = a.b7 * smoothstep(0.02, 0.08, a.b7);               // b7: air drives depth haze

    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float glitchAmt = a.transient * (0.5 + thd * 0.5);                 // transient + THD → glitch

    // ── Background — deep void with nebula haze ──
    float3 col = float3(0.003, 0.002, 0.008) * silence;
    col += starfield(uv, a) * 0.015;
    float nebula = fbm2_4(p * 1.5 + Time * 0.02 * a.motSpeed);
    col += a.brainCol * nebula * 0.015 * a.ambient * a.ambActive * silence;

    // ── Camera — pulled back, gentle vertical sway from stereo + beat zoom ──
    float beatZoom = 1.0 - beatPulse * 0.08;
    float camDist = 4.5 * beatZoom - a.b0 * 0.3 + kickSurge * 0.4;
    float camY = sin(Time * 0.15) * 0.3 + a.stereoDiff * 0.15 + a.b2 * 0.2;
    float3 camPos = float3(0.0, camY, camDist);
    float3 camTarget = float3(0.0, sin(Time * 0.1) * 0.1, 0.0);
    float3 rd = cameraRay(camPos, camTarget, p, 1.0);

    // ── Raymarch ──
    float t = 0.05;
    float marchGlow = 0.0;
    float steps = 0.0;
    bool hit = false;
    float3 trapColor = float3(0.0, 0.0, 0.0);

    [loop] for (int i = 0; i < MARCH_STEPS; i++)
    {
        float3 sp = camPos + rd * t;
        float3 tc;
        float d = kaleidoSDF(sp, a, Time, foldCount, glitchAmt, tc);
        marchGlow += 0.012 / (1.0 + d * d * 40.0);
        steps += 1.0;
        if (d < 0.001) { hit = true; trapColor = tc; break; }
        t += d * 0.65;
        if (t > 8.0) break;
    }
    float ao = 1.0 - steps / float(MARCH_STEPS) * 0.5;

    if (hit)
    {
        float3 hp = camPos + rd * t;
        float3 n = calcNormal(hp, a, Time, foldCount, glitchAmt);

        // 3-light setup — stereo-balanced
        float3 lDir1 = normalize(float3(0.5, 1.0, 0.3));
        float3 lDir2 = normalize(float3(-0.8 + a.stereoBal * 1.6, 0.5, 0.2));
        float3 lDir3 = normalize(float3(0.0, -0.4, 0.8));
        float diff1 = max(dot(n, lDir1), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
        float diff3 = max(dot(n, lDir3), 0.0) * 0.2;
        float spec = pow(max(dot(reflect(-lDir1, n), -rd), 0.0), 32.0 + crest * 64.0);
        float fres = pow(1.0 - max(dot(n, -rd), 0.0), fresnelPower);

        // Orbit trap coloring — per-band from SDF
        float3 baseCol = trapColor / 6.0;
        baseCol = lerp(baseCol, a.brainCol, 0.15);

        // Lighting composition
        float3 litCol = baseCol * (diff1 + diff2 + diff3) * (0.4 + a.brightness * 0.4);
        litCol += float3(1.0, 0.98, 0.9) * spec * 0.35 * (0.5 + a.dynActive * 0.5);
        litCol += a.brainCol2 * fres * (0.25 + a.b4 * 0.25);

        // Presence (b5) — orbit trap emission (hot inner glow)
        float emit = dot(trapColor, trapColor) * 0.03 * a.envelope * (1.0 + trapEmission * 2.5);
        litCol += baseCol * emit * silence;

        // Beat emission — fresnel flash on beat
        float beatEmit = beatPulse * 0.18 * fres;
        litCol += hsv(a.hueCenter, 0.5, 1.0) * beatEmit * silence;

        // Kick flash — warm radial burst
        float kickFlash = kickSurge * 0.2 * exp(-length(hp) * 0.4);
        litCol += float3(1.0, 0.5, 0.15) * kickFlash * silence;

        // LUFS additive — brighter when louder
        litCol *= (1.0 + lufs * 0.4);

        // AO + ambient
        litCol *= ao * (0.35 + a.ambient * 0.65) * a.ambActive;

        // Air (b7) — depth haze fade
        float depthHaze = exp(-t * 0.15) * (1.0 - airFade * 0.3);
        litCol *= depthHaze;

        col = blendScreen(col, litCol);
    }

    // ── Volumetric glow — march accumulation ──
    col += a.brainCol2 * marchGlow * 0.04 * silence;
    col += a.brainCol * marchGlow * trapEmission * 0.03 * silence;

    // ── Global beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.8);
    col += a.brainCol * exp(-ringDist * ringDist * 50.0) * beatPulse * 0.015 * silence;

    // ── Kick flash ──
    col += float3(1.0, 0.5, 0.1) * kickSurge * 0.02 * exp(-r * r * 4.0) * silence;

    // ── Transient scatter ──
    if (a.transient > 0.02)
    {
        [unroll] for (int s = 0; s < 6; s++)
        {
            float sa = hash11(float(s) * 7.3 + a.beatPhase * 10.0) * PI * 2.0;
            float sr = 0.2 + hash11(float(s) * 11.7) * 0.4;
            float2 sparkPos = float2(cos(sa), sin(sa)) * sr;
            float sparkDist = length(p - sparkPos);
            float sparkGlow = exp(-sparkDist * sparkDist * 300.0);
            col += float3(1.0, 0.9, 0.7) * sparkGlow * a.transient * 0.03 * silence;
        }
    }

    // ── Envelope swell ──
    col += a.brainCol2 * a.envelope * 0.008 * exp(-r * 2.0) * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.01 * silence;

    // ── Energy + punch ──
    col += a.brainCol * a.energy * 0.005 * silence;
    col += a.brainCol2 * a.punch * 0.005 * silence;

    // ── Smooth overlays — no frac() teleport ──
    {
        float t2 = Time * (0.3 + a.dynamic * 1.5 + a.profBass * 0.5);
        float swR = (sin(t2 * 0.25) * 0.5 + 0.5) * 1.8;
        float sw = exp(-abs(r - swR) * 16.0) * a.beat * 0.12 * a.tempoConf;
        col += hsv(a.hueCenter + 0.1, 0.6, 1.0) * sw * 0.015 * silence;
        float kickR = (sin(t2 * 0.5) * 0.5 + 0.5) * 1.5 + 0.3;
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
