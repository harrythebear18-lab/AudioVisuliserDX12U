#version 460 core

// WAVE POOL — 3D rippling water surface viewed at angle.
// Heightfield-based waves with Gerstner wave model, Fresnel reflections,
// caustics on the floor, and audio-driven wave amplitude/direction.
// Section drives wave complexity. Beat creates concentric ripples.
// Kick creates splash. Phrase drives wave direction rotation.

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
    for (int i = 0; i < 5; i++) { v += a * noise(p); p *= 2.1; a *= 0.5; }
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

// Gerstner wave — returns height and derivative
vec3 gerstner(vec2 pos, vec2 dir, float wavelength, float steepness, float t) {
    float k = 2.0 * PI / wavelength;
    float c = sqrt(9.8 / k);
    vec2 d = normalize(dir);
    float f = k * dot(d, pos) - c * t;
    float a = steepness / k;
    return vec3(d * a * cos(f), a * sin(f));
}

// Wave heightfield — sum of Gerstner waves driven by frequency bands
float waveHeight(vec2 pos, float t, float secEnergy) {
    float h = 0.0;
    // Phrase beat rotates wave direction
    float phraseRot = PHRASE_BEAT * PI / 16.0;
    
    h += gerstner(pos, rot(phraseRot) * vec2(1.0, 0.3), 3.0, 0.15 + BAND_SUB * 0.3, t).z;
    h += gerstner(pos, rot(phraseRot + 0.5) * vec2(-0.5, 1.0), 2.0, 0.1 + BAND_BASS * 0.25, t * 1.2).z;
    h += gerstner(pos, rot(phraseRot + 1.0) * vec2(0.7, -0.5), 1.5, 0.08 + BAND_LOW_MID * 0.2, t * 1.5).z;
    h += gerstner(pos, rot(phraseRot + 1.5) * vec2(-1.0, 0.2), 1.0, 0.06 + BAND_MID * 0.15, t * 2.0).z;
    h += gerstner(pos, rot(phraseRot + 2.0) * vec2(0.3, 1.0), 0.7, 0.04 + BAND_HIGH_MID * 0.12, t * 2.5).z;
    h += gerstner(pos, rot(phraseRot + 2.5) * vec2(-0.8, -0.6), 0.5, 0.03 + BAND_PRESENCE * 0.08, t * 3.0).z;
    
    // Beat ripple — concentric from center
    float beatDist = length(pos);
    h += sin(beatDist * 20.0 - t * 15.0) * BEAT_INTENSITY * 0.1 * exp(-beatDist * 0.5);
    
    // Kick splash
    h += exp(-beatDist * beatDist * 5.0) * KICK_LEVEL * 0.3;
    
    return h * (0.5 + secEnergy * 0.5);
}

// Normal from heightfield
vec3 waveNormal(vec2 pos, float t, float secEnergy) {
    float eps = 0.01;
    float hL = waveHeight(pos - vec2(eps, 0.0), t, secEnergy);
    float hR = waveHeight(pos + vec2(eps, 0.0), t, secEnergy);
    float hD = waveHeight(pos - vec2(0.0, eps), t, secEnergy);
    float hU = waveHeight(pos + vec2(0.0, eps), t, secEnergy);
    return normalize(vec3(hL - hR, hD - hU, 2.0 * eps));
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;

    float t = u_time;
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;

    // Perspective transform — looking down at water at an angle
    vec2 waterP = p;
    waterP.y *= 1.0 - uv.y * 0.3;  // perspective compression
    float depth = 1.0 + uv.y * 0.5;  // closer at bottom

    // Wave height and normal
    float h = waveHeight(waterP * 2.0, t, secEnergy);
    vec3 normal = waveNormal(waterP * 2.0, t, secEnergy);
    vec3 viewDir = normalize(vec3(0.0, 0.5, 1.0));

    // Fresnel
    float fresnel = pow(1.0 - max(dot(normal, viewDir), 0.0), 5.0);
    fresnel = mix(0.02, 1.0, fresnel);

    // Sky reflection
    vec3 reflectDir = reflect(-viewDir, normal);
    float skyT = reflectDir.y * 0.5 + 0.5;
    vec3 skyCol = mix(hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.4, 0.02),
                      hsv2rgb(BASE_HUE + SECTION_HUE_CTR + 0.1, 0.6, 0.15), skyT);
    // Sun/moon reflection
    float sunRefl = pow(max(dot(reflectDir, normalize(vec3(0.3, 0.8, 0.2))), 0.0), 64.0);
    skyCol += vec3(1.0, 0.9, 0.7) * sunRefl * (0.3 + LASER_INT * 1.0);

    // Water body color — deep section-tinted
    vec3 waterCol = mix(u_color2, u_color, 0.5);
    waterCol = mix(waterCol, hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.5, 0.3), 0.4);
    // Depth gradient — deeper = darker
    waterCol *= 0.3 + 0.7 * smoothstep(-0.5, 0.5, h);

    // Combine water + reflection
    vec3 color = mix(waterCol, skyCol, fresnel) * brightness;

    // === Caustics on floor — visible through water ===
    float causticT = uv.y * 0.5 + 0.5;  // more visible at far end
    vec2 causticP = waterP * 3.0 + normal.xy * 2.0;
    float caustic = 0.0;
    caustic += pow(abs(sin(causticP.x * 5.0 + t * 2.0) * sin(causticP.y * 5.0 + t * 1.5)), 8.0);
    caustic += pow(abs(sin(causticP.x * 8.0 - t * 1.0) * sin(causticP.y * 7.0 + t * 2.5)), 12.0);
    caustic *= (0.3 + BAND_MID * 0.5 + secEnergy * 0.3);
    color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR + 0.05, 0.6, 1.0) * caustic * causticT * brightness * 0.5;

    // === Specular highlights ===
    vec3 lightDir = normalize(vec3(0.3, 0.8, 0.2));
    vec3 halfV = normalize(lightDir + viewDir);
    float spec = pow(max(dot(normal, halfV), 0.0), 128.0);
    spec *= (0.3 + LASER_INT * 1.5 + secEnergy * 0.5);
    color += vec3(1.0) * spec * brightness * 0.8;

    // === Beat ripple — expanding rings ===
    float dist2D = length(waterP);
    for (int ri = 0; ri < 3; ri++) {
        float fr = float(ri);
        float rR = fract(t * 0.3 - fr * 0.33 + PHRASE_BEAT * 0.0625) * 3.0;
        float ring = sin((dist2D - rR) * 30.0) * exp(-pow(dist2D - rR, 2.0) * 8.0);
        ring *= (BEAT_INTENSITY + KICK_LEVEL * 0.3) * exp(-fr * 0.5);
        color += u_color * ring * 0.15 * brightness;
    }

    // === Foam on high waves ===
    float foam = smoothstep(0.3, 0.5, h) * smoothstep(0.8, 0.5, h);
    foam *= (0.3 + BAND_BASS * 0.7 + secEnergy * 0.3);
    color += vec3(0.9, 0.95, 1.0) * foam * brightness * 0.3;

    // === Group behavior — phase drives wave shimmer ===
    float shimmer = sin(waterP.x * 10.0 + GROUP_PHASE * 6.28 + t * 2.0) * 0.5 + 0.5;
    color += u_color * shimmer * 0.03 * SECTION_CONF * brightness;

    // === Fixture effects ===
    if (STROBE_ON > 0.5) {
        float strobe = step(0.5, fract(t * (8.0 + BAND_HIGH_MID * 10.0)));
        color += vec3(1.0) * strobe * 0.15 * brightness;
    }
    color += vec3(1.0) * BLINDER_INT * TRIGGER_FLASH * 0.4;
    if (TRIGGER_PYRO > 0.5) color += vec3(1.0, 0.5, 0.1) * exp(-dist2D * 3.0) * 0.5;
    if (TRIGGER_SMOKE > 0.5) {
        color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.2, 0.3) * fbm(p * 2.0 + t * 0.1) * 0.1;
    }

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.4;
    frag_color = vec4(color, 1.0);
}
