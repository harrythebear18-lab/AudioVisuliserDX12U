#version 460 core

// QUANTUM FIELD — Volumetric wave function, fully brain-driven.
// Section changes: Intro=calm field, Verse=stable interference,
// BuildUp=increasing frequency/amplitude, Drop=explosive wave collapse,
// Breakdown=dissipating waves, Outro=field fades to vacuum.
// 8 frequency bands drive 8 directional waves. Phrase beat drives wavefronts.
// Beat count accumulates energy. Fixtures drive excitations and strobing.

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
    for (int i = 0; i < 5; i++) { v += a * noise(p); p *= 2.13; a *= 0.5; }
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

// 3D wave function — 8 directional waves, one per band
float waveFunction(vec3 p, float t, float secEnergy) {
    float w = 0.0;
    float amp = 0.5 + secEnergy * 0.5;
    w += sin(dot(p, normalize(vec3(1.0, 0.3, 0.5))) * 3.0 + t) * BAND_SUB * 0.5 * amp;
    w += sin(dot(p, normalize(vec3(-0.5, 1.0, 0.3))) * 4.0 - t * 1.3) * BAND_BASS * 0.5 * amp;
    w += sin(dot(p, normalize(vec3(0.7, -0.5, 1.0))) * 5.0 + t * 1.5) * BAND_LOW_MID * 0.4 * amp;
    w += sin(dot(p, normalize(vec3(-1.0, 0.2, -0.6))) * 6.0 - t * 2.0) * BAND_MID * 0.35 * amp;
    w += sin(dot(p, normalize(vec3(0.3, 1.0, -0.4))) * 8.0 + t * 2.5) * BAND_HIGH_MID * 0.3 * amp;
    w += sin(dot(p, normalize(vec3(-0.8, -0.6, 0.8))) * 10.0 - t * 3.0) * BAND_PRESENCE * 0.25 * amp;
    w += sin(dot(p, normalize(vec3(0.9, 0.4, -0.2))) * 14.0 + t * 4.0) * BAND_BRILLIANCE * 0.2 * amp;
    w += sin(dot(p, normalize(vec3(-0.3, -0.9, 0.5))) * 18.0 - t * 5.0) * BAND_AIR * 0.15 * amp;
    return w;
}

float sphericalWave(vec3 p, vec3 center, float t, float freq) {
    float r = length(p - center);
    return sin(r * freq - t * 3.0) / (1.0 + r * r);
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;
    float dist2D = length(p);

    float t = u_time * (0.2 + MOVEMENT_INT * 1.2);
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;

    // Camera
    vec3 ro = vec3(0.0, 0.0, -1.5);
    vec3 rd = normalize(vec3(p, 1.5));
    ro.xy = rot(t * 0.02) * ro.xy;
    rd.xy = rot(t * 0.02) * rd.xy;

    // Volumetric raymarch
    vec3 color = vec3(0.0);
    float transmittance = 1.0;

    for (int i = 0; i < 48; i++) {
        float fi = float(i);
        float rayT = fi * 0.08;
        vec3 pos = ro + rd * rayT;

        float wave = waveFunction(pos, t, secEnergy);
        float prob = wave * wave;

        // Beat-driven spherical wave — phrase synced
        float beatPhase = fract(t * (BPM / 120.0) * 0.5 + PHRASE_BEAT * 0.0625);
        vec3 beatPos = vec3(sin(t) * 0.5, cos(t * 0.7) * 0.5, 0.0);
        prob += sphericalWave(pos, beatPos, t, 8.0) * BEAT_INTENSITY * 0.5 * (0.5 + secEnergy);

        // Quantum noise — more in BuildUp/Drop
        prob += fbm(pos.xy * 3.0 + t * 0.3) * 0.05 * (0.5 + BAND_MID * 0.5 + secEnergy * 0.3);

        // Beat count accumulates — energy builds over time
        float accumulated = float(BEAT_COUNT) * 0.001 * SECTION_CONF;
        prob += accumulated * exp(-rayT * 0.5);

        float density = prob * 0.3;
        float depthFade = exp(-rayT * 0.3);
        density *= depthFade;

        if (density > 0.001) {
            float temp = clamp(prob * 2.0, 0.0, 1.0);
            vec3 fieldCol = mix(u_color2, u_color, temp);
            fieldCol = mix(fieldCol, vec3(1.0), pow(temp, 3.0) * 0.6);
            fieldCol = mix(fieldCol, hsv2rgb(BASE_HUE + SECTION_HUE_CTR + prob * 0.2, 0.8, 1.0), 0.3);

            float extinction = density * 2.0;
            color += fieldCol * extinction * transmittance * 3.0 * brightness;
            transmittance *= exp(-extinction);
            if (transmittance < 0.01) break;
        }
    }

    // Particle excitations — laser driven, more in Drop
    int numParticles = 4 + int(secEnergy * 6.0);
    for (int i = 0; i < 10; i++) {
        if (i >= numParticles) break;
        float fi = float(i);
        float orbitR = 0.3 + fi * 0.1;
        float orbitSpeed = 0.5 + fi * 0.2 + secEnergy * 0.3;
        vec3 part3D = vec3(cos(t * orbitSpeed + fi * 0.8) * orbitR,
                          sin(t * orbitSpeed * 0.7 + fi * 1.2) * orbitR * 0.6,
                          sin(t * orbitSpeed * 0.5 + fi * 0.5) * 0.5);
        float z = part3D.z + 1.5;
        if (z < 0.1) z = 0.1;
        vec2 screenPos = part3D.xy / z * 1.5;
        float depthFade = 1.0 / (z * z);
        float partDist = length(p - screenPos);

        int bandIdx = int(mod(fi, 8.0));
        float bandLevel = 0.0;
        if (bandIdx == 0) bandLevel = BAND_SUB;
        else if (bandIdx == 1) bandLevel = BAND_BASS;
        else if (bandIdx == 2) bandLevel = BAND_LOW_MID;
        else if (bandIdx == 3) bandLevel = BAND_MID;
        else if (bandIdx == 4) bandLevel = BAND_HIGH_MID;
        else if (bandIdx == 5) bandLevel = BAND_PRESENCE;
        else if (bandIdx == 6) bandLevel = BAND_BRILLIANCE;
        else bandLevel = BAND_AIR;

        float partInt = (0.3 + LASER_INT * 2.0 + bandLevel * 1.5) * brightness * (0.5 + secEnergy);
        float partGlow = exp(-partDist * partDist * 80.0 * depthFade) * partInt;
        float partCore = exp(-partDist * partDist * 400.0 * depthFade) * partInt;

        vec3 partCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + fi * 0.05, 0.8, 1.0);
        color += partCol * partGlow * depthFade * 2.0;
        color += vec3(1.0) * partCore * depthFade * 3.0;
    }

    // Interference fringes
    float fringeWave = waveFunction(vec3(p, 0.0), t, secEnergy);
    float fringe = pow(sin(fringeWave * 8.0) * 0.5 + 0.5, 4.0) * 0.15;
    color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR + fringeWave * 0.1, 0.7, 1.0) * fringe * brightness;

    // Kick burst
    color += vec3(1.0, 0.85, 0.7) * exp(-dist2D * dist2D * 4.0) * KICK_LEVEL * 2.0 * brightness;

    // Expanding wavefronts — phrase synced
    for (int wi = 0; wi < 3; wi++) {
        float fw = float(wi);
        float wR = fract(t * 0.15 - fw * 0.33 + PHRASE_BEAT * 0.0625) * 2.5;
        color += u_color * exp(-pow(dist2D - wR, 2.0) * 30.0) * (BEAT_INTENSITY + KICK_LEVEL * 0.3) * exp(-fw * 0.5) * brightness;
    }

    // Group behavior — phase drives field rotation
    float groupRot = GROUP_PHASE * 6.28;
    vec2 rotP = rot(groupRot) * p;
    float groupPattern = sin(rotP.x * 5.0) * sin(rotP.y * 5.0) * 0.5 + 0.5;
    color += u_color * groupPattern * 0.03 * SECTION_CONF * brightness;

    // Fixture effects
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
