// Spatial Pipeline — unified 3D audio spatializer for all modes 30-49
// Pre-computes spatial emitters from stereo spectrum, projects to screen once.
// X = stereo side (L/R cross-over), Y = frequency band, Z = amplitude depth
// VR-ready: all objects have real 3D world positions.

#ifndef SPATIAL_PIPELINE_HLSL
#define SPATIAL_PIPELINE_HLSL

#ifndef PI
#define PI 3.14159265
#endif

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"

#define SP_N_BANDS 8
#define SP_N_SUB 3
#define SP_NUM_OBJ 48  // 8 bands × 3 sub-frequencies × L/R

static const float spBandFreq[SP_N_BANDS] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};
static const float spSubOffset[SP_N_SUB] = { -0.02, 0.0, 0.02 };

// ── Camera ──
struct SpCamera {
    float3 pos;
    float3 target;
    float fov;
    float3 fwd;
    float3 right;
    float3 up;
};

SpCamera spCamera(float3 pos, float3 target, float fov) {
    SpCamera cam;
    cam.pos = pos;
    cam.target = target;
    cam.fov = fov;
    cam.fwd = normalize(target - pos);
    cam.right = normalize(cross(cam.fwd, float3(0, 1, 0)));
    cam.up = cross(cam.right, cam.fwd);
    return cam;
}

// ── Spatial Emitter ──
struct SpEmitter {
    float3 worldPos;
    float3 color;
    float intensity;
    float depth;       // distance from camera
    float2 screenPos;  // projected screen coords (aspect-corrected)
    float screenSize;  // perspective-corrected size
    float active;      // gate threshold
    float wavePhase;   // for ripple rings
    int bandIdx;       // which frequency band (0-7)
    int side;          // 0=left, 1=right
    int subIdx;        // sub-frequency index (0-2)
};

// Project world position to screen using camera
float2 spProject(float3 worldPos, SpCamera cam) {
    float3 toObj = worldPos - cam.pos;
    float depth = dot(toObj, cam.fwd);
    if (depth < 0.01) depth = 0.01;
    return float2(dot(toObj, cam.right) / (depth * cam.fov),
                  dot(toObj, cam.up) / (depth * cam.fov));
}

float spDepth(float3 worldPos, SpCamera cam) {
    return dot(worldPos - cam.pos, cam.fwd);
}

// ── Compute all 48 spatial emitters from spectrum L/R ──
// brainBands[8] = mono brain bands (a.b0-a.b7)
// Returns array of SpEmitter, fully positioned in 3D space
void spComputeEmitters(out SpEmitter emit[SP_NUM_OBJ], float brainBands[8],
                       AudioData a, SpCamera cam,
                       float lufs, float crest, float thd, float phaseCoh,
                       float beatPulse, float kickSurge, float transientAmt,
                       float envelope)
{
    float silence = 1.0 - a.isSilent;
    float widthScale = 1.8 + a.stereoWid * 1.0;
    widthScale *= (1.0 + (1.0 - phaseCoh) * 0.3);
    float energyPush = a.energy * 0.5 * (1.0 + lufs * 0.2);
    float kickLunge = kickSurge * 1.5;
    float transientScatter = transientAmt * 0.3;

    [unroll] for (int bi = 0; bi < SP_N_BANDS; bi++)
    {
        float freqU = spBandFreq[bi];
        float bandVal = brainBands[bi];
        float bandGate = smoothstep(0.02, 0.08, bandVal);
        float baseY = (float(bi) / float(SP_N_BANDS - 1) - 0.5) * 4.5;
        float bassWeight = smoothstep(2.0, 0.0, float(bi));
        float waveFreq = lerp(1.5, 8.0, float(bi) / float(SP_N_BANDS - 1));

        float jt = floor(Time * 4.0);
        float jitterX = (hash11(float(bi) * 17.3 + jt) - 0.5) * thd * 0.04;
        float jitterY = (hash11(float(bi) * 19.7 + jt) - 0.5) * thd * 0.03;

        [unroll] for (int si = 0; si < SP_N_SUB; si++)
        {
            float subFreqU = saturate(freqU + spSubOffset[si]);
            float subFrac = float(si) / float(SP_N_SUB - 1) - 0.5;
            float bandFrac = float(bi) / float(SP_N_BANDS - 1);

            // ── Left emitter ──
            {
                int idx = bi * SP_N_SUB * 2 + si * 2;
                float lE = u_spectrum.SampleLevel(u_sampler, float2(subFreqU, 0.166), 0).r;
                float rE_ref = u_spectrum.SampleLevel(u_sampler, float2(subFreqU, 0.833), 0).r;
                float lEnergy = max(lE, bandVal * 0.5) * bandGate;

                float lrBalance = (lE - rE_ref) / max(lE + rE_ref, 0.001);
                float crossMix = saturate(1.0 - abs(lrBalance) * 0.5);
                float sideSign = -1.0;
                if (lrBalance < -0.3) sideSign = lerp(-1.0, 0.0, saturate(-lrBalance));

                float panMod = (lE / max(lE + rE_ref, 0.001));
                float xPos = sideSign * widthScale * (0.5 + panMod * 0.3) * (1.0 - bassWeight * 0.2);
                xPos += crossMix * widthScale * 0.4 * (bandFrac - 0.5);
                xPos += jitterX + subFrac * 1.0;
                float yPos = baseY + transientScatter * (bi % 2 == 0 ? 1.0 : -0.7) + subFrac * 0.8;
                float zPos = -0.5 - (1.0 - saturate(lEnergy * 2.5)) * 4.5 + energyPush + kickLunge * bassWeight + subFrac * 2.5;

                emit[idx].worldPos = float3(xPos, yPos + jitterY, zPos);
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

                emit[idx].depth = spDepth(emit[idx].worldPos, cam);
                emit[idx].screenPos = spProject(emit[idx].worldPos, cam);
                emit[idx].screenSize = (0.025 + lEnergy * 0.04) / max(emit[idx].depth * 0.3, 0.3) * 3.0;
                emit[idx].screenSize /= (1.0 + crest * 0.3);
            }

            // ── Right emitter ──
            {
                int idx = bi * SP_N_SUB * 2 + si * 2 + 1;
                float rE = u_spectrum.SampleLevel(u_sampler, float2(subFreqU, 0.833), 0).r;
                float lE_ref = u_spectrum.SampleLevel(u_sampler, float2(subFreqU, 0.166), 0).r;
                float rEnergy = max(rE, bandVal * 0.5) * bandGate;

                float lrBalance = (lE_ref - rE) / max(lE_ref + rE, 0.001);
                float crossMix = saturate(1.0 - abs(lrBalance) * 0.5);
                float sideSign = 1.0;
                if (lrBalance > 0.3) sideSign = lerp(1.0, 0.0, saturate(lrBalance));

                float panMod = (rE / max(rE + lE_ref, 0.001));
                float xPos = sideSign * widthScale * (0.5 + panMod * 0.3) * (1.0 - bassWeight * 0.2);
                xPos += crossMix * widthScale * 0.4 * (bandFrac - 0.5);
                xPos += jitterX + subFrac * 1.0;
                float yPosR = baseY + transientScatter * (bi % 2 == 1 ? 1.0 : -0.7) + subFrac * 0.8;
                float zPos = -0.5 - (1.0 - saturate(rEnergy * 2.5)) * 4.5 + energyPush + kickLunge * bassWeight + subFrac * 2.5;

                emit[idx].worldPos = float3(xPos, yPosR + jitterY, zPos);
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

                emit[idx].depth = spDepth(emit[idx].worldPos, cam);
                emit[idx].screenPos = spProject(emit[idx].worldPos, cam);
                emit[idx].screenSize = (0.025 + rEnergy * 0.04) / max(emit[idx].depth * 0.3, 0.3) * 3.0;
                emit[idx].screenSize /= (1.0 + crest * 0.3);
            }
        }
    }
}

// ── Fused glow renderer — computes distance once, all glow layers in one pass ──
// Replaces separate spGlowOuter/Mid/Core/WaveRing/KickBoost/TransientRing/BeatRing
float3 spEmitGlow(float2 p, SpEmitter e, float lufs, float crest, float beatBright,
                  float beatPhase, float kickLunge, float transientAmt, float silence)
{
    float2 diff = p - e.screenPos;
    float d2 = dot(diff, diff);  // squared distance — avoid sqrt
    float s = e.screenSize;
    float s2 = s * s;

    // Distance cull — skip if outer glow is negligible (<0.001)
    // outer = exp(-d2/(s2*8)), so cull when d2 > s2*8*6.9 (~0.001 threshold)
    float cullRad2 = s2 * 55.2;
    if (d2 > cullRad2) return float3(0, 0, 0);

    float d = sqrt(d2);
    float3 col = float3(0, 0, 0);

    // Outer + mid + core glows (3 exp calls instead of 3 separate functions)
    float outer = exp(-d2 / (s2 * 8.0));
    float mid = exp(-d2 / (s2 * 2.5));
    float core = exp(-d2 / (s2 * 0.25));

    col += e.color * outer * e.intensity * 0.07 * (1.0 + lufs * 0.25) * silence;
    col += e.color * mid * (0.05 + e.intensity * 0.17) * 0.12 * silence;
    col += float3(0.9, 0.95, 1.0) * core * e.intensity * (0.5 + beatBright * 0.5) * (1.0 + crest * 0.3) * 0.13 * silence;

    // Wave rings (reuse d)
    float wp = e.wavePhase;
    float r1 = frac(wp * 0.3) * s * 6.0;
    col += e.color * exp(-abs(d - r1) * 50.0 / e.depth) * e.intensity * 0.05 * silence;
    float r2 = frac(wp * 0.3 + 0.33) * s * 6.0;
    col += e.color * exp(-abs(d - r2) * 60.0 / e.depth) * e.intensity * 0.03 * silence;
    float r3 = frac(wp * 0.3 + 0.66) * s * 6.0;
    col += e.color * exp(-abs(d - r3) * 70.0 / e.depth) * e.intensity * 0.025 * silence;

    // Kick boost (bass bands only)
    if (e.bandIdx <= 1) {
        col += float3(1.0, 0.5, 0.15) * core * kickLunge * e.intensity * 0.04 * silence;
    }

    // Transient ring
    if (transientAmt > 0.15) {
        float trR = transientAmt * s * 5.0;
        col += e.color * exp(-abs(d - trR) * 60.0 / e.depth) * transientAmt * 0.05 * silence;
    }

    // Beat ring
    if (beatBright > 0.1) {
        float br = beatPhase * s * 4.0;
        col += e.color * exp(-abs(d - br) * 100.0 / e.depth) * beatBright * 0.02 * silence;
    }

    return col;
}

// ── Connection links between emitters ──
float distToSeg(float2 p, float2 a, float2 b, out float2 closest) {
    float2 ab = b - a;
    float t = saturate(dot(p - a, ab) / max(dot(ab, ab), 0.0001));
    closest = a + ab * t;
    return length(p - closest);
}

// L↔R link per band (center sub-frequency)
float3 spLinkLR(float2 p, SpEmitter emit[SP_NUM_OBJ], int bandIdx,
                float phaseCorr, float phaseCoh, float silence) {
    int li = bandIdx * SP_N_SUB * 2 + 2;  // center sub, left
    int ri = bandIdx * SP_N_SUB * 2 + 3;  // center sub, right
    if (emit[li].active < 0.05 || emit[ri].active < 0.05) return float3(0, 0, 0);
    if (emit[li].depth < 0.1 || emit[ri].depth < 0.1) return float3(0, 0, 0);
    if (emit[li].intensity < 0.08 || emit[ri].intensity < 0.08) return float3(0, 0, 0);

    float2 closest;
    float2 ab = emit[ri].screenPos - emit[li].screenPos;
    float t = saturate(dot(p - emit[li].screenPos, ab) / max(dot(ab, ab), 0.0001));
    closest = emit[li].screenPos + ab * t;
    float2 lineDiff = p - closest;
    float lineDist2 = dot(lineDiff, lineDiff);

    // Cull if too far from line
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

// Vertical link between adjacent bands (same side, center sub)
float3 spLinkBand(float2 p, SpEmitter emit[SP_NUM_OBJ], int bandIdx, int side,
                  float phaseCorr, float silence) {
    int i1 = bandIdx * SP_N_SUB * 2 + 2 + side;
    int i2 = (bandIdx + 1) * SP_N_SUB * 2 + 2 + side;
    if (emit[i1].active < 0.05 || emit[i2].active < 0.05) return float3(0, 0, 0);
    if (emit[i1].depth < 0.1 || emit[i2].depth < 0.1) return float3(0, 0, 0);
    if (emit[i1].intensity < 0.1 || emit[i2].intensity < 0.1) return float3(0, 0, 0);

    float2 closest;
    float lineDist = distToSeg(p, emit[i1].screenPos, emit[i2].screenPos, closest);
    float linkStr = phaseCorr * emit[i1].intensity * emit[i2].intensity * 0.05;
    float3 linkCol = lerp(emit[i1].color, emit[i2].color, 0.5);
    return linkCol * exp(-lineDist * lineDist * 800.0) * linkStr * silence;
}

// ── Full render pass — render all emitters depth-sorted ──
// Call this in main() after setting up camera and computing emitters
float3 spRenderAll(float2 p, SpEmitter emit[SP_NUM_OBJ],
                   float lufs, float crest, float beatBright, float beatPhase,
                   float kickLunge, float transientAmt, float phaseCorr, float phaseCoh,
                   float silence)
{
    float3 col = float3(0, 0, 0);

    // Render emitters depth-sorted (back to front)
    [loop] for (int ri = SP_NUM_OBJ - 1; ri >= 0; ri--) {
        if (emit[ri].active < 0.01) continue;
        if (emit[ri].depth < 0.1) continue;

        col += spEmitGlow(p, emit[ri], lufs, crest, beatBright, beatPhase,
                          kickLunge, transientAmt, silence);
    }

    // L↔R links per band
    [loop] for (int lb = 0; lb < SP_N_BANDS; lb++) {
        col += spLinkLR(p, emit, lb, phaseCorr, phaseCoh, silence);
    }

    // Vertical band links — skip per-pixel, too expensive for 48 emitters
    // (L↔R links already provide spatial connectivity)

    return col;
}

#endif // SPATIAL_PIPELINE_HLSL
