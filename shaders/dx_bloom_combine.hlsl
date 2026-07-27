// Bloom Combine — additive blend bloom back into scene
// Input: t0 = scene (HDR), t1 = bloom (HDR, blurred)
// Output: combined HDR scene + bloom
#include "include/audio_cb.hlsl"

Texture2D<float4> SceneTex : register(t0);
Texture2D<float4> BloomTex : register(t1);
SamplerState PointSampler : register(s0);

struct PSInput {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};

float4 main(PSInput input) : SV_TARGET {
    float3 scene = SceneTex.Sample(PointSampler, input.uv).rgb;
    float3 bloom = BloomTex.Sample(PointSampler, input.uv).rgb;
    float3 col = scene + bloom * 0.5;
    return float4(col, 1.0);
}
