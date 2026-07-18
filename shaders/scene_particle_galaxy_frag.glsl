#version 460 core

// PARTICLE GALAXY — Spiral galaxy with thousands of GPU-rendered stars.
// Spiral arms, core bulge, dust lanes, and audio-driven star formation bursts.
// Frequency bands drive different arm rotation speeds. Beat creates supernova flashes.
// Kick triggers starburst. Section drives galaxy color and density.
// Phrase drives arm rotation. Stereo drives viewing angle.

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
vec3 hash33(vec3 p) {
    return fract(sin(vec3(dot(p, vec3(127.1, 311.7, 74.7)),
                          dot(p, vec3(269.5, 183.3, 246.1)),
                          dot(p, vec3(113.5, 271.9, 124.6)))) * 43758.5453);
}
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

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;
    float dist2D = length(p);
    float angle = atan(p.y, p.x);

    float t = u_time;
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;

    // Galaxy parameters
    float galaxyRot = t * 0.05 + PHRASE_BEAT * PI / 32.0 + STEREO_BALANCE * 0.2;
    int numArms = 2 + int(secEnergy * 2.0);  // 2-4 spiral arms
    float armTightness = 0.5 + BAND_BASS * 0.3 + secEnergy * 0.3;

    vec3 color = vec3(0.0);

    // === Deep space background ===
    color += vec3(0.005, 0.005, 0.01) * brightness;
    // Nebula
    float neb = fbm(p * 1.2 + t * 0.01);
    color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.4, 0.15) * neb * 0.04 * brightness;

    // === Background stars ===
    for (int layer = 0; layer < 3; layer++) {
        float fl = float(layer);
        float scale = 30.0 + fl * 20.0;
        float star = hash21(floor(p * scale + fl * 100.0));
        if (star > 0.994 - fl * 0.001) {
            float tw = sin(t * (1.5 + fl) + star * 100.0) * 0.5 + 0.5;
            tw *= (0.7 + BEAT_DETECTED * 0.3);
            float b = (star - 0.99) * 100.0 * tw * exp(-length(fract(p * scale) - 0.5) * 18.0);
            vec3 sc = mix(vec3(0.8,0.9,1.0), vec3(1.0,0.8,0.6), hash21(floor(p * scale) + 1.0));
            color += sc * b * (1.0 - fl * 0.2) * brightness * 0.5;
        }
    }

    // === Galaxy core — bright bulge ===
    float coreDist = dist2D;
    float coreGlow = exp(-coreDist * coreDist * 8.0) * (0.5 + secEnergy * 0.5);
    vec3 coreCol = mix(vec3(1.0, 0.9, 0.7), u_color, 0.3);
    color += coreCol * coreGlow * brightness * 2.0;
    // Core pulse on beat
    color += coreCol * BEAT_INTENSITY * coreGlow * brightness;

    // === Spiral arms — star fields ===
    // Render stars in spiral pattern
    for (int arm = 0; arm < 4; arm++) {
        if (arm >= numArms) break;
        float fa = float(arm);
        float armOffset = fa * 2.0 * PI / float(numArms);
        
        // Render stars along this arm
        for (int s = 0; s < 40; s++) {
            float fs = float(s);
            // Star position along arm — logarithmic spiral
            float starR = 0.05 + fs * 0.04;
            float starAngle = armOffset + starR * armTightness * 3.0 + galaxyRot / (1.0 + starR);
            
            // Audio-driven arm rotation — different bands for different arms
            starAngle += sin(t * (0.1 + fa * 0.05) + fs * 0.1) * BAND_LOW_MID * 0.3;
            
            // Scatter
            vec3 scatter = hash33(vec3(fs, fa, s));
            starR += (scatter.x - 0.5) * 0.08;
            starAngle += (scatter.y - 0.5) * 0.3;
            
            // Project to screen
            vec2 starPos = vec2(cos(starAngle) * starR, sin(starAngle) * starR * 0.5);  // flattened disk
            
            float starDist = length(p - starPos);
            
            // Star brightness — band driven
            int bandIdx = int(mod(fs + fa * 10.0, 8.0));
            float bandLevel = 0.0;
            if (bandIdx == 0) bandLevel = BAND_SUB;
            else if (bandIdx == 1) bandLevel = BAND_BASS;
            else if (bandIdx == 2) bandLevel = BAND_LOW_MID;
            else if (bandIdx == 3) bandLevel = BAND_MID;
            else if (bandIdx == 4) bandLevel = BAND_HIGH_MID;
            else if (bandIdx == 5) bandLevel = BAND_PRESENCE;
            else if (bandIdx == 6) bandLevel = BAND_BRILLIANCE;
            else bandLevel = BAND_AIR;
            
            float starBright = (0.3 + bandLevel * 1.5 + secEnergy * 0.3) * brightness;
            // Beat twinkle
            starBright *= (0.7 + sin(t * 3.0 + fs * 2.0) * 0.3);
            starBright *= (0.8 + BEAT_INTENSITY * 0.4);
            
            // Star glow
            float glow = exp(-starDist * starDist * 150.0) * starBright;
            float core = exp(-starDist * starDist * 800.0) * starBright;
            
            // Star color — temperature based on band
            vec3 starCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + scatter.z * SECTION_HUE_RNG * 0.3, 0.5, 1.0);
            // Young hot stars are blue, old are red
            starCol = mix(starCol, vec3(0.7, 0.8, 1.0), scatter.z * 0.3);
            
            color += starCol * glow * 1.5;
            color += vec3(1.0) * core * 2.0;
        }
    }

    // === Dust lanes — dark bands between arms ===
    float dustAngle = angle + galaxyRot;
    float dust = sin(dustAngle * float(numArms)) * 0.5 + 0.5;
    dust *= smoothstep(0.1, 0.5, dist2D) * smoothstep(1.5, 0.8, dist2D);
    color *= 1.0 - dust * 0.3 * (0.5 + BAND_MID * 0.3);

    // === Supernova flash on beat ===
    float snDist = length(p - vec2(sin(t * 0.3) * 0.5, cos(t * 0.2) * 0.25));
    float supernova = exp(-snDist * snDist * 50.0) * BEAT_INTENSITY;
    color += vec3(1.0, 0.9, 0.8) * supernova * brightness * 3.0;

    // === Kick starburst ===
    color += vec3(0.8, 0.9, 1.0) * KICK_LEVEL * exp(-dist2D * 2.0) * 0.3 * brightness;

    // === Expanding wavefronts ===
    for (int wi = 0; wi < 2; wi++) {
        float fw = float(wi);
        float wR = fract(t * 0.1 - fw * 0.5 + PHRASE_BEAT * 0.0625) * 2.0;
        color += u_color * exp(-pow(dist2D - wR, 2.0) * 30.0) * BEAT_INTENSITY * exp(-fw * 0.5) * brightness * 0.3;
    }

    // Group behavior — phase drives arm shimmer
    float groupShimmer = sin(angle * float(numArms) + GROUP_PHASE * 6.28 + t) * 0.5 + 0.5;
    color += u_color * groupShimmer * 0.02 * SECTION_CONF * brightness;

    // Fixture effects
    if (STROBE_ON > 0.5) {
        float strobe = step(0.5, fract(t * (8.0 + BAND_HIGH_MID * 10.0)));
        color += vec3(1.0) * strobe * 0.15 * brightness;
    }
    color += vec3(1.0) * BLINDER_INT * TRIGGER_FLASH * 0.4;
    if (TRIGGER_PYRO > 0.5) color += vec3(1.0, 0.5, 0.1) * exp(-dist2D * 3.0) * 0.5;

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.4;
    frag_color = vec4(color, 1.0);
}
