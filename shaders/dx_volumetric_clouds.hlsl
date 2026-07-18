// Mode 11: Volumetric Clouds — 3D volumetric cloud field with lightning
// Sky gradient, brain-colored clouds with sun lighting, lightning on transients
// God rays through gaps, wind driven by BPM, starfield, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

float cloudDensity(float2 p, float time, AudioData a, float depth) {
    float2 wind = float2(time * 0.05 * (a.bpm > 1.0 ? a.bpm / 120.0 : 0.5) * a.motSpeed, 0.0);
    float2 cloudUV = p * (1.5 + depth * 0.5) + wind * (1.0 - depth * 0.3);
    float density = fbm2_4(cloudUV);
    density = smoothstep(0.3, 0.7, density);
    density *= (0.4 + a.profBass * 0.4 + a.envelope * 0.2);
    density *= (1.0 - a.profTreb * 0.2);
    density *= (1.0 - depth * 0.3);
    return density;
}

float lightningBolt(float2 p, float2 a2, float2 b2, float time, float seed) {
    float2 dir = b2 - a2;
    float len = length(dir);
    if (len < 0.001) return 0.0;
    float2 ndir = dir / len;
    float2 perp = float2(-ndir.y, ndir.x);
    float proj = clamp(dot(p - a2, ndir), 0.0, len);
    float perpDist = abs(dot(p - a2, perp));
    perpDist += sin(proj * 15.0 + seed * 10.0) * 0.02 + sin(proj * 30.0 + seed * 20.0) * 0.01;
    perpDist *= sin(time * 20.0);
    return exp(-perpDist * perpDist * 800.0);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // Sky gradient — brain-driven colors
    float skyFrac = clamp(uv.y, 0.0, 1.0);
    float3 skyTop = a.brainCol * 0.4;
    float3 skyBot = a.brainCol2 * 0.3;
    float3 col = lerp(skyTop, skyBot, skyFrac) * 0.6 * (1.0 - a.isSilent * 0.98);

    col += starfield(uv, a) * 0.3;
    col += godRays(p, r, a) * 0.2;

    float2 sunDir = normalize(float2(0.3, 0.8));
    float3 sunCol = hsv(a.hueCenter, 0.4 * a.satur, 1.0) * (0.6 + a.brightness * 0.4);

    // Cloud layers
    float totalDensity = 0.0;
    float3 cloudCol = float3(0, 0, 0);

    [unroll] for (int ci = 0; ci < 4; ci++) {
        float depth = ci / 3.0;
        float density = cloudDensity(p, Time, a, depth);
        if (density > 0.01) {
            float2 cloudUV = p * (1.5 + depth * 0.5);
            float2 wind = float2(Time * 0.05 * a.motSpeed, 0.0);
            float lit = fbm2_4(cloudUV + wind + sunDir * 0.3);
            float shadowed = fbm2_4(cloudUV + wind - sunDir * 0.3);
            float scatter = clamp(lit * 0.7 - shadowed * 0.3, 0.0, 1.0);
            // Cloud color: brain-colored when lit, dark when shadowed
            float3 layerCol = lerp(a.brainCol * 0.3, sunCol * 0.9, scatter);
            layerCol *= (1.0 - depth * 0.2);
            cloudCol += layerCol * density * 0.5;
            totalDensity += density;
        }
    }

    float cloudBlend = saturate(totalDensity * 0.8);
    col = lerp(col, cloudCol, cloudBlend) * (1.0 - a.isSilent * 0.98);

    // Sun glow through cloud gaps
    float gapGlow = smoothstep(0.3, 0.0, totalDensity) * a.brightness * 0.08;
    col += sunCol * gapGlow * (1.0 - a.isSilent);

    // Lightning on transients — brain secondary colored bolts
    if (a.transient > 0.3) {
        float lightTime = Time * 10.0;
        float2 b1A = float2(sin(lightTime * 0.7) * 1.5, 1.0);
        float2 b1B = float2(cos(lightTime * 0.5) * 0.5, -0.3);
        float2 b2A = float2(sin(lightTime * 0.9 + 2.0) * 1.5, 1.0);
        float2 b2B = float2(cos(lightTime * 0.6 + 1.0) * 0.5, -0.3);
        float b1 = lightningBolt(p, b1A, b1B, Time, 1.0);
        float b2 = lightningBolt(p, b2A, b2B, Time, 2.0);
        float lightning = (b1 + b2) * a.transient * a.beam * 0.6 * a.beamActive;
        col += a.brainCol2 * lightning * (1.0 - a.isSilent);
        float flash = a.transient * 0.1 * a.beamActive;
        col += float3(flash, flash, flash * 1.2) * (1.0 - a.isSilent);
    }

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.4;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
