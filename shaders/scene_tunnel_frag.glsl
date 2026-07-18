#version 460 core

// Scene: Tunnel — audio-reactive kaleidoscopic tunnel with spectrum sampling.
// Uses the shared AudioBlock UBO (injected at compile time).

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

void main() {
    vec2 uv = (v_uv - 0.5) * 2.0;
    uv.x *= u_resolution.x / u_resolution.y;

    float r = length(uv);
    float a = atan(uv.y, uv.x);

    float depth = u_time * (0.5 + MOVEMENT_INT * 2.0);
    float tunnel_r = 1.0 / max(r, 0.01);

    float radius_mod = 1.0 + KICK_LEVEL * 0.3 + sin(tunnel_r * 5.0 - depth) * 0.1 * ENVELOPE;
    tunnel_r *= radius_mod;

    float spec_idx = fract(tunnel_r * 0.1 + depth * 0.05);
    float spec_val = texture(u_spectrum, vec2(spec_idx, 0.5)).r;

    float rings = sin(tunnel_r * 8.0 - depth * 2.0);
    rings = smoothstep(0.0, 0.3, rings);

    float bands = sin(a * 6.0 + u_time * 0.5);
    bands = smoothstep(0.0, 0.5, bands);

    float hue = BASE_HUE + SECTION_HUE_CTR + spec_idx * SECTION_HUE_RNG;
    hue += STEREO_BALANCE * 0.1;
    vec3 col = hsv2rgb(hue, 0.8, 0.3 + spec_val * 1.5);

    col += u_color * rings * (0.3 + ENVELOPE * 0.7);
    col += u_color2 * bands * (0.2 + BEAT_INTENSITY * 0.5);

    float center_glow = exp(-r * 3.0) * KICK_LEVEL * 2.0;
    col += u_color * center_glow;

    col *= smoothstep(0.0, 0.15, r);

    col += u_color * BEAT_INTENSITY * 0.1;

    frag_color = vec4(col, 1.0);
}
