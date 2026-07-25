// Mode 47: Sonic Sphereworld — a living planet you stand on
// SDF raymarched planet with audio-driven terrain, volumetric atmosphere, meteor impacts.
// Bass = tectonic plates shifting (large terrain displacement).
// Mids = terrain morphing (ridges, valleys, surface structure).
// Highs = atmosphere shimmer, aurora, particle dust.
// Kick = meteor impacts with shockwaves cratering the surface.
// Transient = atmospheric rupture, aurora bursts.
// Beat = planetary pulse (breathing terrain).
// Section = day/night cycle (sun position, color palette shift).
// Stereo = sun position (L/R drives azimuth).
// LUFS = atmospheric density. Crest = terrain sharpness. THD = surface roughness.
// Phase = cloud coherence. Envelope = ambient glow.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define MARCH_STEPS 48
#define PLANET_R 1.5

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

// Audio-driven terrain height on planet surface
float terrainHeight(float3 p, float bands[8], float beatPulse, float kickSurge,
                    float transient, float crest, float thd, float silence)
{
    // Spherical coords from position
    float r = length(p);
    float3 dir = p / max(r, 0.001);
    float lat = asin(clamp(dir.y, -1.0, 1.0));
    float lon = atan2(dir.z, dir.x);

    // Bass — tectonic plates: large-scale continental displacement
    float plates = fbm3_4(dir * 2.0) * (0.08 + bands[0] * 0.12 + bands[1] * 0.06);
    plates *= silence;

    // Mids — mountain ridges and valleys
    float ridges = fbm3_4(dir * 5.0 + float3(lon * 2.0, lat * 2.0, 0)) * (0.04 + bands[2] * 0.05 + bands[3] * 0.03);
    ridges *= (1.0 + crest * 0.5);
    ridges *= silence;

    // High-mids — surface detail, canyons
    float detail = fbm3_4(dir * 12.0) * (0.015 + bands[4] * 0.02 + bands[5] * 0.015);
    detail *= silence;

    // Highs — fine detail, micro-roughness
    float micro = (hash3(dir * 50.0) - 0.5) * (0.005 + bands[6] * 0.008 + bands[7] * 0.005);
    micro *= (1.0 + thd * 0.5);
    micro *= silence;

    // Beat — planetary breathing
    float breath = beatPulse * 0.015 * sin(lat * 3.0 + lon * 2.0);

    // Kick — meteor crater depressions (negative displacement)
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

    return plates + ridges + detail + micro + breath + craters + rupture;
}

// Planet SDF — sphere with audio-driven terrain displacement
float planetSDF(float3 p, float bands[8], float beatPulse, float kickSurge,
                float transient, float crest, float thd, float silence)
{
    float r = length(p);
    float baseDist = r - PLANET_R;

    // Only displace near surface
    if (baseDist > 0.3) return baseDist;

    float h = terrainHeight(p, bands, beatPulse, kickSurge, transient, crest, thd, silence);
    return baseDist - h;
}

// Surface normal via finite differences
float3 planetNormal(float3 p, float bands[8], float beatPulse, float kickSurge,
                    float transient, float crest, float thd, float silence)
{
    float eps = 0.003;
    float3 n = float3(0, 0, 0);
    float2 h = float2(1.0, 0.0);
    n.x = planetSDF(p + eps * h.xyy, bands, beatPulse, kickSurge, transient, crest, thd, silence)
        - planetSDF(p - eps * h.xyy, bands, beatPulse, kickSurge, transient, crest, thd, silence);
    n.y = planetSDF(p + eps * h.yxy, bands, beatPulse, kickSurge, transient, crest, thd, silence)
        - planetSDF(p - eps * h.yxy, bands, beatPulse, kickSurge, transient, crest, thd, silence);
    n.z = planetSDF(p + eps * h.yyx, bands, beatPulse, kickSurge, transient, crest, thd, silence)
        - planetSDF(p - eps * h.yyx, bands, beatPulse, kickSurge, transient, crest, thd, silence);
    return normalize(n);
}

// Atmosphere density for volumetric raymarch
float atmosphereDensity(float3 p, float bands[8], float envelope, float thd,
                        float phaseCoh, float beatPulse, float silence)
{
    float r = length(p);
    float alt = r - PLANET_R;
    if (alt < 0.0 || alt > 1.5) return 0.0;

    // Exponential falloff
    float falloff = exp(-alt * 2.5);

    // Cloud layers — driven by mids + envelope
    float clouds = fbm3_4(p * 3.0 + float3(0, Time * 0.1, 0)) * (0.3 + bands[2] * 0.2 + bands[3] * 0.15);
    clouds *= falloff;
    clouds *= (1.0 + phaseCoh * 0.3); // phase coherence = cloud organization

    // High-band shimmer — atmospheric particles
    float shimmer = fbm3_4(p * 8.0 + Time * 0.5) * (0.05 + bands[6] * 0.08 + bands[7] * 0.05);
    shimmer *= falloff;

    // THD — turbulence
    float turb = thd * fbm3_4(p * 6.0 + Time * 2.0) * 0.1 * falloff;

    // Beat — atmospheric pulse
    float pulse = beatPulse * 0.05 * falloff;

    return (clouds + shimmer + turb + pulse) * envelope * silence;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    // Spectrum L/R — augment brain bands with stereo spectrum data
    float specL[8]; float specR[8];
    [unroll] for (int sb = 0; sb < 8; sb++) {
        specL[sb] = u_spectrum.SampleLevel(u_sampler, float2(bandFreq[sb], 0.166), 0).r;
        specR[sb] = u_spectrum.SampleLevel(u_sampler, float2(bandFreq[sb], 0.833), 0).r;
        bands[sb] = max(bands[sb], max(specL[sb], specR[sb]) * 0.5);
    }
    float panMod = (specL[0] + specL[1] - specR[0] - specR[1]) * 0.25;
    float dspBands[8] = { DspBand0, DspBand1, DspBand2, DspBand3, DspBand4, DspBand5, DspBand6, DspBand7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — standing on planet surface, looking at horizon ──
    float FOV = 0.6;
    // Section drives day/night — sun azimuth
    float sunAz = a.section * PI + a.stereoBal * 0.5 + panMod * 0.3 + Time * 0.02 * a.motSpeed;
    float sunAlt = 0.3 + a.stereoDiff * 0.15 + sin(a.section * PI) * 0.2;
    float3 sunDir = normalize(float3(cos(sunAz) * cos(sunAlt), sin(sunAlt), sin(sunAz) * cos(sunAlt)));

    // Camera orbits slowly, section-driven
    float camAng = a.section * 0.5 + a.stereoBal * 0.15 + Time * 0.01 * a.motSpeed;
    float camHeight = 0.3 + a.stereoDiff * 0.1;
    float3 camPos = float3(cos(camAng) * (PLANET_R + 0.4), camHeight, sin(camAng) * (PLANET_R + 0.4));
    float3 camTarget = float3(cos(camAng + 0.3) * PLANET_R, 0, sin(camAng + 0.3) * PLANET_R);
    float3 rd = cameraRay(camPos, camTarget, float2(-p.x, -p.y), FOV);

    // ── Background — space sky with stars ──
    float dayNight = smoothstep(-0.3, 0.3, sunDir.y); // 0=night, 1=day
    float3 nightSky = float3(0.002, 0.003, 0.008);
    float3 daySky = float3(0.01, 0.02, 0.04);
    float3 col = lerp(nightSky, daySky, dayNight) * silence;
    col += starfield(uv, a) * (1.0 - dayNight * 0.7) * 0.01;

    // Sun glow
    float sunDot = max(dot(rd, sunDir), 0.0);
    col += float3(1.0, 0.8, 0.5) * pow(sunDot, 200.0) * 0.5 * silence;
    col += float3(0.8, 0.6, 0.3) * pow(sunDot, 20.0) * 0.03 * silence;

    // ── SDF raymarch the planet ──
    float t = 0.05;
    float marchGlow = 0.0;
    float steps = 0.0;
    bool hit = false;

    [loop] for (int i = 0; i < MARCH_STEPS; i++) {
        float3 sp = camPos + rd * t;
        float d = planetSDF(sp, bands, beatPulse, kickSurge, transientAmt, crest, thd, silence);
        marchGlow += 0.01 / (1.0 + d * d * 50.0);
        steps += 1.0;
        if (d < 0.002) { hit = true; break; }
        t += d * 0.5;
        if (t > 10.0) break;
    }

    // Sun color — defined before branch so both hit/miss can use it
    float3 sunCol = lerp(float3(0.3, 0.25, 0.15), float3(1.0, 0.9, 0.7), dayNight);

    if (hit) {
        float3 hp = camPos + rd * t;
        float3 n = planetNormal(hp, bands, beatPulse, kickSurge, transientAmt, crest, thd, silence);
        float3 vDir = normalize(camPos - hp);

        // ── Terrain coloring — altitude + latitude based ──
        float lat = asin(clamp(n.y, -1.0, 1.0));
        float alt = length(hp) - PLANET_R;

        // Color zones: deep craters → lowlands → highlands → peaks
        float3 deepCol = float3(0.02, 0.01, 0.03);          // crater basins
        float3 lowCol = lerp(a.brainCol * 0.3, a.brainCol2 * 0.4, smoothstep(-0.05, 0.02, alt));  // lowlands
        float3 highCol = lerp(a.brainCol2, a.brainCol3, smoothstep(0.02, 0.08, alt));   // highlands
        float3 peakCol = hsv(a.hueBase + 0.1, 0.4 * a.satur, 1.0);                       // peaks

        float3 terrainCol = lerp(deepCol, lowCol, smoothstep(-0.08, -0.02, alt));
        terrainCol = lerp(terrainCol, highCol, smoothstep(0.0, 0.05, alt));
        terrainCol = lerp(terrainCol, peakCol, smoothstep(0.05, 0.1, alt));

        // Frequency-tinted coloring — each band adds color to its region
        float3 freqTint = float3(0, 0, 0);
        [unroll] for (int b = 0; b < N_COMP; b++) {
            float bt = float(b) / float(N_COMP - 1);
            float bandZone = smoothstep(0.04, 0.0, abs(alt - lerp(-0.06, 0.08, bt)));
            float3 bc = hsv(a.hueBase + bt * a.hueRange, 0.5 * a.satur, 0.8);
            freqTint += bc * bands[b] * bandZone * 0.15;
        }
        terrainCol += freqTint * silence;

        // ── Lighting — sun + ambient + bounce ──
        float sunAmt = max(dot(n, sunDir), 0.0);

        // Ambient — sky color bounce
        float3 ambient = lerp(float3(0.01, 0.01, 0.02), float3(0.1, 0.12, 0.15), dayNight);

        // Specular — wet/oily surface at low altitudes
        float spec = pow(max(dot(reflect(-sunDir, n), vDir), 0.0), 40.0) * smoothstep(0.0, -0.03, alt);

        // Fresnel — atmosphere edge glow
        float fres = pow(1.0 - max(dot(n, vDir), 0.0), 3.0);

        float3 lit = terrainCol * (ambient + sunCol * sunAmt);
        lit += sunCol * spec * 0.3;
        lit += a.brainCol * fres * 0.1 * sunAmt;

        // AO from march steps
        float ao = 1.0 - steps / float(MARCH_STEPS) * 0.4;
        lit *= ao;

        // LUFS — emission boost
        lit *= (1.0 + lufs * 0.15);

        // Kick — impact glow at crater sites
        if (kickSurge > 0.01) {
            float impactGlow = kickSurge * smoothstep(0.03, -0.02, alt) * 0.3;
            lit += float3(1.0, 0.5, 0.2) * impactGlow * silence;
        }

        // Transient — surface flash
        if (transientAmt > 0.02) {
            lit += float3(0.9, 0.8, 1.0) * transientAmt * 0.04 * silence;
        }

        col = lit;
    } else {
        // ── Volumetric atmosphere from outside ──
        float3 atmCol = float3(0, 0, 0);
        float transmittance = 1.0;
        float atmt = max(0.05, t - 0.5);
        float atmStep = 0.06;

        [loop] for (int j = 0; j < 12; j++) {
            float3 sp = camPos + rd * atmt;
            float ar = length(sp);
            float aalt = ar - PLANET_R;

            if (aalt < 0.0) break;
            if (aalt > 1.2) { atmt += atmStep; continue; }

            float density = atmosphereDensity(sp, bands, envelope, thd, phaseCoh, beatPulse, silence);
            density *= smoothstep(0.001, 0.02, density);

            if (density > 0.003) {
                // Atmosphere color — sun-lit clouds
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

        // ── Aurora at poles — driven by highs + phase ──
        if (bands[6] + bands[7] > 0.02) {
            float3 auroraPos = camPos + rd * 3.0;
            float auroraLat = abs(normalize(auroraPos).y);
            float auroraBand = exp(-pow((auroraLat - 0.8) * 10.0, 2.0));
            float auroraWave = sin(auroraPos.x * 5.0 + Time * 2.0) * cos(auroraPos.z * 4.0 + Time * 1.5);
            float auroraInt = (bands[6] + bands[7]) * auroraBand * (0.5 + auroraWave * 0.5) * phaseCoh * 0.15;
            col += a.brainCol2 * auroraInt * silence;
        }
    }

    // ── Meteor trails — kick-driven streaks across sky ──
    if (kickSurge > 0.01) {
        float meteorAng = atan2(rd.z, rd.x);
        float meteorStreak = sin(meteorAng * 7.0 + Time * 20.0) * kickSurge * 0.02;
        col += float3(1.0, 0.6, 0.3) * abs(meteorStreak) * exp(-r * r * 0.3) * silence;
    }

    // ── Beat ring — planetary pulse on horizon ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.015 * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.015 * silence;

    // ── Energy + punch ──
    col += a.brainCol2 * a.energy * 0.01 * silence;
    col += a.brainCol * a.punch * 0.01 * silence;

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── HDR limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
