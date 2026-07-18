#version 460 core

// STAGE RIG — 3D concert stage with moving heads, LED video wall, pyro, haze.
// Raymarched stage geometry (truss, platforms) with volumetric light cones.
// Brain drives: moving head positions/rotation, LED wall content, dimmer,
// fixture on/off states, triggers for pyro/strobe/flash, section for color,
// phrase beat for chase patterns, group behavior for coordinated movement.

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

// Volumetric light cone — spotlight beam
vec3 lightCone(vec3 ro, vec3 rd, vec3 lightPos, vec3 lightDir, float coneAngle, float intensity, vec3 lightColor) {
    // Project ray onto light direction
    vec3 toLight = lightPos - ro;
    float tProj = dot(toLight, lightDir) / dot(lightDir, lightDir);
    if (tProj < 0.0 || tProj > 5.0) return vec3(0.0);
    
    vec3 closestPoint = lightPos + lightDir * tProj;
    vec3 toClosest = closestPoint - (ro + rd * dot(toLight, rd) / dot(rd, rd));
    
    // Distance from ray to cone axis
    float perpDist = length(cross(rd, lightDir)) > 0.001 ?
        abs(dot(ro + rd * tProj - lightPos, normalize(cross(rd, lightDir)))) : 1e9;
    
    // Cone radius at this distance
    float coneRadius = tan(coneAngle) * tProj;
    
    // Inside cone?
    if (perpDist > coneRadius) return vec3(0.0);
    
    // Volumetric scattering — stronger at cone edges (rim)
    float coneFalloff = 1.0 - smoothstep(0.0, coneRadius, perpDist);
    float scatter = coneFalloff * intensity / (1.0 + tProj * tProj * 0.05);
    
    return lightColor * scatter * 0.3;
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;

    float t = u_time;
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;

    // Camera — audience view, slightly elevated
    vec3 ro = vec3(STEREO_BALANCE * 0.3, 1.2, -4.0);
    vec3 rd = normalize(vec3(p.x * 0.7, p.y * 0.4 - 0.1, 1.5));

    vec3 color = vec3(0.0);

    // === Haze atmosphere ===
    float hazeDensity = 0.1 + secEnergy * 0.1;
    if (TRIGGER_SMOKE > 0.5) hazeDensity += 0.25;
    
    for (int i = 0; i < 20; i++) {
        float fi = float(i);
        float rayT = fi * 0.15;
        vec3 pos = ro + rd * rayT;
        float haze = fbm(pos.xy * 1.2 + t * 0.04) * hazeDensity;
        haze *= exp(-rayT * 0.12);
        if (haze > 0.001) {
            vec3 hazeCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.15, 0.1) * brightness;
            color += hazeCol * haze * 0.3;
        }
    }

    // === LED Video Wall — back of stage ===
    // Project ray to back wall at z = 2.0
    float wallT = (2.0 - ro.z) / rd.z;
    if (wallT > 0.0 && wallT < 10.0) {
        vec3 wallPos = ro + rd * wallT;
        vec2 wallUV = vec2(wallPos.x / 4.0 + 0.5, wallPos.y / 3.0 + 0.5);
        
        if (wallUV.x > 0.0 && wallUV.x < 1.0 && wallUV.y > 0.0 && wallUV.y < 1.0) {
            // LED wall content — driven by spectrum texture + brain colors
            float ledBright = brightness * (0.3 + secEnergy * 0.7);
            
            // Spectrum bars on LED wall
            float specIdx = wallUV.x * 32.0;
            float specVal = texelFetch(u_spectrum, ivec2(int(specIdx) * 8, 0), 0).r;
            float barHeight = specVal * 2.0 * wallUV.y;
            float bar = smoothstep(0.0, 0.05, barHeight) * smoothstep(0.1, 0.05, barHeight - wallUV.y);
            
            // Color from brain palette
            vec3 ledCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + wallUV.x * SECTION_HUE_RNG, 0.7, 1.0);
            
            // Scan lines
            float scanline = sin(wallUV.y * 200.0 + t * 5.0) * 0.1 + 0.9;
            
            // Pixel grid
            vec2 pixelGrid = fract(wallUV * vec2(64.0, 36.0));
            float pixelMask = smoothstep(0.0, 0.1, pixelGrid.x) * smoothstep(1.0, 0.9, pixelGrid.x) *
                              smoothstep(0.0, 0.1, pixelGrid.y) * smoothstep(1.0, 0.9, pixelGrid.y);
            
            float wallFade = exp(-wallT * 0.15);
            vec3 wallColor = ledCol * bar * ledBright * scanline * (0.7 + pixelMask * 0.3) * wallFade;
            
            // Background glow on wall
            wallColor += ledCol * 0.05 * ledBright * wallFade;
            
            // Beat flash on wall
            wallColor += ledCol * BEAT_INTENSITY * 0.3 * wallFade;
            
            color = mix(color, wallColor, wallFade * 0.8);
        }
    }

    // === Moving head light cones ===
    if (MOVING_ON > 0.5) {
        int numHeads = 4 + int(secEnergy * 4.0);
        for (int hi = 0; hi < 8; hi++) {
            if (hi >= numHeads) break;
            float fi = float(hi);
            
            // Moving head positions on truss
            vec3 headPos = vec3(
                (fi / float(numHeads) - 0.5) * 3.5 + sin(t * 0.2 + fi) * 0.1,
                2.5,
                -0.5 + cos(fi * 1.3) * 0.3
            );
            
            // Chase pattern — phrase beat drives sequential movement
            float chasePhase = t * (0.5 + MOVEMENT_INT * 2.0) + fi * 0.4 + PHRASE_BEAT * 0.3;
            vec3 headDir = normalize(vec3(
                sin(chasePhase) * 1.5,
                -1.5 + cos(chasePhase * 0.7) * 0.3,
                cos(chasePhase) * 0.8 + 0.5
            ));
            
            // Cone angle — narrower in Drop
            float coneAngle = 0.25 + (SECTION > 6.5 && SECTION < 7.5 ? -0.1 : 0.05);
            
            // Intensity — dimmer controlled
            float headIntensity = MOVING_LIGHT_INT * brightness * (0.5 + BEAT_INTENSITY * 0.5);
            
            // Color — group behavior drives color assignment
            vec3 headColor;
            if (int(GROUP_PHASE * 4.0) % 2 == 0) {
                headColor = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + fi * 0.05, 0.7, 1.0);
            } else {
                headColor = mix(u_color, u_color2, fi / float(numHeads));
            }
            
            color += lightCone(ro, rd, headPos, headDir, coneAngle, headIntensity, headColor);
        }
    }

    // === Static wash lights ===
    if (STATIC_ON > 0.5) {
        for (int si = 0; si < 3; si++) {
            float fi = float(si);
            vec3 washPos = vec3((fi - 1.0) * 2.0, 2.5, 0.5);
            vec3 washDir = normalize(vec3(0.0, -1.5, 0.3));
            float washIntensity = STATIC_LIGHT_INT * brightness * 0.5;
            vec3 washColor = mix(u_color, u_color2, fi / 3.0);
            color += lightCone(ro, rd, washPos, washDir, 0.5, washIntensity, washColor);
        }
    }

    // === Blinder flash — from front of stage ===
    if (BLINDERS_ON > 0.5) {
        color += vec3(1.0, 0.95, 0.9) * BLINDER_INT * TRIGGER_FLASH * 0.6;
    }

    // === Strobe ===
    if (STROBE_ON > 0.5) {
        float strobeFreq = 8.0 + BAND_HIGH_MID * 12.0;
        float strobe = step(0.5, fract(t * strobeFreq));
        color += vec3(1.0) * strobe * 0.2 * brightness;
    }

    // === Pyro ===
    if (TRIGGER_PYRO > 0.5) {
        for (int pi = 0; pi < 3; pi++) {
            float fi = float(pi);
            vec2 pyroPos = vec2((fi - 1.0) * 0.5, -0.2);
            float pyroDist = length(p - pyroPos);
            float pyroT = fract(t * 2.0 + fi * 0.3);
            float pyroGlow = exp(-pyroDist * pyroDist * 15.0) * (1.0 - pyroT);
            color += vec3(1.0, 0.4, 0.05) * pyroGlow * 0.8;
            // Sparks
            float sparks = sin(pyroDist * 50.0 - t * 20.0) * 0.5 + 0.5;
            color += vec3(1.0, 0.6, 0.2) * sparks * pyroGlow * 0.3;
        }
    }

    // === Stage floor ===
    float floorT = -ro.y / rd.y;
    if (floorT > 0.0 && floorT < 10.0 && rd.y < 0.0) {
        vec2 floorPos = (ro + rd * floorT).xz;
        float floorFade = exp(-floorT * 0.15);
        
        // Reflective stage floor
        vec3 floorCol = vec3(0.02, 0.02, 0.03);
        floorCol += color * 0.2 * floorFade;  // reflection
        
        // Floor light pools from moving heads
        if (MOVING_ON > 0.5) {
            for (int fi2 = 0; fi2 < 4; fi2++) {
                float ffi = float(fi2);
                float chasePhase = t * (0.5 + MOVEMENT_INT * 2.0) + ffi * 0.4;
                vec2 poolPos = vec2(sin(chasePhase) * 1.5, cos(chasePhase) * 0.8 + 0.5);
                float poolDist = length(floorPos - poolPos);
                float pool = exp(-poolDist * poolDist * 8.0) * MOVING_LIGHT_INT * floorFade;
                vec3 poolCol = hsv2rgb(BASE_HUE + SECTION_HUE_CTR + ffi * 0.05, 0.7, 1.0);
                floorCol += poolCol * pool * 0.5;
            }
        }
        
        color = mix(color, floorCol, floorFade * 0.4);
    }

    // === Crowd silhouette ===
    float crowdY = uv.y + 0.35;
    if (crowdY < 0.0) {
        float crowdNoise = fbm(vec2(p.x * 10.0 + t * 0.2, 0.0));
        float crowd = smoothstep(-0.1, 0.0, crowdY + crowdNoise * 0.05);
        color *= mix(0.15, 1.0, crowd);
        // Phone lights in crowd
        float phone = hash21(vec2(floor(p.x * 20.0), 0.0));
        if (phone > 0.98) {
            color += vec3(0.8, 0.8, 1.0) * (1.0 - crowd) * 0.3 * brightness;
        }
    }

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.5;
    frag_color = vec4(color, 1.0);
}
