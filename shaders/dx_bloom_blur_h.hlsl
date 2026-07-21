// Bloom Blur Horizontal — 9-tap Gaussian blur
#include "include/audio_cb.hlsl"

Texture2D<float4> BloomTex : register(t0);
SamplerState PointSampler : register(s0);

struct PSInput {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};

static const float weights[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };
static const float offsets[5] = { 0.0, 1.0, 2.0, 3.0, 4.0 };

float4 main(PSInput input) : SV_TARGET {
    float2 texelSize = float2(1.0 / Width, 1.0 / Height);
    float3 col = BloomTex.Sample(PointSampler, input.uv).rgb * weights[0];
    for (int i = 1; i < 5; i++) {
        col += BloomTex.Sample(PointSampler, input.uv + float2(offsets[i] * texelSize.x, 0.0)).rgb * weights[i];
        col += BloomTex.Sample(PointSampler, input.uv - float2(offsets[i] * texelSize.x, 0.0)).rgb * weights[i];
    }
    return float4(col, 1.0);
}
