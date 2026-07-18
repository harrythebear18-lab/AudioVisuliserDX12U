// Color utilities — HSV/RGB, temperature, palette functions

float3 hsv(float h, float s, float v) {
    float4 K = float4(1, 2/3.0, 1/3.0, 3);
    float3 p = abs(frac(float3(h,h,h) + K.xyz) * 6 - K.www);
    return v * lerp(K.xxx, saturate(p - K.xxx), s);
}

float3 hsv2rgb(float3 c) {
    return hsv(c.x, c.y, c.z);
}

float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
    float4 p = lerp(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = lerp(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

// Color temperature — warm to cool
float3 colorTemperature(float t) {
    // t: 0=cool blue, 0.5=white, 1=warm orange
    return lerp(
        lerp(float3(0.5, 0.7, 1.2), float3(1,1,1), smoothstep(0.0, 0.5, t)),
        float3(1.4, 1.0, 0.6),
        smoothstep(0.5, 1.0, t)
    );
}

// Palette — cosine-based gradient (Inigo Quilez style)
float3 palette(float t, float3 a, float3 b, float3 c, float3 d) {
    return a + b * cos(6.28318 * (c * t + d));
}

// Default audio-reactive palette
float3 audioPalette(float t, AudioData a) {
    float3 base = palette(t,
        float3(0.5, 0.5, 0.5),
        float3(0.5, 0.5, 0.5),
        float3(1.0, 1.0, 1.0),
        float3(0.0, 0.1, 0.2)
    );
    return lerp(base, a.brainCol, a.dynActive * 0.5);
}

// Luminance
float luminance(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// Saturation adjustment
float3 adjustSat(float3 c, float sat) {
    float l = luminance(c);
    return lerp(float3(l,l,l), c, sat);
}
