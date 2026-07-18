// Mode 17: Spectrum Storm — frequency-driven storm particles
// 48 particles per layer, each assigned a frequency bin
// Amplitude drives orbit radius, stereo pan drifts X, transient scatters
// Kick = radial impulse, lightning between high-amplitude bins on transients
// Starfield, standard overlays, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define STORM_BINS 48

float2 stormParticlePos(int idx, int total, AudioData a, float depth, float layerRot) {
    AudioElement e = audioSimElement(idx, total, a);

    // Base angle — distribute around circle with layer rotation
    float baseAng = (float(idx) / total) * 6.28318 + layerRot;

    // Orbit radius — amplitude drives outward, quiet = tight inner orbit
    float baseR = 0.2 + depth * 0.15;
    float radial = baseR + e.amplitude * 0.6 * a.barScale;

    // Kick = radial impulse outward
    radial += a.kick * 0.2 * a.kickConf;

    // Beat = slight contraction
    radial -= a.beat * 0.08 * a.tempoConf;

    // Position
    float2 pos = float2(cos(baseAng), sin(baseAng)) * radial;

    // Stereo pan drifts X
    pos += e.panOffset;

    // Transient scatter — chaotic displacement
    pos += float2(e.transientScatter, e.transientScatter * 0.6);

    // Depth scaling
    pos *= (0.6 + depth * 0.4);

    return pos;
}

float stormLightning(float2 p, float2 a2, float2 b2, float seed) {
    float2 dir = b2 - a2;
    float len = length(dir);
    if (len < 0.001) return 0.0;
    float2 norm = dir / len;
    float2 perp = float2(-norm.y, norm.x);
    float proj = clamp(dot(p - a2, norm), 0.0, len);
    float perpDist = abs(dot(p - a2, perp));
    perpDist += sin(proj * 20.0 + seed * 10.0) * 0.015;
    return exp(-perpDist * perpDist * 1000.0);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Background — dark storm ──
    float3 col = float3(0.006, 0.005, 0.012) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.15;

    // Storm clouds — subtle background turbulence
    float storm = fbm2_4(p * 2.0 + Time * 0.05 * a.motSpeed);
    col += a.brainCol * storm * 0.03 * a.ambient * a.ambActive * (1.0 - a.isSilent);

    // ── 3 particle depth layers ──
    [unroll] for (int layer = 0; layer < 3; layer++) {
        float depth = layer / 2.0;
        float layerBright = 0.3 + depth * 0.7;
        float pSize = 0.014 + depth * 0.01;
        float layerRot = Time * (0.15 + layer * 0.08) * a.motSpeed;

        [loop] for (int bi = 0; bi < STORM_BINS; bi++) {
            AudioElement e = audioSimElement(bi, STORM_BINS, a);
            float2 partPos = stormParticlePos(bi, STORM_BINS, a, depth, layerRot);

            float dist = length(p - partPos);
            float glow = exp(-dist * dist / (pSize * pSize * 3.0)) * layerBright;

            // Color by frequency + stereo
            float3 pCol = lerp(a.brainCol, a.brainCol2, e.freqFrac);
            float hue = a.hueBase + e.freqFrac * a.hueRange;
            pCol = lerp(pCol, hsv(hue, 0.6 * a.satur, 0.9), 0.3);

            // Brightness driven by amplitude
            col += pCol * glow * e.intensity * 0.35 * (1.0 - a.isSilent);

            // Bright core for high-amplitude
            float coreGlow = exp(-dist * dist * 200.0) * e.amplitude * 0.25;
            col += pCol * coreGlow * a.bloomActive * (1.0 - a.isSilent);
        }
    }

    // ── Lightning between high-amplitude adjacent bins on transients ──
    if (a.transient > 0.25) {
        [loop] for (int li = 0; li < STORM_BINS - 1; li++) {
            AudioElement eL = audioSimElement(li, STORM_BINS, a);
            AudioElement eR = audioSimElement(li + 1, STORM_BINS, a);

            // Only draw lightning if both bins are active
            if (eL.amplitude > 0.15 && eR.amplitude > 0.15) {
                float2 pos1 = stormParticlePos(li, STORM_BINS, a, 0.5, Time * 0.2 * a.motSpeed);
                float2 pos2 = stormParticlePos(li + 1, STORM_BINS, a, 0.5, Time * 0.2 * a.motSpeed);
                float bolt = stormLightning(p, pos1, pos2, float(li));
                float boltIntensity = bolt * a.transient * a.beam * 0.5 * a.beamActive
                                    * (eL.amplitude + eR.amplitude) * 0.5;
                col += a.brainCol2 * boltIntensity * (1.0 - a.isSilent);
            }
        }

        // Random lightning bolt to center on big transients
        if (a.transient > 0.5) {
            int randBin = int(hash11(Time) * STORM_BINS) % STORM_BINS;
            float2 boltPos = stormParticlePos(randBin, STORM_BINS, a, 0.5, Time * 0.2 * a.motSpeed);
            float bolt = stormLightning(p, boltPos, float2(0, 0), hash11(Time * 2.0));
            col += float3(0.8, 0.9, 1.0) * bolt * a.transient * 0.3 * a.beamActive * (1.0 - a.isSilent);
        }

        // Flash
        float flash = a.transient * 0.06 * a.beamActive;
        col += float3(flash, flash, flash * 1.2) * (1.0 - a.isSilent);
    }

    // ── Kick shockwave ──
    float kickR = a.kick * 0.5 * a.kickConf;
    float kickRing = exp(-abs(r - kickR) * 18.0) * a.kick * 0.15 * a.kickConf;
    col += a.brainCol * kickRing * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.3;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
