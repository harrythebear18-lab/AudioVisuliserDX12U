// 3D FREQUENCY TERRAIN — Vertex Shader
// A grid mesh where Y height = spectrum amplitude at that X position.
// Scrolls toward camera over time. Perspective camera looks down a corridor.
cbuffer AudioCB : register(b0)
{
    float4 Bands; float4 Bands2; float4 Dynamics; float4 Rhythm;
    float4 Stereo; float4 ColorHue; float4 VisualIntensities;
    float4 VisualIntensities2; float4 VisualTriggers; float4 VisualActive;
    float4 Group; float4 SectionInfo;
    float4 Profile1; float4 Profile2; float4 Profile3;
};
cbuffer TimeCB : register(b1) { float Time; float Width; float Height; float Aspect; };
cbuffer MeshCB : register(b2)
{
    float4x4 View;
    float4x4 Proj;
    float4x4 Model;
    float4 MeshParams;  // x=scrollSpeed, y=heightScale, z=gridSize, w=unused
};

Texture2D<float> u_spectrum : register(t0);
SamplerState u_sampler : register(s0);

struct VSInput {
    float3 pos : POSITION;
    float2 uv  : TEXCOORD0;
};

struct VSOutput {
    float4 pos       : SV_POSITION;
    float2 uv        : TEXCOORD0;
    float  height    : TEXCOORD1;
    float  bandIdx   : TEXCOORD2;
    float  depth     : TEXCOORD3;
};

VSOutput main(VSInput input)
{
    VSOutput o;

    // UV.x maps to frequency band 0..127
    float bandIdx = input.uv.x * 128.0;
    float freq = 20.0 * pow(1200.0, input.uv.x);
    float samplePos = saturate(freq / 24000.0);
    float specVal = u_spectrum.SampleLevel(u_sampler, float2(samplePos, 0.5), 0).r;
    specVal = saturate(specVal * 0.25) * 0.9;

    // Scroll the grid toward camera by offsetting Z
    float scrollSpeed = MeshParams.x;
    float gridSize = MeshParams.z;
    float z = input.pos.z + Time * scrollSpeed;
    // Wrap Z so the grid is infinite
    z = fmod(z + gridSize * 0.5, gridSize) - gridSize * 0.5;

    // Height from spectrum + bass boost + ripple
    float bass = (Bands.y + Bands.z) * 0.5;
    float heightScale = MeshParams.y;
    float ripple = sin(z * 2.0 + Time * 3.0) * 0.05 * Dynamics.x;
    float h = (specVal + bass * 0.15 + ripple) * heightScale;

    float3 worldPos = float3(input.pos.x, h, z);

    // Transform to clip space
    float4 wp = mul(float4(worldPos, 1.0), Model);
    float4 vp = mul(wp, View);
    o.pos = mul(vp, Proj);

    o.uv = input.uv;
    o.height = h;
    o.bandIdx = bandIdx;
    o.depth = -vp.z;

    return o;
}
