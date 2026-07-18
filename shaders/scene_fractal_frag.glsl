#version 460 core

// Scene: Fractal — kaleidoscopic Mandelbrot with audio-reactive zoom and color.
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

mat2 rot(float a) {
    float c = cos(a), s = sin(a);
    return mat2(c, -s, s, c);
}

vec3 fractal(vec2 uv, float t) {
    vec2 z = uv;
    vec2 c = uv * (1.0 + ENVELOPE * 0.5);

    c += vec2(sin(t * 0.3), cos(t * 0.2)) * 0.3 * MOVEMENT_INT;
    c += vec2(STEREO_BALANCE * 0.2, 0.0);

    float iter = 0.0;
    const float MAX_ITER = 128.0;

    for (float i = 0.0; i < MAX_ITER; i++) {
        z = rot(t * 0.1 + BPM * 0.001) * z;
        z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;

        if (dot(z, z) > 4.0) break;
        iter = i;
    }

    float norm = iter / MAX_ITER;

    float spec_val = texture(u_spectrum, vec2(norm, 0.5)).r;

    float hue = BASE_HUE + SECTION_HUE_CTR + norm * SECTION_HUE_RNG;
    float sat = 0.7 + spec_val * 0.3;
    float val = norm * norm * (1.0 + KICK_LEVEL);

    vec3 col = hsv2rgb(hue, sat, val);

    float edge = smoothstep(0.8, 1.0, norm);
    col += u_color * edge * (1.0 + BEAT_INTENSITY);

    return col;
}

void main() {
    vec2 uv = (v_uv - 0.5) * 2.0;
    uv.x *= u_resolution.x / u_resolution.y;

    float zoom = 1.5 - OVERALL * 0.5;
    uv *= zoom;

    float a = atan(uv.y, uv.x);
    float r = length(uv);
    int segments = int(4.0 + KICK_LEVEL * 4.0);
    a = mod(a, PI * 2.0 / float(segments));
    uv = vec2(cos(a), sin(a)) * r;

    vec3 col = fractal(uv, u_time);

    col += u_color * BEAT_INTENSITY * 0.2;

    col *= 1.0 - length(v_uv - 0.5) * 0.5;

    frag_color = vec4(col, 1.0);
}
