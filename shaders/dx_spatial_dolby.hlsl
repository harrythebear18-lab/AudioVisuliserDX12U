// Mode 23: Spatial Dolby — 3D spatial audio field simulation
// 16 spectrum objects positioned by actual L/R pan + amplitude every frame
// Objects move with music: pan = X, frequency = Y, loudness = Z depth
// Kick lunges bass forward, transients scatter, stereo width expands field
// Phase coherence links, room grid, brain-driven colors, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

// Project 3D world position to screen space matching cameraRay
float2 projectToScreen(float3 worldPos, float3 camPos, float3 fwd, float3 right, float3 up, float fov) {
    float3 toObj = worldPos - camPos;
    float depth = dot(toObj, fwd);
    if (depth < 0.01) depth = 0.01;
    return float2(dot(toObj, right) / (depth * fov), dot(toObj, up) / (depth * fov));
}

float objDepth(float3 worldPos, float3 camPos, float3 fwd) {
    return dot(worldPos - camPos, fwd);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // DSP complement — additive to brain data, never replaces
    float lufs = lufsNormalized();
    float phase = phaseCoherence();  // 0=out-of-phase, 1=mono

    // ── Background ──
    float3 col = float3(0.008, 0.006, 0.015) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.35;
    col += godRays(p, r, a) * 0.2;

    // ── Camera setup — brain-driven sway, original FOV to avoid bloom ──
    float FOV = 1.0;
    float3 camPos = float3(a.stereoBal * 0.3, 0.2, 2.0);
    float3 camTarget = float3(a.stereoBal * 0.15, 0, -3.0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Room grid — perspective floor and ceiling for spatial reference ──
    // Floor at y=-1.5, ceiling at y=+1.5
    float floorY3D = -1.2;
    float ceilY3D = 1.2;
    float roomZ = -5.0;

    // Floor grid
    {
        float3 rd = normalize(fwd + p.x * right * FOV + p.y * up * FOV);
        float tFloor = (floorY3D - camPos.y) / rd.y;
        if (tFloor > 0.0 && tFloor < 20.0) {
            float3 hitPos = camPos + rd * tFloor;
            float2 gridUV = float2(hitPos.x * 2.0, -hitPos.z * 2.0);
            float2 gridId = abs(frac(gridUV) - 0.5);
            float gridLine = smoothstep(0.48, 0.5, max(gridId.x, gridId.y));
            float gridFade = smoothstep(0.0, 8.0, tFloor) * smoothstep(20.0, 10.0, tFloor);
            col += a.brainCol * gridLine * 0.08 * gridFade * (1.0 - a.isSilent);
            col += a.brainCol2 * gridLine * a.kick * 0.1 * a.kickConf * gridFade * (1.0 - a.isSilent);
        }

        // Ceiling grid
        float tCeil = (ceilY3D - camPos.y) / rd.y;
        if (tCeil > 0.0 && tCeil < 20.0) {
            float3 hitPos = camPos + rd * tCeil;
            float2 gridUV = float2(hitPos.x * 2.0, -hitPos.z * 2.0);
            float2 gridId = abs(frac(gridUV) - 0.5);
            float gridLine = smoothstep(0.48, 0.5, max(gridId.x, gridId.y));
            float gridFade = smoothstep(0.0, 8.0, tCeil) * smoothstep(20.0, 10.0, tCeil);
            col += a.brainCol2 * gridLine * 0.05 * gridFade * (1.0 - a.isSilent);
        }

        // Back wall at z = roomZ
        float tWall = (roomZ - camPos.z) / rd.z;
        if (tWall > 0.0) {
            float3 hitPos = camPos + rd * tWall;
            float2 wallUV = float2(hitPos.x * 2.0, hitPos.y * 2.0);
            float2 wallId = abs(frac(wallUV) - 0.5);
            float wallLine = smoothstep(0.48, 0.5, max(wallId.x, wallId.y));
            float wallFade = smoothstep(0.0, 5.0, tWall) * smoothstep(20.0, 10.0, tWall);
            col += a.brainCol * wallLine * 0.04 * wallFade * (1.0 - a.isSilent);
        }
    }

    // ── 16 spectrum objects — each driven by its own frequency bin ──
    // Every frame, each object's position is computed from actual audio:
    // X = stereo pan (L vs R energy at that frequency) — moves with mix
    // Y = frequency height (bass low, treble high)
    // Z = amplitude depth (loud = close, quiet = far) — lunges on hits
    // Stereo width expands/contracts the whole field dynamically

    #define NUM_OBJ 16
    float3 objPos[NUM_OBJ];
    float objInt[NUM_OBJ];
    float3 objCol[NUM_OBJ];
    float2 objScr[NUM_OBJ];
    float objDep[NUM_OBJ];

    // Stereo width expands/contracts field — dynamic with music
    // DSP phase coherence: mono signal = narrower field, stereo = wider
    float widthScale = 1.0 + a.stereoWid * 1.5;
    widthScale *= (1.0 + (1.0 - phase) * 0.3);  // stereo phase = wider spatial spread
    // Energy pushes everything toward listener on surges
    // LUFS: louder = more intense push toward listener
    float energyPush = a.energy * 0.8 * (1.0 + lufs * 0.2);
    // Kick lunges bass objects forward
    float kickLunge = a.kick * a.kickConf * 1.5;
    // Transient scatters objects vertically
    float transientScatter = a.transient * 0.3;

    [unroll] for (int oi = 0; oi < NUM_OBJ; oi++) {
        float freqFrac = oi / float(NUM_OBJ - 1);  // 0..1 across spectrum

        // Sample L/R energy at this frequency
        float lE = u_spectrum.SampleLevel(u_sampler, float2(freqFrac, 0.166), 0).r;
        float rE = u_spectrum.SampleLevel(u_sampler, float2(freqFrac, 0.833), 0).r;
        float monoE = u_spectrum.SampleLevel(u_sampler, float2(freqFrac, 0.5), 0).r;
        float totalE = lE + rE;

        // Pan: -1 = full left, +1 = full right
        float pan = (rE - lE) / max(totalE, 0.001);

        // X: pan drives horizontal position across full width
        // Bass (low freqFrac) stays more centered, treble spreads wider
        float bassCenter = smoothstep(0.3, 0.0, freqFrac);  // 1 for bass, 0 for treble
        float xPos = pan * widthScale * (1.0 - bassCenter * 0.5) * 2.5;

        // Y: frequency height — bass at bottom, treble at top
        float yPos = (freqFrac - 0.5) * 3.0;
        // Transient scatters objects up/down alternately
        yPos += transientScatter * (oi % 2 == 0 ? 1.0 : -1.0);

        // Z: amplitude depth — louder = closer
        // Kick lunges bass objects toward camera
        float bassWeight = smoothstep(0.25, 0.0, freqFrac);
        float zPos = -0.5 - (1.0 - saturate(monoE * 2.5)) * 5.0 + energyPush + kickLunge * bassWeight;

        objPos[oi] = float3(xPos, yPos, zPos);
        objInt[oi] = monoE;
        float hue = a.hueBase + freqFrac * a.hueRange + a.section * 0.03 + a.colorPulse * 0.04;
        objCol[oi] = hsv(hue, 0.85 * a.satur, 1.3);
        objDep[oi] = objDepth(objPos[oi], camPos, fwd);
        objScr[oi] = projectToScreen(objPos[oi], camPos, fwd, right, up, FOV);
    }

    // ── Render objects back-to-front ──
    [loop] for (int ri = NUM_OBJ - 1; ri >= 0; ri--) {
        float depth = objDep[ri];
        if (depth < 0.1) continue;

        float2 scrPos = objScr[ri];
        float screenDist = length(p - scrPos);
        float intensity = objInt[ri];
        float3 oCol = objCol[ri];

        // Depth-based size — closer = bigger
        float baseSize = 0.04 + intensity * 0.08;
        float screenSize = baseSize / depth * 3.0;

        // Outer glow — LUFS boosts intensity (additive to brain)
        float outerGlow = exp(-screenDist * screenDist / (screenSize * screenSize * 6.0));
        col += oCol * outerGlow * intensity * 0.3 * (1.0 + lufs * 0.2) * (1.0 - a.isSilent);

        // Mid glow — main body
        float midGlow = exp(-screenDist * screenDist / (screenSize * screenSize * 2.0));
        col += oCol * midGlow * (0.2 + intensity * 0.5) * 0.5 * (1.0 - a.isSilent);

        // Core — bright center when active
        float coreGlow = exp(-screenDist * screenDist / (screenSize * screenSize * 0.3));
        col += float3(0.9, 0.95, 1.0) * coreGlow * intensity * 0.6 * a.bloomActive * (1.0 - a.isSilent);

        // Transient sound wave ring
        if (a.transient > 0.2) {
            float waveR = a.transient * screenSize * 6.0;
            float waveRing = exp(-abs(screenDist - waveR) * 50.0 / depth) * a.transient * 0.25;
            col += oCol * waveRing * (1.0 - a.isSilent);
        }
    }

    // ── Phase coherence links between adjacent active objects ──
    [loop] for (int ci = 0; ci < NUM_OBJ - 1; ci++) {
        if (objInt[ci] < 0.12 || objDep[ci] < 0.1) continue;
        if (objInt[ci + 1] < 0.12 || objDep[ci + 1] < 0.1) continue;
        float2 a2 = objScr[ci];
        float2 b2 = objScr[ci + 1];
        float2 lineDir = b2 - a2;
        float lineLen = length(lineDir);
        if (lineLen < 0.01 || lineLen > 2.5) continue;
        float2 lineNorm = lineDir / lineLen;
        float proj = clamp(dot(p - a2, lineNorm), 0.0, lineLen);
        float2 closest = a2 + lineNorm * proj;
        float lineDist = length(p - closest);
        float lineStr = a.phaseCorr * objInt[ci] * objInt[ci + 1] * 0.08;
        // DSP phase coherence: mono signal = stronger spatial coherence links
        lineStr *= (1.0 + phase * 0.5);
        float lineGlow = exp(-lineDist * lineDist * 500.0) * lineStr;
        col += objCol[ci] * lineGlow * (1.0 - a.isSilent);
    }

    // ── Listener position — marker at camera focal point ──
    float2 listenerPos = projectToScreen(float3(0, 0, -2.0), camPos, fwd, right, up, FOV);
    float listenDist = length(p - listenerPos);
    float listenGlow = exp(-listenDist * listenDist * 80.0) * 0.15;
    col += a.brainCol * listenGlow * (1.0 - a.isSilent);
    // Beat pulse from listener — only on actual beat detection
    float beatPulseR = a.beat * 0.15 * a.tempoConf;
    float listenPulse = exp(-abs(listenDist - beatPulseR) * 30.0) * a.beat * 0.25 * a.tempoConf;
    col += a.brainCol2 * listenPulse * (1.0 - a.isSilent);

    // ── Kick flash from listener — only on kick ──
    float kickFlash = exp(-listenDist * listenDist * 6.0) * a.kick * 0.3 * a.kickConf;
    col += a.brainCol2 * kickFlash * a.bloomActive * (1.0 - a.isSilent);

    // ── Transient sparks — objects appearing momentarily ──
    float sparkN = hash21(floor(p * 20.0) + floor(Time * 12.0));
    float sparks = step(0.96, sparkN) * a.transient * 0.2;
    col += float3(0.9, 0.95, 1.0) * sparks * a.beamActive * (1.0 - a.isSilent);

    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.3;

    // ── Post-processing ──
    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
