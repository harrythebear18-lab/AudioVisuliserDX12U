#version 460 core

in vec3 v_color;
in float v_alpha;

out vec4 frag_color;

void main() {
    // Soft circular point sprite
    vec2 coord = gl_PointCoord - vec2(0.5);
    float r = length(coord);
    if (r > 0.5) discard;

    // Gaussian falloff for soft glow
    float alpha = exp(-r * r * 8.0) * v_alpha;
    frag_color = vec4(v_color * alpha * 2.0, alpha);
}
