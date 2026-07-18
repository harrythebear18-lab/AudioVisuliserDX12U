#version 460 core

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

struct Particle {
    vec4 pos_life;     // xyz = position, w = life
    vec4 vel_size;     // xyz = velocity, w = size
};

layout(std430, binding = 0) buffer ParticleBuffer {
    Particle particles[];
};

uniform float u_time;
uniform float u_dt;
uniform sampler2D u_spectrum;

#define PI 3.14159265359

// Hash for noise
uint hash(uint x) {
    x = ((x >> 16) ^ x) * 0x45d9f3b;
    x = ((x >> 16) ^ x) * 0x45d9f3b;
    x = (x >> 16) ^ x;
    return x;
}

float rand(uint seed) {
    return float(hash(seed)) / 4294967296.0;
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= particles.length()) return;

    Particle p = particles[idx];

    // Audio-driven forces
    float beat_pulse = BEAT_INTENSITY * 2.0;
    float kick_push = KICK_LEVEL * 3.0;

    // Sample spectrum at particle's frequency position
    float freq_idx = fract(p.pos_life.x * 0.15 + u_time * 0.02);
    float spec_val = texture(u_spectrum, vec2(freq_idx, 0.5)).r;

    // Swirl force — rotates particles around center
    vec3 to_center = -p.pos_life.xyz;
    float dist = length(to_center);
    vec3 swirl = cross(to_center, vec3(0.0, 1.0, 0.0)) * (0.5 + OVERALL * 2.0) / max(dist, 0.1);

    // Beat expansion — pushes particles outward on kick
    vec3 expansion = normalize(p.pos_life.xyz + vec3(0.001)) * kick_push;

    // Spectrum-driven displacement
    vec3 spec_force = vec3(
        sin(u_time * 2.0 + idx * 0.01) * spec_val,
        cos(u_time * 1.5 + idx * 0.02) * spec_val,
        sin(u_time * 1.8 + idx * 0.03) * spec_val
    ) * 0.5;

    // Update velocity with damping
    p.vel_size.xyz = p.vel_size.xyz * 0.96 + (swirl + expansion + spec_force) * u_dt;
    p.vel_size.xyz += vec3(rand(hash(idx) ^ uint(u_time * 1000.0)) - 0.5,
                           rand(hash(idx * 7) ^ uint(u_time * 1000.0)) - 0.5,
                           rand(hash(idx * 13) ^ uint(u_time * 1000.0)) - 0.5) * 0.02;

    // Update position
    p.pos_life.xyz += p.vel_size.xyz * u_dt * (1.0 + beat_pulse);

    // Gravity-like pull back to center
    p.pos_life.xyz -= p.pos_life.xyz * 0.002 * (1.0 - OVERALL);

    // Life cycle
    p.pos_life.w -= u_dt * (0.1 + OVERALL * 0.3);
    if (p.pos_life.w < 0.0) {
        // Respawn
        uint seed = idx ^ uint(u_time * 100.0);
        float theta = rand(seed) * 2.0 * PI;
        float phi = acos(rand(seed * 3) * 2.0 - 1.0);
        float r = 0.5 + rand(seed * 5) * 2.5;
        p.pos_life = vec4(
            r * sin(phi) * cos(theta),
            r * sin(phi) * sin(theta),
            r * cos(phi),
            rand(seed * 11)
        );
        p.vel_size.xyz = vec3(0.0);
        p.vel_size.w = 1.0 + rand(seed * 17) * 3.0;
    }

    // Size pulses with beat
    p.vel_size.w = 1.0 + beat_pulse * 3.0 + spec_val * 2.0;

    particles[idx] = p;
}
