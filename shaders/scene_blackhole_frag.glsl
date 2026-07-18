#version 460 core

// BLACK HOLE — Fully brain-driven gravitational spectacle.
// Section changes alter the entire scene character:
//   Intro:    calm, small BH, faint disk, building stars
//   Verse:    steady disk rotation, moderate energy
//   BuildUp:  disk accelerates, jets charge, tension builds
//   Drop:     violent disk, massive jets, gravitational waves, strobing
//   Breakdown: disk collapses, jets fade, waves dissipate
//   Outro:    BH shrinks, stars fade to black
// Phrase beat drives ring pulses. Fixture states drive real lighting.
// Triggers produce flash/strobe/pyro events. Stereo drives disk tilt.

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

// Section enum: 0=Unknown,1=Intro,2=Verse,3=PreChorus,4=Chorus,5=BuildUp,6=Drop,7=Breakdown,8=Bridge,9=Interlude,10=Outro
float sectionEnergy(float sec) {
    if (sec < 0.5) return 0.0;       // Unknown
    if (sec < 1.5) return 0.15;      // Intro
    if (sec < 2.5) return 0.4;       // Verse
    if (sec < 3.5) return 0.5;       // PreChorus
    if (sec < 4.5) return 0.6;       // Chorus
    if (sec < 5.5) return 0.7;       // BuildUp
    if (sec < 6.5) return 1.0;       // Drop
    if (sec < 7.5) return 0.5;       // Breakdown
    if (sec < 8.5) return 0.45;      // Bridge
    if (sec < 9.5) return 0.3;       // Interlude
    return 0.1;                       // Outro
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;
    float dist = length(p);
    float angle = atan(p.y, p.x);

    float t = u_time;
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;

    // Section-driven parameters — each section has distinct character
    float bhR = 0.08 + BAND_SUB * 0.06 + BAND_BASS * 0.04 + secEnergy * 0.06;
    float rotSpeed = 0.1 + MOVEMENT_INT * 1.0 + secEnergy * 1.5;
    float diskInner = bhR * 1.6;
    float diskOuter = bhR * (3.0 + secEnergy * 3.0) + BAND_BASS * 1.5;
    float tilt = 0.3 + STEREO_WIDTH * 0.3 + abs(STEREO_BALANCE) * 0.15;

    // Phrase-driven evolution — effects build over 16-beat phrases
    float phraseT = PHRASE_BEAT / 16.0;  // 0 to 1 over a phrase
    float phraseBuild = smoothstep(0.0, 1.0, phraseT);
    
    // BuildUp: tension increases over phrase
    float buildTension = (SECTION > 4.5 && SECTION < 5.5) ? phraseBuild : 0.0;
    // Drop: release at phrase start
    float dropRelease = (SECTION > 5.5 && SECTION < 6.5) ? (1.0 - phraseT * 0.5) : 0.0;

    vec3 color = vec3(0.0);

    // === Starfield — density varies by section ===
    int starLayers = 2 + int(secEnergy * 2.0);
    for (int layer = 0; layer < 4; layer++) {
        if (layer >= starLayers) break;
        float fl = float(layer);
        float scale = 40.0 + fl * 30.0;
        vec2 sp = p * (1.0 + fl * 0.08);
        vec2 grid = floor(sp * scale);
        float s = hash21(grid);
        if (s > 0.993 - fl * 0.001) {
            vec2 sf = fract(sp * scale) - 0.5;
            float tw = sin(t * (1.5 + fl) + s * 100.0) * 0.5 + 0.5;
            // Stars pulse on beat
            tw *= (0.7 + BEAT_DETECTED * 0.3);
            float b = (s - 0.99) * 100.0 * tw * exp(-length(sf) * 18.0);
            vec3 sc = mix(vec3(0.8,0.9,1.0), vec3(1.0,0.8,0.6), hash21(grid+1.0));
            color += sc * b * (1.0 - fl * 0.2) * brightness;
        }
    }

    // Nebula — section-colored
    float neb = fbm(p * 1.2 + t * 0.01);
    float nebIntensity = 0.03 + secEnergy * 0.05;
    color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.5, 0.35) * neb * nebIntensity * brightness;

    // === Volumetric accretion disk ===
    float diskY = p.y * tilt;
    float diskDist = length(vec2(p.x, diskY));

    if (diskDist > diskInner && diskDist < diskOuter) {
        float diskT = (diskDist - diskInner) / (diskOuter - diskInner);
        float orbitSpeed = 1.0 / sqrt(diskDist / diskInner);
        float orbitAngle = angle + t * orbitSpeed * rotSpeed * 1.5;

        // Turbulent density — more turbulent in Drop
        float turbScale = 1.0 + secEnergy * 2.0 + buildTension * 3.0;
        float density = fbm(vec2(orbitAngle * 5.0, diskDist * 8.0));
        density *= fbm(vec2(orbitAngle * 12.0 + t * 0.5, diskDist * 15.0));
        density = pow(density, 1.5);

        // Vertical falloff
        float diskThickness = 0.015 + BAND_MID * 0.025;
        density *= exp(-diskY * diskY / (diskThickness * diskThickness));

        // Doppler beaming
        float doppler = pow(0.5 + 0.5 * sin(orbitAngle + PI * 0.5), 2.5);

        // Temperature — hotter in Drop
        float temp = (1.0 - diskT) * (0.5 + secEnergy * 0.5);
        vec3 diskCol = mix(u_color2, u_color, temp);
        diskCol = mix(diskCol, vec3(1.0, 0.9, 0.7), pow(temp, 3.0));
        diskCol = mix(diskCol, vec3(1.0, 0.5, 0.2), pow(temp, 5.0) * 0.5);

        // Audio + section reactivity
        float audioBoost = 0.3 + BEAT_INTENSITY * 1.5 + BAND_LOW_MID * 0.8 + BAND_MID * 0.4;
        audioBoost *= (0.5 + secEnergy * 0.5 + dropRelease * 1.5);
        density *= audioBoost * brightness * (0.4 + doppler * 0.6);

        color += diskCol * density * 2.5;
    }

    // === Photon ring — phrase pulse ===
    float photonR = bhR * 1.4;
    float ringDist = abs(dist - photonR);
    float ringPulse = 0.3 + BEAT_INTENSITY * 4.0 + LASER_INT * 2.0;
    // Phrase beat adds ring pulse
    ringPulse += sin(PHRASE_BEAT * PI / 8.0) * 0.5 * SECTION_CONF;
    float ringGlow = exp(-ringDist * 50.0) * ringPulse * brightness;
    float ringAsym = pow(0.5 + 0.5 * sin(angle + PI * 0.5), 2.0);
    color += vec3(1.0, 0.85, 0.6) * ringGlow * (0.3 + ringAsym * 0.7) * 1.8;

    // === Relativistic jets — kick + section driven ===
    // Jets only fire when brain says they should (moving lights on or in Drop/BuildUp)
    float jetActivation = KICK_LEVEL + (MOVING_ON > 0.5 ? BAND_BRILLIANCE * 0.5 : 0.0) + dropRelease * 0.5;
    float jetWidth = 0.03 + jetActivation * 0.10;
    float jetLen = 0.5 + jetActivation * 2.5 + BAND_AIR * 0.8;
    float jetDistX = abs(p.x);

    if (jetDistX < jetWidth && abs(p.y) > bhR && abs(p.y) < jetLen) {
        float jt = abs(p.y) / jetLen;
        float jInt = exp(-jt * 3.0) * jetActivation * brightness;
        float jTurb = fbm(vec2(p.y * 8.0 + t * 4.0, p.x * 15.0));
        jInt *= (0.5 + jTurb);
        vec3 jCol = mix(vec3(0.4, 0.6, 1.0), vec3(0.9, 0.95, 1.0), 1.0 - jt);
        jCol = mix(jCol, u_color, 0.3);
        color += jCol * jInt * 1.5;
        float jPart = sin(p.y * 40.0 - t * 18.0) * 0.5 + 0.5;
        color += vec3(1.0) * jPart * jInt * 0.3;
    }

    // === Event horizon ===
    if (dist < bhR) {
        color = vec3(0.0);
        color += u_color * smoothstep(bhR - 0.01, bhR, dist) * 0.1;
    }

    // === Gravitational waves — beat + phrase driven ===
    for (int wi = 0; wi < 4; wi++) {
        float fw = float(wi);
        // Waves sync to phrase position
        float wavePhase = fract(t * 0.2 - fw * 0.25 + PHRASE_BEAT * 0.0625);
        float wR = wavePhase * 2.5;
        float wave = exp(-pow(dist - wR, 2.0) * 55.0);
        wave *= (BEAT_INTENSITY + TRIGGER_FLASH * 0.5) * exp(-fw * 0.5);
        // Waves stronger in Drop
        wave *= (0.5 + secEnergy * 0.5);
        color += u_color * wave * 0.6;
    }

    // === Fixture-driven effects ===
    // Strobe — actual strobing when brain fires strobe
    if (STROBE_ON > 0.5) {
        float strobeFreq = 8.0 + BAND_HIGH_MID * 10.0;
        float strobe = step(0.5, fract(t * strobeFreq));
        color += vec3(1.0) * strobe * 0.15 * brightness;
    }
    // Blinder flash — white-out
    color += vec3(1.0) * BLINDER_INT * TRIGGER_FLASH * 0.4;
    // Pyro — orange burst
    if (TRIGGER_PYRO > 0.5) {
        color += vec3(1.0, 0.5, 0.1) * exp(-dist * 3.0) * 0.5;
    }
    // Smoke — fog overlay
    if (TRIGGER_SMOKE > 0.5) {
        float smokeNoise = fbm(p * 2.0 + t * 0.1);
        color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.2, 0.3) * smokeNoise * 0.1;
    }

    // === Group behavior — phase drives rotational shimmer ===
    float groupShimmer = sin(angle * 6.0 + GROUP_PHASE * 6.28 + t * 2.0) * 0.5 + 0.5;
    color += u_color * groupShimmer * 0.05 * SECTION_CONF * brightness;

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.5;
    frag_color = vec4(color, 1.0);
}
