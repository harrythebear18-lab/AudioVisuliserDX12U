// Mode 9: Spectrum Singularity — gravitational lensing black hole with accretion disk
// Accretion disk = spectrum bars orbiting at relativistic speeds, frequency-driven brightness
// Photon ring on beat, gravitational lensing distorts starfield, kick = gravitational wave
// Relativistic jets on transients, event horizon size = bass energy, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define DISK_BINS 64

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float ang = atan2(p.y, p.x);

    // ── Event horizon — radius driven by bass ──
    float ehR = 0.15 + a.profBass * 0.08 + a.b0 * 0.05;

    // ── Gravitational lensing distortion ──
    // Bend light around the black hole — sample background at distorted position
    float lensStrength = ehR * ehR / max(r * r, 0.001);
    float2 lensDir = normalize(p) * lensStrength * 0.3;
    float2 lensUV = uv - lensDir * 0.15;

    // ── Background — deep space with lensing ──
    float3 col = float3(0.005, 0.003, 0.01) * (1.0 - a.isSilent * 0.98);
    col += starfield(lensUV, a) * 0.4;

    // Nebula haze — brain-colored, lensed
    float nebula = fbm2_4(p * 1.5 + Time * 0.02 * a.motSpeed + lensDir);
    col += a.brainCol * nebula * 0.04 * a.ambient * a.ambActive * (1.0 - a.isSilent);

    // ── Event horizon — pure black sphere ──
    if (r < ehR) {
        col = float3(0.0, 0.0, 0.0);
        // Photon sphere glow — thin bright ring at 1.5x event horizon
        float photonR = ehR * 1.5;
        float photonGlow = exp(-abs(r - photonR) * 80.0) * 0.8;
        col += a.brainCol2 * photonGlow * (0.5 + a.beat * 0.5 * a.tempoConf) * (1.0 - a.isSilent);
        // ── Brightness limiter ──
        float mc1 = max(col.r, max(col.g, col.b));
        if (mc1 > 1.2) col *= 1.2 / mc1;
        return float4(applyPostFX(col, uv, a), 1.0);
    }

    // ── Accretion disk — 64 frequency bins orbiting ──
    // Disk is tilted — perspective compression on Y
    float diskTilt = 0.3 + a.stereoBal * 0.1;
    float diskY = p.y * diskTilt;  // flatten Y for disk plane
    float diskR = length(float2(p.x, diskY));
    float diskAng = atan2(diskY, p.x);

    // Disk inner/outer radius
    float diskInner = ehR * 1.8;
    float diskOuter = 1.2 + a.overall * 0.3;

    if (diskR > diskInner && diskR < diskOuter) {
        // Map disk radius to frequency bin — inner = high freq, outer = low freq
        float freqFrac = 1.0 - saturate((diskR - diskInner) / (diskOuter - diskInner));

        // Orbital speed — relativistic, faster inner (Keplerian-ish)
        float orbitSpeed = 2.0 / pow(diskR / diskInner, 1.5);
        float orbitAng = diskAng + Time * orbitSpeed * a.motSpeed;

        // Sample spectrum at this frequency — L/R stereo split by angle
        float stereoSide = sin(orbitAng) * 0.5 + 0.5;
        float specL = u_spectrum.SampleLevel(u_sampler, float2(freqFrac, 0.0), 0).r;
        float specR = u_spectrum.SampleLevel(u_sampler, float2(freqFrac, 1.0), 0).r;
        float specC = u_spectrum.SampleLevel(u_sampler, float2(freqFrac, 0.5), 0).r;
        float specVal = lerp(specL, specR, stereoSide);
        specVal = max(specVal, specC * 0.5);

        // Doppler effect — approaching side brighter (relativistic beaming)
        float doppler = 0.5 + sin(orbitAng) * 0.5;
        float dopplerBoost = 1.0 + doppler * 1.5;

        // Disk brightness — spectrum * doppler * envelope
        float diskBright = specVal * dopplerBoost * (0.4 + a.envelope * 0.6);

        // Disk color — hot inner (white/blue) to cool outer (brain colors)
        float3 hotCol = float3(0.9, 0.95, 1.0);
        float3 coolCol = lerp(a.brainCol, a.brainCol2, freqFrac);
        float3 diskCol = lerp(coolCol, hotCol, smoothstep(0.6, 1.0, 1.0 - freqFrac));

        // Temperature gradient — inner is hotter
        float tempGrad = smoothstep(diskInner, diskOuter, diskR);
        diskCol = lerp(hotCol, diskCol, tempGrad);

        // Spiral arms — density waves
        float spiralPhase = orbitAng * 2.0 + diskR * 8.0 - Time * orbitSpeed * a.motSpeed * 3.0;
        float spiralDensity = 0.7 + sin(spiralPhase) * 0.3;

        // Disk thickness — Gaussian falloff above/below disk plane
        float diskThickness = exp(-pow(p.y - diskY / diskTilt * (1.0 - diskTilt), 2.0) * 30.0);

        // Radial falloff
        float radialFade = smoothstep(diskInner, diskInner + 0.05, diskR) * smoothstep(diskOuter, diskOuter - 0.2, diskR);

        float diskIntensity = diskBright * spiralDensity * diskThickness * radialFade;
        col += diskCol * diskIntensity * 0.5 * (1.0 - a.isSilent);

        // Hot core glow — bright inner edge
        float innerGlow = exp(-abs(diskR - diskInner) * 15.0) * specVal * 0.3;
        col += hotCol * innerGlow * diskThickness * (1.0 - a.isSilent);

        // Frequency-tinted emission
        float freqHue = a.hueBase + freqFrac * a.hueRange;
        col += hsv(freqHue, 0.5 * a.satur, specVal * 0.15) * diskThickness * (1.0 - a.isSilent);
    }

    // ── Photon ring — bright ring at 1.5x event horizon ──
    float photonR = ehR * 1.5;
    float photonRing = exp(-abs(r - photonR) * 60.0) * (0.3 + a.beat * 0.4 * a.tempoConf);
    col += a.brainCol2 * photonRing * a.bloomActive * (1.0 - a.isSilent);

    // ── Gravitational wave — kick creates rippling ring ──
    float gwR = ehR + a.kick * 0.8 * a.kickConf;
    float gwRing = exp(-abs(r - gwR) * 20.0) * a.kick * 0.15 * a.kickConf;
    col += a.brainCol * gwRing * (1.0 - a.isSilent);

    // ── Relativistic jets — on transients, perpendicular to disk ──
    if (a.transient > 0.2) {
        float jetY = abs(p.y);
        float jetX = abs(p.x);
        float jetWidth = 0.03 + a.transient * 0.02;
        float jetFade = exp(-jetX * jetX / (jetWidth * jetWidth)) * exp(-jetY * 0.5);
        float jetIntensity = a.transient * jetFade * 0.4;
        col += a.brainCol2 * jetIntensity * (1.0 - a.isSilent);
        // Jet core — bright white
        float jetCore = exp(-jetX * jetX * 500.0) * exp(-jetY * 0.3) * a.transient * 0.3;
        col += float3(0.8, 0.9, 1.0) * jetCore * a.bloomActive * (1.0 - a.isSilent);
    }

    // ── Lensing ring — subtle distortion at 2.6x event horizon (Einstein ring) ──
    float einsteinR = ehR * 2.6;
    float einsteinRing = exp(-abs(r - einsteinR) * 40.0) * 0.08 * a.bloomActive;
    col += a.brainCol * einsteinRing * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.3;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
