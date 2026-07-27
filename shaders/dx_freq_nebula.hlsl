// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 48: Sonic Sphereworld — a living planet you stand on
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_SPHERICAL.
//
// 48 emitters (8 bands × 3 sub × L/R) placed on a golden-ratio sphere.
// Emitter positions drive planet terrain displacement — bass = tectonic plates,
// mids = mountain ridges, highs = surface detail. Kick = meteor craters.
// Transient = surface rupture. Beat = planetary breathing.
// Section = day/night cycle. Stereo = sun azimuth.
//
// World: grid floor for depth grounding, fog density 0.03, dark ambient.
// Camera: orbiting the planet, FOV 0.6 (VR: head pose from OpenXR).
// Visual: SDF raymarched planet with emitter-driven terrain + volumetric atmosphere.
//
// DSP: LUFS→atmospheric density, crest→terrain sharpness, THD→surface roughness, phase→cloud coherence.
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.

#include "include/spatial_encoder.hlsl"
#include "include/sdf.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define MARCH_STEPS 48
#define PLANET_R 1.5

// Audio-driven terrain height on planet surface — uses emitter influence
float terrainHeight(float3 p, SeEmitter emit[SE_NUM_OBJ], float bands[8],
                    float beatPulse, float kickSurge, float transient,
                    float crest, float thd, float silence)
{
    float r = length(p);
    float3 dir = p / max(r, 0.001);
    float lat = asin(clamp(dir.y, -1.0, 1.0));
    float lon = atan2(dir.z, dir.x);

    // Bass — tectonic plates
    float plates = fbm3_4(dir * 2.0) * (0.08 + bands[0] * 0.12 + bands[1] * 0.06);
    plates *= silence;

    // Mids — mountain ridges and valleys
    float ridges = fbm3_4(dir * 5.0 + float3(lon * 2.0, lat * 2.0, 0)) * (0.04 + bands[2] * 0.05 + bands[3] * 0.03);
    ridges *= (1.0 + crest * 0.5);
    ridges *= silence;

    // High-mids — surface detail
    float detail = fbm3_4(dir * 12.0) * (0.015 + bands[4] * 0.02 + bands[5] * 0.015);
    detail *= silence;

    // Highs — fine detail, micro-roughness
    float micro = (hash3(dir * 50.0) - 0.5) * (0.005 + bands[6] * 0.008 + bands[7] * 0.005);
    micro *= (1.0 + thd * 0.5);
    micro *= silence;

    // Beat — planetary breathing
    float breath = beatPulse * 0.015 * sin(lat * 3.0 + lon * 2.0);

    // Kick — meteor crater depressions
    float craters = 0.0;
    if (kickSurge > 0.01) {
        float craterNoise = fbm3_4(dir * 8.0 + float3(0, 0, Time * 3.0));
        craters = -kickSurge * 0.04 * smoothstep(0.4, 0.8, craterNoise);
    }

    // Transient — surface rupture
    float rupture = 0.0;
    if (transient > 0.02) {
        rupture = transient * 0.02 * sin(lon * 8.0 + lat * 6.0 + Time * 5.0);
    }

    // Emitter influence — nearest emitter adds local displacement
    float emInfluence = 0.0;
    [loop] for (int i = 0; i < SE_NUM_OBJ; i++) {
        if (emit[i].active < 0.01) continue;
        float dist = length(dir - normalize(emit[i].worldPos));
        emInfluence += exp(-dist * dist * 20.0) * emit[i].intensity * 0.02;
    }

    return plates + ridges + detail + micro + breath + craters + rupture + emInfluence * silence;
}

// Planet SDF — sphere with audio-driven terrain displacement
float planetSDF(float3 p, SeEmitter emit[SE_NUM_OBJ], float bands[8], float beatPulse, float kickSurge,
                float transient, float crest, float thd, float silence)
{
    float r = length(p);
    float baseDist = r - PLANET_R;
    if (baseDist > 0.3) return baseDist;
    float h = terrainHeight(p, emit, bands, beatPulse, kickSurge, transient, crest, thd, silence);
    return baseDist - h;
}

// Surface normal via finite differences
float3 planetNormal(float3 p, SeEmitter emit[SE_NUM_OBJ], float bands[8], float beatPulse, float kickSurge,
                    float transient, float crest, float thd, float silence)
{
    float eps = 0.003;
    float2 h = float2(1.0, 0.0);
    float3 n = float3(0, 0, 0);
    n.x = planetSDF(p + eps * h.xyy, emit, bands, beatPulse, kickSurge, transient, crest, thd, silence)
        - planetSDF(p - eps * h.xyy, emit, bands, beatPulse, kickSurge, transient, crest, thd, silence);
    n.y = planetSDF(p + eps * h.yxy, emit, bands, beatPulse, kickSurge, transient, crest, thd, silence)
        - planetSDF(p - eps * h.yxy, emit, bands, beatPulse, kickSurge, transient, crest, thd, silence);
    n.z = planetSDF(p + eps * h.yyx, emit, bands, beatPulse, kickSurge, transient, crest, thd, silence)
        - planetSDF(p - eps * h.yyx, emit, bands, beatPulse, kickSurge, transient, crest, thd, silence);
    return normalize(n);
}

// Atmosphere density for volumetric raymarch
float atmosphereDensity(float3 p, float bands[8], float envelope, float thd,
                        float phaseCoh, float beatPulse, float silence)
{
    float r = length(p);
    float alt = r - PLANET_R;
    if (alt < 0.0 || alt > 1.5) return 0.0;

    float falloff = exp(-alt * 2.5);
    float clouds = fbm3_4(p * 3.0 + float3(0, Time * 0.1, 0)) * (0.3 + bands[2] * 0.2 + bands[3] * 0.15);
    clouds *= falloff;
    clouds *= (1.0 + phaseCoh * 0.3);

    float shimmer = fbm3_4(p * 8.0 + Time * 0.5) * (0.05 + bands[6] * 0.08 + bands[7] * 0.05);
    shimmer *= falloff;

    float turb = thd * fbm3_4(p * 6.0 + Time * 2.0) * 0.1 * falloff;
    float pulse = beatPulse * 0.05 * falloff;

    return (clouds + shimmer + turb + pulse) * envelope * silence;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    // ── DSP additive ──
    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();
    float phaseCorr = phaseCoherence();

    // ── Audio dynamics ──
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — VR head pose or desktop orbiting planet ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.6;
        float camAng = a.section * 0.5 + a.stereoBal * 0.15 + Time * 0.01 * a.motSpeed;
        float camHeight = 0.3 + a.stereoDiff * 0.1;
        float3 camPos = float3(cos(camAng) * (PLANET_R + 0.4), camHeight, sin(camAng) * (PLANET_R + 0.4));
        float3 camTarget = float3(cos(camAng + 0.3) * PLANET_R, 0, sin(camAng + 0.3) * PLANET_R);
        cam = seCamera(camPos, camTarget, FOV);
    }

    // ── Spatial encoder: SPHERICAL profile ──
    SeParams params = seParams(SE_PROFILE_SPHERICAL);
    params.widthScale = 2.0;
    params.heightScale = 2.0;
    params.depthScale = 3.0;
    params.jitterAmt = 0.08 + thd * 0.12;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.03, float3(0.002, 0.003, 0.008), -2.0, 0.0, 0.0);
    world.gridIntensity = 0.015;
    world.ambientLevel = 0.003;
    world.ambientColor = float3(0.005, 0.008, 0.015);
    seApplyWorldFog(emit, world);

    // ── Sun direction — section drives day/night ──
    float sunAz = a.section * PI + a.stereoBal * 0.5 + Time * 0.02 * a.motSpeed;
    float sunAlt = 0.3 + a.stereoDiff * 0.15 + sin(a.section * PI) * 0.2;
    float3 sunDir = normalize(float3(cos(sunAz) * cos(sunAlt), sin(sunAlt), sin(sunAz) * cos(sunAlt)));
    float dayNight = smoothstep(-0.3, 0.3, sunDir.y);
    float3 sunCol = lerp(float3(0.3, 0.25, 0.15), float3(1.0, 0.9, 0.7), dayNight);

    // ── Background — space sky + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    float3 nightSky = float3(0.002, 0.003, 0.008);
    float3 daySky = float3(0.01, 0.02, 0.04);
    col += lerp(nightSky, daySky, dayNight) * silence * 0.5;
    col += starfield(uv, a) * (1.0 - dayNight * 0.7) * 0.008;

    // ── Ray direction for SDF march ──
    float3 rd = normalize(cam.fwd + p.x * cam.right * cam.fov + p.y * cam.up * cam.fov);

    // Sun glow
    float sunDot = max(dot(rd, sunDir), 0.0);
    col += float3(1.0, 0.8, 0.5) * pow(sunDot, 200.0) * 0.15 * silence;
    col += float3(0.8, 0.6, 0.3) * pow(sunDot, 20.0) * 0.01 * silence;

    // ── SDF raymarch the planet ──
    float t = 0.05;
    float steps = 0.0;
    bool hit = false;

    [loop] for (int i = 0; i < MARCH_STEPS; i++) {
        float3 sp = cam.pos + rd * t;
        float d = planetSDF(sp, emit, bands, beatPulse, kickSurge, transientAmt, crest, thd, silence);
        steps += 1.0;
        if (d < 0.002) { hit = true; break; }
        t += d * 0.5;
        if (t > 10.0) break;
    }

    if (hit) {
        float3 hp = cam.pos + rd * t;
        float3 n = planetNormal(hp, emit, bands, beatPulse, kickSurge, transientAmt, crest, thd, silence);
        float3 vDir = normalize(cam.pos - hp);

        float alt = length(hp) - PLANET_R;

        // Color zones: deep craters → lowlands → highlands → peaks
        float3 deepCol = float3(0.02, 0.01, 0.03);
        float3 lowCol = lerp(a.brainCol * 0.3, a.brainCol2 * 0.4, smoothstep(-0.05, 0.02, alt));
        float3 highCol = lerp(a.brainCol2, a.brainCol3, smoothstep(0.02, 0.08, alt));
        float3 peakCol = hsv(a.hueBase + 0.1, 0.4 * a.satur, 1.0);

        float3 terrainCol = lerp(deepCol, lowCol, smoothstep(-0.08, -0.02, alt));
        terrainCol = lerp(terrainCol, highCol, smoothstep(0.0, 0.05, alt));
        terrainCol = lerp(terrainCol, peakCol, smoothstep(0.05, 0.1, alt));

        // Frequency-tinted coloring
        float3 freqTint = float3(0, 0, 0);
        [unroll] for (int b = 0; b < SE_N_BANDS; b++) {
            float bt = float(b) / float(SE_N_BANDS - 1);
            float bandZone = smoothstep(0.04, 0.0, abs(alt - lerp(-0.06, 0.08, bt)));
            float3 bc = hsv(a.hueBase + bt * a.hueRange, 0.5 * a.satur, 0.8);
            freqTint += bc * bands[b] * bandZone * 0.12;
        }
        terrainCol += freqTint * silence;

        // Lighting
        float sunAmt = max(dot(n, sunDir), 0.0);
        float3 ambient = lerp(float3(0.01, 0.01, 0.02), float3(0.1, 0.12, 0.15), dayNight);
        float spec = pow(max(dot(reflect(-sunDir, n), vDir), 0.0), 40.0) * smoothstep(0.0, -0.03, alt);
        float fres = pow(1.0 - max(dot(n, vDir), 0.0), 3.0);

        float3 lit = terrainCol * (ambient + sunCol * sunAmt);
        lit += sunCol * spec * 0.15;
        lit += a.brainCol * fres * 0.05 * sunAmt;

        float ao = 1.0 - steps / float(MARCH_STEPS) * 0.4;
        lit *= ao;
        lit *= (1.0 + lufs * 0.15);

        if (kickSurge > 0.01) {
            float impactGlow = kickSurge * smoothstep(0.03, -0.02, alt) * 0.12;
            lit += float3(1.0, 0.5, 0.2) * impactGlow * silence;
        }
        if (transientAmt > 0.02) {
            lit += float3(0.9, 0.8, 1.0) * transientAmt * 0.04 * silence;
        }

        col = lit;
    } else {
        // Volumetric atmosphere from outside
        float3 atmCol = float3(0, 0, 0);
        float transmittance = 1.0;
        float atmt = max(0.05, t - 0.5);
        float atmStep = 0.06;

        [loop] for (int j = 0; j < 12; j++) {
            float3 sp = cam.pos + rd * atmt;
            float ar = length(sp);
            float aalt = ar - PLANET_R;
            if (aalt < 0.0) break;
            if (aalt > 1.2) { atmt += atmStep; continue; }

            float density = atmosphereDensity(sp, bands, envelope, thd, phaseCoh, beatPulse, silence);
            density *= smoothstep(0.001, 0.02, density);

            if (density > 0.003) {
                float sunAmt = max(dot(normalize(sp), sunDir), 0.0);
                float3 cloudCol = lerp(float3(0.05, 0.05, 0.08), a.brainCol * 0.4 + sunCol * 0.3, sunAmt);
                cloudCol = lerp(cloudCol, a.brainCol2 * 0.5, smoothstep(0.3, 0.8, density));
                float sigma = density * 0.2 + 0.01;
                transmittance *= exp(-sigma * atmStep);
                atmCol += cloudCol * density * transmittance * (1.0 + lufs * 0.2);
            }
            atmt += atmStep;
        }
        col += atmCol * silence;

        // Aurora at poles
        if (bands[6] + bands[7] > 0.02) {
            float3 auroraPos = cam.pos + rd * 3.0;
            float auroraLat = abs(normalize(auroraPos).y);
            float auroraBand = exp(-pow((auroraLat - 0.8) * 10.0, 2.0));
            float auroraWave = sin(auroraPos.x * 5.0 + Time * 2.0) * cos(auroraPos.z * 4.0 + Time * 1.5);
            float auroraInt = (bands[6] + bands[7]) * auroraBand * (0.5 + auroraWave * 0.5) * phaseCoh * 0.12;
            col += a.brainCol2 * auroraInt * silence;
        }
    }

    // ── Emitter glow — depth-aware, VR or desktop ──
    if (VR_ACTIVE) {
        float3 headPos = float3(VRHeadPos.xyz);
        [loop] for (int j = 0; j < SE_NUM_OBJ; j++) {
            if (emit[j].active < 0.01 || emit[j].depth < 0.1) continue;
            col += seEmitGlowVR(p, emit[j], world, headPos, silence);
        }
    } else {
        [loop] for (int j = 0; j < SE_NUM_OBJ; j++) {
            if (emit[j].active < 0.01 || emit[j].depth < 0.1) continue;
            col += seEmitGlowDepth(p, emit[j], world, lufs, crest, beatPulse,
                                   a.beatPhase, kickSurge, transientAmt, silence);
        }
    }

    // ── L↔R links ──
    [loop] for (int lb = 0; lb < SE_N_BANDS; lb++) {
        col += seLinkLR(p, emit, lb, phaseCorr, phaseCoh, silence);
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Meteor trails — kick-driven ──
    if (kickSurge > 0.01) {
        float meteorAng = atan2(rd.z, rd.x);
        float meteorStreak = sin(meteorAng * 7.0 + Time * 20.0) * kickSurge * 0.015;
        col += float3(1.0, 0.6, 0.3) * abs(meteorStreak) * exp(-r * r * 0.3) * silence;
    }

    // ── Mode-specific overlays — subtle ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.012 * silence;
    col += a.brainCol3 * a.colorPulse * 0.012 * silence;
    col += a.brainCol2 * a.energy * 0.008 * silence;
    col += a.brainCol * a.punch * 0.008 * silence;
    col += a.brainCol * a.beatAnt * 0.006 * exp(-r * 2.0) * silence;

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02;

        // ── Active-emitter normalization — busy music doesn't stack brighter ──
    col *= sqrt(16.0 / seActiveCount(emit));
    // ── Soft tone mapping (Reinhard) — no hard clamp, preserves color ──
    col = softReinhard(col);

    col *= silence;

    return float4(col, 1.0);
}
