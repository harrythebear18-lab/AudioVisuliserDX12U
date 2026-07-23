// ============================================================================
// HUD 25: 3D Spatial Soundscape (dx_spatial_dolby.hlsl)
// DX12U Layer 0 — Enhanced 3D spatial audio field with full band × channel
// separation. 8 brain bands split into 16 objects (L+R per band), each driven
// by its own stereo energy, phase correlation, and brain band modulation.
//
// Architecture:
//   Band 0 (b0 Sub)   → L obj + R obj — deep bass, lowest Y, kick-lunge
//   Band 1 (b1 Bass)  → L obj + R obj — bass, low Y, kick-lunge
//   Band 2 (b2 LMid)  → L obj + R obj — low-mid, lower-mid Y
//   Band 3 (b3 Mid)   → L obj + R obj — mid, mid Y
//   Band 4 (b4 HMid)  → L obj + R obj — high-mid, upper-mid Y
//   Band 5 (b5 Pres)  → L obj + R obj — presence, high Y
//   Band 6 (b6 Bril)  → L obj + R obj — brilliance, higher Y
//   Band 7 (b7 Air)   → L obj + R obj — air, highest Y, edge fade
//
// Each L object samples left spectrum at its band frequency.
// Each R object samples right spectrum at its band frequency.
// Phase correlation between L/R pairs drives horizontal beam links.
// Phase correlation between adjacent same-side bands drives vertical links.
//
// Spatial mapping:
//   X = side (L=-, R=+) + pan modulation + stereo width expansion
//   Y = band frequency height (bass bottom → air top)
//   Z = per-channel amplitude depth (loud=close, quiet=far)
//
// Audio events:
//   beat → coherent pulse from listener position, all objects brighten
//   kick → bass bands (0-1) lunge forward, warm flash
//   transient → scatter displacement + expanding sound wave rings per object
//   section → unlocks more visual complexity (link density, ring count)
//   envelope → overall emission gain
//
// DSP additive: LUFS→emission boost, crest→object sharpness/core tightness,
//               THD→position jitter, phase→L/R link coherence strength.
//
// HDR output to shared pipeline. No local postfx, tonemapping, or bloom.
// ============================================================================
#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_BANDS 8
#define NUM_OBJ 16  // 8 bands × 2 (L/R)

// Band frequency centers in spectrum texture U coordinate
static const float bandFreq[N_BANDS] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

// Project 3D world position to screen space
float2 projectToScreen(float3 worldPos, float3 camPos, float3 fwd, float3 right, float3 up, float fov) {
    float3 toObj = worldPos - camPos;
    float depth = dot(toObj, fwd);
    if (depth < 0.01) depth = 0.01;
    return float2(dot(toObj, right) / (depth * fov), dot(toObj, up) / (depth * fov));
}

float objDepth(float3 worldPos, float3 camPos, float3 fwd) {
    return dot(worldPos - camPos, fwd);
}

// Distance from point to line segment
float distToSeg(float2 p, float2 a, float2 b, out float2 closest) {
    float2 ab = b - a;
    float lenSq = dot(ab, ab);
    if (lenSq < 0.0001) { closest = a; return length(p - a); }
    float t = clamp(dot(p - a, ab) / lenSq, 0.0, 1.0);
    closest = a + ab * t;
    return length(p - closest);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    // ── DSP additive ──
    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();  // 0=out-of-phase, 1=mono

    // ── Background — deep spatial void ──
    float3 col = float3(0.004, 0.003, 0.012) * silence;
    col += starfield(uv, a) * 0.02;
    col += godRays(p, r, a) * 0.08 * silence;

    // ── Camera — section-driven orbit with stereo drift ──
    float FOV = 0.9;
    float camAng = a.section * 0.15 + a.stereoBal * 0.12 + Time * 0.008 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 1.5 + a.stereoBal * 0.3, 0.3 + a.stereoDiff * 0.1, 2.8 + cos(camAng) * 0.5);
    float3 camTarget = float3(a.stereoBal * 0.1, 0, -3.0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Room grid — perspective floor, ceiling, back wall ──
    float floorY3D = -1.5;
    float ceilY3D = 1.5;
    float roomZ = -6.0;
    {
        float3 rd = normalize(fwd + p.x * right * FOV + p.y * up * FOV);
        // Floor
        float tFloor = (floorY3D - camPos.y) / rd.y;
        if (tFloor > 0.0 && tFloor < 25.0) {
            float3 hitPos = camPos + rd * tFloor;
            float2 gridUV = float2(hitPos.x * 2.5, -hitPos.z * 2.0);
            float2 gridId = abs(frac(gridUV) - 0.5);
            float gridLine = smoothstep(0.47, 0.5, max(gridId.x, gridId.y));
            float gridFade = smoothstep(0.0, 8.0, tFloor) * smoothstep(25.0, 12.0, tFloor);
            col += a.brainCol * gridLine * 0.06 * gridFade * silence;
            col += a.brainCol2 * gridLine * a.kick * 0.08 * a.kickConf * gridFade * silence;
        }
        // Ceiling
        float tCeil = (ceilY3D - camPos.y) / rd.y;
        if (tCeil > 0.0 && tCeil < 25.0) {
            float3 hitPos = camPos + rd * tCeil;
            float2 gridUV = float2(hitPos.x * 2.5, -hitPos.z * 2.0);
            float2 gridId = abs(frac(gridUV) - 0.5);
            float gridLine = smoothstep(0.47, 0.5, max(gridId.x, gridId.y));
            float gridFade = smoothstep(0.0, 8.0, tCeil) * smoothstep(25.0, 12.0, tCeil);
            col += a.brainCol2 * gridLine * 0.04 * gridFade * silence;
        }
        // Back wall
        float tWall = (roomZ - camPos.z) / rd.z;
        if (tWall > 0.0) {
            float3 hitPos = camPos + rd * tWall;
            float2 wallUV = float2(hitPos.x * 2.0, hitPos.y * 2.0);
            float2 wallId = abs(frac(wallUV) - 0.5);
            float wallLine = smoothstep(0.47, 0.5, max(wallId.x, wallId.y));
            float wallFade = smoothstep(0.0, 5.0, tWall) * smoothstep(25.0, 12.0, tWall);
            col += a.brainCol * wallLine * 0.03 * wallFade * silence;
        }
    }

    // ── Spatial field parameters ──
    float widthScale = 1.0 + a.stereoWid * 1.8;
    widthScale *= (1.0 + (1.0 - phaseCoh) * 0.4);  // stereo phase = wider spread
    float energyPush = a.energy * 0.6 * (1.0 + lufs * 0.25);
    float kickLunge = a.kick * a.kickConf * 1.8;
    float transientScatter = a.transient * 0.35;
    float beatBright = a.beat * a.tempoConf;
    float sectionBoost = 1.0 + a.section * 0.08;

    // Brain band values for per-band modulation
    float bands[N_BANDS];
    bands[0] = a.b0; bands[1] = a.b1; bands[2] = a.b2; bands[3] = a.b3;
    bands[4] = a.b4; bands[5] = a.b5; bands[6] = a.b6; bands[7] = a.b7;

    // ── 16 spatial objects: 8 bands × L/R ──
    float3 objPos[NUM_OBJ];
    float objInt[NUM_OBJ];
    float3 objCol[NUM_OBJ];
    float2 objScr[NUM_OBJ];
    float objDep[NUM_OBJ];
    float objSize[NUM_OBJ];
    float objActive[NUM_OBJ];

    [unroll] for (int bi = 0; bi < N_BANDS; bi++)
    {
        float freqU = bandFreq[bi];
        float bandVal = bands[bi];
        float bandGate = smoothstep(0.02, 0.08, bandVal);

        // Y position — band frequency height
        float baseY = (float(bi) / float(N_BANDS - 1) - 0.5) * 3.2;

        // Bass weight for kick lunge
        float bassWeight = smoothstep(2.0, 0.0, float(bi));

        // THD jitter
        float jt = floor(Time * 4.0);
        float jitterX = (hash11(float(bi) * 17.3 + jt) - 0.5) * thd * 0.04;
        float jitterY = (hash11(float(bi) * 19.7 + jt) - 0.5) * thd * 0.03;

        // ── Left object (index = bi * 2) ──
        {
            int idx = bi * 2;
            float lE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.166), 0).r;
            float lEnergy = max(lE, bandVal * 0.5) * bandGate;

            // X: left side, modulated by pan and stereo width
            float panMod = (lE / max(lE + u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.833), 0).r, 0.001));
            float xPos = -widthScale * (0.8 + panMod * 0.4) * (1.0 - bassWeight * 0.3);
            xPos += jitterX;

            // Transient scatter — independent per side
            float yPos = baseY + transientScatter * (bi % 2 == 0 ? 1.0 : -0.7);

            // Z: amplitude depth — louder = closer
            float zPos = -0.5 - (1.0 - saturate(lEnergy * 2.5)) * 5.0 + energyPush + kickLunge * bassWeight;

            objPos[idx] = float3(xPos, yPos + jitterY, zPos);
            objInt[idx] = lEnergy;
            objActive[idx] = bandGate;

            // Color — left channel gets brainCol blend
            float hue = a.hueBase + float(bi) / float(N_BANDS - 1) * a.hueRange + a.section * 0.03;
            float3 c = hsv(hue, 0.8 * a.satur, 1.0);
            c = lerp(c, a.brainCol, 0.3);
            c = lerp(c, a.brainCol2, float(bi) / float(N_BANDS - 1) * 0.3);
            objCol[idx] = c;

            objDep[idx] = objDepth(objPos[idx], camPos, fwd);
            objScr[idx] = projectToScreen(objPos[idx], camPos, fwd, right, up, FOV);
            objSize[idx] = (0.035 + lEnergy * 0.06) / max(objDep[idx] * 0.3, 0.3) * 3.0;
            objSize[idx] /= (1.0 + crest * 0.3);
        }

        // ── Right object (index = bi * 2 + 1) ──
        {
            int idx = bi * 2 + 1;
            float rE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.833), 0).r;
            float rEnergy = max(rE, bandVal * 0.5) * bandGate;

            float panMod = (rE / max(rE + u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.166), 0).r, 0.001));
            float xPos = widthScale * (0.8 + panMod * 0.4) * (1.0 - bassWeight * 0.3);
            xPos += jitterX;

            float yPosR = baseY + transientScatter * (bi % 2 == 1 ? 1.0 : -0.7);

            float zPos = -0.5 - (1.0 - saturate(rEnergy * 2.5)) * 5.0 + energyPush + kickLunge * bassWeight;

            objPos[idx] = float3(xPos, yPosR + jitterY, zPos);
            objInt[idx] = rEnergy;
            objActive[idx] = bandGate;

            // Color — right channel gets brainCol2 blend
            float hue = a.hueBase + float(bi) / float(N_BANDS - 1) * a.hueRange + a.section * 0.03 + 0.03;
            float3 c = hsv(hue, 0.8 * a.satur, 1.0);
            c = lerp(c, a.brainCol2, 0.3);
            c = lerp(c, a.brainCol, float(bi) / float(N_BANDS - 1) * 0.2);
            objCol[idx] = c;

            objDep[idx] = objDepth(objPos[idx], camPos, fwd);
            objScr[idx] = projectToScreen(objPos[idx], camPos, fwd, right, up, FOV);
            objSize[idx] = (0.035 + rEnergy * 0.06) / max(objDep[idx] * 0.3, 0.3) * 3.0;
            objSize[idx] /= (1.0 + crest * 0.3);
        }
    }

    // ── Render objects back-to-front ──
    [loop] for (int ri = NUM_OBJ - 1; ri >= 0; ri--)
    {
        if (objActive[ri] < 0.01) continue;
        float depth = objDep[ri];
        if (depth < 0.1) continue;

        float2 scrPos = objScr[ri];
        float screenDist = length(p - scrPos);
        float intensity = objInt[ri];
        float3 oCol = objCol[ri];
        float screenSize = objSize[ri];

        // Outer halo — LUFS additive boost
        float outerGlow = exp(-screenDist * screenDist / (screenSize * screenSize * 8.0));
        col += oCol * outerGlow * intensity * 0.25 * (1.0 + lufs * 0.25) * silence;

        // Mid body
        float midGlow = exp(-screenDist * screenDist / (screenSize * screenSize * 2.5));
        col += oCol * midGlow * (0.15 + intensity * 0.5) * 0.4 * silence;

        // Core — crest sharpens, beat brightens
        float coreGlow = exp(-screenDist * screenDist / (screenSize * screenSize * 0.25));
        float coreBright = intensity * (0.5 + beatBright * 0.5) * (1.0 + crest * 0.3);
        col += float3(0.9, 0.95, 1.0) * coreGlow * coreBright * 0.5 * silence;

        // Band-specific accents
        int bandIdx = ri / 2;
        if (bandIdx == 0 || bandIdx == 1) {
            // Bass bands — warm kick glow
            col += float3(1.0, 0.5, 0.15) * coreGlow * kickLunge * intensity * 0.15 * silence;
        }
        if (bandIdx == 5) {
            // Presence — hot white core
            col += float3(0.95, 0.92, 1.0) * coreGlow * intensity * bands[5] * 0.12 * silence;
        }
        if (bandIdx == 7) {
            // Air — edge dissipation
            float airFade = 1.0 - bands[7] * smoothstep(0.02, 0.08, bands[7]) * 0.15 * smoothstep(0.5, 1.5, abs(scrPos.x));
            col *= lerp(1.0, airFade, 0.3);
        }

        // Transient sound wave ring — expanding from object
        if (a.transient > 0.15)
        {
            float waveR = a.transient * screenSize * 5.0;
            float waveRing = exp(-abs(screenDist - waveR) * 60.0 / depth) * a.transient * 0.2;
            col += oCol * waveRing * silence;
            // Second ring at different phase
            float waveR2 = a.transient * screenSize * 9.0;
            float waveRing2 = exp(-abs(screenDist - waveR2) * 80.0 / depth) * a.transient * 0.1;
            col += oCol * waveRing2 * silence;
        }

        // Beat pulse ring — synchronized
        if (beatBright > 0.1)
        {
            float beatR = a.beatPhase * screenSize * 4.0;
            float beatRing = exp(-abs(screenDist - beatR) * 100.0 / depth) * beatBright * 0.08;
            col += oCol * beatRing * silence;
        }
    }

    // ── Phase coherence links ──
    // Type 1: L↔R horizontal beams (same band, left to right)
    [loop] for (int lb = 0; lb < N_BANDS; lb++)
    {
        int li = lb * 2;
        int ri2 = lb * 2 + 1;
        if (objActive[li] < 0.05 || objActive[ri2] < 0.05) continue;
        if (objDep[li] < 0.1 || objDep[ri2] < 0.1) continue;
        if (objInt[li] < 0.08 || objInt[ri2] < 0.08) continue;

        float2 a2 = objScr[li];
        float2 b2 = objScr[ri2];
        float2 closest;
        float lineDist = distToSeg(p, a2, b2, closest);

        // Link strength — phase coherence × both intensities
        float linkStr = a.phaseCorr * objInt[li] * objInt[ri2] * 0.12;
        linkStr *= (0.5 + phaseCoh * 0.5);
        linkStr *= sectionBoost;

        float lineGlow = exp(-lineDist * lineDist * 600.0) * linkStr;
        float3 linkCol = lerp(objCol[li], objCol[ri2], 0.5);
        col += linkCol * lineGlow * silence;

        // Phase coherence midpoint glow — constructive interference
        if (phaseCoh > 0.5)
        {
            float2 midPt = (a2 + b2) * 0.5;
            float midDist = length(p - midPt);
            float midGlow = exp(-midDist * midDist * 800.0) * phaseCoh * objInt[li] * objInt[ri2] * 0.08;
            col += float3(0.85, 0.9, 1.0) * midGlow * silence;
        }
    }

    // Type 2: Vertical links (adjacent bands, same side) — section-gated
    if (a.section > 1.0)
    {
        [loop] for (int side = 0; side < 2; side++)
        {
            [loop] for (int vb = 0; vb < N_BANDS - 1; vb++)
            {
                int i1 = vb * 2 + side;
                int i2 = (vb + 1) * 2 + side;
                if (objActive[i1] < 0.05 || objActive[i2] < 0.05) continue;
                if (objDep[i1] < 0.1 || objDep[i2] < 0.1) continue;
                if (objInt[i1] < 0.1 || objInt[i2] < 0.1) continue;

                float2 a2 = objScr[i1];
                float2 b2 = objScr[i2];
                float2 closest;
                float lineDist = distToSeg(p, a2, b2, closest);

                float linkStr = a.phaseCorr * objInt[i1] * objInt[i2] * 0.06;
                linkStr *= smoothstep(1.0, 4.0, a.section);

                float lineGlow = exp(-lineDist * lineDist * 800.0) * linkStr;
                col += objCol[i1] * lineGlow * silence;
            }
        }
    }

    // ── Listener position — focal point marker ──
    float2 listenerPos = projectToScreen(float3(0, 0, -2.0), camPos, fwd, right, up, FOV);
    float listenDist = length(p - listenerPos);
    float listenGlow = exp(-listenDist * listenDist * 100.0) * 0.12;
    col += a.brainCol * listenGlow * silence;

    // Beat pulse from listener
    float beatPulseR = a.beatPhase * 0.2 * a.tempoConf;
    float listenPulse = exp(-abs(listenDist - beatPulseR) * 35.0) * a.beat * 0.2 * a.tempoConf;
    col += a.brainCol2 * listenPulse * silence;

    // Kick flash from listener
    float kickFlashVal = exp(-listenDist * listenDist * 8.0) * a.kick * 0.25 * a.kickConf;
    col += float3(1.0, 0.5, 0.15) * kickFlashVal * silence;

    // ── Transient sparks ──
    if (a.transient > 0.1)
    {
        float sparkN = hash21(floor(p * 25.0) + floor(Time * 15.0));
        float sparks = step(0.96, sparkN) * a.transient * 0.15;
        col += float3(0.9, 0.95, 1.0) * sparks * a.beamActive * silence;
    }

    // ── Envelope swell ──
    col += a.brainCol2 * a.envelope * 0.008 * exp(-r * 2.5) * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.01 * silence;

    // ── Energy + punch ──
    col += a.brainCol * a.energy * 0.005 * silence;
    col += a.brainCol2 * a.punch * 0.005 * silence;

    // ── Smooth overlays — no frac() teleport ──
    {
        float t = Time * (0.3 + a.dynamic * 1.5 + a.profBass * 0.5);
        float swR = (sin(t * 0.25) * 0.5 + 0.5) * 1.8;
        float sw = exp(-abs(r - swR) * 16.0) * a.beat * 0.12 * a.tempoConf;
        col += hsv(a.hueCenter + 0.1, 0.6, 1.0) * sw * 0.015 * silence;
        float kickR = (sin(t * 0.5) * 0.5 + 0.5) * 1.5 + 0.3;
        float kickRing = exp(-abs(r - kickR) * 20.0) * a.kick * 0.05 * a.kickConf;
        col += hsv(a.hueCenter, 0.3, 1.0) * kickRing * 0.015 * silence;
        col += hsv(a.hueCenter, 0.2, 0.3) * smoothstep(1.0, 0.3, r) * (0.01 + a.atmos * 0.04) * a.ambActive * 0.008 * silence;
        col *= (1.0 + sin(a.phraseBeat / 16.0 * 3.14159) * 0.06 * a.energy);
    }

    // ── HDR brightness limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    return float4(col, 1.0);
}
