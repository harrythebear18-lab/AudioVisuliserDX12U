#version 460 core

// LASER SHOW — Volumetric laser beams through atmospheric haze.
// Real concert laser rig: multiple beams, scanning patterns, color mixing,
// haze volumetric scattering, gobo projections, beam intersections.
// Brain drives: laser intensity, moving light positions, beat-synced scans,
// section-driven color palettes, phrase-driven pattern changes, strobe/flash.

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

// 3D ray-cylinder intersection for laser beam
// Returns distance along ray to closest point on beam, and beam intensity
vec4 beamContribution(vec3 ro, vec3 rd, vec3 beamOrigin, vec3 beamDir, float beamRadius, float beamIntensity, vec3 beamColor) {
    // Closest distance between ray and beam line
    vec3 crossPR = cross(rd, beamDir);
    float denom = length(crossPR);
    if (denom < 0.0001) return vec4(0.0);
    float t = dot(crossPR, beamOrigin - ro) / (denom * denom);
    if (t < 0.0) return vec4(0.0);
    
    // Closest distance
    float closestDist = abs(dot(ro + rd * t - beamOrigin, normalize(crossPR)));
    
    // Beam falloff
    float beamGlow = exp(-closestDist * closestDist / (beamRadius * beamRadius));
    beamGlow *= beamIntensity;
    
    // Distance attenuation
    float distAtten = 1.0 / (1.0 + t * t * 0.1);
    beamGlow *= distAtten;
    
    return vec4(beamColor * beamGlow, beamGlow);
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;

    float t = u_time;
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;

    // Camera — audience perspective
    vec3 ro = vec3(0.0, 1.0, -3.0);
    vec3 rd = normalize(vec3(p.x * 0.8, p.y * 0.5 + 0.3, 1.5));

    vec3 color = vec3(0.0);

    // === Atmospheric haze — volumetric background ===
    // Haze density varies with section and smoke trigger
    float hazeDensity = 0.15 + secEnergy * 0.15;
    if (TRIGGER_SMOKE > 0.5) hazeDensity += 0.3;
    
    // Volumetric haze raymarch
    float hazeTransmittance = 1.0;
    for (int i = 0; i < 24; i++) {
        float fi = float(i);
        float rayT = fi * 0.15;
        vec3 pos = ro + rd * rayT;
        
        // Haze density — fbm based with audio modulation
        float haze = fbm(pos.xy * 1.5 + t * 0.05) * hazeDensity;
        haze *= exp(-rayT * 0.15);  // depth fade
        
        if (haze > 0.001) {
            vec3 hazeCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.2, 0.15) * brightness;
            float ext = haze * 0.3;
            color += hazeCol * ext * hazeTransmittance;
            hazeTransmittance *= exp(-ext);
        }
    }

    // === Laser beams — driven by brain laser state ===
    float laserIntensity = LASER_INT * brightness;
    if (LASERS_ON > 0.5) {
        // Number of beams scales with section
        int numBeams = 4 + int(secEnergy * 8.0);
        
        for (int bi = 0; bi < 12; bi++) {
            if (bi >= numBeams) break;
            float fi = float(bi);
            
            // Beam origin — from above (laser rig)
            vec3 beamOrigin = vec3(
                sin(fi * 1.3 + t * 0.5) * 1.5,
                2.5,
                cos(fi * 1.7 + t * 0.3) * 1.0
            );
            
            // Beam direction — scanning patterns driven by phrase + beat
            float scanSpeed = 0.5 + fi * 0.1 + MOVEMENT_INT * 2.0;
            float scanPhase = fi * 0.7 + t * scanSpeed + PHRASE_BEAT * 0.4;
            
            // Different scan patterns per section
            vec3 beamDir;
            if (SECTION > 5.5 && SECTION < 6.5) {
                // Drop: fast circular scan
                beamDir = normalize(vec3(cos(scanPhase * 2.0) * 2.0, -1.5, sin(scanPhase * 2.0) * 2.0 + 1.0));
            } else if (SECTION > 4.5 && SECTION < 5.5) {
                // BuildUp: converging scan
                beamDir = normalize(vec3(sin(scanPhase) * 1.5, -1.5 + sin(scanPhase) * 0.5, 0.5));
            } else {
                // Default: gentle sweep
                beamDir = normalize(vec3(sin(scanPhase) * 1.0, -1.5, cos(scanPhase * 0.7) * 0.5 + 0.5));
            }
            
            // Beam color — brain palette with per-beam variation
            float hueOff = fi / float(numBeams) * SECTION_HUE_RNG;
            vec3 beamColor = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + hueOff, 0.9, 1.0);
            
            // Beam radius — thinner in Drop, wider in Breakdown
            float beamRadius = 0.015 + (SECTION > 6.5 && SECTION < 7.5 ? 0.02 : 0.0);
            beamRadius += BAND_AIR * 0.01;
            
            // Beam intensity — beat pulse
            float beamPulse = laserIntensity * (0.5 + sin(t * 8.0 + fi) * 0.5);
            beamPulse += BEAT_INTENSITY * 2.0 * (fi == 0.0 ? 1.0 : 0.3);  // first beam gets beat accent
            
            vec4 beam = beamContribution(ro, rd, beamOrigin, beamDir, beamRadius, beamPulse, beamColor);
            color += beam.rgb;
        }
    }

    // === Moving spotlights — when brain says moving lights on ===
    if (MOVING_ON > 0.5) {
        int numSpots = 2 + int(secEnergy * 4.0);
        for (int si = 0; si < 6; si++) {
            if (si >= numSpots) break;
            float fi = float(si);
            
            vec3 spotOrigin = vec3(
                sin(fi * 2.1 + t * 0.3) * 2.0,
                2.8,
                cos(fi * 1.5 + t * 0.2) * 1.5
            );
            
            float spotScan = t * (0.3 + fi * 0.1) + fi * 1.5 + GROUP_PHASE * 6.28;
            vec3 spotDir = normalize(vec3(
                sin(spotScan) * 1.5,
                -2.0,
                cos(spotScan * 0.8) * 1.0 + 0.5
            ));
            
            float spotRadius = 0.04 + BAND_MID * 0.02;
            float spotIntensity = MOVING_LIGHT_INT * brightness * (0.6 + BEAT_INTENSITY * 0.4);
            vec3 spotColor = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + fi * 0.1, 0.7, 1.0);
            
            vec4 spot = beamContribution(ro, rd, spotOrigin, spotDir, spotRadius, spotIntensity, spotColor);
            color += spot.rgb;
        }
    }

    // === Gobo projection — pattern on floor ===
    if (STATIC_ON > 0.5) {
        float floorY = (ro.y + rd.y * (-ro.y / rd.y));
        float floorT = -ro.y / rd.y;
        if (floorT > 0.0 && floorT < 5.0) {
            vec2 floorPos = (ro + rd * floorT).xz;
            // Gobo pattern — rotating geometric
            float goboAngle = t * 0.5 + GROUP_PHASE * 6.28;
            vec2 goboP = rot(goboAngle) * floorPos;
            float gobo = 0.0;
            gobo += sin(goboP.x * 8.0) * sin(goboP.y * 8.0);
            gobo += sin(length(goboP) * 10.0 - t * 2.0);
            gobo = smoothstep(0.0, 0.5, gobo);
            vec3 goboCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.8, 1.0);
            color += goboCol * gobo * STATIC_LIGHT_INT * 0.3 * brightness * exp(-floorT * 0.3);
        }
    }

    // === Stage floor — subtle reflection ===
    float floorT = -ro.y / rd.y;
    if (floorT > 0.0 && floorT < 10.0 && rd.y < 0.0) {
        vec2 floorPos = (ro + rd * floorT).xz;
        float floorFade = exp(-floorT * 0.2);
        // Reflective floor
        vec3 floorCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.3, 0.05) * brightness;
        // Add reflection of beam colors
        floorCol += color * 0.15 * floorFade;
        // Floor texture
        float floorTex = fbm(floorPos * 3.0) * 0.1;
        floorCol += floorTex * brightness * 0.1;
        color = mix(color, floorCol, floorFade * 0.3);
    }

    // === Strobe ===
    if (STROBE_ON > 0.5) {
        float strobeFreq = 8.0 + BAND_HIGH_MID * 12.0;
        float strobe = step(0.5, fract(t * strobeFreq));
        color += vec3(1.0) * strobe * 0.2 * brightness;
    }

    // === Blinder flash ===
    color += vec3(1.0) * BLINDER_INT * TRIGGER_FLASH * 0.5;

    // === Pyro burst ===
    if (TRIGGER_PYRO > 0.5) {
        float pyroDist = length(p - vec2(0.0, -0.3));
        color += vec3(1.0, 0.5, 0.1) * exp(-pyroDist * pyroDist * 8.0) * 0.8;
    }

    // === Crowd silhouette — bottom of screen ===
    float crowdNoise = fbm(vec2(p.x * 8.0 + t * 0.1, 0.0));
    float crowd = smoothstep(0.3, 0.35, crowdNoise + uv.y * 0.3);
    color *= mix(0.3, 1.0, crowd);

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.5;
    frag_color = vec4(color, 1.0);
}
