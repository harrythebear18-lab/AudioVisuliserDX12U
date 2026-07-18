// Particle render vertex shader — renders GPU-simulated particles as point sprites.
// Reads from StructuredBuffer (SRV) populated by compute shader.
cbuffer AudioCB : register(b0)
{
    float4 Bands; float4 Bands2; float4 Dynamics; float4 Rhythm;
    float4 Stereo; float4 ColorHue; float4 VisualIntensities;
    float4 VisualIntensities2; float4 VisualTriggers; float4 VisualActive;
    float4 Group; float4 SectionInfo;
    float4 Profile1; float4 Profile2; float4 Profile3;
};
cbuffer TimeCB : register(b1) { float Time; float Width; float Height; float Aspect; };

struct Particle
{
    float2 pos;
    float2 vel;
    float  life;
    float  maxLife;
    float  size;
    float  hue;
    float  bandIdx;
    float  energy;
    float2 padding;
};

StructuredBuffer<Particle> Particles : register(t0);

struct VSOut
{
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
    float4 col : COLOR0;
};

VSOut VSMain(uint instanceID : SV_InstanceID)
{
    VSOut o;
    Particle p = Particles[instanceID];

    float lifeFrac = saturate(p.life / p.maxLife);
    float alpha = lifeFrac * saturate(p.energy * 2.0);

    // Point sprite — expand to quad in screen space
    o.pos = float4(p.pos, 0, 1);
    o.uv = float2(0, 0);
    o.col = float4(p.hue, p.size, alpha, p.energy);

    return o;
}

// Geometry shader to expand points into quads
[maxvertexcount(4)]
void GSMain(point VSOut input[1], inout TriangleStream<VSOut> stream)
{
    VSOut v = input[0];
    float size = v.col.y * (Height / Width);  // scale to pixels
    float aspect = Aspect;

    float2 offsets[4] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)
    };
    float2 uvs[4] = {
        float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0)
    };

    [unroll] for (int i = 0; i < 4; i++)
    {
        VSOut vert = v;
        vert.pos = float4(v.pos.xy + offsets[i] * size, v.pos.z, 1);
        vert.uv = uvs[i];
        stream.Append(vert);
    }
    stream.RestartStrip();
}
