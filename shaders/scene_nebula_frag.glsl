#version 460 core

// Scene: Nebula — raymarched volumetric audio-reactive sphere with FBM noise.
// Uses the shared AudioBlock UBO (injected at compile time from audio_ubo.glsl).

in vec2 v_uv;
out vec4 frag_color;

uniform float u_time;
uniform vec2 u_resolution;
uniform sampler2D u_spectrum;   // unit 0 — mono spectrum
uniform vec3 u_color;
uniform vec3 u_color2;
uniform int u_section;

#define PI 3.14159265359
#define MAX_STEPS 64
#define MAX_DIST 30.0
#define SURF_DIST 0.005

// --- Noise functions ---
float hash(vec3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(mix(hash(i + vec3(0,0,0)), hash(i + vec3(1,0,0)), f.x),
            mix(hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
        mix(mix(hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x),
            mix(hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y),
        f.z
    );
}

float fbm(vec3 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * noise(p);
        p *= 2.0;
        a *= 0.5;
    }
    return v;
}

vec3 hsv2rgb(float h, float s, float v) {
    vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    vec3 p = abs(fract(vec3(h) + K.xyz) * 6.0 - K.www);
    return v * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), s);
}

float sd_sphere(vec3 p, float r) {
    return length(p) - r;
}

float scene_sdf(vec3 p) {
    float r = 1.0 + KICK_LEVEL * 0.5 + ENVELOPE * 0.3;
    float n = fbm(p * 2.0 + u_time * 0.3 * MOVEMENT_INT) * 0.3;
    n += fbm(p * 4.0 - u_time * 0.2) * 0.15 * EFFECT_INT;
    return sd_sphere(p, r) + n;
}

vec3 get_normal(vec3 p) {
    vec2 e = vec2(0.001, 0.0);
    return normalize(vec3(
        scene_sdf(p + e.xyy) - scene_sdf(p - e.xyy),
        scene_sdf(p + e.yxy) - scene_sdf(p - e.yxy),
        scene_sdf(p + e.yyx) - scene_sdf(p - e.yyx)
    ));
}

float raymarch(vec3 ro, vec3 rd, out int steps) {
    float d = 0.0;
    steps = 0;
    for (int i = 0; i < MAX_STEPS; i++) {
        vec3 p = ro + rd * d;
        float ds = scene_sdf(p);
        if (ds < SURF_DIST) { steps = i; break; }
        d += ds;
        if (d > MAX_DIST) { steps = i; break; }
    }
    return d;
}

void main() {
    vec2 uv = (v_uv - 0.5) * 2.0;
    uv.x *= u_resolution.x / u_resolution.y;

    vec3 ro = vec3(0.0, 0.0, -3.5 - OVERALL);
    vec3 rd = normalize(vec3(uv, 1.5));

    ro.x += sin(u_time * 0.3 + BPM * 0.01) * 0.3 * MOVEMENT_INT;
    ro.y += cos(u_time * 0.25) * 0.2 * MOVEMENT_INT;

    int steps;
    float d = raymarch(ro, rd, steps);

    vec3 bg = vec3(0.0);
    float bg_noise = fbm(vec3(uv * 3.0, u_time * 0.1));
    bg += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.7, 0.05 + bg_noise * 0.1 * OVERALL);

    vec3 star_p = vec3(uv * 50.0, u_time * 0.5);
    float stars = pow(noise(floor(star_p)), 30.0) * 2.0;
    bg += vec3(stars) * (0.5 + ENVELOPE * 0.5);

    vec3 color = bg;

    if (d < MAX_DIST) {
        vec3 p = ro + rd * d;
        vec3 n = get_normal(p);

        vec3 light_dir = normalize(vec3(1.0, 1.0, -1.0));
        float diff = max(dot(n, light_dir), 0.0);
        float fresnel = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);

        vec3 base_col = mix(u_color, u_color2, diff);

        float spec_idx = clamp(length(p) / 3.0, 0.0, 1.0);
        float spec_val = texture(u_spectrum, vec2(spec_idx, 0.5)).r;
        vec3 emission = base_col * (diff * 0.5 + spec_val * 2.0);
        emission += u_color * fresnel * (1.0 + KICK_LEVEL * 2.0);

        float step_glow = float(steps) / float(MAX_STEPS);
        emission += u_color2 * step_glow * 0.3;

        color = mix(bg, emission, 1.0 - exp(-d * 0.3));
    }

    float fog = fbm(vec3(uv * 2.0, u_time * 0.15)) * ENVELOPE * 0.3;
    color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.5, 1.0) * fog;

    color += u_color * BEAT_INTENSITY * 0.15;

    float vig = 1.0 - length(uv) * 0.3;
    color *= vig;

    frag_color = vec4(color, 1.0);
}
