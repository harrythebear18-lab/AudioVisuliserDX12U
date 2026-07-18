#version 460 core

// MANDELBOX — Raymarched Mandelbox fold fractal with kaleidoscopic symmetry.
// Scale and fold count morph with frequency bands. Section drives fold type.
// Phrase beat drives rotation evolution. Full PBR with soft shadows + AO.

in vec2 v_uv;
out vec4 frag_color;

uniform float u_time;
uniform vec2 u_resolution;
uniform sampler2D u_spectrum;
uniform vec3 u_color;
uniform vec3 u_color2;

#define PI 3.14159265359
#define MAX_STEPS 128
#define MAX_DIST 10.0
#define SURF_DIST 0.0005

vec3 hsv2rgb(float h, float s, float v) {
    vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    vec3 p = abs(fract(vec3(h) + K.xyz) * 6.0 - K.www);
    return v * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), s);
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

// Mandelbox distance estimator with audio-driven scale
float mandelboxDE(vec3 p, float scale, float secEnergy) {
    vec3 z = p;
    float dr = 1.0;
    float minR2 = 0.25;
    float r2 = 0.0;
    int iterations = 8 + int(secEnergy * 6.0);
    
    for (int i = 0; i < 14; i++) {
        if (i >= iterations) break;
        // Box fold — clamp to [-1, 1] then reflect
        z = clamp(z, -1.0, 1.0) * 2.0 - z;
        // Sphere fold
        r2 = dot(z, z);
        if (r2 < minR2) {
            float t2 = minR2 / r2;
            z *= t2;
            dr *= t2;
        } else if (r2 < 1.0) {
            float t2 = 1.0 / r2;
            z *= t2;
            dr *= t2;
        }
        // Scale
        z = z * scale + p;
        dr = dr * abs(scale) + 1.0;
    }
    return length(z) / abs(dr);
}

float map(vec3 p, float t, float scale, float secEnergy) {
    // Kaleidoscopic rotation — phrase beat drives fold rotation
    float phraseRot = PHRASE_BEAT * PI / 8.0;
    p.xz = rot(t * 0.08 + STEREO_BALANCE * 0.3) * p.xz;
    p.xy = rot(phraseRot * 0.3 + t * 0.03) * p.xy;
    // Beat-driven scale pulse
    p *= 1.0 - BEAT_INTENSITY * 0.03;
    return mandelboxDE(p, scale, secEnergy);
}

vec3 calcNormal(vec3 p, float t, float scale, float secEnergy) {
    vec2 e = vec2(0.0005, 0.0);
    return normalize(vec3(
        map(p + e.xyy, t, scale, secEnergy) - map(p - e.xyy, t, scale, secEnergy),
        map(p + e.yxy, t, scale, secEnergy) - map(p - e.yxy, t, scale, secEnergy),
        map(p + e.yyx, t, scale, secEnergy) - map(p - e.yyx, t, scale, secEnergy)
    ));
}

float softShadow(vec3 ro, vec3 rd, float mint, float maxt, float k, float t, float scale, float secEnergy) {
    float res = 1.0;
    for (float s = mint; s < maxt; s += 0.015) {
        float h = map(ro + rd * s, t, scale, secEnergy);
        if (h < 0.001) return 0.0;
        res = min(res, k * h / s);
    }
    return clamp(res, 0.0, 1.0);
}

float calcAO(vec3 p, vec3 n, float t, float scale, float secEnergy) {
    float occ = 0.0;
    float sca = 1.0;
    for (int i = 0; i < 5; i++) {
        float h = 0.01 + 0.03 * float(i);
        float d = map(p + n * h, t, scale, secEnergy);
        occ += (h - d) * sca;
        sca *= 0.85;
    }
    return clamp(1.0 - 1.5 * occ, 0.0, 1.0);
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;

    float t = u_time;
    float secEnergy = sectionEnergy(SECTION);
    float brightness = 0.3 + DIMMER_INT * 0.7;

    // Scale morphs with bands — different bands drive different aspects
    float scale = 2.2 + BAND_SUB * 0.5 + BAND_BASS * 0.3 + secEnergy * 0.5;
    scale += sin(PHRASE_BEAT * PI / 8.0) * 0.15;

    // Camera
    float camR = 3.0 - secEnergy * 0.3;
    vec3 ro = vec3(cos(t * 0.12 + STEREO_BALANCE * 0.5) * camR,
                   sin(t * 0.08) * 0.8,
                   sin(t * 0.12) * camR);
    vec3 target = vec3(0.0);
    vec3 forward = normalize(target - ro);
    vec3 right = normalize(cross(vec3(0, 1, 0), forward));
    vec3 up = cross(forward, right);
    vec3 rd = normalize(forward * 1.5 + right * p.x + up * p.y);

    // Raymarch
    float d = 0.0;
    float steps = 0.0;
    for (int i = 0; i < MAX_STEPS; i++) {
        vec3 pos = ro + rd * d;
        float sdf = map(pos, t, scale, secEnergy);
        if (sdf < SURF_DIST) break;
        if (d > MAX_DIST) break;
        d += sdf * 0.8;
        steps += 1.0;
    }

    vec3 color = vec3(0.0);

    // Background
    color += mix(hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.4, 0.01),
                 hsv2rgb(BASE_HUE + SECTION_HUE_CTR + 0.1, 0.5, 0.03), uv.y) * brightness;

    // Stars
    float star = fract(sin(dot(floor(p * 40.0), vec2(127.1, 311.7))) * 43758.5);
    if (star > 0.997) color += vec3(0.7, 0.8, 1.0) * (star - 0.997) * 300.0 * brightness * 0.3;

    if (d < MAX_DIST) {
        vec3 pos = ro + rd * d;
        vec3 normal = calcNormal(pos, t, scale, secEnergy);
        vec3 viewDir = -rd;

        // Orbit-trap coloring — fold position determines hue
        float trap = length(pos) + sin(pos.x * 3.0) * 0.1 + sin(pos.y * 3.0) * 0.1;
        float colorT = fract(trap * 0.3 + BASE_HUE + t * 0.01);
        vec3 baseCol = hsv2rgb(colorT + SECTION_HUE_CTR, 0.7, 1.0);
        // Mix with brain colors
        baseCol = mix(baseCol, mix(u_color, u_color2, trap * 0.2), 0.35);

        // Lighting
        vec3 lightDir = normalize(vec3(-0.4, 0.7, 0.5));
        float diff = max(dot(normal, lightDir), 0.0);
        float shadow = softShadow(pos + normal * 0.002, lightDir, 0.01, 3.0, 8.0, t, scale, secEnergy);
        diff *= shadow;
        float ao = calcAO(pos, normal, t, scale, secEnergy);

        // Specular
        vec3 halfV = normalize(lightDir + viewDir);
        float spec = pow(max(dot(normal, halfV), 0.0), 64.0);
        spec *= (0.3 + LASER_INT * 1.5) * brightness;

        // Fresnel
        float fresnel = pow(1.0 - max(dot(normal, viewDir), 0.0), 4.0);

        vec3 lit = baseCol * (diff * 0.8 + ao * 0.3 + 0.1) * brightness;
        lit += vec3(1.0) * spec;
        lit += baseCol * fresnel * (0.3 + secEnergy * 0.3) * brightness;

        // Beat glow
        lit += baseCol * BEAT_INTENSITY * 0.6 * brightness;
        // Kick flash
        lit += vec3(1.0, 0.9, 0.8) * KICK_LEVEL * 0.3 * brightness;
        // Section boost
        lit *= (0.7 + secEnergy * 0.3);

        // Step glow
        float stepGlow = steps / float(MAX_STEPS);
        color = lit + baseCol * stepGlow * 0.15 * brightness;
    }

    // Fixture effects
    if (STROBE_ON > 0.5) {
        float strobe = step(0.5, fract(t * (8.0 + BAND_HIGH_MID * 10.0)));
        color += vec3(1.0) * strobe * 0.15 * brightness;
    }
    color += vec3(1.0) * BLINDER_INT * TRIGGER_FLASH * 0.4;
    if (TRIGGER_PYRO > 0.5) color += vec3(1.0, 0.5, 0.1) * exp(-length(p) * 3.0) * 0.5;

    // Tone map
    color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    color = pow(color, vec3(0.85));
    color *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.4;
    frag_color = vec4(color, 1.0);
}
