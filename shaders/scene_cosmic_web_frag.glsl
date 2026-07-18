#version 460 core

// COSMIC WEB — 3D network of nodes and filaments, fully brain-driven.
// Section changes: Intro=few nodes appearing, Verse=stable network,
// BuildUp=nodes multiply and accelerate, Drop=dense explosive network,
// Breakdown=nodes drift apart, Outro=network dissolves.
// Each node maps to a frequency band. Phrase beat drives filament pulses.
// Fixtures drive laser filaments. Stereo drives spatial asymmetry.

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

// Node count scales with section
int getNodeCount() {
    if (SECTION < 1.5) return 8;    // Intro
    if (SECTION < 2.5) return 16;   // Verse
    if (SECTION < 5.5) return 24;   // PreChorus/Chorus/BuildUp
    if (SECTION < 6.5) return 32;   // Drop
    if (SECTION < 7.5) return 20;   // Breakdown
    if (SECTION < 9.5) return 12;   // Bridge/Interlude
    return 6;                        // Outro
}

vec3 nodePosition(int i, float t, float secEnergy) {
    float fi = float(i);
    vec3 seed = hash33(vec3(fi, fi * 1.3, fi * 0.7));
    float orbitR = 0.3 + seed.x * 1.2;
    float orbitSpeed = 0.1 + seed.y * 0.3 + secEnergy * 0.3;
    float orbitPhase = seed.z * PI * 2.0;
    float angle = t * orbitSpeed + orbitPhase;

    vec3 center = (seed - 0.5) * 2.5;
    center.y += sin(t * 0.2 + fi) * 0.15;
    // Stereo shifts nodes laterally
    center.x += STEREO_BALANCE * 0.3;

    vec3 offset = vec3(cos(angle) * orbitR, sin(t * 0.3 + fi) * 0.1, sin(angle) * orbitR);
    return center + offset;
}

float nodeBrightness(int i, float t) {
    float fi = float(i);
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

    // Beat pulse with per-node phase
    float pulsePhase = fract(t * (BPM / 120.0) * 0.5 + fi * 0.1);
    float pulse = exp(-pow(pulsePhase - 0.5, 2.0) * 15.0) * BEAT_INTENSITY;
    // Phrase beat adds emphasis on phrase boundaries
    float phraseEmphasis = (PHRASE_BEAT == 0 || PHRASE_BEAT == 8) ? 0.3 : 0.0;

    return bandLevel * 2.0 + pulse + phraseEmphasis;
}

vec3 nodeColor(int i) {
    int bandIdx = int(mod(float(i), 8.0));
    float hueOff = float(bandIdx) / 8.0 * SECTION_HUE_RNG;
    return hsv2rgb(BASE_HUE + SECTION_HUE_CTR + hueOff, 0.7, 1.0);
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;

    float t = u_time * (0.1 + MOVEMENT_INT * 0.6);
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;
    int nodeCount = getNodeCount();

    // Camera
    vec3 ro = vec3(0.0, 0.0, -2.0);
    vec3 rd = normalize(vec3(p, 1.5));
    ro.xz = rot(t * 0.04 + STEREO_BALANCE * 0.2) * ro.xz;
    rd.xz = rot(t * 0.04 + STEREO_BALANCE * 0.2) * rd.xz;

    vec3 color = vec3(0.0);

    // Deep space background
    float bgNeb = hash21(floor(p * 6.0)) * 0.02;
    color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.4, 0.04) * bgNeb * brightness * (0.5 + secEnergy);

    // Stars
    float star = hash21(floor(p * 35.0));
    if (star > 0.995) {
        float tw = sin(u_time * 2.0 + star * 100.0) * 0.5 + 0.5;
        tw *= (0.7 + BEAT_DETECTED * 0.3);
        color += vec3(0.7, 0.8, 1.0) * (star - 0.995) * 200.0 * tw * brightness * 0.25;
    }

    // Project nodes
    vec3 nodeScreen[32];
    float nodeDepth[32];
    float nodeBright[32];

    for (int i = 0; i < 32; i++) {
        if (i >= nodeCount) break;
        vec3 pos3D = nodePosition(i, t, secEnergy);
        float z = pos3D.z + 2.0;
        if (z < 0.1) z = 0.1;
        vec2 screenPos = pos3D.xy / z * 1.5;
        nodeScreen[i] = vec3(screenPos, z);
        nodeDepth[i] = z;
        nodeBright[i] = nodeBrightness(i, t);
    }

    // Draw nodes
    for (int i = 0; i < 32; i++) {
        if (i >= nodeCount) break;
        vec3 ns = nodeScreen[i];
        float z = ns.z;
        float depthFade = 1.0 / (z * z);
        float nodeDist = length(p - ns.xy);
        float glow = exp(-nodeDist * nodeDist * 40.0 * depthFade) * nodeBright[i] * brightness;
        float core = exp(-nodeDist * nodeDist * 200.0 * depthFade) * nodeBright[i] * brightness;
        vec3 nCol = nodeColor(i);
        color += nCol * glow * 1.5 * depthFade;
        color += vec3(1.0) * core * 2.0 * depthFade;
    }

    // Draw filaments — connection threshold scales with section
    float connectThreshold = 0.4 + secEnergy * 0.3;
    for (int i = 0; i < 32; i++) {
        if (i >= nodeCount) break;
        for (int j = i + 1; j < 32; j++) {
            if (j >= nodeCount) break;
            vec3 ni = nodeScreen[i];
            vec3 nj = nodeScreen[j];
            float directDist = length(ni.xy - nj.xy);
            if (directDist > connectThreshold) continue;

            vec2 ab = nj.xy - ni.xy;
            vec2 ap = p - ni.xy;
            float t_proj = clamp(dot(ap, ab) / max(dot(ab, ab), 0.001), 0.0, 1.0);
            vec2 closest = ni.xy + ab * t_proj;
            float lineDist = length(p - closest);

            float lineZ = mix(ni.z, nj.z, t_proj);
            float depthFade = 1.0 / (lineZ * lineZ);

            float filament = exp(-lineDist * lineDist * 300.0 * depthFade);
            filament *= exp(-directDist * 2.0);

            // Energy flow — phrase beat modulates flow speed
            float flowSpeed = 3.0 + PHRASE_BEAT * 0.2;
            float flow = sin(t * flowSpeed + float(i) * 0.5 + float(j) * 0.7 + t_proj * 6.28) * 0.5 + 0.5;
            float avgBright = (nodeBright[i] + nodeBright[j]) * 0.5;
            filament *= avgBright * (0.3 + flow * 0.7) * brightness * (0.5 + LASER_INT * 1.5);

            vec3 fCol = mix(nodeColor(i), nodeColor(j), t_proj);
            color += fCol * filament * 0.6 * depthFade;
        }
    }

    // Kick shockwave
    float dist2D = length(p);
    for (int swi = 0; swi < 2; swi++) {
        float fsw = float(swi);
        float swR = fract(t * 0.25 - fsw * 0.5) * 2.5;
        color += u_color * exp(-pow(dist2D - swR, 2.0) * 50.0) * KICK_LEVEL * exp(-fsw * 0.5) * brightness;
    }

    // Stereo asymmetry
    color.r *= 1.0 + STEREO_BALANCE * 0.15;
    color.b *= 1.0 - STEREO_BALANCE * 0.15;

    // Group behavior — phase drives shimmer
    float shimmer = sin(p.x * 10.0 + GROUP_PHASE * 6.28 + t) * 0.5 + 0.5;
    color += u_color * shimmer * 0.03 * SECTION_CONF * brightness;

    // Fixture effects
    if (STROBE_ON > 0.5) {
        float strobe = step(0.5, fract(t * (8.0 + BAND_HIGH_MID * 10.0)));
        color += vec3(1.0) * strobe * 0.15 * brightness;
    }
    color += vec3(1.0) * BLINDER_INT * TRIGGER_FLASH * 0.3;
    if (TRIGGER_PYRO > 0.5) color += vec3(1.0, 0.5, 0.1) * exp(-dist2D * 3.0) * 0.5;
    if (TRIGGER_SMOKE > 0.5) {
        color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.2, 0.3) * hash21(floor(p * 4.0)) * 0.08;
    }

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.4;
    frag_color = vec4(color, 1.0);
}
