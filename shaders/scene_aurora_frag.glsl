#version 460 core

// AURORA — Volumetric aurora borealis curtains.
// Multi-layer domain-warped curtains with rayleigh-like scattering.
// Audio drives: curtain intensity (energy), wave speed (bass),
// color shifts (section), particle sparks (highs), ground reflection.
// Beat creates pulses along curtains. Kick creates bright flashes.
// Phrase drives curtain sweep direction. Stereo drives lateral shift.

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

// Aurora curtain — domain-warped vertical bands
float auroraCurtain(vec2 p, float t, float secEnergy, float layerOffset) {
    // Phrase drives horizontal sweep
    float sweep = PHRASE_BEAT * PI / 8.0 + layerOffset;
    // Stereo lateral shift
    p.x += STEREO_BALANCE * 0.3;
    
    // Domain warp for organic curtain shape
    vec2 q = vec2(fbm(p * 2.0 + t * 0.1), fbm(p * 2.0 + vec2(5.2, 1.3) + t * 0.08));
    vec2 r = vec2(fbm(p * 3.0 + q * 2.0 + vec2(1.7, 9.2) + t * 0.05),
                  fbm(p * 3.0 + q * 2.0 + vec2(8.3, 2.8) + t * 0.06));
    
    // Curtain shape — vertical bands modulated by warp
    float curtain = sin(p.x * 3.0 + r.x * 4.0 + sweep + t * (0.2 + BAND_BASS * 0.5));
    curtain = pow(max(0.0, curtain), 2.0);
    
    // Vertical falloff — curtains hang from top
    float vertFade = smoothstep(1.2, 0.3, p.y) * smoothstep(-0.8, -0.3, p.y);
    curtain *= vertFade;
    
    // Audio intensity
    curtain *= (0.3 + BAND_SUB * 0.4 + BAND_LOW_MID * 0.3 + secEnergy * 0.5);
    
    // Beat pulse — brightens curtains
    curtain *= (0.7 + BEAT_INTENSITY * 0.5);
    
    // Ripples — mid frequencies add texture
    curtain *= (0.8 + r.y * 0.4);
    
    return curtain;
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;
    float dist2D = length(p);

    float t = u_time;
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;

    vec3 color = vec3(0.0);

    // === Night sky background ===
    float skyT = uv.y;
    vec3 skyTop = vec3(0.01, 0.02, 0.05);
    vec3 skyBot = hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.3, 0.04);
    color += mix(skyBot, skyTop, smoothstep(0.0, 0.7, skyT)) * brightness;

    // Stars
    float star = hash21(floor(p * 30.0));
    if (star > 0.995) {
        float tw = sin(t * 2.0 + star * 100.0) * 0.5 + 0.5;
        tw *= (0.7 + BEAT_DETECTED * 0.3);
        color += vec3(0.8, 0.9, 1.0) * (star - 0.995) * 200.0 * tw * brightness * 0.3;
    }
    // Distant galaxy band
    float galaxy = fbm(p * 1.5 + vec2(t * 0.01, 0.0)) * 0.05;
    color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.4, 0.3) * galaxy * brightness;

    // === Aurora curtains — 4 depth layers ===
    for (int layer = 0; layer < 4; layer++) {
        float fl = float(layer);
        float depth = fl / 4.0;
        
        // Each layer at different position and scale
        vec2 layerP = p;
        layerP.x *= 1.0 + depth * 0.3;
        layerP.y += depth * 0.1;
        
        float curtain = auroraCurtain(layerP, t + depth * 0.5, secEnergy, fl * 1.5);
        
        if (curtain > 0.001) {
            // Color — gradient from green to purple based on height and section
            float colorT = layerP.y * 0.5 + 0.5;
            float hueShift = BASE_HUE + SECTION_HUE_CTR + colorT * SECTION_HUE_RNG * 0.5;
            
            vec3 auroraCol = hsv2rgb(hueShift, 0.7, 1.0);
            // Mix with brain colors
            auroraCol = mix(auroraCol, mix(u_color, u_color2, colorT), 0.3);
            // Hot pink/magenta at top
            auroraCol = mix(auroraCol, vec3(0.9, 0.3, 0.8), smoothstep(0.5, 0.8, colorT) * 0.3);
            // Green at base
            auroraCol = mix(auroraCol, vec3(0.3, 0.9, 0.5), smoothstep(0.3, 0.0, colorT) * 0.3);
            
            // Depth attenuation
            float depthFade = 1.0 - depth * 0.3;
            
            // Volumetric glow
            color += auroraCol * curtain * depthFade * brightness * 1.5;
            
            // Bright edges — rayleigh-like scattering
            float edge = pow(curtain, 0.3);
            color += auroraCol * edge * 0.1 * depthFade * brightness;
        }
    }

    // === Particle sparks — rising from aurora ===
    int numSparks = 6 + int(secEnergy * 10.0);
    for (int si = 0; si < 16; si++) {
        if (si >= numSparks) break;
        float fi = float(si);
        float sparkX = fract(fi * 0.17 + sin(fi * 3.0) * 0.5 + t * 0.03) * 2.0 - 1.0;
        float sparkY = fract(t * (0.1 + BAND_AIR * 0.2) + fi * 0.09) * 1.5 - 0.5;
        sparkX += sin(sparkY * 2.0 + t + fi) * 0.05;
        
        float sparkDist = length(p - vec2(sparkX, sparkY));
        float sparkGlow = exp(-sparkDist * sparkDist * 400.0);
        float sparkFlicker = sin(t * 8.0 + fi * 2.0) * 0.5 + 0.5;
        
        vec3 sparkCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + fi * 0.03, 0.5, 1.0);
        color += sparkCol * sparkGlow * sparkFlicker * 0.3 * brightness;
    }

    // === Ground reflection — aurora reflected in water/snow ===
    if (uv.y < 0.35) {
        float reflT = (0.35 - uv.y) / 0.35;
        vec2 reflP = vec2(p.x, -p.y + 0.7);
        float reflCurtain = 0.0;
        for (int layer = 0; layer < 3; layer++) {
            float fl = float(layer);
            reflCurtain += auroraCurtain(reflP, t + fl * 0.5, secEnergy, fl * 1.5);
        }
        // Wavy reflection
        float wave = sin(p.x * 10.0 + t * 1.0) * 0.5 + 0.5;
        vec3 reflCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.6, 1.0) * reflCurtain * wave * reflT * 0.15;
        color += reflCol * brightness;
    }

    // === Beat pulse — brightens entire aurora ===
    color *= (0.9 + BEAT_INTENSITY * 0.2);

    // === Kick flash ===
    color += vec3(0.8, 0.9, 1.0) * KICK_LEVEL * exp(-dist2D * 2.0) * 0.2 * brightness;

    // === Group behavior — phase drives curtain shimmer ===
    float groupShimmer = sin(p.x * 5.0 + GROUP_PHASE * 6.28 + t) * 0.5 + 0.5;
    color += u_color * groupShimmer * 0.02 * SECTION_CONF * brightness;

    // Fixture effects
    if (STROBE_ON > 0.5) {
        float strobe = step(0.5, fract(t * (8.0 + BAND_HIGH_MID * 10.0)));
        color += vec3(1.0) * strobe * 0.1 * brightness;
    }
    color += vec3(1.0) * BLINDER_INT * TRIGGER_FLASH * 0.3;
    if (TRIGGER_PYRO > 0.5) color += vec3(1.0, 0.5, 0.1) * exp(-dist2D * 3.0) * 0.4;

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.4;
    frag_color = vec4(color, 1.0);
}
