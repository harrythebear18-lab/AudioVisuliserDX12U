#version 460 core

in vec2 v_uv;
out vec4 frag_color;

uniform float u_time;
uniform vec2 u_resolution;
uniform sampler2D u_spectrum;
uniform vec3 u_color;
uniform vec3 u_color2;
uniform int u_section;

#define PI 3.14159265359

vec3 hsv2rgb(float h, float s, float v) {
    vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    vec3 p = abs(fract(vec3(h) + K.xyz) * 6.0 - K.www);
    return v * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), s);
}

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i), hash(i + vec2(1, 0)), f.x),
        mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x),
        f.y
    );
}

float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 6; i++) {
        v += a * noise(p);
        p *= 2.0;
        a *= 0.5;
    }
    return v;
}

void main() {
    vec2 uv = (v_uv - 0.5) * 2.0;
    uv.x *= u_resolution.x / u_resolution.y;

    // Domain warping for liquid effect
    float t = u_time * (0.3 + MOVEMENT_INT);
    vec2 q = vec2(fbm(uv + t * 0.1), fbm(uv + vec2(5.2, 1.3) + t * 0.15));
    vec2 r = vec2(fbm(uv + q + t * 0.05), fbm(uv + q + vec2(1.7, 9.2) + t * 0.08));
    
    // Audio-reactive warp strength
    float warp = (r.x + r.y) * (0.5 + ENVELOPE * 1.5);
    
    // Spectrum sampling
    float spec_idx = clamp(length(uv) * 0.3 + warp * 0.2, 0.0, 1.0);
    float spec_val = texture(u_spectrum, vec2(spec_idx, 0.5)).r;
    
    // Metaball-like blobs
    float blobs = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        vec2 center = vec2(
            sin(t * 0.5 + fi * 1.2) * 0.8,
            cos(t * 0.3 + fi * 2.1) * 0.8
        );
        float d = length(uv - center);
        blobs += 0.3 / (d * d + 0.1);
    }
    blobs = smoothstep(0.5, 2.0, blobs);
    
    // Color
    float hue = BASE_HUE + SECTION_HUE_CTR + warp * SECTION_HUE_RNG;
    hue += STEREO_BALANCE * 0.1;
    vec3 col = hsv2rgb(hue, 0.8, 0.3 + blobs * 0.7);
    
    // Spectrum glow
    col += u_color * spec_val * (1.0 + KICK_LEVEL);
    col += u_color2 * warp * 0.5;
    
    // Ripples on beat
    float ripple = sin(length(uv) * 20.0 - u_time * 5.0) * BEAT_INTENSITY * 0.3;
    col += u_color * ripple;
    
    // Vignette
    col *= 1.0 - length(v_uv - 0.5) * 0.4;
    
    frag_color = vec4(col, 1.0);
}
