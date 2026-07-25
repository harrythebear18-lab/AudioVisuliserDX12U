// Spatial Encoder/Decoder — unified 3D audio-to-spatial mapping for modes 30-49
// Encodes audio brain/DSP/spectrum data into 3D world positions.
// Decodes 3D positions to screen space via camera projection.
// Each mode selects a profile and tunes parameters — positions are audio-driven.
//
// Encoding dimensions (audio → 3D):
//   X = stereo pan (spectrum L/R → left/right with cross-over convergence)
//   Y = frequency band (brain bands → height, with transient scatter)
//   Z = energy depth (amplitude → forward/back, with kick lunge)
//
// DSP modulation (applied to all profiles):
//   LUFS → energy push (depth scale)
//   crest → positioning sharpness (tighter clusters when high)
//   THD → jitter/scatter around base position
//   phaseCoh → L/R convergence (higher = more centered)
//   phaseCorr → link alignment
//
// Profiles:
//   0 = WAVE_FIELD   — X=stereo, Y=freq, Z=depth (flat field)
//   1 = SPHERICAL    — golden-ratio sphere distribution
//   2 = HEMISPHERE   — L/R brain hemisphere split
//   3 = RADIAL       — radial burst from center outward
//   4 = TUNNEL       — corridor depth, walls left/right

#ifndef SPATIAL_ENCODER_HLSL
#define SPATIAL_ENCODER_HLSL

#ifndef PI
#define PI 3.14159265
#endif

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"

#define SE_N_BANDS 8
#define SE_N_SUB 3
#define SE_NUM_OBJ 48  // 8 bands × 3 sub-frequencies × L/R

static const float seBandFreq[SE_N_BANDS] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};
static const float seSubOffset[SE_N_SUB] = { -0.02, 0.0, 0.02 };

#define SE_PROFILE_WAVE_FIELD   0
#define SE_PROFILE_SPHERICAL    1
#define SE_PROFILE_HEMISPHERE   2
#define SE_PROFILE_RADIAL       3
#define SE_PROFILE_TUNNEL       4

// ── Camera ──
struct SeCamera {
    float3 pos;
    float3 target;
    float fov;
    float3 fwd;
    float3 right;
    float3 up;
};

SeCamera seCamera(float3 pos, float3 target, float fov) {
    SeCamera cam;
    cam.pos = pos;
    cam.target = target;
    cam.fov = fov;
    cam.fwd = normalize(target - pos);
    cam.right = normalize(cross(cam.fwd, float3(0, 1, 0)));
    cam.up = cross(cam.right, cam.fwd);
    return cam;
}

// ── Spatial Emitter ──
struct SeEmitter {
    float3 worldPos;
    float3 color;
    float intensity;
    float depth;
    float2 screenPos;
    float screenSize;
    float active;
    float wavePhase;
    int bandIdx;
    int side;       // 0=left, 1=right
    int subIdx;
};

// ── Projection (decoder) ──
float2 seProject(float3 worldPos, SeCamera cam) {
    float3 toObj = worldPos - cam.pos;
    float depth = dot(toObj, cam.fwd);
    if (depth < 0.01) depth = 0.01;
    return float2(dot(toObj, cam.right) / (depth * cam.fov),
                  dot(toObj, cam.up) / (depth * cam.fov));
}

float seDepth(float3 worldPos, SeCamera cam) {
    return dot(worldPos - cam.pos, cam.fwd);
}

// ── Encoder parameters — tune per mode ──
struct SeParams {
    int profile;
    float widthScale;    // X spread
    float heightScale;   // Y spread
    float depthScale;    // Z spread
    float stereoWid;     // stereo width influence
    float stereoBal;     // balance offset
    float motionSpeed;   // animation speed multiplier
    float crossOver;     // L/R convergence toward center (0=none, 1=full)
    float jitterAmt;     // THD-driven scatter multiplier
};

SeParams seParams(int profile) {
    SeParams p;
    p.profile = profile;
    p.widthScale = 1.8;
    p.heightScale = 4.5;
    p.depthScale = 5.0;
    p.stereoWid = 1.0;
    p.stereoBal = 0.0;
    p.motionSpeed = 1.0;
    p.crossOver = 0.4;
    p.jitterAmt = 1.0;
    return p;
}

// ── Core encoder: maps one emitter's audio data to 3D position ──
// This is the heart of the spatial encoder — all audio features feed into
// the 3D coordinate. Each profile transforms the same audio data differently.
float3 seEncodePosition(int bandIdx, int subIdx, int side,
                        float lE, float rE, float bandVal,
                        SeParams params, AudioData a,
                        float lufs, float crest, float thd, float phaseCoh,
                        float beatPulse, float kickSurge, float transientAmt,
                        float envelope)
{
    float bandFrac = float(bandIdx) / float(SE_N_BANDS - 1);
    float subFrac = float(subIdx) / float(SE_N_SUB - 1) - 0.5;
    float sideSign = (side == 0) ? -1.0 : 1.0;

    // Common audio-derived quantities
    float energy = (side == 0) ? lE : rE;
    float totalE = lE + rE + 0.001;
    float panMod = (side == 0) ? lE / totalE : rE / totalE;
    float lrBalance = (lE - rE) / totalE;
    float crossMix = saturate(1.0 - abs(lrBalance) * 0.5) * params.crossOver;
    float bassWeight = smoothstep(2.0, 0.0, float(bandIdx));
    float energyPush = a.energy * 0.5 * (1.0 + lufs * 0.2);
    float kickLunge = kickSurge * 1.5;
    float transientScatter = transientAmt * 0.3 * params.jitterAmt;
    float sharpness = 1.0 / (1.0 + crest * 0.3);

    // THD jitter
    float jt = floor(Time * 4.0 * params.motionSpeed);
    float jitterX = (hash11(float(bandIdx) * 17.3 + jt) - 0.5) * thd * 0.04 * params.jitterAmt;
    float jitterY = (hash11(float(bandIdx) * 19.7 + jt) - 0.5) * thd * 0.03 * params.jitterAmt;

    // Stereo width stretches X
    float widthMod = params.widthScale * (1.0 + params.stereoWid * 0.5);
    widthMod *= (1.0 + (1.0 - phaseCoh) * 0.3);

    float3 pos = float3(0, 0, 0);

    if (params.profile == SE_PROFILE_WAVE_FIELD) {
        // X = stereo side with cross-over convergence
        float xPos = sideSign * widthMod * (0.5 + panMod * 0.3) * (1.0 - bassWeight * 0.2);
        xPos += crossMix * widthMod * 0.4 * (bandFrac - 0.5);
        xPos += jitterX + subFrac * 1.0;
        // Y = frequency band height
        float yPos = (bandFrac - 0.5) * params.heightScale + transientScatter * (bandIdx % 2 == 0 ? 1.0 : -0.7) + subFrac * 0.8;
        // Z = energy depth (louder = closer)
        float zPos = -0.5 - (1.0 - saturate(energy * 2.5)) * params.depthScale + energyPush + kickLunge * bassWeight + subFrac * 2.5;
        pos = float3(xPos, yPos + jitterY, zPos);
    }
    else if (params.profile == SE_PROFILE_SPHERICAL) {
        // Golden-ratio sphere — band/sub/side mapped to sphere surface
        int globalIdx = bandIdx * SE_N_SUB * 2 + subIdx * 2 + side;
        float t = float(globalIdx) / float(SE_NUM_OBJ);
        float phi = acos(1.0 - 2.0 * t);
        float theta = float(globalIdx) * 1.618 * PI * 2.0 + params.stereoBal * 0.4 + panMod * 0.3;
        float radius = params.widthScale * 0.5 + sin(float(globalIdx) * 1.7) * 0.5;
        radius += energyPush * 0.3 + kickLunge * bassWeight * 0.2;
        float stretchX = 1.0 + params.stereoWid * 0.4;
        pos = float3(
            radius * sin(phi) * cos(theta) * stretchX + jitterX,
            radius * cos(phi) + jitterY,
            radius * sin(phi) * sin(theta)
        );
    }
    else if (params.profile == SE_PROFILE_HEMISPHERE) {
        // L/R hemisphere split — left emitters on left, right on right
        float xBase = sideSign * (0.8 + params.stereoWid * 0.4);
        float ang = subFrac * PI + float(bandIdx) * 0.5 + params.stereoBal * 0.3;
        float radius = 0.5 + float(bandIdx) * 0.3;
        float yLevel = lerp(-params.heightScale * 0.3, params.heightScale * 0.3, bandFrac);
        pos = float3(
            xBase + cos(ang) * radius * 0.3 + jitterX,
            yLevel + sin(float(bandIdx * 6 + subIdx * 2 + side) * 2.3) * 0.3 + jitterY,
            sin(ang) * radius - energyPush * 0.5
        );
    }
    else if (params.profile == SE_PROFILE_RADIAL) {
        // Radial burst from center — emitters placed on rings at varying depths
        float ringAngle = (bandFrac * PI * 2.0 + subFrac * PI * 0.5 + params.stereoBal * 0.5);
        if (side == 1) ringAngle += PI;  // R on opposite side
        float ringRadius = params.widthScale * (0.3 + bandFrac * 0.7) * sharpness;
        float ringDepth = lerp(params.depthScale * 0.5, -params.depthScale * 0.5, bandFrac);
        ringDepth += energyPush + kickLunge * bassWeight;
        pos = float3(
            cos(ringAngle) * ringRadius + jitterX,
            sin(ringAngle) * ringRadius * 0.6 + jitterY,
            ringDepth + subFrac * 1.5
        );
    }
    else if (params.profile == SE_PROFILE_TUNNEL) {
        // Corridor — L on left wall, R on right wall, depth by frequency
        float corridorDepth = lerp(params.depthScale * 0.5, -params.depthScale * 0.8, bandFrac);
        float wallX = sideSign * params.widthScale * (0.5 + panMod * 0.3);
        float wallY = subFrac * params.heightScale * 0.4 + sin(Time * 0.5 * params.motionSpeed + float(bandIdx)) * 0.3;
        pos = float3(
            wallX + jitterX,
            wallY + jitterY,
            corridorDepth + energyPush * 0.5 + kickLunge * bassWeight * 0.3
        );
    }

    return pos;
}

// ── Full encoder: compute all 48 emitters from audio data ──
void seComputeEmitters(out SeEmitter emit[SE_NUM_OBJ],
                       float brainBands[8], AudioData a, SeCamera cam,
                       SeParams params,
                       float lufs, float crest, float thd, float phaseCoh,
                       float beatPulse, float kickSurge, float transientAmt,
                       float envelope)
{
    float silence = 1.0 - a.isSilent;

    [unroll] for (int bi = 0; bi < SE_N_BANDS; bi++)
    {
        float freqU = seBandFreq[bi];
        float bandVal = brainBands[bi];
        float bandGate = smoothstep(0.02, 0.08, bandVal);
        float waveFreq = lerp(1.5, 8.0, float(bi) / float(SE_N_BANDS - 1));

        [unroll] for (int si = 0; si < SE_N_SUB; si++)
        {
            float subFreqU = saturate(freqU + seSubOffset[si]);
            float subFrac = float(si) / float(SE_N_SUB - 1) - 0.5;
            float bandFrac = float(bi) / float(SE_N_BANDS - 1);

            // ── Left emitter ──
            {
                int idx = bi * SE_N_SUB * 2 + si * 2;
                float lE = u_spectrum.SampleLevel(u_sampler, float2(subFreqU, 0.166), 0).r;
                float rE_ref = u_spectrum.SampleLevel(u_sampler, float2(subFreqU, 0.833), 0).r;
                float lEnergy = max(lE, bandVal * 0.5) * bandGate;

                emit[idx].worldPos = seEncodePosition(bi, si, 0, lE, rE_ref, bandVal,
                    params, a, lufs, crest, thd, phaseCoh,
                    beatPulse, kickSurge, transientAmt, envelope);
                emit[idx].intensity = lEnergy;
                emit[idx].active = bandGate;
                emit[idx].wavePhase = Time * waveFreq + float(bi) * 0.5 + subFrac * PI;
                emit[idx].bandIdx = bi;
                emit[idx].side = 0;
                emit[idx].subIdx = si;

                float hue = a.hueBase + bandFrac * a.hueRange + a.section * 0.03 + subFrac * 0.05;
                float3 c = hsv(hue, 0.7 * a.satur, 1.0);
                c = lerp(c, a.brainCol, 0.3);
                c = lerp(c, a.brainCol2, bandFrac * 0.3);
                emit[idx].color = c;

                emit[idx].depth = seDepth(emit[idx].worldPos, cam);
                emit[idx].screenPos = seProject(emit[idx].worldPos, cam);
                emit[idx].screenSize = (0.025 + lEnergy * 0.04) / max(emit[idx].depth * 0.3, 0.3) * 3.0;
                emit[idx].screenSize /= (1.0 + crest * 0.3);
            }

            // ── Right emitter ──
            {
                int idx = bi * SE_N_SUB * 2 + si * 2 + 1;
                float rE = u_spectrum.SampleLevel(u_sampler, float2(subFreqU, 0.833), 0).r;
                float lE_ref = u_spectrum.SampleLevel(u_sampler, float2(subFreqU, 0.166), 0).r;
                float rEnergy = max(rE, bandVal * 0.5) * bandGate;

                emit[idx].worldPos = seEncodePosition(bi, si, 1, lE_ref, rE, bandVal,
                    params, a, lufs, crest, thd, phaseCoh,
                    beatPulse, kickSurge, transientAmt, envelope);
                emit[idx].intensity = rEnergy;
                emit[idx].active = bandGate;
                emit[idx].wavePhase = Time * waveFreq + float(bi) * 0.5 + subFrac * PI + PI;
                emit[idx].bandIdx = bi;
                emit[idx].side = 1;
                emit[idx].subIdx = si;

                float hue = a.hueBase + bandFrac * a.hueRange + a.section * 0.03 + 0.03 + subFrac * 0.05;
                float3 c = hsv(hue, 0.7 * a.satur, 1.0);
                c = lerp(c, a.brainCol2, 0.3);
                c = lerp(c, a.brainCol, bandFrac * 0.2);
                emit[idx].color = c;

                emit[idx].depth = seDepth(emit[idx].worldPos, cam);
                emit[idx].screenPos = seProject(emit[idx].worldPos, cam);
                emit[idx].screenSize = (0.025 + rEnergy * 0.04) / max(emit[idx].depth * 0.3, 0.3) * 3.0;
                emit[idx].screenSize /= (1.0 + crest * 0.3);
            }
        }
    }
}

// ── Fused glow renderer with distance culling ──
float3 seEmitGlow(float2 p, SeEmitter e, float lufs, float crest, float beatBright,
                  float beatPhase, float kickLunge, float transientAmt, float silence)
{
    float2 diff = p - e.screenPos;
    float d2 = dot(diff, diff);
    float s = e.screenSize;
    float s2 = s * s;

    float cullRad2 = s2 * 55.2;
    if (d2 > cullRad2) return float3(0, 0, 0);

    float d = sqrt(d2);
    float3 col = float3(0, 0, 0);

    float outer = exp(-d2 / (s2 * 8.0));
    float mid = exp(-d2 / (s2 * 2.5));
    float core = exp(-d2 / (s2 * 0.25));

    col += e.color * outer * e.intensity * 0.07 * (1.0 + lufs * 0.25) * silence;
    col += e.color * mid * (0.05 + e.intensity * 0.17) * 0.12 * silence;
    col += float3(0.9, 0.95, 1.0) * core * e.intensity * (0.5 + beatBright * 0.5) * (1.0 + crest * 0.3) * 0.13 * silence;

    float wp = e.wavePhase;
    float r1 = frac(wp * 0.3) * s * 6.0;
    col += e.color * exp(-abs(d - r1) * 50.0 / e.depth) * e.intensity * 0.05 * silence;
    float r2 = frac(wp * 0.3 + 0.33) * s * 6.0;
    col += e.color * exp(-abs(d - r2) * 60.0 / e.depth) * e.intensity * 0.03 * silence;
    float r3 = frac(wp * 0.3 + 0.66) * s * 6.0;
    col += e.color * exp(-abs(d - r3) * 70.0 / e.depth) * e.intensity * 0.025 * silence;

    if (e.bandIdx <= 1) {
        col += float3(1.0, 0.5, 0.15) * core * kickLunge * e.intensity * 0.04 * silence;
    }

    if (transientAmt > 0.15) {
        float trR = transientAmt * s * 5.0;
        col += e.color * exp(-abs(d - trR) * 60.0 / e.depth) * transientAmt * 0.05 * silence;
    }

    if (beatBright > 0.1) {
        float br = beatPhase * s * 4.0;
        col += e.color * exp(-abs(d - br) * 100.0 / e.depth) * beatBright * 0.02 * silence;
    }

    return col;
}

// ── Culled L↔R link per band ──
float3 seLinkLR(float2 p, SeEmitter emit[SE_NUM_OBJ], int bandIdx,
                float phaseCorr, float phaseCoh, float silence)
{
    int li = bandIdx * SE_N_SUB * 2 + 2;
    int ri = bandIdx * SE_N_SUB * 2 + 3;
    if (emit[li].active < 0.05 || emit[ri].active < 0.05) return float3(0, 0, 0);
    if (emit[li].depth < 0.1 || emit[ri].depth < 0.1) return float3(0, 0, 0);
    if (emit[li].intensity < 0.08 || emit[ri].intensity < 0.08) return float3(0, 0, 0);

    float2 ab = emit[ri].screenPos - emit[li].screenPos;
    float t = saturate(dot(p - emit[li].screenPos, ab) / max(dot(ab, ab), 0.0001));
    float2 closest = emit[li].screenPos + ab * t;
    float2 lineDiff = p - closest;
    float lineDist2 = dot(lineDiff, lineDiff);
    if (lineDist2 > 0.02) return float3(0, 0, 0);

    float lineDist = sqrt(lineDist2);
    float linkStr = phaseCorr * emit[li].intensity * emit[ri].intensity * 0.1;
    float3 linkCol = lerp(emit[li].color, emit[ri].color, 0.5);
    float3 col = linkCol * exp(-lineDist * lineDist * 600.0) * linkStr * silence;

    if (phaseCoh > 0.5) {
        float2 midPt = (emit[li].screenPos + emit[ri].screenPos) * 0.5;
        float midDist = length(p - midPt);
        col += float3(0.85, 0.9, 1.0) * exp(-midDist * midDist * 800.0) *
               phaseCoh * emit[li].intensity * emit[ri].intensity * 0.06 * silence;
    }
    return col;
}

// ── Full render pass ──
float3 seRenderAll(float2 p, SeEmitter emit[SE_NUM_OBJ],
                   float lufs, float crest, float beatBright, float beatPhase,
                   float kickLunge, float transientAmt, float phaseCorr, float phaseCoh,
                   float silence)
{
    float3 col = float3(0, 0, 0);

    [loop] for (int ri = SE_NUM_OBJ - 1; ri >= 0; ri--) {
        if (emit[ri].active < 0.01) continue;
        if (emit[ri].depth < 0.1) continue;
        col += seEmitGlow(p, emit[ri], lufs, crest, beatBright, beatPhase,
                          kickLunge, transientAmt, silence);
    }

    [loop] for (int lb = 0; lb < SE_N_BANDS; lb++) {
        col += seLinkLR(p, emit, lb, phaseCorr, phaseCoh, silence);
    }

    return col;
}

#endif // SPATIAL_ENCODER_HLSL
