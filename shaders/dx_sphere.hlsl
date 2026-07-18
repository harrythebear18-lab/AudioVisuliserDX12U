// Mode 6: Spectrum Resonator — volumetric frequency-displaced energy core
// Raymarched sphere where surface displacement = directional spectrum sampling
// 16-band spherical harmonic waves, internal core glow, fresnel rim
// Kick = radial shockwave, beat = emission pulse, transients = surface crackles
// Volumetric aura, PBR-style lighting, starfield, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define RESONATOR_BANDS 16

float sphereSDF(float3 p, AudioData a, float time) {
    float3 dir = normalize(p);
    float theta = atan2(dir.x, dir.z) / 6.28318 + 0.5;
    float phi = asin(clamp(dir.y, -1.0, 1.0)) / 3.14159 + 0.5;

    // Directional spectrum sampling — theta = frequency, phi = L/R blend
    float specL = u_spectrum.SampleLevel(u_sampler, float2(theta, 0.0), 0).r;
    float specR = u_spectrum.SampleLevel(u_sampler, float2(theta, 1.0), 0).r;
    float specC = u_spectrum.SampleLevel(u_sampler, float2(theta, 0.5), 0).r;
    float specVal = lerp(specL, specR, phi);
    specVal = max(specVal, specC * 0.5);

    float baseR = 0.7 + a.profBass * 0.12 + a.envelope * 0.04;
    float disp = specVal * 0.2 * a.barScale;

    // Spherical harmonic waves — 4 bands modulated by spectrum
    [unroll] for (int bi = 0; bi < 4; bi++) {
        float bandFreq = float(bi + 1) * 2.0;
        float bandPhase = time * (1.0 + bi * 0.3) * a.motSpeed;
        float bandAmp = u_spectrum.SampleLevel(u_sampler, float2(float(bi) / 16.0, 0.5), 0).r;
        disp += sin(theta * 6.28318 * bandFreq + bandPhase) * cos(phi * 3.14159 * bandFreq) * bandAmp * 0.04;
    }

    // Transient crackles
    disp += a.transient * 0.02 * sin(theta * 6.28318 * 16.0 + time * 12.0);

    // Kick shockwave — radial bulge traveling outward
    float kickR = a.kick * 0.6 * a.kickConf;
    float kickDist = length(p);
    disp += exp(-abs(kickDist - kickR) * 8.0) * a.kick * 0.08;

    return sdSphere(p, baseR + disp);
}

float3 calcNormal(float3 p, AudioData a, float time) {
    float eps = 0.001;
    return normalize(float3(
        sphereSDF(p + float3(eps,0,0), a, time) - sphereSDF(p - float3(eps,0,0), a, time),
        sphereSDF(p + float3(0,eps,0), a, time) - sphereSDF(p - float3(0,eps,0), a, time),
        sphereSDF(p + float3(0,0,eps), a, time) - sphereSDF(p - float3(0,0,eps), a, time)
    ));
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Background ──
    float3 col = float3(0.008, 0.006, 0.015) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.3;

    // Volumetric aura — brain-colored glow around sphere
    float auraGlow = exp(-r * r * 0.8) * (0.1 + a.bloom * 0.12 * a.bloomActive + a.envelope * 0.04);
    col += a.brainCol2 * auraGlow * (1.0 - a.isSilent);
    float innerAura = exp(-r * r * 2.5) * (0.05 + a.beat * 0.06 * a.tempoConf);
    col += a.brainCol * innerAura * (1.0 - a.isSilent);

    // Camera — slow stereo-driven orbit
    float camAng = a.stereoBal * 0.3 + Time * 0.05 * a.motSpeed;
    float camDist = 3.0 + a.profBass * 0.2;
    float3 camPos = float3(sin(camAng) * camDist, 0.3 + a.stereoDiff * 0.15, cos(camAng) * camDist);
    float3 rd = cameraRay(camPos, float3(0, 0, 0), p, 1.0);

    // Raymarch
    float t = 0.05;
    float marchGlow = 0.0;
    float steps = 0.0;
    bool hit = false;

    [loop] for (int i = 0; i < 48; i++) {
        float3 sp = camPos + rd * t;
        float d = sphereSDF(sp, a, Time);
        marchGlow += 0.015 / (1.0 + d * d * 30.0);
        steps += 1.0;
        if (d < 0.001) { hit = true; break; }
        t += d * 0.5;
        if (t > 8.0) break;
    }
    float ao = 1.0 - steps / 48.0 * 0.4;

    if (hit) {
        float3 hp = camPos + rd * t;
        float3 n = calcNormal(hp, a, Time);

        // Directional spectrum at hit point
        float3 dir = normalize(hp);
        float theta = atan2(dir.x, dir.z) / 6.28318 + 0.5;
        float phi = asin(clamp(dir.y, -1.0, 1.0)) / 3.14159 + 0.5;
        float specL = u_spectrum.SampleLevel(u_sampler, float2(theta, 0.0), 0).r;
        float specR = u_spectrum.SampleLevel(u_sampler, float2(theta, 1.0), 0).r;
        float specC = u_spectrum.SampleLevel(u_sampler, float2(theta, 0.5), 0).r;
        float specVal = lerp(specL, specR, phi);
        specVal = max(specVal, specC * 0.5);

        // 3-light setup
        float3 lDir1 = normalize(float3(0.5, 1.0, 0.3));
        float3 lDir2 = normalize(float3(-1.0 + a.stereoBal, 0.5, 0.2));
        float3 lDir3 = normalize(float3(0.0, -0.5, 0.8));
        float diff1 = max(dot(n, lDir1), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
        float diff3 = max(dot(n, lDir3), 0.0) * 0.2;
        float spec = pow(max(dot(reflect(-lDir1, n), -rd), 0.0), 96.0);
        float fres = pow(1.0 - max(dot(n, -rd), 0.0), 4.0 + a.overall * 3.0);

        // Surface color — frequency-position driven
        float hue = a.hueBase + theta * a.hueRange + phi * 0.1 + a.section * 0.03;
        float3 baseCol = hsv(hue, 0.7 * a.satur, 0.5 + specVal * 0.3);
        float3 coreCol = a.brainCol * (0.6 + a.brightness * 0.4);

        float3 litCol = baseCol * (diff1 + diff2 + diff3) * (0.5 + a.brightness * 0.4);
        litCol += float3(1.0, 0.95, 0.8) * spec * 0.5 * a.dynLight * a.dynActive;
        litCol = lerp(litCol, coreCol, fres * 0.4);
        litCol += a.brainCol2 * fres * (0.5 + specVal * 0.3) * a.bloomActive;

        // Spectrum emission
        float emit = specVal * 0.3 * a.envelope;
        litCol += hsv(hue, 0.5 * a.satur, emit) * (1.0 - a.isSilent);

        // Beat emission
        float beatEmit = a.beat * 0.25 * a.tempoConf * fres;
        litCol += hsv(a.hueCenter, 0.4, beatEmit) * (1.0 - a.isSilent);

        // Kick flash
        float kickFlash = exp(-length(hp) * 3.0) * a.kick * 0.2 * a.kickConf;
        litCol += a.brainCol2 * kickFlash * (1.0 - a.isSilent);

        litCol *= ao * (0.4 + a.ambient * 0.6) * a.ambActive;
        col = blendScreen(col, litCol);
    }

    // March glow — volumetric
    col += a.brainCol2 * marchGlow * 0.06 * a.bloomActive * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.4;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
