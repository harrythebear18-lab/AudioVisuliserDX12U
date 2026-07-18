#version 460 core

// Bloom pass: bright-pass extract + Gaussian blur
// Multi-tap blur for quality

in vec2 v_uv;
out vec4 frag_color;

uniform sampler2D u_scene;
uniform vec2 u_resolution;

// Separable Gaussian blur weights
const float weights[5] = float[](
    0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216
);

void main() {
    vec2 texel = 1.0 / u_resolution;
    
    // Bright-pass threshold
    vec3 scene = texture(u_scene, v_uv).rgb;
    float brightness = dot(scene, vec3(0.2126, 0.7152, 0.0722));
    vec3 bright = scene * smoothstep(0.6, 1.2, brightness);
    
    // Horizontal blur
    vec3 result = bright * weights[0];
    for (int i = 1; i < 5; i++) {
        result += texture(u_scene, v_uv + vec2(texel.x * float(i) * 2.0, 0.0)).rgb * weights[i] * smoothstep(0.6, 1.2, 1.0);
        result += texture(u_scene, v_uv - vec2(texel.x * float(i) * 2.0, 0.0)).rgb * weights[i] * smoothstep(0.6, 1.2, 1.0);
    }
    
    // Vertical blur
    vec3 result2 = result * weights[0];
    for (int i = 1; i < 5; i++) {
        vec2 offset = vec2(0.0, texel.y * float(i) * 2.0);
        result2 += texture(u_scene, v_uv + offset).rgb * weights[i] * 0.5;
        result2 += texture(u_scene, v_uv - offset).rgb * weights[i] * 0.5;
    }
    
    frag_color = vec4(result2, 1.0);
}
