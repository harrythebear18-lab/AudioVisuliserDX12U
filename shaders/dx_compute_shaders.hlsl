// Mode: Spectrum Vortex — 3D raymarched volumetric tornado of frequency energy
// 8 frequency bands map to different heights in the vortex column
// Bass = vortex width + rotation speed, treble = turbulence + fine detail
// Volumetric raymarching through swirling density field, spectrum-driven
// Beat = expansion pulse, kick = intensification, transients = debris swirl
// Camera orbit, lightning arcs on transients, brain-colored, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define VORTEX_BANDS 8

// Vortex density field — 3D swirling column
float vortexDensity(float3 p, AudioData a, float time) {
    float r = length(p.xz);
    float ang = atan2(p.z, p.x);
    float h = p.y;

    // Vortex spans -1.5 to +1.5
    if (abs(h) > 1.8) return 0.0;

    // Map height to frequency band — bottom = bass, top = treble
    float hNorm = saturate((h + 1.5) / 3.0);

    // Sample spectrum for this height
    float specVal = u_spectrum.SampleLevel(u_sampler, float2(hNorm, 0.5), 0).r;
    float specL = u_spectrum.SampleLevel(u_sampler, float2(hNorm, 0.0), 0).r;
    float specR = u_spectrum.SampleLevel(u_sampler, float2(hNorm, 1.0), 0).r;
    specVal = max(max(specVal, specL), specR);

    // Vortex radius — narrows at top and bottom, widest in middle
    float baseR = 0.5 * (1.0 - abs(hNorm - 0.4) * 0.4);
    baseR += a.profBass * 0.15 * (1.0 - hNorm);
    baseR += specVal * 0.25 * a.barScale;
    baseR += a.kick * 0.12 * a.kickConf;

    // Rotation — faster at top, speed driven by treble
    float rotSpeed = (1.0 + hNorm * 2.0) * (1.0 + a.profTreb * 2.0) * a.motSpeed;
    float twistAng = ang + time * rotSpeed + h * 3.0;

    // Swirl — radial offset based on twisted angle
    float2 swirl = float2(cos(twistAng), sin(twistAng)) * baseR;
    float swirlR = length(p.xz - swirl);

    // Core density — Gaussian falloff from swirl center
    float density = exp(-swirlR * swirlR * 10.0);
    density *= (0.25 + specVal * 0.6);

    // Turbulence — fbm noise warped by rotation
    float3 turbPos = p * 3.0 + float3(cos(twistAng), 0, sin(twistAng)) * 2.0;
    turbPos.y += time * 2.0 * a.motSpeed;
    float turb = fbm3_4(turbPos) * 0.25;
    density += turb * specVal * 0.3;

    // Transient debris
    density += a.transient * fbm3_4(p * 8.0 + time * 5.0) * 0.1;

    // Beat expansion
    density += a.beat * 0.06 * a.tempoConf * exp(-swirlR * swirlR * 5.0);

    // Vertical falloff
    density *= smoothstep(1.8, 1.2, abs(h)) * smoothstep(-1.8, -1.4, h);

    return max(density, 0.0);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Background — deep storm sky ──
    float3 col = float3(0.004, 0.003, 0.01) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.25;

    // Distant nebula
    float nebula = fbm2_4(p * 1.5 + Time * 0.02 * a.motSpeed);
    col += a.brainCol * nebula * 0.02 * a.ambient * a.ambActive * (1.0 - a.isSilent);

    // ── Camera — orbiting the vortex ──
    float camAng = a.stereoBal * 0.3 + Time * 0.04 * a.motSpeed;
    float camDist = 4.5 + a.profBass * 0.3;
    float3 camPos = float3(sin(camAng) * camDist, 0.5 + a.stereoDiff * 0.2, cos(camAng) * camDist);
    float3 rd = cameraRay(camPos, float3(0, 0, 0), p, 1.0);

    // ── Volumetric raymarching through vortex ──
    float t = 0.05;
    float3 totalGlow = float3(0.0, 0.0, 0.0);
    float totalDensity = 0.0;

    [loop] for (int i = 0; i < 64; i++) {
        float3 sp = camPos + rd * t;
        float dens = vortexDensity(sp, a, Time);

        if (dens > 0.01) {
            float hNorm = saturate((sp.y + 1.5) / 3.0);
            float specVal = u_spectrum.SampleLevel(u_sampler, float2(hNorm, 0.5), 0).r;

            // Color by height = frequency position
            float hue = a.hueBase + hNorm * a.hueRange;
            float3 bandCol = lerp(a.brainCol, a.brainCol2, hNorm);
            bandCol = lerp(bandCol, hsv(hue, 0.7 * a.satur, 0.8), 0.4);

            float bright = dens * (0.3 + a.envelope * 0.5) * (0.4 + a.brightness * 0.4);
            totalGlow += bandCol * bright * 0.03;
            totalDensity += dens * 0.03;

            // Hot core highlights
            float coreGlow = smoothstep(0.5, 0.9, dens) * 0.015;
            totalGlow += float3(0.9, 0.95, 1.0) * coreGlow;
        }

        t += 0.08;
        if (t > 8.0) break;
    }

    col += totalGlow * (1.0 - a.isSilent);

    // ── Vortex core — tight bright center ──
    float coreGlow = exp(-r * r * 15.0) * (0.06 + a.profBass * 0.08 + a.b0 * 0.04);
    col += a.brainCol * coreGlow * (1.0 - a.isSilent);

    // ── Lightning arcs — on transient, crackling through vortex ──
    if (a.transient > 0.3) {
        float arcSeed = floor(Time * 20.0);
        float2 arcStart = float2(hash11(arcSeed) * 0.4 - 0.2, hash11(arcSeed * 1.7) * 1.6 - 0.8);
        float2 arcEnd = float2(hash11(arcSeed * 2.3) * 0.4 - 0.2, hash11(arcSeed * 3.1) * 1.6 - 0.8);
        float2 arcDir = arcEnd - arcStart;
        float arcLen = length(arcDir);
        if (arcLen > 0.01) {
            float2 arcNorm = arcDir / arcLen;
            float arcProj = clamp(dot(p - arcStart, arcNorm), 0.0, arcLen);
            float2 arcClosest = arcStart + arcNorm * arcProj;
            float arcDist = length(p - arcClosest);
            float jagged = sin(arcProj * 30.0 + arcSeed * 10.0) * 0.02;
            arcDist += abs(jagged);
            float arcGlow = exp(-arcDist * arcDist * 1000.0) * a.transient * 0.2;
            col += float3(0.7, 0.85, 1.0) * arcGlow * (1.0 - a.isSilent);
        }
    }

    // ── Kick — ground impact flash ──
    float kickFlash = exp(-length(p - float2(0, -0.8)) * length(p - float2(0, -0.8)) * 6.0) * a.kick * 0.08 * a.kickConf;
    col += a.brainCol2 * kickFlash * (1.0 - a.isSilent);

    // ── Beat — vortex pulse ring ──
    float beatRing = exp(-abs(r - a.beat * 0.5 * a.tempoConf) * 25.0) * a.beat * 0.05 * a.tempoConf;
    col += a.brainCol * beatRing * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.25;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
