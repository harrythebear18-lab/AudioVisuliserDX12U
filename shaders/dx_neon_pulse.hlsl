// Mode 3: Spectrum Sonar — professional polar spectrum display
// 64 spectrum bins around 360°, filled bars with gradient, L/R stereo lobes
// Sonar sweep with persistence trail, beat rings, kick flash, transient contacts
// Frequency gradient coloring, ambient glow, center bass pulse, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define RADAR_BINS 64

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float ang = atan2(p.y, p.x);

    // ── Background — dark sonar screen with subtle gradient ──
    float3 col = float3(0.003, 0.006, 0.005) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.1;

    // Ambient center glow — bass driven
    float ambientGlow = exp(-r * r * 3.0) * (0.02 + a.profBass * 0.04);
    col += a.brainCol * ambientGlow * (1.0 - a.isSilent);

    // ── Sonar range rings — concentric circles with labels ──
    [unroll] for (int ri = 1; ri <= 4; ri++) {
        float ringR = ri * 0.32;
        float ringDist = abs(r - ringR);
        float ringGlow = exp(-ringDist * ringDist * 2500.0) * 0.4;
        col += float3(0.015, 0.04, 0.025) * ringGlow * (1.0 - a.isSilent);
    }

    // ── Sonar crosshairs — cardinal directions ──
    float angDist0 = min(abs(ang), abs(abs(ang) - 3.14159));
    float angDist90 = abs(abs(ang) - 1.5708);
    float crosshair = min(angDist0, angDist90);
    col += float3(0.015, 0.04, 0.02) * exp(-crosshair * crosshair * 150.0) * exp(-r * r * 2.5) * 0.25 * (1.0 - a.isSilent);

    // ── Spectrum sonar bins — filled bars with gradient ──
    [loop] for (int bi = 0; bi < RADAR_BINS; bi++) {
        AudioElement e = audioSimElement(bi, RADAR_BINS, a);

        float binAng = (float(bi) / RADAR_BINS) * 6.28318 - 3.14159;
        float angDiff = abs(ang - binAng);
        angDiff = min(angDiff, 6.28318 - angDiff);

        float barInner = 0.06;
        float barOuter = 0.06 + e.amplitude * 0.55 * a.barScale;
        float angWidth = 6.28318 / RADAR_BINS * 0.85;

        if (angDiff < angWidth && r > barInner && r < barOuter) {
            float rf = (r - barInner) / max(barOuter - barInner, 0.001);
            float angFade = 1.0 - angDiff / angWidth;

            // Frequency gradient color
            float hue = a.hueBase + e.freqFrac * a.hueRange;
            float3 binCol = hsv(hue, 0.7 * a.satur, 0.7 + rf * 0.3);
            binCol = lerp(binCol, a.brainCol, 0.2);
            binCol = lerp(binCol, a.brainCol2, e.pan * 0.5 + 0.5);

            // Filled bar with angular falloff
            float barIntensity = angFade * (0.3 + e.intensity * 0.5);
            col += binCol * barIntensity * (1.0 - a.isSilent);

            // Bright tip on bar
            float tipGlow = smoothstep(0.8, 1.0, rf) * e.amplitude * 0.4 * angFade;
            col += binCol * tipGlow * a.bloomActive * (1.0 - a.isSilent);

            // Inner edge glow
            float innerEdge = smoothstep(0.0, 0.1, rf) * smoothstep(0.2, 0.0, rf) * angFade * 0.15;
            col += binCol * innerEdge * (1.0 - a.isSilent);
        }

        // L/R lobes — separate L and R amplitude as glowing dots
        float2 lobePosL = float2(cos(binAng), sin(binAng)) * (0.12 + e.ampL * 0.45);
        float2 lobePosR = float2(cos(binAng), sin(binAng)) * (0.12 + e.ampR * 0.45);
        float lobeDistL = length(p - lobePosL);
        float lobeDistR = length(p - lobePosR);
        col += a.brainCol * exp(-lobeDistL * lobeDistL * 200.0) * e.ampL * 0.12 * (1.0 - a.isSilent);
        col += a.brainCol2 * exp(-lobeDistR * lobeDistR * 200.0) * e.ampR * 0.12 * (1.0 - a.isSilent);
    }

    // ── Sonar sweep — rotating with persistence trail ──
    float sweepAng = Time * 0.4 * a.motSpeed;
    float sweepDiff = abs(ang - sweepAng);
    sweepDiff = min(sweepDiff, 6.28318 - sweepDiff);

    // Main sweep line
    float sweepGlow = exp(-sweepDiff * sweepDiff * 100.0) * 0.12;
    col += float3(0.2, 0.6, 0.4) * sweepGlow * a.dynActive * (1.0 - a.isSilent);

    // Persistence trail — fading wedge behind sweep
    float trailDiff = atan2(sin(sweepAng - ang), cos(sweepAng - ang));
    if (trailDiff > 0.0 && trailDiff < 1.5) {
        float trailFade = exp(-trailDiff * 2.5);
        float trailWidth = smoothstep(1.5, 0.0, trailDiff);
        col += float3(0.08, 0.3, 0.15) * trailFade * trailWidth * 0.03 * a.dynActive * (1.0 - a.isSilent);
    }

    // ── Beat rings — expanding from center on beat ──
    float beatRingR = a.beat * 0.65 * a.tempoConf;
    float beatRing = exp(-abs(r - beatRingR) * 12.0) * a.beat * 0.2;
    col += a.brainCol2 * beatRing * a.bloomActive * (1.0 - a.isSilent);

    // Secondary beat ring — delayed
    float beatRingR2 = a.beat * 0.4 * a.tempoConf;
    float beatRing2 = exp(-abs(r - beatRingR2) * 18.0) * a.beat * 0.1;
    col += a.brainCol * beatRing2 * (1.0 - a.isSilent);

    // ── Kick flash — center burst ──
    float kickGlow = exp(-r * r * 12.0) * a.kick * 0.25 * a.kickConf;
    col += hsv(a.hueCenter, 0.3, 1.0) * kickGlow * a.bloomActive * (1.0 - a.isSilent);

    // ── Transient contacts — random radar blips ──
    if (a.transient > 0.2) {
        float blipN = hash11(floor(uv.x * 80.0) + floor(uv.y * 80.0) + floor(Time * 15.0));
        if (blipN > 0.93) {
            float blipDist = length(p - float2(hash11(blipN) * 1.5 - 0.75, hash11(blipN * 2.0) * 1.5 - 0.75));
            float blipGlow = exp(-blipDist * blipDist * 400.0) * a.transient * 0.25;
            col += float3(0.3, 0.8, 0.5) * blipGlow * (1.0 - a.isSilent);
            // Blip ring
            float blipRing = exp(-abs(blipDist - 0.03) * 200.0) * a.transient * 0.1;
            col += float3(0.2, 0.6, 0.4) * blipRing * (1.0 - a.isSilent);
        }
    }

    // ── Center — bass pulse core ──
    float bassPulse = exp(-r * r * 40.0) * (0.04 + a.profBass * 0.15);
    col += a.brainCol * bassPulse * (1.0 - a.isSilent);
    float bassCore = exp(-r * r * 100.0) * a.b0 * 0.2;
    col += float3(0.6, 0.8, 1.0) * bassCore * a.bloomActive * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.25;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
