// Post-processing — tone mapping, bloom, vignette, chromatic aberration

// ACES filmic tone map
float3 tonemapACES(float3 col) {
    return (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
}

// Reinhard tone map
float3 tonemapReinhard(float3 col) {
    return col / (1.0 + col);
}

// Film grain
float3 applyGrain(float3 col, float2 uv, float time, float strength) {
    float grain = (hash21(uv * float2(Width, Height) + time) - 0.5) * strength;
    return col + grain;
}

// Chromatic aberration — edge-weighted
float3 applyChromaticAberration(float3 col, float2 uv, float intensity) {
    float edgeDist = length(uv - 0.5);
    col.r *= (1.0 + edgeDist * 0.01 * intensity);
    col.b *= (1.0 - edgeDist * 0.008 * intensity);
    return col;
}

// Vignette
float3 applyVignette(float3 col, float2 uv, float strength) {
    col *= 1.0 - dot(uv - 0.5, uv - 0.5) * strength;
    return col;
}

// Bloom — subtle, capped to prevent flash buildup
float3 applyBloom(float3 col, float bloom, float bloomActive) {
    float pxBright = max(col.r, max(col.g, col.b));
    float bloomAmt = bloom * max(0.3, bloomActive);
    if (pxBright > 0.8) col += col * (pxBright - 0.8) * bloomAmt * 0.15;
    if (pxBright > 0.6) col += col * (pxBright - 0.6) * bloomAmt * 0.08;
    return col;
}

// Anamorphic streak — subtle blue horizontal lens flare
float3 applyAnamorphic(float3 col, float beamActive) {
    float pxBright = max(col.r, max(col.g, col.b));
    if (pxBright > 0.85)
        col += float3(0.08, 0.15, 0.3) * (pxBright - 0.85) * 0.3 * max(0.3, beamActive);
    return col;
}

// Full post-processing stack — gentle, fatigue-free
float3 applyPostFX(float3 col, float2 uv, AudioData a) {
    col = applyBloom(col, a.bloom, a.bloomActive);
    col = applyAnamorphic(col, a.beamActive);
    col = tonemapReinhard(col);
    col = applyGrain(col, uv, Time, 0.015);
    col = applyChromaticAberration(col, uv, min(a.transient, 0.5));
    col = applyVignette(col, uv, 0.25 * a.persp);
    return col;
}
