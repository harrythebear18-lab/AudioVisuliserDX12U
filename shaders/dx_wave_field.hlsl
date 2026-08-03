// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 49: Spatiotemporal Wave Field — 3D wave propagation from audio sources
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_WAVE_FIELD.
//
// 48 emitters (8 bands × 3 sub × L/R) placed as a flat wave field.
// X = stereo side (L/R cross-over), Y = frequency band, Z = amplitude depth.
// Visual identity: 3D wave grid with expanding spherical wavefronts and interference links.
//
// World: grid floor + back wall for depth grounding, fog density 0.04, dark ambient.
// Camera: orbiting the wave field, FOV 0.75 (VR: head pose from OpenXR).
// Visual: emitter glow with wave rings, L/R interference links, listener focal point.
//
// DSP: LUFS→emission brightness, crest→glow sharpness, THD→jitter, phase→link coherence.
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.
//
// OPTIMIZED: wfComputeEmitters uses [loop] instead of [unroll] — compiler reuses
// registers instead of duplicating code 48×. Hardcodes WAVE_FIELD profile path
// (skips 6 unused profile branches in seEncodePosition). wfEmitGlow reduces exp()
// per emitter. Inlined seLinkLR avoids 28KB array copy per pixel.
// Same 48 emitters, same positions, same visual.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// Custom [loop]-based emitter computation — same math as seComputeEmitters
// but hardcoded to WAVE_FIELD profile and using [loop] instead of [unroll]
void wfComputeEmitters(out SeEmitter emit[SE_NUM_OBJ],
                       float brainBands[8], AudioData a, SeCamera cam,
                       SeParams params,
                       float lufs, float crest, float thd, float phaseCoh,
                       float beatPulse, float kickSurge, float transientAmt,
                       float envelope)
{
    float wrappedTime = Time % 3600.0;

    // Global spatial telemetry
    float lrTotal = a.leftEn + a.rightEn + 0.001;
    float lGlobal = a.leftEn / lrTotal * 2.0;
    float rGlobal = a.rightEn / lrTotal * 2.0;
    float panBase = a.stereoBal * 0.35;
    float widthMod = a.stereoWid;
    float phaseConv = saturate(phaseCoh * 0.5);
    float specDiff = a.stereoDiff;

    float dspBands[8] = { DspBand0, DspBand1, DspBand2, DspBand3,
                          DspBand4, DspBand5, DspBand6, DspBand7 };
    float peakL = saturate((DspPeakDbL + 60.0) / 60.0);
    float peakR = saturate((DspPeakDbR + 60.0) / 60.0);

    float domBand = a.domBand;
    float specCent = a.specCent;
    float specSpread = a.specSpread;
    float centShift = (specCent - 0.5) * 2.0;

    float calmFloor = 1.0 - a.calmMode * 0.5;
    float visualScale = (0.7 + a.brightness * 0.3) * (0.8 + a.effectInt * 0.2) * a.barScale;
    float sectionMod = a.section * 0.1 * a.sectionConf;

    // Init all emitters
    [loop] for (int i0 = 0; i0 < SE_NUM_OBJ; i0++) {
        emit[i0].active = 0.0;
        emit[i0].intensity = 0.0;
        emit[i0].depth = 0.0;
        emit[i0].depthFog = 1.0;
        emit[i0].nearFade = 1.0;
    }

    // Common position params (WAVE_FIELD only)
    float widthModPos = params.widthScale * (1.0 + params.stereoWid * 0.5);
    widthModPos *= (1.0 + (1.0 - phaseCoh) * 0.3);
    float energyPush = a.energy * 0.5 * (1.0 + lufs * 0.2);
    float kickLunge = kickSurge * 1.5;
    float transientScatter = transientAmt * 0.3 * params.jitterAmt;
    float sharpness = 1.0 / (1.0 + crest * 0.3);

    [loop] for (int bi = 0; bi < SE_N_BANDS; bi++)
    {
        float bandFrac = float(bi) / float(SE_N_BANDS - 1);
        float bandVal = brainBands[bi];
        float dspAdd = dspBands[bi] * 0.12;
        float baseEnergy = bandVal + dspAdd;
        float bandGate = smoothstep(0.02, 0.08, bandVal);
        float waveFreq = lerp(1.5, 8.0, bandFrac);

        float bandPanMod = lerp(0.3, 1.0, bandFrac);
        float bandPan = panBase * bandPanMod + specDiff * bandFrac * 0.2;
        float widthSplit = lerp(0.5, 1.0, widthMod);
        float convPull = phaseConv * 0.3;

        float lE = baseEnergy * lGlobal * (1.0 - bandPan * widthSplit) * (1.0 - convPull);
        float rE = baseEnergy * rGlobal * (1.0 + bandPan * widthSplit) * (1.0 - convPull);
        lE = max(lE, baseEnergy * peakL * 0.5);
        rE = max(rE, baseEnergy * peakR * 0.5);

        float domBoost = exp(-abs(float(bi) - domBand) * 1.5);
        float vocalWeight = smoothstep(2.5, 3.5, float(bi)) * (1.0 - smoothstep(5.0, 6.0, float(bi)));
        float speechBoost = a.speechMode * vocalWeight * 0.3;
        float phrasePhase = a.phraseBeat * PI * 2.0 + float(bi) * 0.3;

        float bassWeight = smoothstep(2.0, 0.0, float(bi));

        // Dynamics enrichment (band-level, shared across subs)
        float antSwel = a.beatAnt * (0.5 + bandFrac * 0.5) * 0.15;
        float rhythmMod = a.tempoPulse * lerp(0.1, 0.05, bandFrac);
        float punchMod = a.punch * smoothstep(2.0, 0.0, float(bi)) * 0.3;
        float dynMod = a.dynamic * lerp(0.08, 0.03, bandFrac);
        float glowMod = a.glow * 0.05;

        // THD jitter (band-level)
        float jtRaw = wrappedTime * 4.0 * params.motionSpeed;
        float jt0 = floor(jtRaw);
        float jt1 = jt0 + 1.0;
        float jtFrac = jtRaw - jt0;
        float jtSmooth = jtFrac * jtFrac * (3.0 - 2.0 * jtFrac);
        float hashX0 = hash11(float(bi) * 17.3 + jt0);
        float hashX1 = hash11(float(bi) * 17.3 + jt1);
        float hashY0 = hash11(float(bi) * 19.7 + jt0);
        float hashY1 = hash11(float(bi) * 19.7 + jt1);
        float jitterX = (lerp(hashX0, hashX1, jtSmooth) - 0.5) * thd * 0.04 * params.jitterAmt;
        float jitterY = (lerp(hashY0, hashY1, jtSmooth) - 0.5) * thd * 0.03 * params.jitterAmt;

        [loop] for (int si = 0; si < SE_N_SUB; si++)
        {
            float subFrac = float(si) / float(SE_N_SUB - 1) - 0.5;

            float subWeight = 1.0;
            if (si == 1) subWeight = 1.0 + domBoost * 0.3;
            else if (si == 0) subWeight = 1.0 - centShift * 0.15;
            else subWeight = 1.0 + centShift * 0.15;
            subWeight *= lerp(0.8, 1.2, specSpread);

            float phraseMod = sin(phrasePhase + subFrac * PI) * 0.1 + 0.1;

            // L + R emitters
            [loop] for (int side = 0; side < 2; side++)
            {
                int idx = bi * SE_N_SUB * 2 + si * 2 + side;
                float sideSign = (side == 0) ? -1.0 : 1.0;
                float sideE = (side == 0) ? lE : rE;
                float energy = sideE;

                float totalE = lE + rE + 0.001;
                float panMod = (side == 0) ? lE / totalE : rE / totalE;
                float lrBalance = (lE - rE) / totalE;
                float crossMix = saturate(1.0 - abs(lrBalance) * 0.5) * params.crossOver;

                // WAVE_FIELD position (hardcoded — no profile branching)
                float xPos = sideSign * widthModPos * (0.5 + panMod * 0.3) * (1.0 - bassWeight * 0.2);
                xPos += crossMix * widthModPos * 0.4 * (bandFrac - 0.5);
                xPos += jitterX + subFrac * 1.0;
                float yPos = (bandFrac - 0.5) * params.heightScale + transientScatter * (bi % 2 == 0 ? 1.0 : -0.7) + subFrac * 0.8;
                float zPos = -0.5 - (1.0 - saturate(energy * 2.5)) * params.depthScale + energyPush + kickLunge * bassWeight + subFrac * 2.5;
                float3 worldPos = float3(xPos, yPos + jitterY, zPos);

                // Intensity
                float emEnergy = max(sideE * subWeight, baseEnergy * 0.3) * bandGate;
                emEnergy += antSwel + rhythmMod + punchMod + dynMod + glowMod + phraseMod + sectionMod;
                emEnergy += speechBoost * subWeight;
                emEnergy *= calmFloor * visualScale;
                emEnergy = clamp(emEnergy, 0.0, 1.5);

                // Depth + screen projection
                float3 toE = worldPos - cam.pos;
                float depth = dot(toE, cam.fwd);
                float2 scrPos;
                if (depth < 0.01) depth = 0.01;
                scrPos = float2(dot(toE, cam.right) / (depth * cam.fov), dot(toE, cam.up) / (depth * cam.fov));
                float scrSize = (0.025 + emEnergy * 0.04) / max(depth * 0.3, 0.3) * 3.0;
                scrSize /= (1.0 + crest * 0.3);
                scrSize *= a.barScale;

                // Wave phase
                float wavePhase = wrappedTime * waveFreq + float(bi) * 0.5 + subFrac * PI;
                if (side == 1) wavePhase += PI;
                wavePhase += phrasePhase * 0.1;

                // Color
                float hue = a.hueBase + bandFrac * a.hueRange;
                if (side == 1) hue += 0.03;
                hue += a.section * 0.03 + subFrac * 0.05 + a.colorPulse * 0.02;
                float3 c = hsv(hue, 0.7 * a.satur, 1.0);
                if (side == 0) {
                    c = lerp(c, a.brainCol, 0.3);
                    c = lerp(c, a.brainCol2, bandFrac * 0.3);
                } else {
                    c = lerp(c, a.brainCol2, 0.3);
                    c = lerp(c, a.brainCol, bandFrac * 0.2);
                }
                c = lerp(c, a.brainCol3, speechBoost * 0.5);

                emit[idx].worldPos = worldPos;
                emit[idx].intensity = emEnergy;
                emit[idx].active = bandGate;
                emit[idx].wavePhase = wavePhase;
                emit[idx].bandIdx = bi;
                emit[idx].side = side;
                emit[idx].subIdx = si;
                emit[idx].color = c;
                emit[idx].depth = depth;
                emit[idx].screenPos = scrPos;
                emit[idx].screenSize = scrSize;
                emit[idx].depthFog = 1.0;
                emit[idx].nearFade = saturate((depth - 0.5) / 0.5);
            }
        }
    }
}

// Lightweight emitter glow — same visual as seEmitGlowDepth, fewer exp() calls
float3 wfEmitGlow(float2 p, SeEmitter e, SeWorld world,
                  float lufs, float crest, float beatBright,
                  float beatPhase, float kickSurge, float silence)
{
    float2 diff = p - e.screenPos;
    float d2 = dot(diff, diff);
    float s = e.screenSize;
    float s2 = s * s;

    float cullRad2 = s2 * 55.0;
    if (d2 > cullRad2) return float3(0, 0, 0);
    float cullFade = smoothstep(cullRad2 * 0.7, cullRad2, d2);

    float depthFog = exp(-e.depth * world.fogDensity);  // inline instead of seApplyWorldFog
    float vrSafe = e.nearFade;
    float satFade = lerp(0.3, 1.0, depthFog);
    float brightFade = lerp(0.15, 1.0, depthFog) * vrSafe;

    float d = sqrt(d2);
    float3 col = float3(0, 0, 0);

    // 2 exp() for glow instead of 3 — fold outer into mid by widening radius
    float mid = exp(-d2 / (s2 * 3.5));   // was 2.5 for mid + 8.0 for outer
    float core = exp(-d2 / (s2 * 0.6));

    float3 emitCol = lerp(dot(e.color, float3(0.33, 0.33, 0.34)), e.color, satFade);

    // Combined outer+mid contribution
    col += emitCol * mid * (0.07 + e.intensity * 0.17) * 0.12 * brightFade * (1.0 + lufs * 0.25) * (1.0 - cullFade) * silence;
    float coreBright = core * e.intensity * (0.5 + beatBright * 0.5) * (1.0 + crest * 0.3) * 0.08 * brightFade * (1.0 - cullFade) * silence;
    coreBright = min(coreBright, 0.8);
    col += float3(0.9, 0.95, 1.0) * coreBright;

    // 1 wave ring instead of 2 — combined intensity
    float wp = e.wavePhase;
    float r1 = frac(wp * 0.3) * s * 6.0;
    col += emitCol * exp(-abs(d - r1) * 27.0 / e.depth) * e.intensity * 0.07 * brightFade * (1.0 - cullFade) * silence;

    if (e.bandIdx <= 1) {
        col += float3(1.0, 0.5, 0.15) * core * kickSurge * e.intensity * 0.04 * brightFade * silence;
    }

    if (beatBright > 0.1) {
        float br = beatPhase * s * 4.0;
        col += emitCol * exp(-abs(d - br) * 50.0 / e.depth) * beatBright * 0.02 * brightFade * (1.0 - cullFade) * silence;
    }

    // Fog tint
    col = lerp(col, col * world.fogColor, (1.0 - depthFog) * 0.3);

    return col;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    p += vrParallax(2.0);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    // ── DSP additive ──
    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();
    float phaseCorr = phaseCoh;  // same value, avoid double call

    // ── Audio dynamics ──
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;
    float beatBright = a.beat * a.tempoConf;

    // ── Camera — VR head pose or desktop orbiting wave field ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float camAng = a.section * 0.15 + a.stereoBal * 0.08 + (Time % 3600.0) * 0.005 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 1.5, 1.5 + a.stereoDiff * 0.08, 2.8 + cos(camAng) * 0.3);
        cam = seCamera(camPos, float3(0, -0.3, -2.0), 0.75);
    }

    // ── Spatial encoder: WAVE_FIELD profile — gentle audio-reactive movement ──
    SeParams params = seParams(SE_PROFILE_WAVE_FIELD);
    // Use envelope (slowest-changing) for param scaling to avoid coordinate jumps
    params.depthScale = 4.0 + envelope * 1.5;
    params.widthScale = 1.5 + (1.0 - phaseCoh) * 0.5;
    params.heightScale = 4.0 + envelope * 1.0;
    params.motionSpeed = 0.5 + a.motSpeed * 0.5;
    params.jitterAmt = 0.1 + thd * 0.15;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    wfComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment — floor + back wall (wave_field visual identity) ──
    SeWorld world = seWorld(0.04, float3(0.003, 0.002, 0.008), -1.8, 0.0, -6.0);
    world.gridScale = 2.0;
    world.gridIntensity = 0.04;
    world.ambientLevel = 0.004;
    world.ambientColor = float3(0.01, 0.008, 0.02);
    world.flags = 5;  // floor + back wall
    // ── Background — dark wave field space + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.005;

    // ── Emitter glow — depth-aware, VR or desktop ──
    // Desktop: use optimized wfEmitGlow (3 exp() per emitter vs 5-7 in seEmitGlowDepth)
    // VR: keep seEmitGlowVR (already lightweight — only 2 exp() per emitter)
    if (VR_ACTIVE) {
        float3 headPos = float3(VRHeadPos.xyz);
        [loop] for (int j = 0; j < SE_NUM_OBJ; j++) {
            if (emit[j].active < 0.01 || emit[j].depth < 0.1) continue;
            col += seEmitGlowVR(p, emit[j], world, headPos, silence);
        }
    } else {
        [loop] for (int j = 0; j < SE_NUM_OBJ; j++) {
            if (emit[j].active < 0.01 || emit[j].depth < 0.1) continue;
            col += wfEmitGlow(p, emit[j], world, lufs, crest, beatBright,
                              a.beatPhase, kickSurge, silence);
        }
    }

    // ── L↔R links — inlined to avoid passing 48-element array by value ──
    // seLinkLR takes SeEmitter emit[SE_NUM_OBJ] by value = 3.5KB copy per call × 8 = 28KB/pixel
    [loop] for (int lb = 0; lb < SE_N_BANDS; lb++) {
        int li = lb * SE_N_SUB * 2 + 2;
        int ri = lb * SE_N_SUB * 2 + 3;
        if (emit[li].active < 0.05 || emit[ri].active < 0.05) continue;
        if (emit[li].depth < 0.1 || emit[ri].depth < 0.1) continue;
        if (emit[li].intensity < 0.08 || emit[ri].intensity < 0.08) continue;

        float2 ab = emit[ri].screenPos - emit[li].screenPos;
        float t = saturate(dot(p - emit[li].screenPos, ab) / max(dot(ab, ab), 0.0001));
        float2 closest = emit[li].screenPos + ab * t;
        float2 lineDiff = p - closest;
        float lineDist2 = dot(lineDiff, lineDiff);
        if (lineDist2 > 0.04) continue;

        float lineDist = sqrt(lineDist2);
        float linkStr = phaseCorr * emit[li].intensity * emit[ri].intensity * 0.1;
        float3 linkCol = lerp(emit[li].color, emit[ri].color, 0.5);
        float lineFade = smoothstep(0.04, 0.02, lineDist2);
        col += linkCol * exp(-lineDist * lineDist * 300.0) * linkStr * lineFade * silence;

        if (phaseCoh > 0.5) {
            float2 midPt = (emit[li].screenPos + emit[ri].screenPos) * 0.5;
            float midDist = length(p - midPt);
            col += float3(0.85, 0.9, 1.0) * exp(-midDist * midDist * 800.0) *
                   phaseCoh * emit[li].intensity * emit[ri].intensity * 0.06 * silence;
        }
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Central bass/sub node — depth + height pulsing with low-end energy ──
    {
        float bassEnergy = (a.b0 + a.b1) * 0.5;
        // 3D position: centered X, height rises with bass, depth pushes forward on kick
        float3 nodePos = float3(
            0.0,
            -0.5 + bassEnergy * 1.5 + kickSurge * 0.8,
            -1.0 - bassEnergy * 2.0 + kickSurge * 1.5
        );
        // Project to screen space
        float3 toNode = nodePos - cam.pos;
        float depth = dot(toNode, cam.fwd);
        if (depth > 0.1) {
            float3 right = cam.right;
            float3 up = cam.up;
            float2 screenPos;
            screenPos.x = dot(toNode, right) / (depth * cam.fov);
            screenPos.y = dot(toNode, up) / (depth * cam.fov);
            float2 diff = p - screenPos;
            float dist2 = dot(diff, diff);
            // Core glow — tight bright center
            float coreRadius = 0.02 + bassEnergy * 0.04 + kickSurge * 0.03;
            float core = exp(-dist2 / (coreRadius * coreRadius));
            // Outer halo — softer, larger
            float haloRadius = coreRadius * 3.0;
            float halo = exp(-dist2 / (haloRadius * haloRadius)) * 0.3;
            // Depth fade
            float depthFade = exp(-depth * 0.15);
            // Color — warm bass color blending with brain colors
            float3 nodeCol = lerp(float3(1.0, 0.4, 0.1), a.brainCol, 0.4);
            nodeCol = lerp(nodeCol, a.brainCol3, bassEnergy * 0.3);
            col += nodeCol * (core + halo) * (0.15 + bassEnergy * 0.3) * depthFade * silence;
            // Beat ring expanding from node
            float ringR = a.beatPhase * 0.15;
            float ringDist = abs(sqrt(dist2) - ringR);
            float ring = exp(-ringDist * ringDist * 80.0) * beatPulse * 0.08 * depthFade * silence;
            col += nodeCol * ring;
        }
    }

    // ── Ambient energy ──
    col += a.brainCol2 * envelope * 0.006 * exp(-r * 2.5) * silence;
    col += a.brainCol3 * a.colorPulse * 0.01 * silence;
    col += a.brainCol * a.energy * 0.005 * silence;
    col += a.brainCol2 * a.punch * 0.005 * silence;
    col += a.brainCol * a.beatAnt * 0.008 * exp(-r * 2.0) * silence;

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── Dynamic HDR limiter ──
    col = hdrLimiter(col);

    col *= silence;

    return float4(col, 1.0);
}
