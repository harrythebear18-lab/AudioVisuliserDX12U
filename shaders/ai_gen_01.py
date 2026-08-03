// AI-generated RTXAudioVisualizer HLSL fullscreen pixel shader
// could you build me a 3d spatial audio/psycoacustic accurate 3d rendering mode, id like a high fedelity/true to music visulisation but not cartoony or block colour
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float3 col = float3(0.0, 0.0, 0.0);

    // --- USER SCENE START
col = hsv(a.hueBase + a.beat * 0.1, a.satur, a.brightness);
float3 pos = float3(p.x * Width, p.y * Height, r * Time);
col *= sin(pos.x) * cos(pos.y) * exp(-r * 0.5);
    // --- USER SCENE END

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}