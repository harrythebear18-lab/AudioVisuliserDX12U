// PARTICLE VORTEX VERTEX SHADER — reads structured buffer, renders point sprites.
// Each particle is a point. Size based on particle.size + distance attenuation.
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
    float4 MeshParams;  // unused for particles, kept for CB layout
};

struct Particle
{
    float4 pos;    // xyz position, w = size
    float4 vel;    // xyz velocity, w = energy
    float4 data;   // x = life, y = maxLife, z = hue, w = bandIdx
};

StructuredBuffer<Particle> Particles : register(t0);

struct VSOutput {
    float4 pos : SV_POSITION;
    float  size : TEXCOORD0;
    float  hue : TEXCOORD1;
    float  energy : TEXCOORD2;
    float  lifeFrac : TEXCOORD3;
};

VSOutput main(uint vid : SV_VertexID)
{
    VSOutput o;

    Particle p = Particles[vid];

    // Skip dead particles — push behind camera
    if (p.data.x <= 0 || p.data.x > 100.0) {
        o.pos = float4(0, 0, -10, 1);
        o.size = 0;
        o.hue = 0;
        o.energy = 0;
        o.lifeFrac = 0;
        return o;
    }

    // Transform to world (model is identity)
    float4 worldPos = mul(float4(p.pos.xyz, 1.0), Model);
    float4 viewPos = mul(worldPos, View);
    float4 clipPos = mul(viewPos, Proj);

    o.pos = clipPos;
    // Point size — scale by viewport height and distance
    float dist = max(-viewPos.z, 0.1);
    o.size = max(p.pos.w * (Height / dist) * 3.0, 2.0);
    o.hue = p.data.z;
    o.energy = p.vel.w;
    o.lifeFrac = p.data.x / p.data.y;

    return o;
}
