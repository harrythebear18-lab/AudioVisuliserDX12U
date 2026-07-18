// Mode 7: Spectrum Aurora — frequency-driven aurora curtains
// 8 curtains, each assigned a frequency band, height + brightness = amplitude
// L/R stereo creates twin curtains, beat shimmer, kick ground glow
// Multi-octave domain warp, smooth mountain silhouettes, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define AURORA_BANDS 8

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // Night sky gradient — smooth
    float skyFrac = clamp(uv.y, 0.0, 1.0);
    float3 skyTop = a.brainCol * 0.1;
    float3 skyBot = a.brainCol2 * 0.06;
    float3 col = lerp(skyTop, skyBot, skyFrac) * (1.0 - a.isSilent * 0.98);

    // Stars — upper portion, density decreases downward
    float starMask = smoothstep(0.0, 0.4, 1.0 - uv.y);
    float2 starUV = uv * float2(12.0, 8.0);
    float starHash = hash11(floor(starUV.x) * 37.0 + floor(starUV.y) * 73.0);
    if (starHash > 0.97 && starMask > 0.1) {
        float twinkle = sin(Time * (2.0 + starHash * 5.0) + starHash * 10.0) * 0.5 + 0.5;
        col += float3(0.7, 0.8, 1.0) * twinkle * 0.4 * (starHash - 0.97) * 33.0 * starMask;
    }

    // ── Mountain silhouette — smooth multi-octave, no hard cutoff ──
    float mountainH = 0.55 + fbm2_4(float2(p.x * 2.0, 0.0)) * 0.08
                    + fbm2_4(float2(p.x * 5.0, 1.0)) * 0.04;
    float mountainFade = smoothstep(mountainH, mountainH - 0.04, p.y);
    col = lerp(col, float3(0.002, 0.004, 0.007), mountainFade * 0.9);

    // ── 8 frequency-driven aurora curtains ──
    [loop] for (int bi = 0; bi < AURORA_BANDS; bi++) {
        AudioElement e = audioSimElement(bi, AURORA_BANDS, a);

        // Curtain base position — spread across screen, stereo pan shifts
        float curtainX = (float(bi) / (AURORA_BANDS - 1) - 0.5) * 2.8 + e.pan * 0.15;
        float curtainY = -0.15 + e.freqFrac * 0.25;

        // Curtain height driven by amplitude
        float curtainH = 0.25 + e.amplitude * 0.5 * a.barScale;

        // Multi-octave domain warp for organic flowing curtains
        float2 curtainUV = float2(p.x - curtainX, p.y - curtainY);
        float2 warp1 = float2(
            fbm2_4(curtainUV * 1.5 + Time * 0.08 * a.motSpeed + bi * 3.7),
            fbm2_4(curtainUV * 1.5 + Time * 0.08 * a.motSpeed + bi * 5.3)
        );
        float2 warp2 = float2(
            fbm2_4(curtainUV * 4.0 + warp1 * 2.0 + Time * 0.15 * a.motSpeed),
            fbm2_4(curtainUV * 4.0 + warp1 * 2.0 + Time * 0.12 * a.motSpeed + bi * 1.7)
        );
        float curtainShape = fbm2_4(curtainUV * 2.5 + warp1 * 1.5 + warp2 * 0.5);

        // Vertical falloff — curtain hangs from top, fades downward smoothly
        float vertFade = smoothstep(curtainH, 0.0, abs(p.y - curtainY)) * smoothstep(0.5, -0.1, p.y);

        // Horizontal falloff — curtain is centered at curtainX
        float horizFade = exp(-(p.x - curtainX) * (p.x - curtainX) * 2.5);

        // Audio reactivity — brightness from amplitude
        float audioBright = e.intensity * (0.4 + a.envelope * 0.6);

        // Beat adds shimmer
        float shimmer = a.beat * a.tempoConf * sin(p.x * 15.0 + Time * 8.0) * 0.08;

        float curtainIntensity = (curtainShape * vertFade * horizFade * audioBright) + shimmer * vertFade * horizFade;

        // Color by frequency position
        float hue = a.hueBase + e.freqFrac * a.hueRange + a.section * 0.03;
        float3 auroraCol = lerp(a.brainCol, a.brainCol2, e.freqFrac);
        auroraCol = lerp(auroraCol, hsv(hue, 0.6 * a.satur, 1.0), 0.4);

        col += auroraCol * curtainIntensity * 0.35 * (1.0 - a.isSilent);

        // L/R twin — mirror curtain on opposite side
        float twinX = -curtainX;
        float twinHorizFade = exp(-(p.x - twinX) * (p.x - twinX) * 2.5);
        float twinIntensity = curtainShape * vertFade * twinHorizFade * e.intensity * 0.4;
        float3 twinCol = lerp(a.brainCol2, a.brainCol, e.freqFrac);
        col += twinCol * twinIntensity * 0.25 * (1.0 - a.isSilent);

        // Curtain glow — soft vertical pillar
        float pillarGlow = smoothstep(0.15, 0.0, abs(p.y - curtainY)) * horizFade * curtainShape * 0.08;
        col += auroraCol * pillarGlow * audioBright * a.bloomActive * (1.0 - a.isSilent);
    }

    // ── Kick ground glow — horizon flash ──
    float kickGlow = exp(-(p.y - 0.45) * (p.y - 0.45) * 8.0) * a.kick * 0.12 * a.kickConf;
    col += a.brainCol * kickGlow * (1.0 - a.isSilent);

    // ── Transient aurora flicker ──
    if (a.transient > 0.2) {
        float flicker = fbm2_4(p * 8.0 + Time * 4.0) * a.transient * 0.04;
        col += a.brainCol2 * flicker * smoothstep(0.3, -0.3, p.y) * (1.0 - a.isSilent);
    }

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.25;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
