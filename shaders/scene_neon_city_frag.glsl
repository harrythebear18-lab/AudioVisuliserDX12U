#version 460 core

// NEON CITY — Cyberpunk skyline, fully brain-driven.
// Section changes: Intro=few dark buildings, Verse=windows lighting up,
// BuildUp=neon signs intensifying, Drop=full city blaze + holograms,
// Breakdown=windows dimming, Outro=city goes dark.
// 5 parallax layers. Phrase beat drives billboard scan patterns.
// Fixtures drive neon sign intensity, laser beams, strobing.
// Stereo drives parallax shift. Beat count drives city density.

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

// Layer count scales with section
int getLayerCount() {
    if (SECTION < 1.5) return 2;
    if (SECTION < 5.5) return 4;
    if (SECTION < 6.5) return 5;
    return 3;
}

vec3 buildingLayer(vec2 uv, float scroll, float scale, float depth, float dark, float t, float brightness, float secEnergy) {
    vec3 col = vec3(0.0);
    float layerX = uv.x + scroll;
    float grid = floor(layerX * scale);
    float frac = fract(layerX * scale);
    float bHash = hash21(vec2(grid, depth * 100.0));
    float bHeight = 0.1 + bHash * 0.5;
    float bY = uv.y - (0.05 + bHeight * (1.0 - depth * 0.2));

    if (bY < 0.0) {
        vec3 bCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + bHash * 0.08, 0.15, 0.01 + bHash * 0.02);
        col = bCol * dark;

        // Windows — lit probability scales with section
        float winRows = 6.0 + bHash * 8.0;
        float winCols = 3.0 + bHash * 2.0;
        vec2 winUV = vec2(frac * winCols, abs(bY) * winRows * 4.0);
        vec2 winGrid = floor(winUV);
        vec2 winFrac = fract(winUV);
        float winHash = hash21(winGrid + vec2(grid * 50.0 + depth * 1000.0, 0.0));

        float litProb = 0.15 + BAND_BASS * 0.4 + BAND_LOW_MID * 0.2 + secEnergy * 0.2;
        float flicker = sin(t * 4.0 + winHash * 100.0) * 0.5 + 0.5;
        flicker = step(0.4 + BEAT_INTENSITY * 0.3, flicker);

        if (winHash < litProb && flicker > 0.5) {
            float winShape = smoothstep(0.1, 0.2, winFrac.x) * smoothstep(0.9, 0.8, winFrac.x) *
                             smoothstep(0.1, 0.2, winFrac.y) * smoothstep(0.9, 0.8, winFrac.y);
            vec3 winCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + winHash * SECTION_HUE_RNG, 0.6, 1.0);
            float winBright = (0.3 + BAND_BASS * 0.7 + BAND_MID * 0.3) * brightness * (1.0 - depth * 0.3) * (0.5 + secEnergy);
            col += winCol * winShape * winBright * 2.0;
        }

        // Neon signs — laser driven, more intense in Drop
        float neonIntensity = (0.15 + LASER_INT * 1.8) * brightness * (1.0 - depth * 0.3) * (0.3 + secEnergy);
        if (frac < 0.04 || frac > 0.96) {
            vec3 neonCol = hsv2rgb(BASE_HUE + bHash * SECTION_HUE_RNG, 0.9, 1.0);
            col += neonCol * neonIntensity * 0.8;
        }
        // Neon strips on building tops
        if (abs(bY) < 0.015 && frac > 0.1 && frac < 0.9) {
            float stripPulse = sin(t * 3.0 + bHash * 10.0 + PHRASE_BEAT * 0.4) * 0.5 + 0.5;
            vec3 stripCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + bHash * 0.1, 0.9, 1.0);
            col += stripCol * stripPulse * neonIntensity * 0.5;
        }

        // Rooftop beacons
        if (abs(bY) < 0.02 && frac > 0.4 && frac < 0.6) {
            float antBlink = step(0.5, sin(t * 2.0 + bHash * 10.0));
            col += vec3(1.0, 0.2, 0.1) * antBlink * 0.5 * brightness;
        }
    }
    return col;
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;

    float t = u_time * (0.02 + MOVEMENT_INT * 0.15);
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;
    float scroll = t * 0.3;
    int layerCount = getLayerCount();

    vec3 color = vec3(0.0);

    // Sky — section-tinted with horizon glow
    float skyT = uv.y;
    vec3 skyTop = hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.4, 0.02 + secEnergy * 0.01);
    vec3 skyBot = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + 0.05, 0.6, 0.08 + secEnergy * 0.06);
    skyBot += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.8, 0.6) * BEAT_INTENSITY * 0.3 * (0.5 + secEnergy);
    color += mix(skyBot, skyTop, smoothstep(0.0, 0.6, skyT)) * brightness;

    // Moon
    float moonDist = length(uv - vec2(0.7, 0.75));
    color += hsv2rgb(BASE_HUE + 0.1, 0.3, 1.0) * exp(-moonDist * moonDist * 20.0) * 0.3 * brightness;

    // Stars
    float star = hash21(floor(p * 30.0 + vec2(scroll * 5.0, 0.0)));
    if (star > 0.996 && uv.y > 0.3) {
        float blink = sin(u_time * 3.0 + star * 100.0) * 0.5 + 0.5;
        blink *= (0.7 + BEAT_DETECTED * 0.3);
        color += vec3(0.7, 0.8, 1.0) * (star - 0.996) * 250.0 * blink * brightness * 0.3;
    }

    // Building layers
    for (int layer = 0; layer < 5; layer++) {
        if (layer >= layerCount) break;
        float fl = float(layer);
        float parallax = scroll * (0.3 + fl * 0.2) + STEREO_BALANCE * (0.01 + fl * 0.01);
        float layerScale = 2.0 + fl * 1.5;
        float layerDark = 0.2 + fl * 0.15;
        float layerDepth = fl / 5.0;
        color += buildingLayer(uv, parallax, layerScale, layerDepth, layerDark, t, brightness, secEnergy);
    }

    // Holographic billboards — more in Drop, phrase-driven scan
    int numHolo = 1 + int(secEnergy * 3.0);
    for (int bi = 0; bi < 4; bi++) {
        if (bi >= numHolo) break;
        float fi = float(bi);
        float holoX = fract(scroll * 0.1 + fi * 0.33);
        float holoY = 0.35 + fi * 0.15;
        float holoW = 0.15;
        float holoH = 0.12;
        if (holoX > 0.2 && holoX < 0.8 && abs(uv.x - holoX) < holoW && abs(uv.y - holoY) < holoH) {
            vec2 holoUV = vec2((uv.x - (holoX - holoW)) / (holoW * 2.0), (uv.y - (holoY - holoH)) / (holoH * 2.0));
            float scan = sin(holoUV.y * 80.0 - t * 5.0 + PHRASE_BEAT * 0.4) * 0.5 + 0.5;
            float glitch = step(0.97, sin(holoUV.x * 20.0 + t * 10.0));
            float holoNoise = fbm(holoUV * 8.0 + t * 2.0);
            vec3 holoCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + fi * 0.15, 0.8, 1.0);
            float holoAlpha = (holoNoise * 0.5 + scan * 0.3 + glitch * 0.2) * (0.2 + BEAT_INTENSITY * 0.5) * brightness * secEnergy;
            holoAlpha *= smoothstep(0.0, 0.1, holoUV.x) * smoothstep(1.0, 0.9, holoUV.x) *
                         smoothstep(0.0, 0.1, holoUV.y) * smoothstep(1.0, 0.9, holoUV.y);
            color += holoCol * holoAlpha * 2.0;
        }
    }

    // Volumetric fog — section-tinted
    float fog = fbm(vec2(uv.x * 3.0 + t * 0.1, uv.y * 2.0)) * 0.15;
    fog *= smoothstep(0.0, 0.4, uv.y) * smoothstep(0.8, 0.3, uv.y);
    color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.3, 0.15) * fog * brightness * (0.5 + secEnergy);

    // Rain — more intense in Drop
    float rainIntensity = 0.5 + secEnergy * 0.5;
    for (int rl = 0; rl < 3; rl++) {
        float frl = float(rl);
        float rainSpeed = 8.0 + frl * 4.0;
        float rainScale = 10.0 + frl * 5.0;
        vec2 rainUV = vec2(p.x * rainScale + hash21(vec2(frl, 0.0)) * 100.0,
                           uv.y * rainScale * 3.0 - t * rainSpeed);
        float rainX = fract(rainUV.x);
        float rainY = fract(rainUV.y);
        if (rainX < 0.015 && rainY < 0.7) {
            float rainBright = (0.1 + BAND_PRESENCE * 0.3 + BAND_AIR * 0.2) * (1.0 - frl * 0.2) * rainIntensity;
            color += vec3(0.6, 0.7, 0.9) * rainBright * brightness;
        }
    }

    // Rain splash on kick
    float splash = exp(-pow(uv.y - 0.03, 2.0) * 200.0) * KICK_LEVEL;
    color += vec3(0.5, 0.6, 0.8) * splash * brightness * 0.5;

    // Flying vehicles — more in Drop, beat-synced
    int numVehicles = 2 + int(secEnergy * 4.0);
    for (int vi = 0; vi < 6; vi++) {
        if (vi >= numVehicles) break;
        float fi = float(vi);
        float vehX = fract(t * (0.08 + fi * 0.02) + fi * 0.2);
        float vehY = 0.25 + sin(t * 0.3 + fi * 2.0) * 0.12 + fi * 0.08;
        float vehDist = length(uv - vec2(vehX, vehY));
        float vehGlow = exp(-vehDist * vehDist * 600.0);
        float trailX = fract(vehX - t * 0.05);
        float trailDist = length(uv - vec2(trailX, vehY));
        float trailGlow = exp(-trailDist * trailDist * 300.0) * 0.3;
        vec3 vehCol = hsv2rgb(BASE_HUE + fi * 0.12, 0.9, 1.0);
        color += vehCol * (vehGlow + trailGlow) * (0.3 + BAND_BRILLIANCE * 0.5) * brightness;
    }

    // Ground reflection
    if (uv.y < 0.08) {
        float reflT = (0.08 - uv.y) / 0.08;
        vec2 reflUV = vec2(uv.x, 0.16 - uv.y);
        vec3 reflCol = vec3(0.0);
        for (int layer = 0; layer < 3; layer++) {
            float fl = float(layer);
            float parallax = scroll * (0.3 + fl * 0.2);
            reflCol += buildingLayer(reflUV, parallax, 2.0 + fl * 1.5, fl / 5.0, 0.2 + fl * 0.15, t, brightness, secEnergy);
        }
        float wetNoise = fbm(vec2(p.x * 5.0 + t * 0.2, uv.y * 30.0));
        reflCol *= (0.2 + wetNoise * 0.3) * reflT;
        color += reflCol;
    }

    // Laser beams when brain says lasers on
    if (LASERS_ON > 0.5) {
        for (int bi = 0; bi < 3; bi++) {
            float fb = float(bi);
            float beamY = 0.3 + fb * 0.2;
            float beamSwing = sin(t * 2.0 + fb * 2.0) * 0.3;
            float beamDist = abs(uv.y - beamY - beamSwing);
            float beamGlow = exp(-beamDist * beamDist * 500.0) * LASER_INT;
            vec3 beamCol = mix(u_color, u_color2, fb / 3.0);
            color += beamCol * beamGlow * 1.5 * brightness;
        }
    }

    // Fixture effects
    if (STROBE_ON > 0.5) {
        float strobe = step(0.5, fract(t * (8.0 + BAND_HIGH_MID * 10.0)));
        color += vec3(1.0) * strobe * 0.15 * brightness;
    }
    color += vec3(1.0) * BLINDER_INT * TRIGGER_FLASH * 0.3;
    if (TRIGGER_PYRO > 0.5) color += vec3(1.0, 0.5, 0.1) * exp(-length(p) * 3.0) * 0.5;
    if (TRIGGER_SMOKE > 0.5) {
        color += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.2, 0.3) * fbm(p * 2.0 + t * 0.1) * 0.1;
    }

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.5;
    frag_color = vec4(color, 1.0);
}
