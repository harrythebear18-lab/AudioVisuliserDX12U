// Fullscreen triangle vertex shader — SM 6.6
// Generates a fullscreen triangle without vertex buffer input

struct VSOut {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

VSOut main(uint vid : SV_VertexID) {
    VSOut o;
    // Fullscreen triangle: 3 vertices cover entire screen
    o.pos = float4((float)(vid << 1) & 2, (float)(vid & 2), 0, 1);
    o.uv = float2((float)(vid << 1) & 2, (float)(vid & 2));
    // Flip Y for correct texture coordinates
    o.uv.y = 1.0 - o.uv.y;
    return o;
}
