// Mode 5: Spectrum Ribbons — flowing 3D frequency ribbons in perspective
// 8 ribbons, each assigned a frequency band, flowing toward camera
// Ribbon height/thickness/brightness = amplitude, L/R stereo = twin sets
// Beat = ribbon pulse, kick = flow surge, transients = flutter, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define RIBBON_COUNT 8

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Background — deep gradient ──
    float skyFrac = uv.y;
    float3 skyTop = a.brainCol * 0.08;
    float3 skyBot = a.brainCol2 * 0.04;
    float3 col = lerp(skyTop, skyBot, skyFrac) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.2;

    // ── Perspective camera — looking down a corridor ──
    float camY = 0.5 + a.stereoDiff * 0.1;
    float3 camPos = float3(a.stereoBal * 0.3, camY, 1.5);
    float3 camTarget = float3(a.stereoBal * 0.2, 0.0, -5.0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(fwd + p.x * right + p.y * up);

    // ── 8 frequency ribbons — each a flowing wave in 3D ──
    [loop] for (int ri = 0; ri < RIBBON_COUNT; ri++) {
        AudioElement e = audioSimElement(ri, RIBBON_COUNT, a);

        // Ribbon Z position — flows toward camera over time
        float ribbonZ = -float(ri) * 0.6 - frac(Time * 0.3 * a.motSpeed) * 0.6 + 0.5;
        // Kick surge — pushes ribbons closer
        ribbonZ += a.kick * 0.15 * a.kickConf;

        // Ribbon Y — stacked vertically, amplitude drives height
        float ribbonY = (float(ri) / (RIBBON_COUNT - 1) - 0.5) * 1.6;
        float ampHeight = e.amplitude * 0.3 * a.barScale;

        // Ribbon X — spans width, stereo pan offsets
        float ribbonX = e.pan * 0.3;

        // Project to screen
        float3 ribbonPos = float3(ribbonX + e.panOffset.x, ribbonY, ribbonZ);
        float depth = ribbonPos.z + camPos.z;
        if (depth < 0.1) continue;
        float2 screenPos = ribbonPos.xy / depth * 1.2;

        // Ribbon wave — horizontal flowing sine modulated by amplitude
        float wavePhase = p.x * 8.0 + Time * 3.0 * a.motSpeed + ri * 0.7;
        float waveY = sin(wavePhase) * ampHeight;
        float waveY2 = cos(wavePhase * 1.3 + ri * 1.2) * ampHeight * 0.5;

        // Distance to ribbon curve
        float2 ribbonScreen = screenPos + float2(0, waveY * 0.3 / depth);
        float dist = length(p - ribbonScreen);

        // Ribbon thickness — amplitude driven, perspective scaled
        float thickness = (0.005 + e.amplitude * 0.02) / depth;
        float ribbonGlow = exp(-dist * dist / (thickness * thickness * 4.0)) * e.intensity;

        // Beat pulse — thickens ribbon momentarily
        float beatPulse = a.beat * a.tempoConf * exp(-dist * dist / (thickness * thickness * 8.0)) * 0.3;
        ribbonGlow += beatPulse;

        // Transient flutter — adds chaotic displacement
        float flutter = e.transientScatter * exp(-dist * dist / (thickness * thickness * 2.0)) * 0.2;
        ribbonGlow += flutter;

        // Color by frequency position
        float hue = a.hueBase + e.freqFrac * a.hueRange;
        float3 ribbonCol = lerp(a.brainCol, a.brainCol2, e.freqFrac);
        ribbonCol = lerp(ribbonCol, hsv(hue, 0.6 * a.satur, 0.9), 0.4);

        // Depth fog — distant ribbons dimmer
        float depthFade = exp(-abs(ribbonZ) * 0.15);

        col += ribbonCol * ribbonGlow * depthFade * 0.5 * (1.0 - a.isSilent);

        // Bright core line
        float coreGlow = exp(-dist * dist / (thickness * thickness * 20.0)) * e.amplitude * 0.3;
        col += ribbonCol * coreGlow * a.bloomActive * depthFade * (1.0 - a.isSilent);

        // L/R twin — mirror ribbon with opposite stereo
        float2 twinScreen = float2(-screenPos.x, screenPos.y) + float2(0, waveY2 * 0.3 / depth);
        float twinDist = length(p - twinScreen);
        float twinGlow = exp(-twinDist * twinDist / (thickness * thickness * 4.0)) * e.intensity * 0.5;
        float3 twinCol = lerp(a.brainCol2, a.brainCol, e.freqFrac);
        col += twinCol * twinGlow * depthFade * 0.3 * (1.0 - a.isSilent);
    }

    // ── Flow particles — sparkles traveling toward camera ──
    [loop] for (int pi = 0; pi < 12; pi++) {
        float pTime = Time * (0.5 + pi * 0.03) * a.motSpeed + pi * 0.27;
        float pZ = -frac(pTime) * 5.0 + 0.5;
        float pX = sin(pi * 2.3 + Time * 0.2) * 1.2;
        float pY = cos(pi * 1.7 + Time * 0.15) * 0.8;
        float depth = pZ + camPos.z;
        if (depth < 0.1) continue;
        float2 pScreen = float2(pX, pY) / depth * 1.2;
        float pDist = length(p - pScreen);
        float pBright = a.envelope * 0.15 / depth;
        col += a.brainCol2 * exp(-pDist * pDist * 100.0) * pBright * (1.0 - a.isSilent);
    }

    // ── Kick flash ──
    float kickFlash = exp(-r * r * 3.0) * a.kick * 0.1 * a.kickConf;
    col += a.brainCol * kickFlash * a.bloomActive * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.25;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
