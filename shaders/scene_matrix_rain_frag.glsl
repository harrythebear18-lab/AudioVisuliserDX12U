#version 460 core

// MATRIX RAIN — Cascading digital rain with 3D depth layers.
// Multiple rain columns at different depths, each with independent fall speed.
// Audio drives: fall speed (bass), character brightness (beat), corruption (highs),
// color shifts (section), rain density (energy), glitch bursts (kick).
// Phrase beat drives wave patterns across columns. Stereo drives horizontal drift.

in vec2 v_uv;
out vec4 frag_color;

uniform float u_time;
uniform vec2 u_resolution;
uniform sampler2D u_spectrum;
uniform vec3 u_color;
uniform vec3 u_color2;

#define PI 3.14159265359

vec3 hsv2rgb(float h, float s, float v) {
    vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    vec3 p = abs(fract(vec3(h) + K.xyz) * 6.0 - K.www);
    return v * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), s);
}
float hash11(float p) { return fract(sin(p * 127.1) * 43758.5453); }
float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i+vec2(1,0)), f.x),
               mix(hash21(i+vec2(0,1)), hash21(i+vec2(1,1)), f.x), f.y);
}

float sectionEnergy(float sec) {
    if (sec < 0.5) return 0.0;
    if (sec < 1.5) return 0.15;
    if (sec < 2.5) return 0.4;
    if (sec < 3.5) return 0.5;
    if (sec < 4.5) return 0.6;
    if (sec < 5.5) return 0.7;
    if (sec < 6.5) return 1.0;
    if (sec < 7.5) return 0.5;
    if (sec < 8.5) return 0.45;
    if (sec < 9.5) return 0.3;
    return 0.1;
}

// Pseudo-katakana character — generates a glyph-like pattern
float character(vec2 uv, float seed) {
    vec2 grid = floor(uv * vec2(5.0, 7.0));
    vec2 cell = fract(uv * vec2(5.0, 7.0));
    float h = hash21(grid + seed);
    // Draw segments based on hash — looks like random characters
    float c = 0.0;
    if (h > 0.5) c = max(c, smoothstep(0.1, 0.0, cell.x) * smoothstep(0.9, 1.0, cell.y));
    if (h > 0.7) c = max(c, smoothstep(0.9, 1.0, cell.x) * smoothstep(0.1, 0.0, cell.y));
    if (h > 0.3) c = max(c, smoothstep(0.4, 0.5, abs(cell.x - 0.5)) * smoothstep(0.3, 0.4, abs(cell.y - 0.5)));
    if (h > 0.8) c = max(c, smoothstep(0.2, 0.3, abs(cell.x - 0.3)) * smoothstep(0.2, 0.3, abs(cell.y - 0.3)));
    if (h > 0.6) c = max(c, smoothstep(0.1, 0.0, abs(cell.x - 0.5)) * smoothstep(0.8, 0.9, cell.y));
    return c * step(0.0, grid.x) * step(grid.x, 5.0) * step(0.0, grid.y) * step(grid.y, 7.0);
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;

    float t = u_time;
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;

    vec3 color = vec3(0.0);

    // Background — deep black with subtle tint
    color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.3, 0.005) * brightness;

    // === 3 depth layers of rain ===
    for (int layer = 0; layer < 3; layer++) {
        float fl = float(layer);
        float depth = fl / 3.0;
        float layerScale = 15.0 + fl * 10.0;
        float layerSpeed = 0.5 + fl * 0.3 + BAND_BASS * 1.5 + secEnergy * 1.0;
        float layerBright = (1.0 - depth * 0.4) * brightness;
        
        // Stereo drift
        float drift = STEREO_BALANCE * 0.02 * (1.0 + fl);
        vec2 layerP = p + vec2(drift, 0.0);
        
        // Column grid
        float col = floor(layerP.x * layerScale);
        float colFrac = fract(layerP.x * layerScale);
        
        // Per-column random properties
        float colSeed = hash11(col + fl * 100.0);
        float colSpeed = layerSpeed * (0.5 + colSeed * 1.5);
        float colDelay = colSeed * 10.0;
        float colBright = 0.3 + colSeed * 0.7;
        
        // Fall position
        float fallY = layerP.y * layerScale * 0.8 - t * colSpeed - colDelay;
        float row = floor(fallY);
        float rowFrac = fract(fallY);
        
        // Trail — bright head fading to dark tail
        float trailLen = 8.0 + BAND_LOW_MID * 8.0 + secEnergy * 4.0;
        float trail = exp(-rowFrac * trailLen);
        
        // Character glyph
        vec2 charUV = vec2(colFrac, fract(fallY));
        float glyph = character(charUV, colSeed + row * 7.0);
        
        // Character corruption — highs drive glitch
        float corrupt = BAND_BRILLIANCE * 0.5 + BAND_AIR * 0.3;
        if (hash21(vec2(col, row + t * 10.0)) < corrupt * 0.1) {
            glyph = 1.0 - glyph;  // invert
        }
        
        // Brightness — beat pulse
        float charBright = colBright * trail * glyph * layerBright;
        charBright *= (0.5 + BEAT_INTENSITY * 0.5);
        
        // Head flash — brightest at trail head
        float headFlash = exp(-rowFrac * 2.0) * (0.5 + BEAT_DETECTED * 0.5);
        charBright += headFlash * layerBright * 0.3;
        
        // Color — green base with section hue shift
        vec3 rainCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + colSeed * SECTION_HUE_RNG * 0.3, 0.7, 1.0);
        // Head is brighter/whiter
        rainCol = mix(rainCol, vec3(0.9, 1.0, 0.95), headFlash * 0.5);
        
        color += rainCol * charBright;
    }

    // === Wave pattern — phrase beat drives horizontal wave ===
    float wavePhase = PHRASE_BEAT * PI / 8.0;
    float wave = sin(p.x * 5.0 + wavePhase + t * 0.5) * 0.5 + 0.5;
    color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.5, 0.3) * wave * 0.02 * SECTION_CONF * brightness;

    // === Glitch bursts on kick ===
    if (KICK_LEVEL > 0.1) {
        float glitchY = floor(p.y * 20.0 + t * 30.0);
        float glitch = hash11(glitchY);
        if (glitch > 0.95) {
            float glitchOffset = (glitch - 0.95) * 20.0 * KICK_LEVEL;
            color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.8, 1.0) * exp(-abs(p.x - glitchOffset) * 20.0) * 0.3;
        }
    }

    // === Scanlines ===
    color *= 0.85 + sin(uv.y * u_resolution.y * 0.8) * 0.15;

    // === Vignette + CRT curvature feel ===
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.8;

    // === Fixture effects ===
    if (STROBE_ON > 0.5) {
        float strobe = step(0.5, fract(t * (8.0 + BAND_HIGH_MID * 10.0)));
        color += vec3(0.8, 1.0, 0.9) * strobe * 0.1 * brightness;
    }
    color += vec3(0.9, 1.0, 0.95) * BLINDER_INT * TRIGGER_FLASH * 0.3;
    if (TRIGGER_PYRO > 0.5) color += vec3(1.0, 0.5, 0.1) * exp(-length(p) * 3.0) * 0.5;

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.9));
    frag_color = vec4(color, 1.0);
}
