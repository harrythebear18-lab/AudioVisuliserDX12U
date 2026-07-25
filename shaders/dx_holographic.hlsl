// Mode 16: Holo-Frequency Matrix — holographic grid of frequency cells viewed at angle
// Each cell = a spectrum bin, height + brightness = amplitude, L/R stereo split
// Holographic styling: scan lines, glitch, flicker, perspective tilt, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

// Project a grid cell (col, row) to screen with perspective tilt
float2 gridToScreen(int col, int row, int cols, int rows, float tilt, float stereoBal) {
    float xFrac = (col + 0.5) / cols - 0.5;  // -0.5..0.5
    float zFrac = (row + 0.5) / rows - 0.5;  // -0.5..0.5

    // Perspective: rows further back are higher and smaller
    float depth = 1.0 + zFrac * 1.5;
    float x = xFrac * 2.8 * Aspect / depth + stereoBal * 0.1;
    float y = 0.3 - zFrac * tilt / depth;
    return float2(x, y);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);

    // DSP complement — additive to brain data, never replaces
    float lufs = lufsNormalized();
    float thd = thdNormalized();
    float phase = phaseCoherence();  // 0=out-of-phase, 1=mono

    // ── Background — holographic dark ──
    float3 col = float3(0.003, 0.006, 0.012) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.15;

    // ── Holographic floor grid — perspective lines ──
    float gridTilt = 0.8 + a.energy * 0.2;
    int COLS = 32;
    int ROWS = 16;

    // Draw grid lines
    [loop] for (int gl = 0; gl <= ROWS; gl++) {
        float zFrac = (float(gl) / ROWS - 0.5);
        float depth = 1.0 + zFrac * 1.5;
        float y = 0.3 - zFrac * gridTilt / depth;
        float yThick = 0.002 / depth;
        if (abs(p.y - y) < yThick) {
            float gridFade = smoothstep(-0.5, 0.5, zFrac);
            col += a.brainCol * 0.08 * gridFade * (1.0 - a.isSilent);
        }
    }
    [loop] for (int gl2 = 0; gl2 <= COLS; gl2++) {
        float xFrac = (float(gl2) / COLS - 0.5);
        // Draw two points and connect
        float2 top = gridToScreen(gl2, 0, COLS, ROWS, gridTilt, a.stereoBal);
        float2 bot = gridToScreen(gl2, ROWS - 1, COLS, ROWS, gridTilt, a.stereoBal);
        float2 dir = bot - top;
        float len = length(dir);
        if (len < 0.001) continue;
        float2 norm = dir / len;
        float proj = clamp(dot(p - top, norm), 0.0, len);
        float2 closest = top + norm * proj;
        float lineDist = length(p - closest);
        if (lineDist < 0.003) {
            float gridFade = smoothstep(0.0, 1.0, proj / len);
            col += a.brainCol * 0.05 * gridFade * (1.0 - a.isSilent);
        }
    }

    // ── Frequency matrix cells — each cell is a spectrum bin ──
    [loop] for (int row = 0; row < ROWS; row++) {
        float zFrac = (row + 0.5) / ROWS - 0.5;  // -0.5..0.5
        float depth = 1.0 + zFrac * 1.5;
        float rowFade = smoothstep(-0.5, 0.5, zFrac);  // front rows brighter

        // Each row samples a different part of the spectrum
        // Row 0 = bass (front), Row 15 = treble (back)
        float freqFrac = row / float(ROWS - 1);

        // Sample L/R/mono at this frequency
        float specL = u_spectrum.SampleLevel(u_sampler, float2(freqFrac, 0.0), 0).r;
        float specR = u_spectrum.SampleLevel(u_sampler, float2(freqFrac, 1.0), 0).r;
        float specC = u_spectrum.SampleLevel(u_sampler, float2(freqFrac, 0.5), 0).r;

        [loop] for (int c = 0; c < COLS; c++) {
            float xFrac = (c + 0.5) / COLS - 0.5;  // -0.5..0.5

            // L/R split: left half = L channel, right half = R
            float stereoBlend = smoothstep(-0.1, 0.1, xFrac);
            float cellVal = lerp(specL, specR, stereoBlend);
            cellVal = max(cellVal, specC * 0.5);

            // Cell position on screen
            float2 cellPos = gridToScreen(c, row, COLS, ROWS, gridTilt, a.stereoBal);
            float cellSize = 0.04 / depth;

            // Bar height from amplitude — rises upward
            float barH = cellVal * 0.4 * a.barScale / depth;
            barH += a.beat * 0.03 * a.tempoConf / depth;  // beat pulse on bars
            barH += a.kick * 0.05 * a.kickConf / depth;  // kick surge on bars
            float2 barTop = cellPos + float2(0, barH);
            float2 barBot = cellPos;

            // Distance to bar (vertical line from cellPos upward)
            float2 barDir = barTop - barBot;
            float barLen = length(barDir);
            if (barLen < 0.001) continue;
            float2 barNorm = barDir / barLen;
            float barProj = clamp(dot(p - barBot, barNorm), 0.0, barLen);
            float2 barClosest = barBot + barNorm * barProj;
            float barDist = length(p - barClosest);

            // Cell glow
            float cellDist = length(p - cellPos);
            float cellGlow = exp(-cellDist * cellDist / (cellSize * cellSize * 2.0)) * cellVal * 0.3;

            // Bar glow
            float barWidth = cellSize * 0.4;
            float barGlow = exp(-barDist * barDist / (barWidth * barWidth * 2.0)) * cellVal * 0.8;
            barGlow *= (0.5 + a.envelope * 0.5);  // envelope boosts glow

            // Color by frequency + height
            float hue = a.hueBase + freqFrac * a.hueRange + a.section * 0.03;
            float3 cellCol = hsv(hue, 0.6 * a.satur, 0.9);
            cellCol = lerp(a.brainCol, cellCol, 0.6);

            col += cellCol * (cellGlow + barGlow) * rowFade * (0.5 + a.brightness * 0.5) * (1.0 - a.isSilent);
            // LUFS: louder = brighter cells (additive boost to brain brightness)
            col += cellCol * (cellGlow + barGlow) * rowFade * lufs * 0.15 * (1.0 - a.isSilent);

            // Bright top cap on tall bars
            if (barLen > 0.01) {
                float topDist = length(p - barTop);
                float topGlow = exp(-topDist * topDist * 100.0) * cellVal * 0.4;
                col += float3(0.8, 0.9, 1.0) * topGlow * rowFade * a.bloomActive * (1.0 - a.isSilent);
            }
        }
    }

    // ── Holographic scan lines (screen space) — phase splits scan channels ──
    float scanSplit = (1.0 - phase) * 0.5;  // stereo = wider scan separation
    float holoScan = sin(uv.y * Height * 0.5 + scanSplit * 10.0) * 0.5 + 0.5;
    col *= (0.85 + holoScan * 0.15);

    // Moving scan bar
    float scanY = frac(Time * 0.15 * a.motSpeed) * 2.0 - 1.0;
    float scanDist = abs(p.y - scanY);
    col += a.brainCol2 * exp(-scanDist * scanDist * 60.0) * 0.08 * a.dynActive * (1.0 - a.isSilent);

    // ── Glitch on transient — THD amplifies glitch intensity ──
    if (a.transient > 0.3) {
        float glitchShift = a.transient * 0.015 * (1.0 + thd * 0.8);  // THD: more distortion = bigger glitch
        col.r *= (1.0 + glitchShift);
        col.b *= (1.0 - glitchShift);
        float glitchBlock = step(0.97 - thd * 0.04, hash11(floor(uv.y * 30.0) + floor(Time * 8.0)));  // THD: more glitch blocks
        col += a.brainCol * glitchBlock * a.transient * 0.1 * (1.0 - a.isSilent);
    }

    // ── Holographic flicker — audio reactive ──
    float flicker = 0.9 + sin(Time * 12.0) * 0.04 + sin(Time * 19.0) * 0.02;
    flicker *= (0.8 + a.overall * 0.2 + a.envelope * 0.1);
    col *= flicker;

    // ── Kick flash ──
    float kickFlash = exp(-length(p) * length(p) * 4.0) * a.kick * 0.12 * a.kickConf;
    col += a.brainCol2 * kickFlash * a.bloomActive * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, length(p), a) * 0.025;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
