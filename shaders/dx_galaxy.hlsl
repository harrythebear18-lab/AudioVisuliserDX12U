// Mode: Spectrum Galaxy — 3D volumetric spiral galaxy with spectrum-driven arms
// Logarithmic spiral arms with density field, core bulge, dust lanes, halo
// Spectrum drives arm density at different radii — bass = core, mid = arms, treble = halo
// Beat = galactic pulse, kick = supernova, transients = star birth regions
// 3D volumetric raymarch, proper depth attenuation, brain-colored, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define GALAXY_ARMS 4
#define GALAXY_STEPS 64

// Galaxy density field — logarithmic spiral arms + core bulge + halo
float galaxyDensity(float3 p, AudioData a, float time) {
    float r = length(p.xz);
    float ang = atan2(p.z, p.x);
    float h = p.y;

    // Galaxy disk thickness — thin disk with thicker bulge
    float diskThick = 0.15 + 0.4 * exp(-r * 0.8);
    float vertDensity = exp(-h * h / (diskThick * diskThick));

    // Core bulge — Gaussian centered at origin
    float bulge = exp(-r * r * 3.0) * exp(-h * h * 4.0);
    bulge *= (0.4 + a.profBass * 0.3 + a.b0 * 0.2);

    // Spiral arms — logarithmic spiral
    float armDensity = 0.0;
    [unroll] for (int arm = 0; arm < GALAXY_ARMS; arm++) {
        float armOffset = float(arm) * 6.28318 / float(GALAXY_ARMS);
        // Logarithmic spiral angle
        float spiralAng = ang - log(max(r, 0.1)) * 2.0 - armOffset + time * 0.05 * a.motSpeed;

        // Arm width — narrower at outer edge
        float armWidth = 0.3 + 0.2 * smoothstep(2.0, 0.3, r);
        float armDist = abs(fmod(spiralAng + 3.14159, 6.28318) - 3.14159);
        float armProfile = exp(-armDist * armDist / (armWidth * armWidth));

        // Map radius to spectrum — inner = low freq, outer = high freq
        float specU = saturate(r / 2.5);
        float specVal = u_spectrum.SampleLevel(u_sampler, float2(specU, 0.5), 0).r;
        float specL = u_spectrum.SampleLevel(u_sampler, float2(specU, 0.0), 0).r;
        float specR = u_spectrum.SampleLevel(u_sampler, float2(specU, 1.0), 0).r;
        specVal = max(max(specVal, specL), specR);

        armDensity += armProfile * vertDensity * (0.15 + specVal * 0.35 * a.barScale);
    }

    // Radial falloff — galaxy extends to ~2.5 units
    float radialFalloff = smoothstep(2.8, 0.3, r);

    // Dust lanes — dark bands between arms
    float dustPhase = ang - log(max(r, 0.1)) * 2.0 + time * 0.05 * a.motSpeed;
    float dust = smoothstep(0.2, 0.5, abs(sin(dustPhase * float(GALAXY_ARMS) * 0.5)));
    armDensity *= (0.6 + 0.4 * dust);

    // Halo — treble-driven diffuse glow
    float halo = exp(-r * 0.5) * exp(-h * h * 0.3) * a.profTreb * 0.08;

    // Turbulence — star-forming regions
    float turb = fbm3_4(p * 3.0 + time * 0.1) * 0.1 * radialFalloff * vertDensity;

    // Beat — galactic pulse
    float beatPulse = a.beat * 0.05 * a.tempoConf * radialFalloff * vertDensity;

    // Transient — star birth flashes
    float starBirth = a.transient * 0.08 * exp(-r * r * 2.0) * vertDensity;

    float totalDensity = (bulge + armDensity + halo + turb + beatPulse + starBirth) * radialFalloff;

    return max(totalDensity, 0.0);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Background — deep space ──
    float3 col = float3(0.002, 0.001, 0.005) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.5;

    // Distant nebula clouds
    float nebula1 = fbm2_4(p * 1.0 + Time * 0.01 * a.motSpeed);
    float nebula2 = fbm2_4(p * 2.0 - Time * 0.015 * a.motSpeed + 5.0);
    col += a.brainCol * nebula1 * 0.02 * a.ambient * a.ambActive * (1.0 - a.isSilent);
    col += a.brainCol2 * nebula2 * 0.015 * a.ambient * a.ambActive * (1.0 - a.isSilent);

    // ── Camera — orbiting the galaxy, tilted view ──
    float camAng = a.stereoBal * 0.3 + Time * 0.015 * a.motSpeed;
    float camDist = 5.0 + a.profBass * 0.2;
    float3 camPos = float3(sin(camAng) * camDist, 2.0 + a.stereoDiff * 0.3, cos(camAng) * camDist);
    float3 camTarget = float3(0, 0, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(fwd + p.x * right + p.y * up);

    // ── Volumetric raymarch through galaxy ──
    float t = 0.05;
    float3 totalGlow = float3(0.0, 0.0, 0.0);
    float totalDensity = 0.0;

    [loop] for (int i = 0; i < GALAXY_STEPS; i++) {
        float3 sp = camPos + rd * t;
        float dens = galaxyDensity(sp, a, Time);

        if (dens > 0.003) {
            float galR = length(sp.xz);

            // Color by region — core = warm, arms = brain-colored, halo = cool
            float coreFrac = exp(-galR * galR * 3.0);
            float3 coreCol = float3(1.0, 0.85, 0.6);
            float3 armCol = lerp(a.brainCol, a.brainCol2, galR * 0.4);
            float3 haloCol = a.brainCol2 * 0.5;

            float3 regionCol = lerp(armCol, coreCol, coreFrac);
            regionCol = lerp(regionCol, haloCol, smoothstep(1.5, 2.5, galR) * 0.5);

            // Spectrum tinting
            float specU = saturate(galR / 2.5);
            float hue = a.hueBase + specU * a.hueRange;
            regionCol = lerp(regionCol, hsv(hue, 0.5 * a.satur, 0.8), 0.2);

            // Depth attenuation
            float depthFog = exp(-t * 0.03);

            // Brightness
            float bright = dens * (0.3 + a.envelope * 0.3) * (0.3 + a.brightness * 0.4) * depthFog;

            totalGlow += regionCol * bright * 0.04;
            totalDensity += dens * 0.04;

            // Hot core highlights — white-blue where density is very high
            float hotGlow = smoothstep(0.5, 0.9, dens) * 0.01;
            totalGlow += float3(0.8, 0.85, 1.0) * hotGlow * depthFog;
        }

        t += 0.1;
        if (t > 8.0) break;
    }

    col += totalGlow * (1.0 - a.isSilent);

    // ── Galactic core — bright point ──
    float coreGlow = exp(-r * r * 20.0) * (0.05 + a.profBass * 0.08 + a.b0 * 0.04);
    col += float3(1.0, 0.9, 0.7) * coreGlow * (1.0 - a.isSilent);

    // ── Kick — supernova flash ──
    float supernova = exp(-r * r * 8.0) * a.kick * 0.06 * a.kickConf;
    col += float3(0.9, 0.85, 0.7) * supernova * (1.0 - a.isSilent);

    // ── Beat — galactic pulse ──
    float beatPulse = exp(-r * r * 4.0) * a.beat * 0.03 * a.tempoConf;
    col += a.brainCol2 * beatPulse * (1.0 - a.isSilent);

    // ── Transient — stellar flares ──
    if (a.transient > 0.15) {
        float flareN = hash11(floor(uv.x * 50.0) + floor(uv.y * 50.0) + floor(Time * 8.0));
        if (flareN > 0.95) {
            float2 flarePos = float2(hash11(flareN) * 2.5 - 1.25, hash11(flareN * 2.0) * 1.5 - 0.75);
            float flareDist = length(p - flarePos);
            float flareGlow = exp(-flareDist * flareDist * 500.0) * a.transient * 0.08;
            col += float3(0.8, 0.9, 1.0) * flareGlow * (1.0 - a.isSilent);
        }
    }

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.15;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
