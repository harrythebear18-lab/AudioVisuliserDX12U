// MESH VERTEX SHADER — 3D sphere with audio-driven vertex displacement.
// Bass pushes vertices outward, mids add ripple, treble adds fine noise.
// Perspective camera with orbit. Outputs world position, normal, uv, displacement amount.
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
    float4 MeshParams;  // x=bassAmt, y=midAmt, z=trebleAmt, w=beatAmt
};

Texture2D<float> u_spectrum : register(t0);
SamplerState u_sampler : register(s0);

struct VSInput {
    float3 pos : POSITION;
    float3 normal : NORMAL;
    float2 uv : TEXCOORD0;
};

struct VSOutput {
    float4 pos : SV_POSITION;
    float3 worldPos : TEXCOORD0;
    float3 worldNormal : TEXCOORD1;
    float2 uv : TEXCOORD2;
    float  displacement : TEXCOORD3;
    float  bandEnergy : TEXCOORD4;
};

VSOutput main(VSInput input)
{
    VSOutput o;

    float3 pos = input.pos;
    float3 nrm = input.normal;

    // Sample spectrum at this vertex's UV
    float specVal = u_spectrum.SampleLevel(u_sampler, float2(input.uv.x, 0.5), 0).r;
    specVal = saturate(specVal * 0.25) * 0.9;

    // Audio displacement along normal
    float bass = MeshParams.x;
    float mid = MeshParams.y;
    float treble = MeshParams.z;
    float beat = MeshParams.w;

    // Bass — large scale push outward
    float bassDisp = bass * 0.5;
    // Mid — ripple based on UV position
    float midDisp = sin(input.uv.x * 20.0 + Time * 3.0) * mid * 0.15;
    // Treble — fine high-frequency noise
    float trebleDisp = sin(input.uv.x * 80.0 + Time * 8.0) * cos(input.uv.y * 60.0) * treble * 0.08;
    // Beat — shockwave from center
    float beatDisp = sin(length(input.uv - 0.5) * 15.0 - Time * 6.0) * beat * 0.2;
    // Spectrum — per-vertex energy displacement
    float specDisp = specVal * 0.4;

    float totalDisp = bassDisp + midDisp + trebleDisp + beatDisp + specDisp;
    pos += nrm * totalDisp;

    // Transform to world space
    float4 worldPos = mul(float4(pos, 1.0), Model);
    o.worldPos = worldPos.xyz;
    o.worldNormal = normalize(mul(nrm, (float3x3)Model));

    // Transform to clip space
    float4 viewPos = mul(worldPos, View);
    o.pos = mul(viewPos, Proj);

    o.uv = input.uv;
    o.displacement = totalDisp;
    o.bandEnergy = specVal;

    return o;
}
