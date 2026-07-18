// PARTICLE VORTEX GEOMETRY SHADER — expands points into screen-space quads.
cbuffer TimeCB : register(b1) { float Time; float Width; float Height; float Aspect; };

struct GSInput {
    float4 pos : SV_POSITION;
    float  size : TEXCOORD0;
    float  hue : TEXCOORD1;
    float  energy : TEXCOORD2;
    float  lifeFrac : TEXCOORD3;
};

struct GSOutput {
    float4 pos : SV_POSITION;
    float2 uv : TEXCOORD0;
    float  hue : TEXCOORD1;
    float  energy : TEXCOORD2;
    float  lifeFrac : TEXCOORD3;
};

[maxvertexcount(4)]
void main(point GSInput input[1], inout TriangleStream<GSOutput> stream)
{
    GSOutput o;

    float4 pos = input[0].pos;
    float size = input[0].size;

    // Skip dead particles
    if (size <= 0) return;

    // Convert clip space to pixel offsets
    float2 pixelSize = float2(size / Width, size / Height);

    // Quad corners in clip space (two triangles)
    // Bottom-left
    o.pos = float4(pos.x - pixelSize.x, pos.y - pixelSize.y, pos.z, pos.w);
    o.uv = float2(-1, -1);
    o.hue = input[0].hue; o.energy = input[0].energy; o.lifeFrac = input[0].lifeFrac;
    stream.Append(o);

    // Top-left
    o.pos = float4(pos.x - pixelSize.x, pos.y + pixelSize.y, pos.z, pos.w);
    o.uv = float2(-1, 1);
    o.hue = input[0].hue; o.energy = input[0].energy; o.lifeFrac = input[0].lifeFrac;
    stream.Append(o);

    // Bottom-right
    o.pos = float4(pos.x + pixelSize.x, pos.y - pixelSize.y, pos.z, pos.w);
    o.uv = float2(1, -1);
    o.hue = input[0].hue; o.energy = input[0].energy; o.lifeFrac = input[0].lifeFrac;
    stream.Append(o);

    // Top-right
    o.pos = float4(pos.x + pixelSize.x, pos.y + pixelSize.y, pos.z, pos.w);
    o.uv = float2(1, 1);
    o.hue = input[0].hue; o.energy = input[0].energy; o.lifeFrac = input[0].lifeFrac;
    stream.Append(o);

    stream.RestartStrip();
}
