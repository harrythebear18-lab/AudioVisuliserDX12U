// Fast tonemap for spatial encoder modes — merges PostFX + Tonemap into one pass
// Input:  t1=layer0 (scene HDR)
// Output: R8G8B8A8_UNorm backbuffer (LDR)
// Skips bloom/overlay (already handled by spatial encoder), applies light postfx + ACES

#include "include/audio_cb.hlsl"
#include "include/noise.hlsl"
#include "include/postfx.hlsl"
#include "include/dsp_cb.hlsl"

Texture2D<float4> SceneLayer : register(t1);

SamplerState PointSampler : register(s0);

struct PSInput {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};

float4 main(PSInput input) : SV_TARGET
{
    AudioData a = extractAudio();
    float2 uv = float2(input.uv.x, 1.0 - input.uv.y);

    // Sample scene directly (no bloom, no overlay for spatial modes)
    float3 col = SceneLayer.Sample(PointSampler, uv).rgb;

    // Light postfx — grain + CA + vignette only (skip anamorphic, bloom)
    float thdNorm = thdNormalized();
    col = applyGrain(col, uv, Time, 0.012 + thdNorm * 0.008);
    float phaseSplit = (1.0 - phaseCoherence()) * 0.3;
    col = applyChromaticAberration(col, uv, min(a.transient + phaseSplit, 0.8));
    col = applyVignette(col, uv, 0.20 * a.persp);

    // Exposure
    float lufsNorm = lufsNormalized();
    float exposure = 1.0 + a.overall * 0.15 + (lufsNorm - 0.5) * 0.3;
    col *= exposure;

    // ACES filmic tonemap
    float3 ldr = tonemapACES(col);

    // Contrast
    float crestNorm = crestFactorNormalized();
    float lum = dot(ldr, float3(0.2126, 0.7152, 0.0722));
    float contrastBoost = 1.0 + crestNorm * 0.12;
    ldr = lum + (ldr - lum) * contrastBoost;

    // Saturation
    float satBoost = 1.0 + a.satur * 0.15;
    ldr = lerp(float3(lum, lum, lum), ldr, satBoost);

    ldr = saturate(ldr);
    return float4(ldr, 1.0);
}
