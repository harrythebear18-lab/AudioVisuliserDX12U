// Noise functions — 2D/3D hash, value noise, gradient noise, FBM, curl noise

float hash21(float2 p) { return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
float hash3(float3 p) { return frac(sin(dot(p, float3(127.1, 311.7, 74.7))) * 43758.5453); }
float hash11(float p) { return frac(sin(p * 127.1) * 43758.5453); }

float2 hash22(float2 p) {
    return float2(hash21(p), hash21(p + float2(3.7, 1.1)));
}

float3 hash33(float3 p) {
    return float3(hash3(p), hash3(p + float3(1.1, 2.3, 3.7)), hash3(p + float3(3.7, 1.1, 2.3)));
}

// Trilinear interpolated 3D value noise
float vnoise(float3 p) {
    float3 i = floor(p); float3 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash3(i), n100 = hash3(i + float3(1,0,0));
    float n010 = hash3(i + float3(0,1,0)), n110 = hash3(i + float3(1,1,0));
    float n001 = hash3(i + float3(0,0,1)), n101 = hash3(i + float3(1,0,1));
    float n011 = hash3(i + float3(0,1,1)), n111 = hash3(i + float3(1,1,1));
    return lerp(lerp(lerp(n000,n100,f.x), lerp(n010,n110,f.x), f.y),
                lerp(lerp(n001,n101,f.x), lerp(n011,n111,f.x), f.y), f.z);
}

// 2D value noise
float vnoise2(float2 p) {
    float2 i = floor(p); float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1,0));
    float c = hash21(i + float2(0,1));
    float d = hash21(i + float2(1,1));
    return lerp(lerp(a,b,f.x), lerp(c,d,f.x), f.y);
}

// FBM — 6 octaves
float fbm3(float3 p) {
    float v = 0.0, a = 0.5;
    [unroll] for (int i = 0; i < 6; i++) { v += a * vnoise(p); p = p * 2.02 + 0.5; a *= 0.5; }
    return v;
}

// FBM — 4 octaves (lighter)
float fbm3_4(float3 p) {
    float v = 0.0, a = 0.5;
    [unroll] for (int i = 0; i < 4; i++) { v += a * vnoise(p); p = p * 2.03 + 0.3; a *= 0.5; }
    return v;
}

// 2D FBM
float fbm2(float2 p) {
    float v = 0.0, a = 0.5;
    [unroll] for (int i = 0; i < 6; i++) { v += a * vnoise2(p); p = p * 2.02 + 0.5; a *= 0.5; }
    return v;
}

// 2D FBM — 4 octaves
float fbm2_4(float2 p) {
    float v = 0.0, a = 0.5;
    [unroll] for (int i = 0; i < 4; i++) { v += a * vnoise2(p); p = p * 2.03 + 0.3; a *= 0.5; }
    return v;
}

// Curl noise 3D — for particle flow fields
float3 curlN(float3 p) {
    float e = 0.1;
    float x = vnoise(p + float3(0,0,e)) - vnoise(p - float3(0,0,e))
            - (vnoise(p + float3(0,e,0)) - vnoise(p - float3(0,e,0)));
    float y = vnoise(p + float3(e,0,0)) - vnoise(p - float3(e,0,0))
            - (vnoise(p + float3(0,0,e)) - vnoise(p - float3(0,0,e)));
    float z = vnoise(p + float3(0,e,0)) - vnoise(p - float3(0,e,0))
            - (vnoise(p + float3(e,0,0)) - vnoise(p - float3(e,0,0)));
    return float3(x, y, z);
}

// 2D curl noise
float2 curl2(float2 p) {
    float e = 0.1;
    float x = vnoise2(p + float2(0,e)) - vnoise2(p - float2(0,e));
    float y = vnoise2(p + float2(e,0)) - vnoise2(p - float2(e,0));
    return float2(x, -y);
}

// Domain-warped FBM — creates organic flowing patterns
float warpedFBM(float2 p, float time) {
    float2 q = float2(fbm2(p + float2(0.0, 0.0) + time * 0.1),
                      fbm2(p + float2(5.2, 1.3) + time * 0.12));
    float2 r = float2(fbm2(p + 4.0 * q + float2(1.7, 9.2) + time * 0.015),
                      fbm2(p + 4.0 * q + float2(8.3, 2.8) + time * 0.018));
    return fbm2(p + 4.0 * r);
}
