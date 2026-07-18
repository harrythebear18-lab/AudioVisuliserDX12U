// Mode 15: Spectrum Lattice — frequency-driven quantum particle lattice
// 24x24 grid, each particle assigned a frequency bin
// Amplitude drives position offset, energy, color; beat = wave function collapse
// Phase-linked entanglement, transient = quantum jitter, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define GRID_SIZE 24.0
#define TOTAL_PARTICLES 576

int2 cellFromIdx(int idx) {
    return int2(idx % 24, idx / 24);
}

int idxFromCell(int2 cell) {
    return cell.x + cell.y * 24;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Background ──
    float3 col = float3(0.008, 0.006, 0.015) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.3;

    // Quantum vacuum fluctuations
    float vacuum = fbm2_4(p * 5.0 + Time * 0.1 * a.motSpeed);
    col += a.brainCol * vacuum * 0.03 * a.ambient * a.ambActive * (1.0 - a.isSilent);

    float2 gridCoord = (p / 3.0 + 0.5) * GRID_SIZE;
    int2 cell = int2(floor(gridCoord));

    // ── Render particles in 3x3 neighborhood ──
    [unroll] for (int dx = -1; dx <= 1; dx++) {
        [unroll] for (int dy = -1; dy <= 1; dy++) {
            int2 pCell = cell + int2(dx, dy);
            int pIdx = idxFromCell(pCell);

            // Each particle gets its own frequency bin
            AudioElement e = audioSimElement(pIdx % 128, 128, a);

            // Base grid position
            float2 base = (float2(pCell) / GRID_SIZE - 0.5) * 3.0;

            // Amplitude-driven oscillation offset
            float2 offset = float2(
                cos(Time * 2.0 * a.motSpeed + pIdx * 0.3),
                sin(Time * 2.0 * a.motSpeed + pIdx * 0.5)
            ) * e.amplitude * 0.08 * a.barScale;

            // Stereo pan shifts X
            offset += e.panOffset * 0.3;

            // Transient jitter — quantum uncertainty
            offset += float2(e.transientScatter, e.transientScatter * 0.7);

            // Beat = wave function collapse — snap toward grid position
            float collapse = a.beat * a.tempoConf;
            offset = lerp(offset, float2(0, 0), collapse * 0.7);

            float2 screenPos = (base + offset) * Aspect * 0.5;
            float dist = length(p - screenPos);

            // Energy = amplitude * envelope
            float energy = e.intensity * (0.5 + sin(Time * 3.0 + pIdx * 0.7) * 0.3);

            float probDensity = exp(-dist * dist * 80.0) * energy;

            // Color by frequency position + stereo pan
            float3 pCol = lerp(a.brainCol, a.brainCol2, e.freqFrac);
            float hue = a.hueBase + e.freqFrac * a.hueRange;
            pCol = lerp(pCol, hsv(hue, 0.5 * a.satur, 0.9), 0.3);

            col += pCol * probDensity * 0.25 * (1.0 - a.isSilent);

            // Bright core for high-energy particles
            float coreGlow = exp(-dist * dist * 300.0) * energy * 0.15;
            col += pCol * coreGlow * a.bloomActive * (1.0 - a.isSilent);

            // Entanglement lines to right and down neighbors
            if (dx == 0 && dy == 0) {
                // Right neighbor
                int2 rCell = pCell + int2(1, 0);
                int rIdx = idxFromCell(rCell);
                AudioElement eR = audioSimElement(rIdx % 128, 128, a);
                float2 rBase = (float2(rCell) / GRID_SIZE - 0.5) * 3.0;
                float2 rOffset = float2(cos(Time * 2.0 * a.motSpeed + rIdx * 0.3), sin(Time * 2.0 * a.motSpeed + rIdx * 0.5)) * eR.amplitude * 0.08;
                rOffset = lerp(rOffset, float2(0, 0), collapse * 0.7);
                float2 screenR = (rBase + rOffset) * Aspect * 0.5;

                float2 segDir = screenR - screenPos;
                float segLen = length(segDir);
                if (segLen > 0.001 && segLen < 0.3) {
                    float2 segNorm = segDir / segLen;
                    float segProj = clamp(dot(p - screenPos, segNorm), 0.0, segLen);
                    float2 segClosest = screenPos + segNorm * segProj;
                    float segDist = length(p - segClosest);
                    float linkStrength = audioSimLink(e, eR, a.phaseCorr);
                    float linkGlow = exp(-segDist * segDist * 250.0) * linkStrength * 0.06;
                    col += hsv(a.hueCenter, 0.4 * a.satur, 1.0) * linkGlow * a.stereoWid * a.dynActive * (1.0 - a.isSilent);
                }

                // Down neighbor
                int2 dCell = pCell + int2(0, 1);
                int dIdx = idxFromCell(dCell);
                AudioElement eD = audioSimElement(dIdx % 128, 128, a);
                float2 dBase = (float2(dCell) / GRID_SIZE - 0.5) * 3.0;
                float2 dOffset = float2(cos(Time * 2.0 * a.motSpeed + dIdx * 0.3), sin(Time * 2.0 * a.motSpeed + dIdx * 0.5)) * eD.amplitude * 0.08;
                dOffset = lerp(dOffset, float2(0, 0), collapse * 0.7);
                float2 screenD = (dBase + dOffset) * Aspect * 0.5;

                float2 segDirD = screenD - screenPos;
                float segLenD = length(segDirD);
                if (segLenD > 0.001 && segLenD < 0.3) {
                    float2 segNormD = segDirD / segLenD;
                    float segProjD = clamp(dot(p - screenPos, segNormD), 0.0, segLenD);
                    float2 segClosestD = screenPos + segNormD * segProjD;
                    float segDistD = length(p - segClosestD);
                    float linkStrengthD = audioSimLink(e, eD, a.phaseCorr);
                    float linkGlowD = exp(-segDistD * segDistD * 250.0) * linkStrengthD * 0.06;
                    col += hsv(a.hueCenter, 0.4 * a.satur, 1.0) * linkGlowD * a.stereoWid * a.dynActive * (1.0 - a.isSilent);
                }
            }
        }
    }

    // ── Wave function collapse flash on beat ──
    float collapseFlash = a.beat * 0.1 * a.tempoConf * exp(-r * r * 3.0);
    col += a.brainCol2 * collapseFlash * a.bloomActive * (1.0 - a.isSilent);

    // ── Kick ripple — radial wave from center ──
    float kickR = a.kick * 0.5 * a.kickConf;
    float kickRing = exp(-abs(r - kickR) * 15.0) * a.kick * 0.15;
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
