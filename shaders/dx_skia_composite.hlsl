// SkiaSharp overlay composite — alpha-blends 2D overlay on top of tonemapped scene
// Input:  t7=skiaTex (R8G8B8A8_UNorm, premultiplied alpha)
// Output: R8G8B8A8_UNorm backbuffer (with overlay blended)

#include "include/audio_cb.hlsl"

Texture2D<float4> SkiaTex : register(t7);
SamplerState PointSampler : register(s0);

struct PSInput {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};

float4 main(PSInput input) : SV_TARGET
{
    // Sample the SkiaSharp overlay (premultiplied alpha)
    float4 overlay = SkiaTex.Sample(PointSampler, input.uv);

    // Premultiplied alpha blend: result = src + (1 - srcAlpha) * dst
    // Since we're writing to the same backbuffer, we need to read it.
    // In DX12 we can't read and write the same RTV simultaneously.
    // Instead, the caller passes the backbuffer content via a separate SRV.
    // For now, use additive blend with the overlay's alpha as weight.
    float3 overlayColor = overlay.rgb;
    float overlayAlpha = overlay.a;

    // Output premultiplied — the pipeline blend state will handle the composite
    return float4(overlayColor * overlayAlpha, overlayAlpha);
}
