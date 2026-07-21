// HDR Post-processing + Composite pass
// Inputs: t1=layer0 (scene), t2=layer1 (overlay), t3=bloom0
// Output: R16G16B16A16_Float HDR intermediate (_postfxTex)
// Composites all layers in HDR space, then applies grain, CA, vignette, anamorphic

#include "include/audio_cb.hlsl"
#include "include/noise.hlsl"
#include "include/color_utils.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"
#include "include/dsp_cb.hlsl"

Texture2D<float4> SceneLayer   : register(t1);
Texture2D<float4> OverlayLayer : register(t2);
Texture2D<float4> BloomLayer   : register(t3);

SamplerState PointSampler  : register(s0);
SamplerState WrapSampler   : register(s1);

struct PSInput {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};

float4 main(PSInput input) : SV_TARGET
{
    AudioData a = extractAudio();
    float2 uv = input.uv;

    // Sample layers
    float3 scene   = SceneLayer.Sample(PointSampler, uv).rgb;
    float3 overlay = OverlayLayer.Sample(PointSampler, uv).rgb;
    float3 bloom   = BloomLayer.Sample(PointSampler, uv).rgb;

    // Composite in HDR: scene + overlay (screen blend) + bloom (additive)
    float3 col = scene;
    col = blendScreen(col, overlay);
    col += bloom * (0.6 + a.bloom * 0.4);

    // Anamorphic streak — subtle blue horizontal lens flare on bright pixels
    col = applyAnamorphic(col, a.beamActive);

    // Film grain — THD adds warmth/grit; more distortion = more grain character
    float thdNorm = thdNormalized();
    col = applyGrain(col, uv, Time, 0.012 + thdNorm * 0.008);

    // Chromatic aberration — transient-driven + phase correlation split
    // Out-of-phase content (low correlation) increases CA for stereo widening effect
    float phaseSplit = (1.0 - phaseCoherence()) * 0.3;
    col = applyChromaticAberration(col, uv, min(a.transient + phaseSplit, 0.8));

    // Vignette — gentle, driven by perspective modifier
    col = applyVignette(col, uv, 0.20 * a.persp);

    // Keep in HDR — no tonemap here, that's the next pass
    return float4(col, 1.0);
}
