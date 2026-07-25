// Mode 30: Synthwave Horizon — 3D raymarched neon landscape
// Synthwave phenomenon: infinite grid floor with audio-driven heightfield mountains,
// neon grid lines, retro sun on horizon, volumetric fog. True 3D raymarched scene.
// Bass→terrain elevation, mids→grid topology, highs→neon edge glow,
// beat→forward surge, kick→shockwave on grid, transient→glitch tearing.
// DSP: LUFS→fog density, crest→grid line sharpness, THD→terrain roughness, phase→sun symmetry.
// HDR output, no local postfx. Follows DX12U rules.
#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

// Ridged noise — creates sharp mountain ridges
float ridgedNoise(float2 p) {
    float v = 0.0, a = 0.5;
    [unroll] for (int i = 0; i < 4; i++) {
        float n = vnoise2(p);
        v += a * (1.0 - abs(n * 2.0 - 1.0));
        p = p * 2.03 + 0.3;
        a *= 0.5;
    }
    return v;
}

// Audio-driven heightfield — 8 bands split across X axis (left=bass, right=highs)
// Each band gets a distinct lateral zone with its own elevation and glow
float terrainHeight(float2 pos, AudioData a, float time, out int bandIdx, out float bandEnergy) {
    float bassMass = pow(a.b0, 0.5) * (1.0 + lufsNormalized() * 0.2);
    float bandVals[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    // Map X to band index — 8 zones across the tunnel width
    float xNorm = saturate((pos.x + 4.0) / 8.0);  // -4..4 → 0..1
    bandIdx = clamp(int(xNorm * 8.0), 0, 7);
    bandEnergy = bandVals[bandIdx];

    // Compressor on bass bands (b0-b3), linear on highs (b4-b7)
    float compEnergy = bandIdx < 4 ? pow(bandEnergy, 0.5) : bandEnergy;
    // Noise gate — flat when band is quiet
    float gate = smoothstep(0.02, 0.08, bandEnergy);

    float h = 0.0;
    float2 q = pos * 0.15;

    // Base terrain — ridged noise shaped by this zone's band energy
    h += ridgedNoise(q * 1.0) * compEnergy * 1.5 * gate;
    h += ridgedNoise(q * 2.0 + 5.3) * 0.3 * (0.5 + bandEnergy * 0.5);
    h += ridgedNoise(q * 4.0 + 11.7) * 0.15 * (0.5 + bandEnergy * 0.5);

    // Bass adds large-scale mass across all zones
    h += bassMass * 0.3 * ridgedNoise(q * 0.5);

    // THD adds roughness
    h += thdNormalized() * vnoise2(q * 12.0) * 0.15;

    // Kick — radial bump from center
    float kickR = length(pos);
    h += a.kick * a.kickConf * exp(-kickR * 0.15) * sin(kickR * 0.5 - time * 4.0) * 0.5;

    // Beat — traveling wave along Z (forward direction)
    h += a.beat * a.tempoConf * sin(pos.y * 0.3 - time * 2.0) * 0.2;

    return h;
}

// Grid distance — how close to a neon grid line
float gridDistance(float2 pos, float gridSpacing) {
    float2 g = abs(frac(pos / gridSpacing) - 0.5) * gridSpacing;
    float d = min(g.x, g.y);
    return d;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // DSP additive
    float dspLUFS = lufsNormalized();
    float dspCrest = crestFactorNormalized();
    float dspTHD = thdNormalized();
    float dspPhaseCoh = phaseCoherence();

    float bassMass = pow(a.b0, 0.5) * (1.0 + dspLUFS * 0.2);

    // Background — synthwave sky
    float3 col = float3(0.005, 0.002, 0.02) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.4;

    // Camera — centered in tunnel, looking forward, audio-driven
    float camAng = a.stereoBal * 0.15 + a.section * 0.3;
    float beatZoom = 1.0 - a.beat * 0.05 * a.tempoConf;
    float3 camPos = float3(
        sin(camAng) * 2.0,
        0.0,  // centered between floor and ceiling
        cos(camAng) * 2.0 - Time * (1.0 + bassMass * 2.0) * a.motSpeed
    );

    // Camera ray — looking forward, slight stereo tilt
    float3 camTarget = camPos + float3(sin(camAng), a.stereoDiff * 0.1, cos(camAng));
    float3 rd = cameraRay(camPos, camTarget, p, 1.2);

    // Tunnel half-height — bass pushes walls apart, beat compresses
    float tunnelHalf = 2.0 + bassMass * 0.8 - a.beat * 0.3 * a.tempoConf;

    // ── Raymarch both floor and ceiling ──
    // Floor: y = -tunnelHalf + terrainHeight
    // Ceiling: y = +tunnelHalf - terrainHeight (mirrored)
    float t = 0.1;
    bool hit = false;
    float3 hitPos = float3(0, 0, 0);
    bool hitCeiling = false;
    int hitBand = 0;
    float hitBandEnergy = 0.0;

    [loop] for (int i = 0; i < 48; i++) {
        float3 sp = camPos + rd * t;
        int bi; float be;
        float terrainH = terrainHeight(sp.xz, a, Time, bi, be);
        float floorY = -tunnelHalf + terrainH;
        float ceilY = tunnelHalf - terrainH;

        if (rd.y < 0.0 && sp.y < floorY) {
            hit = true; hitPos = sp; hitCeiling = false; hitBand = bi; hitBandEnergy = be; break;
        }
        if (rd.y > 0.0 && sp.y > ceilY) {
            hit = true; hitPos = sp; hitCeiling = true; hitBand = bi; hitBandEnergy = be; break;
        }
        // Adaptive step
        float distToSurface = rd.y < 0.0 ? (sp.y - floorY) : (ceilY - sp.y);
        float stepSize = max(0.05, distToSurface * 0.5);
        t += stepSize;
        if (t > 50.0) break;
    }

    if (hit) {
        // Terrain normal via finite differences
        float eps = 0.1;
        int dummyBi; float dummyBe;
        float hL = terrainHeight(hitPos.xz - float2(eps, 0), a, Time, dummyBi, dummyBe);
        float hR = terrainHeight(hitPos.xz + float2(eps, 0), a, Time, dummyBi, dummyBe);
        float hD = terrainHeight(hitPos.xz - float2(0, eps), a, Time, dummyBi, dummyBe);
        float hU = terrainHeight(hitPos.xz + float2(0, eps), a, Time, dummyBi, dummyBe);
        // Flip normal for ceiling
        float3 n = normalize(float3(
            (hL - hR) * (hitCeiling ? -1.0 : 1.0),
            2.0 * eps,
            (hD - hU) * (hitCeiling ? -1.0 : 1.0)
        ));
        if (hitCeiling) n.y = -n.y;

        // Grid lines — neon synthwave grid
        float gridSpacing = 1.0;
        float gd = gridDistance(hitPos.xz, gridSpacing);
        float gridSharp = 0.02 + dspCrest * 0.01;
        float gridLine = smoothstep(gridSharp, 0.0, gd);

        // Grid color — per-band hue, floor and ceiling use complementary hues
        // Band 0 (bass) = warm orange, Band 7 (highs) = cool cyan
        float bandHue = lerp(0.05, 0.55, float(hitBand) / 7.0);  // orange→cyan across bands
        float gridHue = hitCeiling ? frac(bandHue + 0.5) : bandHue;  // ceiling = complementary
        gridHue += a.section * 0.03;
        float3 gridCol = hsv(gridHue, 0.8 * a.satur, 1.0);

        // Grid intersection glow — driven by THIS band's energy (not generic spectrum)
        float intersection = smoothstep(gridSharp, 0.0, abs(frac(hitPos.x / gridSpacing) - 0.5) * gridSpacing) *
                            smoothstep(gridSharp, 0.0, abs(frac(hitPos.z / gridSpacing) - 0.5) * gridSpacing);
        // Compressor on bass bands
        float compEnergy = hitBand < 4 ? pow(hitBandEnergy, 0.5) : hitBandEnergy;
        float gate = smoothstep(0.02, 0.08, hitBandEnergy);
        float pointGlow = intersection * (0.3 + compEnergy * 3.0 * gate);

        // Lighting — 2-light setup, ceiling lights point down
        float3 lDir1 = normalize(float3(0.5, hitCeiling ? -0.8 : 0.8, 0.3));
        float3 lDir2 = normalize(float3(-0.3 + a.stereoBal * 0.5, hitCeiling ? -0.5 : 0.5, 0.4));
        float diff1 = max(dot(n, lDir1), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
        float spec = pow(max(dot(reflect(-lDir1, n), -rd), 0.0), 32.0 + dspCrest * 64.0);
        float fres = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);

        // Surface base color — dark with band-tinted terrain
        float3 terrainCol = hsv(gridHue, 0.3, 0.03) * (1.0 + compEnergy * 0.5);
        float3 litCol = terrainCol * (diff1 + diff2) * (0.3 + a.brightness * 0.3 + a.envelope * 0.3);

        // Neon grid lines — brightness driven by this band's energy
        litCol += gridCol * gridLine * (1.0 + compEnergy * 2.5 * gate) * (1.0 + dspLUFS * 0.3);
        litCol += gridCol * pointGlow * 1.5;
        litCol += float3(1.0, 0.95, 0.8) * spec * 0.3 * (0.3 + a.dynActive * 0.7);

        // Highs bands (6-7) — extra neon edge shimmer
        if (hitBand >= 6) {
            litCol += hsv(gridHue + 0.1, 0.5, 1.0) * gridLine * fres * hitBandEnergy * 2.0 * (1.0 - a.isSilent);
        }

        // Kick shockwave — expanding ring on grid
        float kickDist = length(hitPos.xz - camPos.xz);
        float shockR = frac(Time * 0.5) * 20.0;
        float shockwave = a.kick * a.kickConf * exp(-abs(kickDist - shockR) * 1.5) * 0.5;
        litCol += hsv(a.hueCenter, 0.5, 1.0) * shockwave * gridLine * (1.0 - a.isSilent);

        // Beat — traveling brightness wave along grid
        float beatWave = a.beat * a.tempoConf * pow(0.5 + 0.5 * sin(hitPos.z * 0.5 - Time * 3.0), 6.0) * 0.3;
        litCol += hsv(gridHue + 0.05, 0.6, 1.0) * beatWave * gridLine * (1.0 - a.isSilent);

        // Transient — glitch tear on grid
        litCol += hsv(gridHue + 0.5, 0.8, 1.0) * a.transient * gridLine * fres * 0.5 * (1.0 - a.isSilent);

        // DSP additive
        litCol *= (1.0 + dspLUFS * 0.3);
        litCol *= lerp(0.7, 1.2, dspPhaseCoh);

        // Distance fog — fade into distance, LUFS drives density
        float fog = exp(-t * (0.04 + dspLUFS * 0.02));
        litCol *= fog;

        col = blendScreen(col, litCol);
    } else {
        // No hit — vanishing point glow at horizon
        float vanish = exp(-abs(rd.y) * 20.0);
        col += hsv(0.85, 0.5, 1.0) * vanish * bassMass * 0.2 * (1.0 - a.isSilent);
    }

    // Foreground overlays
    col += standardOverlays(p, r, a) * 0.02;

    // Brightness limiter
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.5) col *= 1.5 / maxChannel;

    // Silence suppression
    col *= (1.0 - a.isSilent * 0.98);

    return float4(col, 1.0);
}
