#version 460 core

// PLASMA FLUID — Volumetric plasma/fire simulation driven by audio.
// Uses domain-warped fbm with advection-like flow for fluid motion.
// Frequency bands drive different flow velocities and temperatures.
// Section drives base behavior (calm fire → explosive plasma → cooling).
// Beat creates pressure waves. Kick creates eruptions. Phrase drives flow direction.

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

// Domain-warped fbm for fluid-like motion
float fluidField(vec2 p, float t, float secEnergy) {
    // Flow velocity — different bands drive different flow speeds
    vec2 flow = vec2(
        BAND_BASS * 0.5 + BAND_LOW_MID * 0.3 + sin(t * 0.3) * 0.2,
        BAND_SUB * 0.8 + BAND_MID * 0.4 + cos(t * 0.2) * 0.3
    );
    // Phrase beat changes flow direction
    flow = rot(PHRASE_BEAT * PI / 8.0) * flow;
    // Stereo shifts flow
    flow.x += STEREO_BALANCE * 0.3;
    
    // Advect the coordinate — fluid simulation look
    vec2 advected = p - flow * t * 0.15;
    
    // Domain warp — multi-layer turbulence
    vec2 q = vec2(fbm(advected + t * 0.1), fbm(advected + vec2(5.2, 1.3) + t * 0.08));
    vec2 r = vec2(fbm(advected + q * 2.0 + vec2(1.7, 9.2) + t * 0.05),
                  fbm(advected + q * 2.0 + vec2(8.3, 2.8) + t * 0.06));
    
    float f = fbm(advected + r * (1.5 + secEnergy * 1.5));
    
    // Beat pressure wave — radial distortion
    float beatWave = sin(length(p) * 15.0 - t * 8.0) * BEAT_INTENSITY * 0.3;
    f += beatWave;
    
    // Kick eruption — vertical burst
    float kickErupt = exp(-abs(p.x) * 3.0) * exp(-max(p.y, 0.0) * 2.0) * KICK_LEVEL;
    f += kickErupt * 0.5;
    
    return f;
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;

    float t = u_time;
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;

    // Sample fluid field at multiple depths for volumetric look
    vec3 color = vec3(0.0);
    float transmittance = 1.0;
    
    for (int layer = 0; layer < 12; layer++) {
        float fl = float(layer);
        float depth = fl / 12.0;
        
        // Sample at different scales — volumetric depth
        vec2 sampleP = p * (1.0 - depth * 0.3);
        float field = fluidField(sampleP, t + depth * 0.5, secEnergy);
        
        // Density — higher field = more plasma
        float density = max(0.0, field) * (0.15 + secEnergy * 0.1);
        density *= 1.0 - depth * 0.5;  // front layers denser
        
        if (density > 0.001) {
            // Temperature — based on field value and depth
            float temp = clamp(field * 1.5 + (1.0 - depth) * 0.3, 0.0, 1.0);
            
            // Color mapping — black body radiation style
            // Cool: brain colors, Hot: white-blue
            vec3 coolCol = mix(u_color2, u_color, temp);
            vec3 hotCol = mix(vec3(1.0, 0.6, 0.2), vec3(1.0, 0.9, 0.7), temp);
            vec3 whiteHot = mix(vec3(0.8, 0.9, 1.0), vec3(1.0), temp);
            
            vec3 plasmaCol = mix(coolCol, hotCol, temp * 0.5);
            plasmaCol = mix(plasmaCol, whiteHot, pow(temp, 4.0) * 0.6);
            
            // Section hue tint
            plasmaCol = mix(plasmaCol, hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.5, 1.0), 0.2);
            
            float ext = density * 2.5;
            color += plasmaCol * ext * transmittance * 3.0 * brightness;
            transmittance *= exp(-ext);
            if (transmittance < 0.01) break;
        }
    }

    // Background — dark void
    color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.3, 0.01) * brightness * 0.5;

    // === Ember particles — rising sparks ===
    int numEmbers = 8 + int(secEnergy * 12.0);
    for (int ei = 0; ei < 20; ei++) {
        if (ei >= numEmbers) break;
        float fi = float(ei);
        // Ember rises with audio-driven speed
        float emberSpeed = 0.3 + BAND_AIR * 0.5 + secEnergy * 0.3;
        float emberX = fract(fi * 0.13 + sin(fi * 7.0) * 0.5 + t * 0.05) * 2.0 - 1.0;
        float emberY = fract(t * emberSpeed + fi * 0.17) * 2.0 - 1.0;
        emberX += sin(emberY * 3.0 + t + fi) * 0.1;  // drift
        
        float emberDist = length(p - vec2(emberX, emberY));
        float emberGlow = exp(-emberDist * emberDist * 200.0);
        float emberFlicker = sin(t * 10.0 + fi * 3.0) * 0.5 + 0.5;
        
        vec3 emberCol = mix(vec3(1.0, 0.5, 0.1), vec3(1.0, 0.9, 0.6), emberY * 0.5 + 0.5);
        color += emberCol * emberGlow * emberFlicker * 0.5 * brightness;
    }

    // === Beat pressure wave — visual ring ===
    float dist2D = length(p);
    for (int wi = 0; wi < 3; wi++) {
        float fw = float(wi);
        float wR = fract(t * 0.2 - fw * 0.33 + PHRASE_BEAT * 0.0625) * 2.0;
        float wave = exp(-pow(dist2D - wR, 2.0) * 20.0) * BEAT_INTENSITY * exp(-fw * 0.5);
        color += u_color * wave * 0.4 * brightness;
    }

    // === Kick eruption — bright vertical column ===
    float eruption = exp(-abs(p.x) * 4.0) * exp(-max(-p.y, 0.0) * 2.0) * KICK_LEVEL;
    color += vec3(1.0, 0.8, 0.5) * eruption * 2.0 * brightness;

    // === Fixture effects ===
    if (STROBE_ON > 0.5) {
        float strobe = step(0.5, fract(t * (8.0 + BAND_HIGH_MID * 10.0)));
        color += vec3(1.0) * strobe * 0.15 * brightness;
    }
    color += vec3(1.0) * BLINDER_INT * TRIGGER_FLASH * 0.4;
    if (TRIGGER_PYRO > 0.5) {
        color += vec3(1.0, 0.4, 0.05) * exp(-dist2D * 3.0) * 0.8;
    }
    if (TRIGGER_SMOKE > 0.5) {
        color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.2, 0.3) * fbm(p * 2.0 + t * 0.1) * 0.15;
    }

    // Group behavior — phase drives rotational flow
    float groupRot = GROUP_PHASE * 6.28;
    vec2 rotP = rot(groupRot) * p;
    float groupFlow = sin(rotP.y * 3.0) * 0.5 + 0.5;
    color += u_color * groupFlow * 0.05 * SECTION_CONF * brightness;

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.4;
    frag_color = vec4(color, 1.0);
}
