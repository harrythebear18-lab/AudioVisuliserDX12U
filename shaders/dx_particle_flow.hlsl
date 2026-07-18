// Mode 4: Spectrum Vortex — frequency-assigned particles in audio-driven vortex
// 48 particles per layer, each assigned a frequency bin
// Amplitude drives radial position, stereo pan drives X, transient scatters
// Kick = radial impulse, beat = contraction, phase links between adjacent bins
// Starfield, standard overlays, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define VORTEX_BINS 48

float2 vortexParticlePos(int idx, int total, AudioData a, float depth, float layerRot) {
    AudioElement e = audioSimElement(idx, total, a);

    // Base angle — distribute around circle, with layer rotation
    float baseAng = (float(idx) / total) * 6.28318 + layerRot;

    // Radial position — amplitude pushes outward, silence pulls inward
    float baseR = 0.3 + depth * 0.2;
    float radial = baseR + e.amplitude * 0.5 * a.barScale;

    // Beat contracts particles inward momentarily
    radial -= a.beat * 0.1 * a.tempoConf;

    // Kick pushes outward
    radial += a.kick * 0.15 * a.kickConf;

    // Stereo pan shifts X position
    float2 pos = float2(cos(baseAng), sin(baseAng)) * radial;
    pos += e.panOffset;

    // Transient scatter
    pos += float2(e.transientScatter, e.transientScatter * 0.5);

    // Depth scaling
    pos *= (0.7 + depth * 0.3);

    return pos;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Background ──
    float3 col = float3(0.008, 0.006, 0.015) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.2;

    // ── 3 particle depth layers ──
    [unroll] for (int layer = 0; layer < 3; layer++) {
        float depth = layer / 2.0;
        float layerBright = 0.3 + depth * 0.7;
        float pSize = 0.015 + depth * 0.01;
        float layerRot = Time * (0.1 + layer * 0.05) * a.motSpeed;

        // Render each particle
        [loop] for (int bi = 0; bi < VORTEX_BINS; bi++) {
            AudioElement e = audioSimElement(bi, VORTEX_BINS, a);
            float2 partPos = vortexParticlePos(bi, VORTEX_BINS, a, depth, layerRot);

            float dist = length(p - partPos);
            float glow = exp(-dist * dist / (pSize * pSize * 3.0)) * layerBright;

            // Color by frequency position + stereo pan
            float3 pCol = lerp(a.brainCol, a.brainCol2, e.freqFrac);
            float hue = a.hueBase + e.freqFrac * a.hueRange;
            pCol = lerp(pCol, hsv(hue, 0.6 * a.satur, 0.9), 0.3);

            // Brightness driven by amplitude
            col += pCol * glow * e.intensity * 0.4 * (1.0 - a.isSilent);

            // Bright core for high-amplitude particles
            float coreGlow = exp(-dist * dist * 200.0) * e.amplitude * 0.3;
            col += pCol * coreGlow * a.bloomActive * (1.0 - a.isSilent);

            // Phase-linked connections to adjacent bin
            if (bi > 0 && layer == 1) {
                float2 prevPos = vortexParticlePos(bi - 1, VORTEX_BINS, a, depth, layerRot);
                float2 segDir = partPos - prevPos;
                float segLen = length(segDir);
                if (segLen < 0.001) continue;
                float2 segNorm = segDir / segLen;
                float segProj = clamp(dot(p - prevPos, segNorm), 0.0, segLen);
                float2 segClosest = prevPos + segNorm * segProj;
                float segDist = length(p - segClosest);

                float linkStrength = audioSimLink(
                    audioSimElement(bi - 1, VORTEX_BINS, a),
                    e, a.phaseCorr);
                float linkGlow = exp(-segDist * segDist * 300.0) * linkStrength * 0.08;
                col += a.brainCol2 * linkGlow * (1.0 - a.isSilent);
            }
        }
    }

    // ── Kick shockwave — radial ring from center ──
    float kickR = a.kick * 0.4 * a.kickConf;
    float kickRing = exp(-abs(r - kickR) * 20.0) * a.kick * 0.2 * a.kickConf;
    col += a.brainCol * kickRing * (1.0 - a.isSilent);

    // ── Beat flash — center contraction glow ──
    float beatGlow = exp(-r * r * 8.0) * a.beat * 0.15 * a.tempoConf;
    col += a.brainCol2 * beatGlow * a.bloomActive * (1.0 - a.isSilent);

    // ── Transient sparks ──
    if (a.transient > 0.2) {
        float sparkN = hash21(floor(p * 30.0) + floor(Time * 20.0));
        float sparks = step(0.96, sparkN) * a.transient * 0.2;
        col += float3(0.9, 0.95, 1.0) * sparks * a.beamActive * (1.0 - a.isSilent);
    }

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.3;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
