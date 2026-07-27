// Bloom Extract — threshold bright pixels from scene
// Input: t0 = scene texture (HDR)
// Output: half-res bloom texture (HDR, bright parts only)
#include "include/audio_cb.hlsl"

Texture2D<float4> SceneTex : register(t0);
SamplerState PointSampler : register(s0);

struct PSInput {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};

float4 main(PSInput input) : SV_TARGET {
    float3 scene = SceneTex.Sample(PointSampler, input.uv).rgb;
    float brightness = max(scene.r, max(scene.g, scene.b));
    float threshold = 1.2;
    float3 bloom = scene * smoothstep(threshold, threshold + 0.3, brightness);
    return float4(bloom, 1.0);
}
