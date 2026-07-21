// HDR → LDR Tone-mapping pass
// Input:  t6=postfxTex (R16G16B16A16_Float HDR)
// Output: R8G8B8A8_UNorm backbuffer (LDR)
// Applies exposure + ACES filmic tonemap + final sRGB approximation

#include "include/audio_cb.hlsl"
#include "include/noise.hlsl"
#include "include/postfx.hlsl"
#include "include/dsp_cb.hlsl"

Texture2D<float4> PostFxTex : register(t6);

SamplerState PointSampler : register(s0);

struct PSInput {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};

float4 main(PSInput input) : SV_TARGET
{
    AudioData a = extractAudio();
    float2 uv = float2(input.uv.x, 1.0 - input.uv.y);

    // Sample HDR post-processed result
    float3 hdr = PostFxTex.Sample(PointSampler, uv).rgb;

    // Exposure — audio-reactive base + DSP LUFS refinement
    // LUFS gives true perceived loudness — brighter when louder, darker when quieter
    float lufsNorm = lufsNormalized();  // 0..1 from -70..0 LUFS
    float exposure = 1.0 + a.overall * 0.15 + (lufsNorm - 0.5) * 0.3;
    hdr *= exposure;

    // ACES filmic tonemap — HDR → LDR
    float3 ldr = tonemapACES(hdr);

    // Crest factor influences contrast — high crest = dynamic content, boost contrast
    float crestNorm = crestFactorNormalized();  // 0=compressed, 1=dynamic
    float lum = dot(ldr, float3(0.2126, 0.7152, 0.0722));
    float contrastBoost = 1.0 + crestNorm * 0.12;
    ldr = lum + (ldr - lum) * contrastBoost;

    // Subtle saturation boost in LDR space
    float satBoost = 1.0 + a.satur * 0.15;
    ldr = lerp(float3(lum, lum, lum), ldr, satBoost);

    // Clamp to [0,1] for LDR target
    ldr = saturate(ldr);

    return float4(ldr, 1.0);
}
