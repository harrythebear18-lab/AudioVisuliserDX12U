#version 460 core

// Particle nebula mode — dark background with brain-driven ambient glow.
// The actual particles are rendered by the compute-shader particle system
// on top of this fragment shader. This provides the atmospheric backdrop.

in vec2 v_uv;
out vec4 frag_color;

uniform float u_time;
uniform vec2 u_resolution;
uniform sampler2D u_spectrum;
uniform vec3 u_color;
uniform vec3 u_color2;
uniform int u_section;

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
    for (int i = 0; i < 5; i++) {
        v += a * noise(p);
        p *= 2.0;
        a *= 0.5;
    }
    return v;
}

void main() {
    vec2 uv = (v_uv - 0.5) * 2.0;
    uv.x *= u_resolution.x / u_resolution.y;

    // Deep space background
    vec3 col = vec3(0.01, 0.01, 0.02);
    
    // Nebula clouds
    float clouds = fbm(uv * 2.0 + u_time * 0.05);
    clouds *= fbm(uv * 4.0 - u_time * 0.03);
    
    float hue = BASE_HUE + SECTION_HUE_CTR;
    col += hsv2rgb(hue, 0.6, 1.0) * clouds * (0.1 + ENVELOPE * 0.3);
    
    // Spectrum bar at bottom
    float bar_y = v_uv.y;
    if (bar_y < 0.15) {
        float bar_fade = smoothstep(0.0, 0.05, bar_y) * smoothstep(0.15, 0.12, bar_y);
        float spec_val = texture(u_spectrum, vec2(v_uv.x, 0.5)).r;
        col += u_color * spec_val * bar_fade * 3.0;
    }
    
    // Kick-driven radial pulse
    float r = length(uv);
    float pulse = exp(-r * 2.0) * KICK_LEVEL * 0.5;
    col += u_color * pulse;
    
    // Stars
    vec2 star_uv = uv * 30.0;
    float star = pow(noise(floor(star_uv)), 40.0) * 2.0;
    col += vec3(star) * (0.3 + ENVELOPE * 0.3);
    
    frag_color = vec4(col, 1.0);
}
