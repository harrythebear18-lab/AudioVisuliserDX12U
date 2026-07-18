#version 460 core

// Postprocess: composite scene + bloom + chromatic aberration + vignette + film grain
// This is the final pass — renders to the default framebuffer (screen).

in vec2 v_uv;
out vec4 frag_color;

uniform sampler2D u_scene;
uniform sampler2D u_bloom;
uniform float u_time;
uniform vec2 u_resolution;
uniform float u_flash;
uniform float u_strobe;
uniform vec3 u_tint;

// Hash for film grain
float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void main() {
    vec2 uv = v_uv;

    // --- Chromatic aberration (shifts on beat) ---
    float ca_strength = 0.003 + BEAT_INTENSITY * 0.008;
    vec2 dir = (uv - 0.5);
    float r_channel = texture(u_scene, uv - dir * ca_strength).r;
    float g_channel = texture(u_scene, uv).g;
    float b_channel = texture(u_scene, uv + dir * ca_strength).b;
    vec3 scene = vec3(r_channel, g_channel, b_channel);

    // --- Bloom additive ---
    vec3 bloom = texture(u_bloom, uv).rgb;
    scene += bloom * 1.5;

    // --- Flash ---
    scene += u_tint * u_flash * 0.8;

    // --- Strobe ---
    if (u_strobe > 0.5) {
        float strobe_pulse = step(0.5, fract(u_time * 8.0));
        scene = mix(scene, vec3(1.0), strobe_pulse * 0.3);
    }

    // --- Vignette ---
    float vig = 1.0 - dot(dir, dir) * 0.8;
    scene *= vig;

    // --- Film grain ---
    float grain = (hash(uv * u_resolution + u_time) - 0.5) * 0.04;
    scene += grain;

    // --- Subtle scanline (CRT vibe) ---
    float scanline = sin(uv.y * u_resolution.y * 1.5) * 0.015;
    scene -= scanline;

    // --- Tone mapping (Reinhard) ---
    scene = scene / (1.0 + scene);
    
    // --- Gamma correction ---
    scene = pow(scene, vec3(1.0 / 2.2));

    frag_color = vec4(scene, 1.0);
}
