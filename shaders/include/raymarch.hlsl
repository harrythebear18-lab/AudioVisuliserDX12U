// Raymarching framework — camera setup, MarchResult struct, soft shadows, clean lighting
// Each shader defines its own SDF function and inlines the march loop, normals, shadows, AO

struct MarchResult {
    float t;
    float glow;
    float steps;
    bool hit;
};

// Camera setup — returns ray direction
float3 cameraRay(float3 camPos, float3 camTarget, float2 p, float fov) {
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);
    return normalize(fwd + p.x * right * fov + p.y * up * fov);
}

// Clean lighting model — fresnel glow + diffuse + specular, no active flag gating
// Returns lit color with audio-reactive fresnel edge glow (ARTEF4KT/Codrops method)
float3 cleanLighting(float3 n, float3 rd, float3 lDir, float3 baseCol,
                     AudioData a, float hue) {
    float diff = max(dot(n, lDir), 0.0);
    float3 viewDir = -rd;
    float fres = pow(1.0 - max(dot(n, viewDir), 0.0), 2.0 + a.overall * 2.0);
    float spec = pow(max(dot(reflect(-lDir, n), viewDir), 0.0), 48.0);

    float3 col = baseCol * diff * (0.5 + a.brightness * 0.4);
    col += float3(1.0, 0.98, 0.95) * spec * 0.4;
    col += a.brainCol2 * fres * (0.3 + a.b4 * 0.3);
    return col;
}

// Global brightness modulator — mode 21 method with noise gate
float globalMod(AudioData a) {
    float gated = max(a.overall - 0.015, 0.0) / 0.985;
    return 0.45 + gated * 0.55 + a.brightness * 0.15;
}

// ACES filmic tonemap — preserves color vibrancy better than Reinhard
float3 acesTonemap(float3 x) {
    float a = 2.51; float b = 0.03; float c = 2.43; float d = 0.59; float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// Clean finish — ACES tonemap + subtle vignette (no bloom, no grain, no chromatic aberration)
float3 cleanFinish(float3 col, float2 uv, AudioData a) {
    col *= globalMod(a);
    col = acesTonemap(col);
    col *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.15;
    return col;
}
