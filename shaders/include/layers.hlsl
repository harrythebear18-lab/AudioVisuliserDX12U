// Layer composition — blend modes, starfield, god rays, common layered elements
// NOTE: Must be included AFTER audio_reactive.hlsl

// ── Soft tone mapping (Reinhard) — replaces hard HDR clamp ──
// Dark/medium brightness passes through unchanged. Only highlights compress.
// Prevents color desaturation that the hard clamp (col *= 1/maxC) causes.
float3 softReinhard(float3 col) {
    return col / (1.0 + col);
}

// ── Dynamic visual brightness limiter (soft knee) ──
// Below threshold: passes through unchanged (preserves vivid colors).
// Above threshold: smooth compression toward ceiling, never hard clamps.
// knee controls how gradual the transition is (0.5 = gentle, 2.0 = aggressive).
// ceiling is the maximum output brightness (1.0 = SDR white, 1.5 = HDR bright).
float3 hdrLimiter(float3 col, float threshold, float knee, float ceiling) {
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC <= threshold) return col;
    // Soft compression: above threshold, compress toward ceiling
    float excess = maxC - threshold;
    float compress = excess / (excess * knee + 1.0);
    float scale = (threshold + compress) / maxC;
    // Never exceed ceiling
    float outMax = maxC * scale;
    if (outMax > ceiling) scale *= ceiling / outMax;
    return col * scale;
}

// Convenience: standard dynamic limiter (threshold 0.8, knee 1.0, ceiling 1.2)
float3 hdrLimiter(float3 col) {
    return hdrLimiter(col, 0.8, 1.0, 1.2);
}

// ── VR parallax shift for screen-space shapes ──
// Fakes stereo depth by offsetting screen coords horizontally per eye.
// depth = simulated distance of the shape (0.5 = close, 3.0 = far).
// Returns a parallax offset to ADD to screen-space p.
// In desktop mode returns 0 — no effect.
float2 vrParallax(float depth) {
    if (!VR_ACTIVE) return float2(0.0, 0.0);
    // Eye separation: left eye sees shape shifted right, right eye shifted left
    // Closer depth = more shift (stronger parallax)
    float eyeSign = VR_EYE_INDEX * 2.0 - 1.0;  // -1 = left, +1 = right
    float parallaxAmount = VR_IPD * 0.5 / max(depth, 0.3);
    return float2(-eyeSign * parallaxAmount, 0.0);
}

// ── VR comfort: scale down flash intensity to prevent discomfort ──
// Full intensity on desktop, reduced in VR (closer to eyes).
float vrFlashScale() {
    return VR_ACTIVE ? 0.5 : 1.0;
}

// ── VR comfort: reduce high-frequency flicker amplitude ──
// THD-driven noise and transient jitter can be uncomfortable in VR.
float vrFlickerScale() {
    return VR_ACTIVE ? 0.4 : 1.0;
}

// ── VR comfort: clamp motion speed to prevent nausea ──
float vrMotionScale(float speed) {
    return VR_ACTIVE ? speed * 0.6 : speed;
}

// ── Additive budget — normalize a pass contribution by active count ──
// Each rendering stage gets a fixed budget. Divide by active emitters so
// busy music (many active) doesn't stack brighter than quiet music (few active).
float3 budgetPass(float3 passCol, float budget, float activeCount) {
    if (activeCount < 1.0) activeCount = 1.0;
    float maxC = max(passCol.r, max(passCol.g, passCol.b));
    if (maxC < 0.001) return float3(0, 0, 0);
    float scale = budget / (maxC * activeCount);
    scale = min(scale, 1.0);  // don't amplify quiet passes
    return passCol * scale;
}

// ── Blend modes (roadmap Phase 2 spec) ──

float3 blendScreen(float3 base, float3 blend) {
    return 1.0 - (1.0 - base) * (1.0 - blend);
}

float3 blendAdd(float3 base, float3 blend) {
    return base + blend;
}

float3 blendOverlay(float3 base, float3 blend) {
    float3 r;
    r.r = base.r < 0.5 ? 2.0 * base.r * blend.r : 1.0 - 2.0 * (1.0 - base.r) * (1.0 - blend.r);
    r.g = base.g < 0.5 ? 2.0 * base.g * blend.g : 1.0 - 2.0 * (1.0 - base.g) * (1.0 - blend.g);
    r.b = base.b < 0.5 ? 2.0 * base.b * blend.b : 1.0 - 2.0 * (1.0 - base.b) * (1.0 - blend.b);
    return r;
}

float3 blendSoftLight(float3 base, float3 blend) {
    return base + (blend - 0.5) * base * (1.0 - base) * 2.0;
}

float3 blendMultiply(float3 base, float3 blend) {
    return base * blend;
}

// 3-layer parallax starfield
float3 starfield(float2 uv, AudioData a) {
    float3 col = float3(0,0,0);
    [unroll] for (int si = 0; si < 3; si++) {
        float depth = 0.5 + si * 0.5;
        float2 starUV = (uv + a.stereoBal * 0.02 * depth) * (40.0 + si * 30.0);
        float2 starId = floor(starUV);
        float starH = hash21(starId + si * 17.3);
        float starB = pow(hash21(starId + si * 23.7 + 1.3), 30.0);
        float twinkle = 0.5 + 0.5 * sin(Time * (1.5 + starH * 3.0) + starH * 15.0);
        float starHue = a.hueCenter + starH * 0.15 + a.section * 0.03;
        col += hsv(starHue, 0.15, starB * twinkle * 0.4) * depth * (1.0 - a.isSilent);
    }
    return col;
}

// Volumetric god rays — radial sampling
float3 godRays(float2 p, float r, AudioData a) {
    float3 col = float3(0,0,0);
    [unroll] for (int gi = 0; gi < 6; gi++) {
        float ga = gi * 3.14159 / 3.0 + Time * 0.1 + a.stereoDiff * 0.3;
        float2 gdir = float2(cos(ga), sin(ga));
        float ray = smoothstep(0.6, 1.0, dot(normalize(p), gdir)) * exp(-r * 0.4);
        col += hsv(a.hueCenter + gi * 0.04, 0.3, 1.0) * ray * a.beam * 0.08 * a.beamActive * (1.0 - a.isSilent);
    }
    return col;
}

// Ambient atmosphere — soft radial glow
float3 ambientGlow(float r, AudioData a) {
    return hsv(a.hueCenter, 0.2, 0.3) * smoothstep(1.0, 0.3, r) * (0.01 + a.atmos * 0.04) * a.ambActive * (1.0 - a.isSilent);
}

// Standard post-burst layers — beat shockwave, kick ring, effect burst, section flash
// Energy is distributed as expanding rings — NOT concentrated at center.
float3 standardOverlays(float2 p, float r, AudioData a) {
    float3 col = float3(0,0,0);
    float t = Time * (0.3 + a.dynamic * 1.5 + a.profBass * 0.5);

    // Beat shockwave — expanding ring, not center flash
    float swR = frac(t * 0.25) * 1.8;
    float sw = exp(-abs(r - swR) * 16.0) * a.beat * 0.12 * a.tempoConf;
    col += hsv(a.hueCenter + 0.1, 0.6, 1.0) * sw * (1.0 - a.isSilent);

    // Kick ring — distributed outward, not center-concentrated
    float kickR = frac(t * 0.5) * 1.5 + 0.3;
    float kickRing = exp(-abs(r - kickR) * 20.0) * a.kick * 0.05 * a.kickConf;
    col += hsv(a.hueCenter, 0.3, 1.0) * kickRing * (1.0 - a.isSilent);

    col += effectBurst(p, r, a);
    col += sectionFlash(r, a);
    col *= phrasePulse(a);
    col += ambientGlow(r, a) * 0.5;
    col *= (1.0 + a.motionPers * 0.1);
    col *= globalBrightness(a);
    // Subtle beat sparkle — distributed, not center flash
    if (a.beatDet > 0.7) {
        float spark = hash21(p * 200.0 + floor(Time * 4.0));
        col += hsv(a.hueCenter + spark * 0.2, 0.4, 1.0) * step(0.97, spark) * 0.004 * a.beat;
    }
    return col;
}
