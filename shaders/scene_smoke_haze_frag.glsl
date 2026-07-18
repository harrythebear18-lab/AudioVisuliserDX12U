#version 460 core

// SMOKE HAZE — Volumetric cloud/smoke dynamics driven by audio.
// Multi-octave domain-warped fbm for realistic turbulent smoke.
// Audio energy drives turbulence intensity and updraft velocity.
// Section drives smoke color and density. Beat creates pressure pulses.
// Kick creates mushroom-cloud bursts. Stereo drives lateral drift.
// Phrase beat drives slow rotation of the smoke field.

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
    for (int i = 0; i < 6; i++) { v += a * noise(p); p *= 2.17; a *= 0.5; }
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

// Turbulent smoke field — domain warped fbm with audio-driven turbulence
float smokeField(vec2 p, float t, float secEnergy) {
    // Updraft velocity — bass + sub drive upward flow
    float updraft = BAND_SUB * 0.8 + BAND_BASS * 0.5 + secEnergy * 0.3;
    // Lateral drift — stereo + movement
    float drift = STEREO_BALANCE * 0.4 + MOVEMENT_INT * 0.2;
    // Phrase rotation
    float phraseRot = PHRASE_BEAT * PI / 16.0;
    
    // Advect coordinates — smoke rises and drifts
    vec2 advected = p;
    advected.y -= t * updraft * 0.3;  // rise
    advected.x += t * drift * 0.2;     // drift
    advected = rot(phraseRot * 0.3) * advected;  // slow rotation
    
    // Multi-layer domain warp for turbulence
    float turbulence = BAND_MID * 0.5 + BAND_HIGH_MID * 0.3 + secEnergy * 0.4;
    
    vec2 q = vec2(
        fbm(advected * 2.0 + t * 0.15),
        fbm(advected * 2.0 + vec2(3.4, 1.1) + t * 0.12)
    );
    
    vec2 r = vec2(
        fbm(advected * 3.0 + q * (2.0 + turbulence) + vec2(1.7, 9.2) + t * 0.08),
        fbm(advected * 3.0 + q * (2.0 + turbulence) + vec2(8.3, 2.8) + t * 0.1)
    );
    
    float f = fbm(advected * 1.5 + r * (1.5 + turbulence * 0.5));
    
    // Beat pressure pulse — compresses smoke
    float beatPulse = sin(length(p) * 8.0 - t * 5.0) * BEAT_INTENSITY * 0.2;
    f += beatPulse;
    
    // Kick mushroom cloud — rising burst from bottom
    float kickY = p.y + 0.5;
    float kickDist = length(vec2(p.x, kickY * 1.5));
    float mushroom = exp(-kickDist * kickDist * 3.0) * KICK_LEVEL;
    mushroom *= smoothstep(-0.5, 0.0, p.y);  // only from bottom
    f += mushroom * 0.6;
    
    return f;
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;
    float dist2D = length(p);

    float t = u_time;
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;

    // Volumetric raymarch through smoke
    vec3 color = vec3(0.0);
    float transmittance = 1.0;
    
    for (int layer = 0; layer < 16; layer++) {
        float fl = float(layer);
        float depth = fl / 16.0;
        
        // Sample at different depths — parallax for 3D smoke
        vec2 sampleP = p * (1.0 - depth * 0.2) + vec2(depth * 0.1, 0.0);
        float field = smokeField(sampleP, t + depth * 0.3, secEnergy);
        
        // Density — smoke fills more in higher sections
        float density = max(0.0, field - 0.1) * (0.2 + secEnergy * 0.15);
        density *= 1.0 - depth * 0.3;  // front layers denser
        
        // Vertical density gradient — smoke rises
        density *= smoothstep(-1.0, 0.5, p.y) * smoothstep(1.2, 0.8, p.y);
        
        if (density > 0.001) {
            // Smoke color — section-tinted with lighting
            // Backlit by brain colors, front is darker
            float backlit = 1.0 - depth;  // front = dark, back = lit
            vec3 smokeCol = mix(
                hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.1, 0.05),  // dark front
                hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.4, 0.6),    // lit back
                backlit
            );
            
            // Hot spots — where field is high, add glow
            float hot = smoothstep(0.5, 0.8, field);
            smokeCol = mix(smokeCol, mix(u_color, vec3(1.0, 0.8, 0.5), hot), hot * 0.4);
            
            // Beat illumination — flash lights up smoke
            smokeCol += u_color * BEAT_INTENSITY * 0.3 * backlit;
            
            float ext = density * 1.5;
            color += smokeCol * ext * transmittance * 2.0 * brightness;
            transmittance *= exp(-ext);
            if (transmittance < 0.01) break;
        }
    }

    // Background — dark with subtle gradient
    color += mix(hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.3, 0.01),
                 hsv2rgb(BASE_HUE + SECTION_HUE_CTR + 0.05, 0.4, 0.03), uv.y) * brightness * 0.3;

    // === Light shafts through smoke — when fixtures are on ===
    if (MOVING_ON > 0.5 || LASERS_ON > 0.5) {
        for (int si = 0; si < 4; si++) {
            float fi = float(si);
            // Shaft angle — scanning
            float shaftAngle = t * (0.2 + fi * 0.05) + fi * PI * 0.5 + GROUP_PHASE * 6.28;
            vec2 shaftDir = vec2(cos(shaftAngle), sin(shaftAngle) * 0.5 + 0.5);
            float shaftProj = dot(p, shaftDir);
            float shaftPerp = abs(p.x * shaftDir.y - p.y * shaftDir.x);
            
            // Shaft width
            float shaftWidth = 0.03 + BAND_MID * 0.02;
            float shaftGlow = exp(-shaftPerp * shaftPerp / (shaftWidth * shaftWidth));
            shaftGlow *= exp(-shaftProj * 0.3);  // fade with distance
            shaftGlow *= (MOVING_LIGHT_INT + LASER_INT) * brightness * 0.5;
            
            // Color per shaft
            vec3 shaftCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + fi * 0.08, 0.7, 1.0);
            // Volumetric scattering — smoke makes shaft visible
            shaftGlow *= (0.3 + fbm(p * 2.0 + t * 0.1) * 0.7);  // only visible through smoke
            color += shaftCol * shaftGlow * 0.8;
        }
    }

    // === Ember sparks in smoke ===
    int numSparks = 4 + int(secEnergy * 8.0);
    for (int si = 0; si < 12; si++) {
        if (si >= numSparks) break;
        float fi = float(si);
        float sparkX = fract(fi * 0.23 + sin(fi * 5.0) * 0.5) * 2.0 - 1.0;
        float sparkY = fract(t * (0.2 + BAND_AIR * 0.3) + fi * 0.13) * 2.0 - 1.0;
        sparkX += sin(sparkY * 2.0 + t + fi * 3.0) * 0.08;
        
        float sparkDist = length(p - vec2(sparkX, sparkY));
        float sparkGlow = exp(-sparkDist * sparkDist * 300.0);
        float sparkFlicker = sin(t * 15.0 + fi * 4.0) * 0.5 + 0.5;
        
        vec3 sparkCol = mix(vec3(1.0, 0.4, 0.1), vec3(1.0, 0.8, 0.5), sparkY * 0.5 + 0.5);
        color += sparkCol * sparkGlow * sparkFlicker * 0.3 * brightness;
    }

    // === Beat pressure wave ===
    for (int wi = 0; wi < 2; wi++) {
        float fw = float(wi);
        float wR = fract(t * 0.15 - fw * 0.5 + PHRASE_BEAT * 0.0625) * 2.0;
        color += u_color * exp(-pow(dist2D - wR, 2.0) * 25.0) * BEAT_INTENSITY * exp(-fw * 0.5) * brightness * 0.5;
    }

    // === Fixture effects ===
    if (STROBE_ON > 0.5) {
        float strobe = step(0.5, fract(t * (8.0 + BAND_HIGH_MID * 10.0)));
        // Strobe illuminates smoke
        color += vec3(1.0) * strobe * 0.2 * brightness * fbm(p * 2.0 + t * 0.1);
    }
    color += vec3(1.0) * BLINDER_INT * TRIGGER_FLASH * 0.5;
    if (TRIGGER_PYRO > 0.5) {
        // Pyro creates smoke burst
        color += vec3(1.0, 0.4, 0.05) * exp(-dist2D * 3.0) * 0.8;
        // Extra smoke from pyro
        color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.2, 0.4) * fbm(p * 3.0 + t * 0.2) * 0.1;
    }
    if (TRIGGER_SMOKE > 0.5) {
        // Heavy smoke trigger — boost density
        color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.15, 0.2) * fbm(p * 1.5 + t * 0.08) * 0.2 * brightness;
    }

    // Group behavior — phase drives smoke rotation
    float groupRot = GROUP_PHASE * 6.28;
    vec2 rotP = rot(groupRot) * p;
    float groupSwirl = sin(rotP.x * 2.0 + rotP.y * 2.0) * 0.5 + 0.5;
    color += u_color * groupSwirl * 0.03 * SECTION_CONF * brightness;

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.4;
    frag_color = vec4(color, 1.0);
}
