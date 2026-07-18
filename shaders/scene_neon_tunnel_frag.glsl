#version 460 core

// NEON TUNNEL — Infinite zoom tunnel with audio-reactive speed and color.
// Concentric rings recede into distance, each ring pulses with audio.
// Multiple tunnel layers at different speeds for parallax depth.
// Beat creates ring flash. Kick creates speed burst. Section drives color palette.
// Phrase drives ring rotation. Stereo drives tunnel curve.

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

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;

    float t = u_time;
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;

    // Tunnel coordinates — polar
    float dist = length(p);
    float angle = atan(p.y, p.x);

    // Zoom speed — bass + kick drive forward motion
    float zoomSpeed = 0.3 + BAND_BASS * 1.5 + KICK_LEVEL * 3.0 + secEnergy * 0.5;
    float zoom = t * zoomSpeed;
    
    // Stereo curves the tunnel
    vec2 curvedP = p;
    curvedP.x += sin(dist * 3.0 + t * 0.2) * STEREO_BALANCE * 0.1;
    float curvedDist = length(curvedP);
    float curvedAngle = atan(curvedP.y, curvedP.x);

    vec3 color = vec3(0.0);

    // === 3 tunnel layers ===
    for (int layer = 0; layer < 3; layer++) {
        float fl = float(layer);
        float layerSpeed = 1.0 + fl * 0.5;
        float layerScale = 1.0 + fl * 0.3;
        float layerBright = (1.0 - fl * 0.25) * brightness;
        
        // Depth coordinate — logarithmic for constant speed perception
        float depth = fract(curvedDist * layerScale - zoom * layerSpeed);
        // Ring position
        float ringPos = 1.0 - depth;  // 0 = far, 1 = near
        float ringFade = smoothstep(0.0, 0.05, depth) * smoothstep(1.0, 0.95, depth);
        
        // Ring number — for color variation
        float ringNum = floor(curvedDist * layerScale - zoom * layerSpeed);
        
        // Ring shape — angular modulation
        float phraseRot = PHRASE_BEAT * PI / 8.0 + fl * 0.5;
        float angularMod = sin(curvedAngle * (4.0 + fl * 2.0) + phraseRot + t * (0.5 + fl));
        angularMod = pow(0.5 + 0.5 * angularMod, 2.0);
        
        // Ring intensity — audio driven
        int bandIdx = int(mod(ringNum + fl * 10.0, 8.0));
        float bandLevel = 0.0;
        if (bandIdx == 0) bandLevel = BAND_SUB;
        else if (bandIdx == 1) bandLevel = BAND_BASS;
        else if (bandIdx == 2) bandLevel = BAND_LOW_MID;
        else if (bandIdx == 3) bandLevel = BAND_MID;
        else if (bandIdx == 4) bandLevel = BAND_HIGH_MID;
        else if (bandIdx == 5) bandLevel = BAND_PRESENCE;
        else if (bandIdx == 6) bandLevel = BAND_BRILLIANCE;
        else bandLevel = BAND_AIR;
        
        float ringIntensity = bandLevel * 2.0 + 0.2;
        ringIntensity *= (0.5 + BEAT_INTENSITY * 0.5);
        ringIntensity *= angularMod;
        
        // Ring thickness — thinner in Drop
        float ringThickness = 0.02 + (SECTION > 6.5 && SECTION < 7.5 ? 0.0 : 0.01);
        float ringGlow = exp(-pow(depth - 0.5, 2.0) / (ringThickness * ringThickness)) * ringFade;
        
        // Ring color
        float hueShift = BASE_HUE + SECTION_HUE_CTR + ringNum * 0.02 + fl * 0.05;
        vec3 ringCol = hsv2rgb(hueShift, 0.8, 1.0);
        // Mix with brain colors
        ringCol = mix(ringCol, mix(u_color, u_color2, fract(ringNum * 0.1)), 0.3);
        // Hot center on beat
        ringCol = mix(ringCol, vec3(1.0), BEAT_INTENSITY * 0.3);
        
        color += ringCol * ringGlow * ringIntensity * layerBright * 2.0;
        
        // Ring edges — bright lines
        float edge = exp(-pow(depth - 0.5, 2.0) * 500.0) * ringFade;
        color += ringCol * edge * ringIntensity * layerBright * 1.5;
    }

    // === Center glow — the vanishing point ===
    float centerGlow = exp(-dist * dist * 15.0) * (0.3 + BAND_SUB * 0.7 + secEnergy * 0.3);
    centerGlow *= (0.5 + BEAT_INTENSITY * 0.5);
    vec3 centerCol = mix(u_color, vec3(1.0), 0.3);
    color += centerCol * centerGlow * brightness * 2.0;

    // === Speed lines — radial streaks ===
    float streakAngle = floor(curvedAngle * 60.0) / 60.0;
    float streak = hash21(vec2(streakAngle, floor(zoom)));
    if (streak > 0.7) {
        float streakInt = (streak - 0.7) * 3.0 * (0.3 + BAND_HIGH_MID * 0.5 + secEnergy * 0.3);
        streakInt *= exp(-dist * 2.0);
        color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR + streakAngle * 0.1, 0.7, 1.0) * streakInt * brightness * 0.5;
    }

    // === Beat flash — entire tunnel brightens ===
    color *= (0.8 + BEAT_INTENSITY * 0.3);

    // === Kick speed burst — white flash ===
    color += vec3(1.0, 0.95, 0.9) * KICK_LEVEL * exp(-dist * 3.0) * 0.4 * brightness;

    // === Group behavior — phase drives rotation ===
    float groupRot = GROUP_PHASE * 6.28;
    float groupPattern = sin(curvedAngle * 8.0 + groupRot + t) * 0.5 + 0.5;
    color += u_color * groupPattern * 0.03 * SECTION_CONF * brightness;

    // === Fixture effects ===
    if (STROBE_ON > 0.5) {
        float strobe = step(0.5, fract(t * (8.0 + BAND_HIGH_MID * 10.0)));
        color += vec3(1.0) * strobe * 0.15 * brightness;
    }
    color += vec3(1.0) * BLINDER_INT * TRIGGER_FLASH * 0.5;
    if (TRIGGER_PYRO > 0.5) color += vec3(1.0, 0.5, 0.1) * exp(-dist * 3.0) * 0.5;
    if (TRIGGER_SMOKE > 0.5) {
        color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.2, 0.3) * fbm(p * 2.0 + t * 0.1) * 0.1;
    }

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.3;
    frag_color = vec4(color, 1.0);
}
