// Mode 3: Spectrum Tectonics — audio-sculpted infinite canyon flyover
// Heightfield raymarch (32 steps). Full audio spectrum drives geology:
// 128 spectrum bins via audioSimElement → terrain warping + ridge frequency
// Bass → elevation, mids → ridge accentuation, treble → surface detail
// Beat → seismic ripple (beatPhase direction), kick → tectonic uplift
// Transient → fault cracks, stereoBal → camera lean, stereoWid → canyon width
// phaseCorr → valley compression, stereoDiff → asymmetric walls
// beatAnt → pre-beat camera tilt, tempoPulse → terrain breathing
// speechMode → flatten terrain, calmMode → reduce motion
// section → biome hue, colorPulse → hue cycling, phrasePulse → 16-beat dynamics
// standardOverlays handles beat/kick/transient/phrase brightness events
// Silent = flat dormant ground under dark sky. No circles, no spheres.
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

// ── Heightfield function — full-spectrum audio-sculpted terrain ──
// Base terrain always visible. Audio morphs shape via 128-bin spectrum + spatial data.
float terrainHeight(float2 p, AudioData a, float time) {
    // Scroll — BPM drives flight speed, stereo drifts sideways, calmMode slows
    float motionScale = (1.0 - a.calmMode * 0.7) * (1.0 - a.speechMode * 0.5);
    float2 scroll = float2(
        time * a.motSpeed * (0.5 + a.bpm / 240.0) * 3.0 * motionScale + a.stereoBal * 2.0,
        time * a.motSpeed * 0.3 * motionScale
    );
    float2 sp = p + scroll;

    // ── Base terrain — always present ──
    float continental = fbm2(sp * 0.12) * 3.0;
    float2 ridgeWarp = float2(fbm2(sp * 0.25), fbm2(sp * 0.25 + 5.2)) * 0.6;
    float ridges = (1.0 - abs(fbm2(sp * 0.35 + ridgeWarp) * 2.0 - 1.0)) * 1.5;
    float hills = fbm2_4(sp * 0.7 + ridgeWarp * 0.3) * 0.6;
    float detail = fbm2_4(sp * 2.5) * 0.15;

    // ── Full spectrum: 8 bands drive terrain shape at different scales ──
    float bass = a.b0 * 0.6 + a.b1 * 0.4;
    float lmid = a.b2 * 0.6 + a.b3 * 0.4;
    float hmid = a.b4 * 0.6 + a.b5 * 0.4;
    float treb = a.profTreb;
    // Gate by silence
    bass *= (1.0 - a.isSilent);
    lmid *= (1.0 - a.isSilent);
    hmid *= (1.0 - a.isSilent);
    treb *= (1.0 - a.isSilent);

    // Speech mode flattens terrain (calmer landscape when talking)
    float speechFlat = a.speechMode * 0.5;

    float h = continental + ridges + hills + detail;
    h += bass * 1.5 * (1.0 - speechFlat);
    h += lmid * 0.6 * ridges * (1.0 - speechFlat);
    h += hmid * 0.3;
    h += treb * 0.1;

    // ── Stereo width → canyon width (phaseCorr compresses/expands valleys) ──
    float canyonWidth = 0.8 + a.stereoWid * 0.4;
    float canyonCompress = 1.0 - a.phaseCorr * 0.15;  // mono audio = narrower valleys
    h *= canyonWidth * canyonCompress;

    // ── Stereo diff → asymmetric walls (L/R channel difference warps terrain) ──
    float2 asymWarp = float2(a.stereoDiff, -a.stereoDiff) * 0.3;
    h += fbm2_4(sp * 0.5 + asymWarp) * 0.3 * (1.0 - a.isSilent);

    // ── Beat → seismic ripple (beatPhase gives direction) ──
    float dist = length(sp - scroll);
    float seismicR = a.beatPhase * 30.0;
    float seismic = exp(-abs(dist - seismicR) * 0.8) * a.beat * 0.3 * a.tempoConf;
    h += seismic * (1.0 - a.isSilent);

    // ── Kick → tectonic uplift near camera ──
    float kickUplift = a.kick * a.kickConf * exp(-dist * 0.1) * 0.4;
    h += kickUplift * (1.0 - a.isSilent);

    // ── Transient → fault line cracks ──
    if (a.transient > 0.15) {
        float fault = abs(fbm2(sp * 1.5 + time * 0.3) - 0.5) * 2.0;
        fault = 1.0 - smoothstep(0.0, 0.08, fault);
        h -= fault * a.transient * 0.2 * (1.0 - a.isSilent);
    }

    // ── tempoPulse → terrain breathing (subtle expansion/contraction) ──
    h *= (0.9 + a.tempoPulse * 0.1);

    // ── Envelope → gentle shape modulation ──
    h *= (0.8 + a.envelope * 0.2);

    // ── Visual limiter ──
    h = clamp(h, -2.0, 12.0);

    return h;
}

// ── Tetrahedral normals — 4 samples instead of 6 (25% faster) ──
float3 terrainNormal(float2 p, AudioData a, float time) {
    float e = 0.02;
    float h1 = terrainHeight(p + float2(e, -e), a, time);
    float h2 = terrainHeight(p + float2(-e, -e), a, time);
    float h3 = terrainHeight(p + float2(0, e), a, time);
    return normalize(float3(h1 - h2, 2.0 * e, h1 + h2 - 2.0 * h3));
}

// ── Layer 1: Background — dark sky + stars + faint aurora ──
float3 skyLayer(float2 uv, float2 p, AudioData a) {
    float t = saturate(uv.y);
    float3 skyTop = a.brainCol * 0.06 + float3(0.008, 0.008, 0.015);
    float3 skyBot = a.brainCol2 * 0.08 + float3(0.02, 0.01, 0.015);
    float3 col = lerp(skyBot, skyTop, pow(t, 0.5));

    // Faint aurora — energy + colorPulse drive hue, stays dark otherwise
    float2 auroraUV = float2(uv.x * 3.0 + Time * 0.1 * a.motSpeed, 0.45 + 0.3 * t);
    float auroraShape = fbm2_4(auroraUV);
    float auroraMask = smoothstep(0.4, 0.7, auroraShape) * smoothstep(0.8, 0.4, t) * smoothstep(0.3, 0.5, t);
    float auroraHue = a.hueBase + 0.3 + a.colorPulse * 0.05 + a.section * 0.03;
    float auroraIntensity = a.energy * 0.03 * (1.0 - a.isSilent);
    col += hsv(auroraHue, 0.6 * a.satur, 1.0) * auroraMask * auroraIntensity;

    // Stars — stereoWid affects parallax
    col += starfield(uv, a) * smoothstep(0.4, 0.85, t) * 0.35;

    return col * (1.0 - a.isSilent * 0.96);
}

// ── Terrain coloring — audio drives HUE via section/colorPulse/energy, not brightness ──
float3 terrainColor(float3 pos, float3 nor, float h, AudioData a, float time) {
    float slope = 1.0 - nor.y;

    // Water at low elevation
    float waterLevel = -0.5;
    float isWater = smoothstep(waterLevel + 0.3, waterLevel, h);
    float3 waterCol = a.brainCol * 0.1 + float3(0.015, 0.01, 0.018);

    // Rock layers — hue shifts with section, colorPulse, energy (NOT brightness)
    float hueShift = (a.energy * 0.04 + a.colorPulse * 0.03 + a.section * 0.02) * (1.0 - a.isSilent);
    float3 valleyCol = a.brainCol * 0.15 + float3(0.02, 0.015, 0.025);
    float3 ridgeCol = hsv(a.hueBase + 0.08 + hueShift, 0.65 * a.satur, 0.35);
    float3 peakCol = lerp(a.brainCol2, float3(0.7, 0.8, 0.95), 0.35) * 0.4;

    float3 col = lerp(valleyCol, ridgeCol, smoothstep(-0.5, 3.0, h));
    col = lerp(col, peakCol, smoothstep(4.0, 10.0, h));
    col = lerp(col, waterCol, isWater);

    // Steep slopes → darker rock
    col = lerp(col, col * 0.45, smoothstep(0.3, 0.7, slope) * (1.0 - isWater));

    // Fault lines — transient-driven, subtle
    float2 faultUV = pos.xz * 2.0 + time * 0.2;
    float faultNoise = fbm2(faultUV);
    float faultLine = 1.0 - smoothstep(0.0, 0.06, abs(faultNoise - 0.5));
    float faultGlow = faultLine * a.transient * 0.06 * (1.0 - isWater) * (1.0 - a.isSilent);
    col += hsv(a.hueBase + 0.05, 0.9, 1.0) * faultGlow;

    return col;
}

// ── Layer 2: Heightfield raymarch — terrain intersection ──
float3 terrainLayer(float2 p, float2 uv, AudioData a) {
    // Camera — audio drives position: bass height, kick altitude, stereo lean, beatAnt anticipation
    float camHeight = 4.0 + a.profBass * 0.3 + a.kick * a.kickConf * 0.4;
    // beatAnt → pre-beat camera tilt (anticipation), stereoBal → lean, tempoPulse → breathe
    float camLean = a.stereoBal * 0.05 + a.beatAnt * 0.02 + a.tempoPulse * 0.01;
    // calmMode pulls camera back for wider view, speechMode holds steady
    float camZ = -10.0 - a.calmMode * 2.0;
    float3 camPos = float3(a.stereoBal * 1.5, camHeight, camZ);
    float3 camTarget = float3(a.stereoBal * 1.0, camHeight - 2.0 - camLean, 25.0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);
    // Wide FOV for expansive landscape
    float3 rd = normalize(fwd + p.x * right * 1.4 + (-p.y) * up * 1.4);

    // Heightfield raymarch — step along ray, check against terrain
    float t = 0.1;
    float3 pos = float3(0, 0, 0);
    bool hit = false;

    [loop] for (int i = 0; i < 32; i++) {
        pos = camPos + rd * t;
        float h = terrainHeight(pos.xz, a, Time);
        if (pos.y < h) { hit = true; break; }
        // Adaptive step — larger steps when far above terrain
        float stepAdj = max(pos.y - h, 0.05) * 0.5 + 0.1;
        t += stepAdj;
        if (t > 60.0) break;
    }

    if (!hit) return float3(0, 0, 0);

    // Normal + color
    float3 nor = terrainNormal(pos.xz, a, Time);
    float h = terrainHeight(pos.xz, a, Time);
    float3 col = terrainColor(pos, nor, h, a, Time);

    // ── Lighting — fixed brightness, audio drives sun DIRECTION (shape, not light) ──
    // stereoBal shifts sun angle, phaseCorr affects sun height
    float3 sunDir = normalize(float3(0.3 + a.stereoBal * 0.15, 0.5 + a.phaseCorr * 0.1, 0.8));
    float diff = max(dot(nor, sunDir), 0.0);
    col *= (0.25 + diff * 0.9);

    // Subtle specular on flat surfaces
    float3 viewDir = -rd;
    float spec = pow(max(dot(reflect(-sunDir, nor), viewDir), 0.0), 32.0);
    col += float3(0.5, 0.5, 0.55) * spec * 0.08 * smoothstep(0.5, 0.9, nor.y);

    // ── Atmospheric fog — atmos + calmMode thicken fog ──
    float fogDist = t;
    float fogDensity = 0.015 + a.atmos * 0.015 + a.calmMode * 0.01;
    float fog = 1.0 - exp(-fogDist * fogDensity);
    float3 fogCol = skyLayer(uv, p, a);
    col = lerp(col, fogCol, fog);

    return col;
}

// ── Layer 3: Foreground — full spectrum ribbons via audioSimElement ──
float3 foregroundLayer(float2 p, float2 uv, AudioData a) {
    float3 col = float3(0, 0, 0);

    // 16 spectrum ribbons — each with stereo pan, transient scatter, intensity
    [loop] for (int bi = 0; bi < 16; bi++) {
        AudioElement e = audioSimElement(bi, 16, a);
        if (e.amplitude < 0.02) continue;

        // Ribbon position — freqFrac spreads vertically, pan shifts horizontally
        float ribbonY = 0.3 + e.freqFrac * 0.4;
        float ribbonX = e.pan * 0.1 * a.stereoWid;
        // Transient scatter adds jitter
        float2 ribbonPos = float2(ribbonX + e.transientScatter, ribbonY);

        // Wavy ribbon with organic curve
        float wave = sin(uv.x * 6.0 + Time * 0.5 * a.motSpeed + float(bi)) * 0.015 * e.amplitude;
        float yDist = abs(uv.y - ribbonPos.y - wave);
        float xDist = abs(uv.x - ribbonPos.x);

        // Intensity from audioSimElement (includes envelope + overall)
        float bandGlow = exp(-yDist * yDist * 500.0) * exp(-xDist * xDist * 8.0) * e.intensity * 0.04;

        float hue = a.hueBase + e.freqFrac * a.hueRange + a.section * 0.03 + a.colorPulse * 0.02;
        col += hsv(hue, 0.7 * a.satur, 1.0) * bandGlow * (1.0 - a.isSilent);
    }

    return col;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Compose layers ──
    float3 col = skyLayer(uv, p, a);
    float3 terrain = terrainLayer(p, uv, a);
    col = lerp(col, terrain, smoothstep(0.0, 1.0, length(terrain) * 2.0));
    col = blendScreen(col, foregroundLayer(p, uv, a));

    // ── Standard overlays — beat/kick/transient/phrase/section brightness events ──
    // This handles: beat shockwave, kick ring, effect burst, section flash,
    // phrase pulse (16-beat), ambient glow, global brightness (speech-aware)
    col += standardOverlays(p, r, a) * 0.3;

    // ── Brightness limiter — match other modes (HDR headroom at 1.2) ──
    float maxCh = max(col.r, max(col.g, col.b));
    if (maxCh > 1.2) col *= 1.2 / maxCh;

    // ── Post-processing ──
    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
