#version 460 core

// REACTIVE METAL — Brushed chrome surface that deforms and ripples with audio.
// Heightfield displacement with PBR lighting: anisotropic specular, Fresnel,
// environment reflection, ambient occlusion in crevices.
// Bass drives large deformations, mids drive ripples, highs drive surface roughness.
// Beat creates impact craters. Kick creates shockwave ripples. Section drives color temperature.

in vec2 v_uv;
out vec4 frag_color;

uniform float u_time;
uniform vec2 u_resolution;
uniform sampler2D u_spectrum;
uniform vec3 u_color;
uniform vec3 u_color2;

#define PI 3.14159265359

vec3 hsv2rgb(float h, float s, float v) {
    vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    vec3 p = abs(fract(vec3(h) + K.xyz) * 6.0 - K.www);
    return v * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), s);
}
float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i+vec2(1,0)), f.x),
               mix(hash21(i+vec2(0,1)), hash21(i+vec2(1,1)), f.x), f.y);
}
float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 6; i++) { v += a * noise(p); p *= 2.13; a *= 0.5; }
    return v;
}
mat2 rot(float a) { return mat2(cos(a), -sin(a), sin(a), cos(a)); }

float sectionEnergy(float sec) {
    if (sec < 0.5) return 0.0;
    if (sec < 1.5) return 0.15;
    if (sec < 2.5) return 0.4;
    if (sec < 3.5) return 0.5;
    if (sec < 4.5) return 0.6;
    if (sec < 5.5) return 0.7;
    if (sec < 6.5) return 1.0;
    if (sec < 7.5) return 0.5;
    if (sec < 8.5) return 0.45;
    if (sec < 9.5) return 0.3;
    return 0.1;
}

// Heightfield — audio-driven deformation
float metalHeight(vec2 p, float t, float secEnergy) {
    float h = 0.0;
    
    // Large bass-driven deformation
    h += sin(p.x * 2.0 + t * 0.5) * cos(p.y * 2.0 + t * 0.3) * BAND_SUB * 0.15;
    h += sin(length(p) * 3.0 - t * 0.8) * BAND_BASS * 0.12;
    
    // Mid-frequency ripples
    h += sin(p.x * 8.0 + t * 1.5) * sin(p.y * 6.0 + t * 1.2) * BAND_LOW_MID * 0.06;
    h += fbm(p * 5.0 + t * 0.3) * BAND_MID * 0.04;
    
    // High-frequency surface texture
    h += (noise(p * 20.0 + t * 0.5) - 0.5) * BAND_HIGH_MID * 0.02;
    h += (noise(p * 40.0) - 0.5) * BAND_PRESENCE * 0.01;
    
    // Beat impact — crater at center
    float beatDist = length(p);
    h -= exp(-beatDist * beatDist * 3.0) * BEAT_INTENSITY * 0.08;
    
    // Kick shockwave — expanding ring
    float kickR = fract(t * 0.5) * 2.0;
    h += sin((beatDist - kickR) * 30.0) * exp(-pow(beatDist - kickR, 2.0) * 10.0) * KICK_LEVEL * 0.06;
    
    // Phrase rotation
    float phraseRot = PHRASE_BEAT * PI / 16.0;
    p = rot(phraseRot) * p;
    h += sin(p.x * 4.0 + t * 0.2) * SECTION_CONF * 0.02;
    
    return h * (0.5 + secEnergy * 0.5);
}

vec3 metalNormal(vec2 p, float t, float secEnergy) {
    float eps = 0.005;
    float hL = metalHeight(p - vec2(eps, 0.0), t, secEnergy);
    float hR = metalHeight(p + vec2(eps, 0.0), t, secEnergy);
    float hD = metalHeight(p - vec2(0.0, eps), t, secEnergy);
    float hU = metalHeight(p + vec2(0.0, eps), t, secEnergy);
    return normalize(vec3(hL - hR, hD - hU, 2.0 * eps * 10.0));
}

// Environment map
vec3 envMap(vec3 dir, float t, float secEnergy) {
    float t2 = dir.y * 0.5 + 0.5;
    vec3 col = mix(u_color2, u_color, t2);
    col = mix(col, vec3(1.0), pow(t2, 4.0) * 0.5);
    // Studio light bars
    float bars = sin(dir.x * 15.0 + t * 0.5) * 0.5 + 0.5;
    col *= 0.6 + bars * 0.4;
    // Section-tinted
    col = mix(col, hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.3, 1.0), 0.15);
    return col;
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;

    float t = u_time;
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;

    // Height and normal
    float h = metalHeight(p, t, secEnergy);
    vec3 normal = metalNormal(p, t, secEnergy);
    vec3 viewDir = normalize(vec3(0.0, 0.3, 1.0));

    // Fresnel
    float fresnel = pow(1.0 - max(dot(normal, viewDir), 0.0), 3.0);
    fresnel = mix(0.1, 0.95, fresnel);

    // Reflection
    vec3 reflectDir = reflect(-viewDir, normal);
    vec3 envCol = envMap(reflectDir, t, secEnergy) * brightness;

    // Anisotropic specular — brushed metal look
    // Brush direction rotates with phrase
    float brushAngle = PHRASE_BEAT * PI / 16.0;
    vec2 brushDir = vec2(cos(brushAngle), sin(brushAngle));
    vec3 tangent = normalize(vec3(brushDir, 0.0));
    float aniso = pow(max(dot(reflectDir, normalize(vec3(0.5, 0.8, 0.2))), 0.0), 16.0);
    aniso *= (0.5 + abs(dot(tangent.xy, normal.xy)) * 0.5);
    aniso *= (0.3 + LASER_INT * 1.5 + secEnergy * 0.5);

    // Standard specular
    vec3 lightDir = normalize(vec3(-0.3, 0.7, 0.5));
    vec3 halfV = normalize(lightDir + viewDir);
    float spec = pow(max(dot(normal, halfV), 0.0), 96.0);
    spec *= (0.3 + LASER_INT * 1.0) * brightness;

    // Metal base color — section-tinted chrome
    vec3 metalCol = mix(vec3(0.7, 0.71, 0.73), hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.12, 0.9), 0.2);
    // Heat tint — bass warms the metal
    metalCol = mix(metalCol, vec3(1.0, 0.7, 0.4), BAND_BASS * 0.15);
    // Cool tint — highs cool it
    metalCol = mix(metalCol, vec3(0.6, 0.7, 1.0), BAND_AIR * 0.1);

    // Combine
    vec3 color = mix(metalCol * brightness * 0.3, envCol, fresnel);
    color += vec3(1.0) * spec;
    color += vec3(1.0, 0.95, 0.9) * aniso * brightness * 0.5;

    // Ambient occlusion in crevices
    float ao = smoothstep(-0.1, 0.05, h);
    color *= 0.5 + ao * 0.5;

    // Beat glow — hot spots where deformation is extreme
    float heat = smoothstep(0.05, 0.15, abs(h));
    color += mix(u_color, vec3(1.0, 0.6, 0.3), heat) * heat * BEAT_INTENSITY * 0.5 * brightness;

    // Kick flash
    color += vec3(1.0, 0.9, 0.8) * KICK_LEVEL * exp(-length(p) * 2.0) * 0.3 * brightness;

    // Brushed texture lines
    float brushed = sin(dot(p, brushDir) * 80.0) * 0.5 + 0.5;
    color *= 0.92 + brushed * 0.08;

    // Group behavior — phase drives shimmer
    float shimmer = sin(p.x * 15.0 + GROUP_PHASE * 6.28 + t) * 0.5 + 0.5;
    color += u_color * shimmer * 0.02 * SECTION_CONF * brightness;

    // Fixture effects
    if (STROBE_ON > 0.5) {
        float strobe = step(0.5, fract(t * (8.0 + BAND_HIGH_MID * 10.0)));
        color += vec3(1.0) * strobe * 0.15 * brightness;
    }
    color += vec3(1.0) * BLINDER_INT * TRIGGER_FLASH * 0.5;
    if (TRIGGER_PYRO > 0.5) color += vec3(1.0, 0.5, 0.1) * exp(-length(p) * 3.0) * 0.5;
    if (TRIGGER_SMOKE > 0.5) {
        color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.2, 0.3) * fbm(p * 2.0 + t * 0.1) * 0.1;
    }

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.35;
    frag_color = vec4(color, 1.0);
}
