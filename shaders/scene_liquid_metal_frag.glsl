#version 460 core

// LIQUID METAL — Raymarched metaballs with PBR, fully brain-driven.
// Section changes: Intro=single calm blob, Verse=gentle merging,
// BuildUp=rapid deformation, Drop=explosive fragmentation,
// Breakdown=slow settling, Outro=flat pool.
// Phrase beat drives surface ripple pulses. Stereo drives lateral flow.
// Fixtures drive reflections and specular. Triggers produce surface disruptions.

in vec2 v_uv;
out vec4 frag_color;

uniform float u_time;
uniform vec2 u_resolution;
uniform sampler2D u_spectrum;
uniform vec3 u_color;
uniform vec3 u_color2;

#define PI 3.14159265359
#define MAX_STEPS 96
#define MAX_DIST 15.0
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
float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) { v += a * noise(p); p *= 2.17; a *= 0.5; }
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

// Metaball field — number and behavior of balls changes by section
float metaballs(vec3 p, float t, float secEnergy) {
    float field = 0.0;
    // Ball count and energy scales with section
    int numBalls = 3 + int(secEnergy * 5.0);
    
    for (int i = 0; i < 8; i++) {
        if (i >= numBalls) break;
        float fi = float(i);
        // Each ball orbits at different speed/phase
        float speed = 0.5 + fi * 0.15 + secEnergy * 0.5;
        float phase = fi * 0.8;
        float orbitR = 0.2 + fi * 0.08 + secEnergy * 0.1;
        
        vec3 ballPos = vec3(
            cos(t * speed + phase) * orbitR + STEREO_BALANCE * 0.15,
            sin(t * speed * 0.7 + phase * 1.3) * orbitR * 0.6,
            sin(t * speed * 0.5 + phase * 0.7) * 0.4
        );
        
        // Ball radius driven by frequency band
        float bandLevel = 0.0;
        int bandIdx = i % 8;
        if (bandIdx == 0) bandLevel = BAND_SUB;
        else if (bandIdx == 1) bandLevel = BAND_BASS;
        else if (bandIdx == 2) bandLevel = BAND_LOW_MID;
        else if (bandIdx == 3) bandLevel = BAND_MID;
        else if (bandIdx == 4) bandLevel = BAND_HIGH_MID;
        else if (bandIdx == 5) bandLevel = BAND_PRESENCE;
        else if (bandIdx == 6) bandLevel = BAND_BRILLIANCE;
        else bandLevel = BAND_AIR;
        
        float r = 0.08 + bandLevel * 0.12 + secEnergy * 0.03;
        // Phrase beat adds pulsing
        r += sin(PHRASE_BEAT * PI / 8.0 + fi) * 0.015;
        
        vec3 diff = p - ballPos;
        field += r * r / max(dot(diff, diff), 0.001);
    }
    
    return 1.0 - field;
}

float map(vec3 p, float t, float secEnergy) {
    return metaballs(p, t, secEnergy);
}

vec3 calcNormal(vec3 p, float t, float secEnergy) {
    vec2 e = vec2(0.001, 0.0);
    return normalize(vec3(
        map(p + e.xyy, t, secEnergy) - map(p - e.xyy, t, secEnergy),
        map(p + e.yxy, t, secEnergy) - map(p - e.yxy, t, secEnergy),
        map(p + e.yyx, t, secEnergy) - map(p - e.yyx, t, secEnergy)
    ));
}

vec3 envMap(vec3 dir, float t, float secEnergy) {
    float t2 = dir.y * 0.5 + 0.5;
    vec3 col = mix(u_color2, u_color, t2);
    col = mix(col, vec3(1.0), pow(t2, 4.0) * 0.4);
    // Section energy adds environment structure
    float bands = sin(dir.x * (8.0 + secEnergy * 8.0) + t) * 0.5 + 0.5;
    col *= 0.7 + bands * 0.3;
    // Group phase adds moving stripes
    float stripes = sin(dir.z * 15.0 + GROUP_PHASE * 6.28) * 0.5 + 0.5;
    col *= 0.85 + stripes * 0.15;
    return col;
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;

    float t = u_time * (0.2 + MOVEMENT_INT * 1.2);
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;

    // Camera
    vec3 ro = vec3(0.0, 0.3, -2.5);
    vec3 rd = normalize(vec3(p, 1.8));
    ro.xz = rot(t * 0.04) * ro.xz;
    rd.xz = rot(t * 0.04) * rd.xz;

    // Raymarch
    float d = 0.0;
    for (int i = 0; i < MAX_STEPS; i++) {
        vec3 pos = ro + rd * d;
        float sdf = map(pos, t, secEnergy);
        if (sdf < SURF_DIST) break;
        if (d > MAX_DIST) break;
        d += sdf * 0.8;
    }

    vec3 color = vec3(0.0);

    // Background
    float bgT = uv.y;
    color += mix(hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.3, 0.02),
                 hsv2rgb(BASE_HUE + SECTION_HUE_CTR + 0.1, 0.4, 0.05), bgT) * brightness;

    // Background stars
    float star = hash21(floor(p * 30.0));
    if (star > 0.997) color += vec3(0.6, 0.7, 0.9) * (star - 0.997) * 300.0 * brightness * 0.2;

    if (d < MAX_DIST) {
        vec3 pos = ro + rd * d;
        vec3 normal = calcNormal(pos, t, secEnergy);
        vec3 viewDir = -rd;

        // Fresnel
        float fresnel = pow(1.0 - max(dot(normal, viewDir), 0.0), 3.0);
        fresnel = mix(0.3, 0.95, fresnel);

        // Reflection — section-aware environment
        vec3 reflectDir = reflect(rd, normal);
        vec3 envCol = envMap(reflectDir, t, secEnergy) * brightness;

        // Specular — laser driven, more intense in Drop
        vec3 light1 = normalize(vec3(0.5, 0.8, 0.3));
        vec3 light2 = normalize(vec3(-0.3, 0.5, 0.7));
        float spec1 = pow(max(dot(reflectDir, light1), 0.0), 64.0);
        float spec2 = pow(max(dot(reflectDir, light2), 0.0), 128.0);
        float spec = (spec1 * 0.6 + spec2 * 0.4) * (0.5 + LASER_INT * 2.0 + secEnergy) * brightness;

        // Metal color
        vec3 metalCol = mix(vec3(0.75, 0.75, 0.78), hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.15, 0.9), 0.25);

        color = envCol * fresnel + vec3(1.0) * spec;
        color = mix(metalCol * brightness, color, fresnel * 0.8 + 0.2);

        // Beat ripple glow
        float beatGlow = BEAT_INTENSITY * exp(-length(pos.xz) * 2.0);
        color += u_color * beatGlow * 0.5 * brightness * (0.5 + secEnergy);

        // Kick splash
        color += vec3(1.0, 0.9, 0.8) * KICK_LEVEL * exp(-length(pos) * 3.0) * brightness;

        // Phrase ripple — surface waves synced to phrase position
        float phraseRipple = sin(length(pos.xz) * 10.0 - PHRASE_BEAT * PI / 4.0) * 0.5 + 0.5;
        color += u_color * phraseRipple * 0.05 * SECTION_CONF * brightness;
    }

    // Background ripples on beat
    float dist2D = length(p);
    for (int ri = 0; ri < 3; ri++) {
        float fr = float(ri);
        float rR = fract(t * 0.4 - fr * 0.33) * 2.0;
        float ripple = sin((dist2D - rR) * 25.0) * exp(-pow(dist2D - rR, 2.0) * 12.0);
        ripple *= (BEAT_INTENSITY + KICK_LEVEL * 0.3) * exp(-fr * 0.5);
        color += u_color * ripple * 0.25 * brightness;
    }

    // Fixture effects
    if (STROBE_ON > 0.5) {
        float strobe = step(0.5, fract(t * (8.0 + BAND_HIGH_MID * 10.0)));
        color += vec3(1.0) * strobe * 0.15 * brightness;
    }
    color += vec3(1.0) * BLINDER_INT * TRIGGER_FLASH * 0.5;
    if (TRIGGER_PYRO > 0.5) color += vec3(1.0, 0.5, 0.1) * exp(-dist2D * 3.0) * 0.5;
    if (TRIGGER_SMOKE > 0.5) {
        color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.2, 0.3) * fbm(p * 2.0 + t * 0.1) * 0.1;
    }

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.35;
    frag_color = vec4(color, 1.0);
}
