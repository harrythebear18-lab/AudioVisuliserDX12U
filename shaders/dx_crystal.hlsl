// Mode: Spectrum Black Hole — gravitational lensing + spectrum-driven accretion disk
// Photon sphere ring, warped starfield, accretion disk with frequency bars spiraling inward
// Bass = event horizon size, mid = disk temperature, treble = relativistic jets
// Beat = photon ring pulse, kick = gravitational wave, transients = matter spiraling
// Raymarched disk + analytical lensing, brain-colored, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

// Accretion disk density — spectrum bars spiraling around the black hole
float diskDensity(float3 p, AudioData a, float time) {
    float r = length(p.xz);
    float ang = atan2(p.z, p.x);
    float h = p.y;

    // Event horizon — bass-driven
    float eh = 0.3 + a.profBass * 0.08 + a.b0 * 0.04;
    // Innermost stable orbit
    float iso = eh * 1.5;

    // Disk lives between ISCO and outer edge
    float outerR = 2.5 + a.envelope * 0.3;
    if (r < iso || r > outerR) return 0.0;

    // Disk thickness — thin, flares slightly at edges
    float diskThick = 0.05 + 0.03 * (1.0 - smoothstep(iso, outerR, r));
    if (abs(h) > diskThick * 3.0) return 0.0;

    // Spiral pattern — spectrum bars wind around
    float spiralAng = ang + r * 2.5 - time * 0.5 * a.motSpeed;

    // Map spiral angle to spectrum position
    float specU = saturate((sin(spiralAng) + 1.0) * 0.5);
    float specVal = u_spectrum.SampleLevel(u_sampler, float2(specU, 0.5), 0).r;
    float specL = u_spectrum.SampleLevel(u_sampler, float2(specU, 0.0), 0).r;
    float specR = u_spectrum.SampleLevel(u_sampler, float2(specU, 1.0), 0).r;
    specVal = max(max(specVal, specL), specR);

    // Base disk density — Gaussian vertical profile
    float vertProfile = exp(-h * h / (diskThick * diskThick));
    float radialProfile = smoothstep(iso, iso + 0.3, r) * smoothstep(outerR, outerR - 0.5, r);

    // Density = spectrum amplitude * geometry
    float density = vertProfile * radialProfile * (0.2 + specVal * 0.5 * a.barScale);

    // Temperature — hotter inner disk (Doppler beaming: approaching side brighter)
    float dopplerSide = cos(ang + time * 0.3 * a.motSpeed);
    density *= (0.6 + 0.4 * dopplerSide);

    // Turbulence
    float3 turbPos = p * 5.0 + float3(time * 2.0, 0, time * 1.5);
    density += fbm3_4(turbPos) * 0.08 * radialProfile * vertProfile;

    // Kick — gravitational wave compresses disk
    density += a.kick * 0.06 * a.kickConf * exp(-(r - iso) * 3.0) * vertProfile;

    // Transient — matter spiraling inward
    density += a.transient * 0.04 * exp(-h * h * 20.0) * smoothstep(outerR, iso, r);

    return max(density, 0.0);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Event horizon size ──
    float eh = 0.3 + a.profBass * 0.08 + a.b0 * 0.04;
    float photonR = eh * 1.5;

    // ── Camera — orbiting, slightly above disk plane ──
    float camAng = a.stereoBal * 0.4 + Time * 0.03 * a.motSpeed;
    float camDist = 4.0 + a.profBass * 0.2;
    float3 camPos = float3(sin(camAng) * camDist, 1.2 + a.stereoDiff * 0.15, cos(camAng) * camDist);
    float3 camTarget = float3(0, 0, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(fwd + p.x * right + p.y * up);

    // ── Gravitational lensing — warp background stars near black hole ──
    float2 lensUV = uv;
    float2 lensDir = normalize(uv - 0.5);
    float lensDist = length(uv - 0.5);
    float lensStrength = eh * 0.15 / max(lensDist * lensDist, 0.005);
    lensUV = uv - lensDir * lensStrength;

    // ── Background — warped starfield ──
    float3 col = float3(0.002, 0.001, 0.006) * (1.0 - a.isSilent * 0.98);
    col += starfield(lensUV, a) * 0.5;

    // Distant nebula
    float nebula = fbm2_4(p * 1.0 + Time * 0.01 * a.motSpeed);
    col += a.brainCol * nebula * 0.015 * a.ambient * a.ambActive * (1.0 - a.isSilent);

    // ── Event horizon — black sphere (occludes background) ──
    // Project event horizon onto screen
    float ehScreenR = eh * camDist / dot(float3(0, 0, 0) - camPos, fwd);
    float ehScreenDist = length(p);
    if (ehScreenDist < ehScreenR) {
        // Inside event horizon — pure black
        col = float3(0.0, 0.0, 0.0);
    } else {
        // Photon sphere — bright ring at 1.5x event horizon
        float photonScreenR = photonR * camDist / dot(float3(0, 0, 0) - camPos, fwd);
        float photonRing = exp(-abs(ehScreenDist - photonScreenR) * 200.0);
        float ringBright = (0.15 + a.beat * 0.1 * a.tempoConf) * (1.0 + a.envelope * 0.3);
        col += float3(1.0, 0.85, 0.6) * photonRing * ringBright * (1.0 - a.isSilent);

        // Secondary photon ring — thinner, further out
        float photon2R = photonScreenR * 1.15;
        float photon2 = exp(-abs(ehScreenDist - photon2R) * 400.0);
        col += float3(0.9, 0.7, 0.4) * photon2 * 0.06 * (1.0 - a.isSilent);
    }

    // ── Volumetric raymarch accretion disk ──
    float t = 0.05;
    float3 totalGlow = float3(0.0, 0.0, 0.0);

    [loop] for (int i = 0; i < 48; i++) {
        float3 sp = camPos + rd * t;
        float dens = diskDensity(sp, a, Time);

        if (dens > 0.005) {
            // Temperature color — inner = white-hot, outer = brain-colored
            float diskR = length(sp.xz);
            float tempFrac = smoothstep(2.5, 0.4, diskR); // 1=hot inner, 0=cool outer

            float3 hotCol = float3(1.0, 0.9, 0.7);
            float3 coolCol = lerp(a.brainCol, a.brainCol2, diskR * 0.3);
            float3 diskCol = lerp(coolCol, hotCol, tempFrac);

            // Spectrum tinting
            float specU = saturate((sin(atan2(sp.z, sp.x) + diskR * 2.5 - Time * 0.5) + 1.0) * 0.5);
            float hue = a.hueBase + specU * a.hueRange;
            diskCol = lerp(diskCol, hsv(hue, 0.5 * a.satur, 0.8), 0.2);

            // Doppler beaming — one side brighter
            float doppler = 0.5 + 0.5 * cos(atan2(sp.z, sp.x) + Time * 0.3 * a.motSpeed);
            float bright = dens * (0.4 + a.envelope * 0.3) * (0.5 + doppler * 0.5) * (0.3 + a.brightness * 0.4);

            totalGlow += diskCol * bright * 0.04;
        }

        t += 0.08;
        if (t > 6.0) break;
    }

    col += totalGlow * (1.0 - a.isSilent);

    // ── Relativistic jets — treble-driven, perpendicular to disk ──
    float jetIntensity = a.profTreb * 0.15 + a.b7 * 0.08;
    float jetDist = abs(p.x) + 0.1;
    float jetGlow = exp(-jetDist * jetDist * 30.0) * jetIntensity;
    col += a.brainCol2 * jetGlow * (1.0 - a.isSilent);

    // ── Kick — gravitational wave ripple ──
    float gwRipple = sin(r * 20.0 - Time * 15.0) * a.kick * 0.03 * a.kickConf;
    col += a.brainCol * gwRipple * exp(-r * 2.0) * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.2;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
