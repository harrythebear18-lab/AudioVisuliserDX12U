#version 460 core

// REACTOR — Raymarched SDF fusion reactor, fully brain-driven.
// Section changes: Intro=cold start, Verse=stable operation, BuildUp=charging,
// Drop=critical output, Breakdown=cooling, Outro=shutdown.
// Phrase beat drives energy conduit pulses. Fixtures drive real lighting.
// Group behavior drives rotation patterns. Stereo drives camera sway.

in vec2 v_uv;
out vec4 frag_color;

uniform float u_time;
uniform vec2 u_resolution;
uniform sampler2D u_spectrum;
uniform vec3 u_color;
uniform vec3 u_color2;

#define PI 3.14159265359
#define MAX_STEPS 80
#define MAX_DIST 20.0
#define SURF_DIST 0.001

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
float sdSphere(vec3 p, float r) { return length(p) - r; }
float sdTorus(vec3 p, vec2 t) {
    vec2 q = vec2(length(p.xz) - t.x, p.y);
    return length(q) - t.y;
}
float sdBox(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
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

float map(vec3 p, float t, float coreR, float pulse, float secEnergy) {
    // Toroidal plasma core — size varies by section
    float torus = sdTorus(p, vec2(coreR, coreR * 0.22 + pulse * 0.04));
    float innerSph = sdSphere(p, coreR * 0.35 + pulse * 0.06);
    float core = min(torus, innerSph);

    // Cooling fins — 6 radial, rotating with group phase
    float fins = 1e9;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float angle = fi * PI / 3.0 + t * 0.1 + GROUP_PHASE * 6.28;
        vec3 fp = p;
        fp.xz = rot(angle) * fp.xz;
        float fin = sdBox(vec3(fp.x - coreR * 2.2, fp.y, fp.z), vec3(coreR * 1.8, 0.008, coreR * 0.5));
        fins = min(fins, fin);
    }

    // Outer containment ring
    float ring = sdTorus(p.xzy, vec2(coreR * 3.5, 0.025)) - 0.02;

    // Energy conduits — pulse with phrase beat
    float conduitPulse = sin(PHRASE_BEAT * PI / 8.0) * 0.5 + 0.5;
    float conduits = 1e9;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float a = fi * PI * 0.5 + PI * 0.25;
        vec3 cp = p;
        cp.xz = rot(a) * cp.xz;
        float pipeR = 0.035 + conduitPulse * 0.01;
        float pipe = sdBox(vec3(cp.x - coreR * 4.0, cp.y, cp.z), vec3(pipeR, 3.0, pipeR));
        conduits = min(conduits, pipe);
    }

    return min(min(core, fins), min(ring, conduits));
}

vec3 calcNormal(vec3 p, float t, float coreR, float pulse, float secEnergy) {
    vec2 e = vec2(0.001, 0.0);
    return normalize(vec3(
        map(p + e.xyy, t, coreR, pulse, secEnergy) - map(p - e.xyy, t, coreR, pulse, secEnergy),
        map(p + e.yxy, t, coreR, pulse, secEnergy) - map(p - e.yxy, t, coreR, pulse, secEnergy),
        map(p + e.yyx, t, coreR, pulse, secEnergy) - map(p - e.yyx, t, coreR, pulse, secEnergy)
    ));
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;

    float t = u_time * (0.15 + MOVEMENT_INT * 0.8);
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;
    float coreR = 0.25 + BAND_SUB * 0.12 + BAND_BASS * 0.08 + secEnergy * 0.1;
    float pulse = BEAT_INTENSITY + KICK_LEVEL * 0.5 + (SECTION > 5.5 && SECTION < 6.5 ? 0.3 : 0.0);

    // Camera with stereo sway
    vec3 ro = vec3(STEREO_BALANCE * 0.3, 1.0, -3.5);
    vec3 rd = normalize(vec3(p, 1.5));
    ro.xz = rot(t * 0.12) * ro.xz;
    rd.xz = rot(t * 0.12) * rd.xz;

    // Raymarch
    float d = 0.0;
    float glow = 0.0;
    for (int i = 0; i < MAX_STEPS; i++) {
        vec3 pos = ro + rd * d;
        float sdf = map(pos, t, coreR, pulse, secEnergy);
        if (sdf < SURF_DIST) break;
        if (d > MAX_DIST) break;
        glow += exp(-sdf * 4.0) * 0.015;
        d += sdf;
    }

    vec3 color = vec3(0.0);

    // Background — section-tinted
    color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.3, 0.02) * brightness;

    if (d < MAX_DIST) {
        vec3 pos = ro + rd * d;
        vec3 normal = calcNormal(pos, t, coreR, pulse, secEnergy);

        // Heat — distance from core, amplified by section
        float distFromCore = length(pos.xz);
        float heat = 1.0 - smoothstep(coreR * 0.4, coreR * 4.5, distFromCore);
        heat *= brightness * (0.5 + secEnergy * 0.5);

        // Section-colored surfaces
        vec3 surfCol = mix(u_color2, u_color, heat);
        surfCol = mix(surfCol, vec3(1.0, 0.95, 0.8), pow(heat, 3.0));
        surfCol = mix(surfCol, vec3(1.0, 0.4, 0.1), pow(heat, 2.0) * 0.4);

        // Lighting
        vec3 keyDir = normalize(vec3(0.5, 1.0, 0.3));
        float key = max(dot(normal, keyDir), 0.0);
        float fill = max(dot(normal, normalize(-pos)), 0.0);
        vec3 lit = surfCol * (key * 0.6 + fill * 0.8 + 0.15) * brightness;

        // Emissive — hotter in Drop
        lit += surfCol * heat * heat * (1.0 + BEAT_INTENSITY * 2.0 + secEnergy * 1.5);

        // Fresnel rim — laser driven
        float fresnel = pow(1.0 - max(dot(normal, -rd), 0.0), 4.0);
        lit += u_color * fresnel * (0.3 + LASER_INT * 1.0) * brightness;

        // Specular
        vec3 halfV = normalize(keyDir - rd);
        float spec = pow(max(dot(normal, halfV), 0.0), 32.0);
        lit += vec3(1.0) * spec * (0.3 + LASER_INT * 1.5) * brightness;

        color = lit;
    }

    // Volumetric glow — section-colored plasma
    vec3 glowCol = mix(u_color, vec3(1.0, 0.6, 0.3), BAND_BASS * 0.5);
    color += glowCol * glow * (0.5 + BAND_LOW_MID * 1.0 + BEAT_INTENSITY * 2.0 + secEnergy) * brightness;

    // Plasma leak
    float plasmaNoise = noise(p * 5.0 + t * 2.0);
    color += hsv2rgb(BASE_HUE + 0.05, 0.8, 1.0) * plasmaNoise * BAND_MID * 0.3 * brightness;

    // Laser beams when brain says lasers on
    if (LASERS_ON > 0.5) {
        for (int bi = 0; bi < 4; bi++) {
            float fb = float(bi);
            float beamAngle = t * 0.5 + fb * PI * 0.5;
            float beamProj = p.x * cos(beamAngle) + p.y * sin(beamAngle);
            float beamGlow = exp(-beamProj * beamProj * 200.0) * LASER_INT;
            beamGlow *= (0.5 + sin(t * 5.0 + fb) * 0.5);
            vec3 beamCol = mix(u_color, u_color2, fb / 4.0);
            color += beamCol * beamGlow * 2.0;
        }
    }

    // Kick shockwave
    float dist2D = length(p);
    for (int swi = 0; swi < 2; swi++) {
        float fsw = float(swi);
        float swR = fract(t * 0.3 - fsw * 0.5) * 2.0;
        color += u_color * exp(-pow(dist2D - swR, 2.0) * 40.0) * KICK_LEVEL * exp(-fsw * 0.5) * brightness;
    }

    // Strobe
    if (STROBE_ON > 0.5) {
        float strobe = step(0.5, fract(t * (8.0 + BAND_HIGH_MID * 10.0)));
        color += vec3(1.0) * strobe * 0.15 * brightness;
    }
    // Blinder
    color += vec3(1.0) * BLINDER_INT * TRIGGER_FLASH * 0.4;
    // Pyro
    if (TRIGGER_PYRO > 0.5) color += vec3(1.0, 0.5, 0.1) * exp(-dist2D * 3.0) * 0.5;
    // Smoke
    if (TRIGGER_SMOKE > 0.5) {
        color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.2, 0.3) * fbm(p * 2.0 + t * 0.1) * 0.1;
    }

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.4;
    frag_color = vec4(color, 1.0);
}
