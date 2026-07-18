#version 460 core

layout(location = 0) in vec3 a_position;
layout(location = 1) in vec3 a_velocity;
layout(location = 2) in float a_life;
layout(location = 3) in float a_size;

uniform float u_time;
uniform vec2 u_resolution;
uniform vec3 u_color;
uniform vec3 u_color2;

out vec3 v_color;
out float v_alpha;

void main() {
    // Simple perspective projection
    vec3 pos = a_position;
    // Velocity influences motion slightly
    pos.xy += a_velocity.xy * u_time * 0.01;
    float z = pos.z + 5.0;  // push back
    float fov = 1.5;
    float aspect = u_resolution.x / u_resolution.y;

    vec2 projected;
    projected.x = (pos.x / z) * fov * aspect;
    projected.y = (pos.y / z) * fov;

    gl_Position = vec4(projected, 0.0, 1.0);

    // Point size based on distance and audio
    float dist_atten = 1.0 / max(z * 0.3, 0.5);
    gl_PointSize = a_size * dist_atten * (1.0 + KICK_LEVEL * 2.0) * 3.0;

    // Color: blend between two brain colors based on life
    v_color = mix(u_color, u_color2, a_life);
    v_color *= (0.5 + OVERALL * 1.5);

    // Alpha fades at end of life
    v_alpha = smoothstep(0.0, 0.1, a_life) * smoothstep(1.0, 0.7, a_life);
    v_alpha *= (0.3 + BEAT_INTENSITY * 0.7);
}
