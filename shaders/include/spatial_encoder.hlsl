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
#define SE_PROFILE_PSYCHOACOUSTIC 5

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
    float depthFog;  // precomputed: exp(-depth * fogDensity) — avoids exp() in per-pixel loop
    float nearFade;  // VR vergence safety: 0 if too close, 1 if safe distance
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
    else if (params.profile == SE_PROFILE_PSYCHOACOUSTIC) {
        // Psychoacoustic mapping — objects placed where the sound feels like it's coming from
        // Azimuth from stereo pan (HRTF-inspired horizontal plane, ±60°)
        float azimuth = sideSign * (0.35 + panMod * 0.35) * PI;  // up to ~63°
        azimuth += crossMix * 0.2 * sideSign;  // convergence toward center
        // Elevation from band frequency (bass=low, treble=high, ±45°)
        float elevation = lerp(-0.35, 0.55, bandFrac) + subFrac * 0.15;
        elevation += transientScatter * 0.1;
        // Distance from energy (loud=close, quiet=far) — inverse loudness
        float dist = lerp(0.8, params.depthScale, 1.0 - saturate(energy * 2.5));
        dist -= energyPush * 0.5 + kickLunge * bassWeight * 0.3;
        dist = max(0.5, dist);
        // Convert spherical to cartesian — listener at origin
        pos = float3(
            dist * cos(elevation) * sin(azimuth) * (1.0 + params.stereoWid * 0.3) + jitterX,
            dist * sin(elevation) + jitterY,
            -dist * cos(elevation) * cos(azimuth)
        );
    }

    return pos;
}

// ── Full encoder: compute all 48 emitters from brain data — zero texture fetches ──
// The brain is the source of truth. It already computed:
//   - 8 frequency bands (b0-b7) from spectrum
//   - Stereo spatial telemetry (stereoBal, stereoWid, leftEn, rightEn, stereoDiff, phaseCorr)
//   - Dynamics (beat, transient, envelope, overall, kick, punch, dynamic, glow)
//   - Rhythm (bpm, tempoConf, beatPhase, beatPeriod, tempoPulse, beatAnt)
//   - Structure (section, sectionConf, phraseBeat, beatCount)
//   - Spectral profile (specCent, specSpread, domFreq, domBand)
//   - Voice/speech (speechMode, voiceActivity, calmMode, ambientLevel)
//   - Visual modifiers (brightness, beam, bloom, ambient, effectInt, colorPulse, barScale)
//   - Color (brainCol, brainCol2, brainCol3, hueBase, hueRange, satur)
//   - DSP additive (DspBand0-7, DspPeakDbL/R, DspCrestFactorDb, DspTHD, DspPhaseCorrelation)
//
// We derive per-emitter L/R energy and enrichment from ALL of these.
// No u_spectrum.SampleLevel calls — the brain already sampled the spectrum.
//
// Algorithm:
//   1. Per-band base energy = brain band + DSP biquad band (additive, per rules)
//   2. Per-band L/R split = band × spatial telemetry:
//      - stereoBal → pan offset (frequency-dependent via stereoDiff)
//      - leftEn/rightEn → global L/R RMS weighting
//      - stereoWid → widens L/R separation
//      - phaseCorr → converges L/R when correlated, diverges when not
//   3. Per-sub variation from spectral profile:
//      - specCent/specSpread → sub-frequency weighting
//      - domBand → boost center sub when this band is dominant
//   4. Intensity enrichment:
//      - beatAnt → anticipatory swell before beats
//      - tempoPulse → speech-aware rhythm modulation
//      - punch → kick-derived impulse on bass bands
//      - dynamic → transient-derived scatter energy
//      - glow → bloom-derived sustained brightness
//      - phraseBeat → 16-beat evolutionary phase
//      - section/sectionConf → structural repositioning
//      - speechMode → emphasis on vocal bands (b3-b5)
//      - calmMode → reduced intensity floor in quiet passages
//      - colorPulse → hue cycling per emitter
//      - brightness/effectInt → global visual scaling
void seComputeEmitters(out SeEmitter emit[SE_NUM_OBJ],
                       float brainBands[8], AudioData a, SeCamera cam,
                       SeParams params,
                       float lufs, float crest, float thd, float phaseCoh,
                       float beatPulse, float kickSurge, float transientAmt,
                       float envelope)
{
    float silence = 1.0 - a.isSilent;

    // ── Global spatial telemetry decomposition ──
    float lrTotal = a.leftEn + a.rightEn + 0.001;
    float lGlobal = a.leftEn / lrTotal * 2.0;     // ~1.0 when balanced
    float rGlobal = a.rightEn / lrTotal * 2.0;
    float panBase = a.stereoBal * 0.35;           // global pan offset
    float widthMod = a.stereoWid;                  // 0..1 stereo width
    float phaseConv = saturate(phaseCoh * 0.5);   // phase convergence (0=diverge, 1=mono)
    float specDiff = a.stereoDiff;                 // spectral L-R difference

    // ── DSP additive bands (biquad band-pass levels) ──
    float dspBands[8] = { DspBand0, DspBand1, DspBand2, DspBand3,
                          DspBand4, DspBand5, DspBand6, DspBand7 };

    // ── DSP peak levels for precise L/R ──
    float peakL = saturate((DspPeakDbL + 60.0) / 60.0);  // dB → 0..1
    float peakR = saturate((DspPeakDbR + 60.0) / 60.0);

    // ── Spectral profile for sub-weighting ──
    float specCent = a.specCent;    // 0..1 spectral centroid
    float specSpread = a.specSpread; // spectral spread
    float domBand = a.domBand;      // dominant band index (0..7)

    // ── Dynamics enrichment globals ──
    float beatAnt = a.beatAnt;           // anticipatory lookahead
    float tempoPulse = a.tempoPulse;     // speech-aware rhythm
    float punch = a.punch;               // kick impulse
    float dynamic = a.dynamic;           // transient energy
    float glow = a.glow;                 // bloom-derived
    float phraseEv = a.phraseBeat;       // 16-beat phrase progression 0..1
    float sectionDrift = a.section * 0.1; // structural repositioning
    float sectionConf = a.sectionConf;    // section tracking confidence
    float speechMode = a.speechMode;      // 0..1 speech detection
    float calmMode = a.calmMode;          // 0..1 quiet passage
    float colorPulse = a.colorPulse;      // hue cycling trigger
    float brightness = a.brightness;      // visual modifier
    float effectInt = a.effectInt;        // effect intensity
    float barScale = a.barScale;          // bar scaling

    [unroll] for (int bi = 0; bi < SE_N_BANDS; bi++)
    {
        float bandFrac = float(bi) / float(SE_N_BANDS - 1);
        float bandVal = brainBands[bi];

        // ── 1. Base energy: brain band + DSP additive (per rules: DSP is additive only) ──
        float dspAdd = dspBands[bi] * 0.12;
        float baseEnergy = bandVal + dspAdd;
        float bandGate = smoothstep(0.02, 0.08, bandVal);
        float waveFreq = lerp(1.5, 8.0, bandFrac);

        // ── 2. Per-band L/R decomposition from spatial telemetry ──
        // Frequency-dependent pan: stereoDiff gives spectral L-R, modulate per band
        // Low freqs pan less (bass is omnidirectional), highs pan more
        float bandPanMod = lerp(0.3, 1.0, bandFrac);  // freq-dependent pan sensitivity
        float bandPan = panBase * bandPanMod + specDiff * bandFrac * 0.2;
        // Stereo width widens the split
        float widthSplit = lerp(0.5, 1.0, widthMod);
        // Phase convergence pulls L/R toward center
        float convPull = phaseConv * 0.3;

        // Per-band L/R energy
        float lE = baseEnergy * lGlobal * (1.0 - bandPan * widthSplit) * (1.0 - convPull);
        float rE = baseEnergy * rGlobal * (1.0 + bandPan * widthSplit) * (1.0 - convPull);
        // DSP peak levels refine L/R precision
        lE = max(lE, baseEnergy * peakL * 0.5);
        rE = max(rE, baseEnergy * peakR * 0.5);

        // ── 3. Spectral profile: is this band dominant? ──
        float domBoost = exp(-abs(float(bi) - domBand) * 1.5);  // 1.0 at dominant band
        // specCent shifts which sub-freq is emphasized
        float centShift = (specCent - 0.5) * 2.0;  // -1..1

        // ── 4. Speech-band emphasis (vocal range: b3-b5) ──
        float vocalWeight = smoothstep(2.5, 3.5, float(bi)) * (1.0 - smoothstep(5.0, 6.0, float(bi)));
        float speechBoost = speechMode * vocalWeight * 0.3;

        // ── 5. Calm mode: reduce intensity floor ──
        float calmFloor = 1.0 - calmMode * 0.5;

        // ── 6. Phrase evolution: slow phase offset per band ──
        float phrasePhase = phraseEv * PI * 2.0 + float(bi) * 0.3;

        [unroll] for (int si = 0; si < SE_N_SUB; si++)
        {
            float subFrac = float(si) / float(SE_N_SUB - 1) - 0.5;  // -0.5..+0.5

            // ── Sub-frequency weighting from spectral profile ──
            // Center sub (si=1) gets boost when band is dominant
            float subWeight = 1.0;
            if (si == 1) subWeight = 1.0 + domBoost * 0.3;
            else if (si == 0) subWeight = 1.0 - centShift * 0.15;  // lower sub
            else subWeight = 1.0 + centShift * 0.15;               // upper sub
            // specSpread widens/narrows sub weighting
            subWeight *= lerp(0.8, 1.2, specSpread);

            // ── Dynamics enrichment per emitter ──
            // Beat anticipation: swell before beat hits
            float antSwel = beatAnt * (0.5 + bandFrac * 0.5) * 0.15;
            // Tempo pulse: speech-aware rhythm
            float rhythmMod = tempoPulse * lerp(0.1, 0.05, bandFrac);
            // Punch: kick impulse on bass bands
            float punchMod = punch * smoothstep(2.0, 0.0, float(bi)) * 0.3;
            // Dynamic: transient scatter energy
            float dynMod = dynamic * lerp(0.08, 0.03, bandFrac);
            // Glow: sustained brightness from bloom
            float glowMod = glow * 0.05;
            // Phrase evolution: slow intensity breathing
            float phraseMod = sin(phrasePhase + subFrac * PI) * 0.1 + 0.1;
            // Section drift: structural repositioning confidence
            float sectionMod = sectionDrift * sectionConf * 0.1;
            // Brightness/effectInt: global visual scaling
            float visualScale = (0.7 + brightness * 0.3) * (0.8 + effectInt * 0.2) * barScale;

            // ── Left emitter ──
            {
                int idx = bi * SE_N_SUB * 2 + si * 2;
                float lEnergy = max(lE * subWeight, baseEnergy * 0.3) * bandGate;
                // Enrich with dynamics
                lEnergy += antSwel + rhythmMod + punchMod + dynMod + glowMod + phraseMod + sectionMod;
                lEnergy += speechBoost * subWeight;
                lEnergy *= calmFloor * visualScale;
                lEnergy = clamp(lEnergy, 0.0, 1.5);

                emit[idx].worldPos = seEncodePosition(bi, si, 0, lE, rE, baseEnergy,
                    params, a, lufs, crest, thd, phaseCoh,
                    beatPulse, kickSurge, transientAmt, envelope);
                emit[idx].intensity = lEnergy;
                emit[idx].active = bandGate;
                emit[idx].wavePhase = Time * waveFreq + float(bi) * 0.5 + subFrac * PI + phrasePhase * 0.1;
                emit[idx].bandIdx = bi;
                emit[idx].side = 0;
                emit[idx].subIdx = si;

                // Color: brain palette + hue cycling + section shift + colorPulse
                float hue = a.hueBase + bandFrac * a.hueRange
                          + a.section * 0.03 + subFrac * 0.05
                          + colorPulse * 0.02;
                float3 c = hsv(hue, 0.7 * a.satur, 1.0);
                c = lerp(c, a.brainCol, 0.3);
                c = lerp(c, a.brainCol2, bandFrac * 0.3);
                // Speech mode shifts vocal bands toward brainCol3
                c = lerp(c, a.brainCol3, speechBoost * 0.5);
                emit[idx].color = c;

                emit[idx].depth = seDepth(emit[idx].worldPos, cam);
                emit[idx].screenPos = seProject(emit[idx].worldPos, cam);
                emit[idx].screenSize = (0.025 + lEnergy * 0.04) / max(emit[idx].depth * 0.3, 0.3) * 3.0;
                emit[idx].screenSize /= (1.0 + crest * 0.3);
                emit[idx].screenSize *= barScale;
                emit[idx].depthFog = 1.0;
                emit[idx].nearFade = saturate((emit[idx].depth - 0.5) / 0.5);
            }

            // ── Right emitter ──
            {
                int idx = bi * SE_N_SUB * 2 + si * 2 + 1;
                float rEnergy = max(rE * subWeight, baseEnergy * 0.3) * bandGate;
                rEnergy += antSwel + rhythmMod + punchMod + dynMod + glowMod + phraseMod + sectionMod;
                rEnergy += speechBoost * subWeight;
                rEnergy *= calmFloor * visualScale;
                rEnergy = clamp(rEnergy, 0.0, 1.5);

                emit[idx].worldPos = seEncodePosition(bi, si, 1, lE, rE, baseEnergy,
                    params, a, lufs, crest, thd, phaseCoh,
                    beatPulse, kickSurge, transientAmt, envelope);
                emit[idx].intensity = rEnergy;
                emit[idx].active = bandGate;
                emit[idx].wavePhase = Time * waveFreq + float(bi) * 0.5 + subFrac * PI + PI + phrasePhase * 0.1;
                emit[idx].bandIdx = bi;
                emit[idx].side = 1;
                emit[idx].subIdx = si;

                float hue = a.hueBase + bandFrac * a.hueRange + 0.03
                          + a.section * 0.03 + subFrac * 0.05
                          + colorPulse * 0.02;
                float3 c = hsv(hue, 0.7 * a.satur, 1.0);
                c = lerp(c, a.brainCol2, 0.3);
                c = lerp(c, a.brainCol, bandFrac * 0.2);
                c = lerp(c, a.brainCol3, speechBoost * 0.5);
                emit[idx].color = c;

                emit[idx].depth = seDepth(emit[idx].worldPos, cam);
                emit[idx].screenPos = seProject(emit[idx].worldPos, cam);
                emit[idx].screenSize = (0.025 + rEnergy * 0.04) / max(emit[idx].depth * 0.3, 0.3) * 3.0;
                emit[idx].screenSize /= (1.0 + crest * 0.3);
                emit[idx].screenSize *= barScale;
                emit[idx].depthFog = 1.0;
                emit[idx].nearFade = saturate((emit[idx].depth - 0.5) / 0.5);
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

// ═══════════════════════════════════════════════════════════════════════════════
// WORLD ENVIRONMENT LAYER — room grid, atmospheric fog, listener focal point
// Modes opt-in by calling seWorldEnvironment() before rendering emitters.
// ═══════════════════════════════════════════════════════════════════════════════

struct SeWorld {
    float fogDensity;       // exponential fog coefficient (0.02-0.15)
    float3 fogColor;        // fog tint (dark blue/purple for venue)
    float floorY;           // ground plane Y position
    float ceilY;            // ceiling plane Y (0 = no ceiling)
    float wallZ;            // back wall Z position (0 = no wall)
    float gridScale;        // perspective grid spacing
    float gridIntensity;    // grid brightness (0.02-0.06)
    float ambientLevel;     // ambient fill light (0.002-0.01)
    float3 ambientColor;    // ambient tint
    int flags;              // bit 0=floor, bit 1=ceiling, bit 2=wall
};

SeWorld seWorld(float fogDensity, float3 fogColor, float floorY, float ceilY, float wallZ) {
    SeWorld w;
    w.fogDensity = fogDensity;
    w.fogColor = fogColor;
    w.floorY = floorY;
    w.ceilY = ceilY;
    w.wallZ = wallZ;
    w.gridScale = 2.0;
    w.gridIntensity = 0.04;
    w.ambientLevel = 0.004;
    w.ambientColor = float3(0.1, 0.08, 0.15);
    w.flags = 1;  // floor only by default
    return w;
}

// Room grid via ray-plane intersection — same technique as modes 25 & 49
float3 seWorldEnvironment(float2 p, SeCamera cam, SeWorld world,
                          AudioData a, float kickSurge, float silence)
{
    float3 col = float3(0, 0, 0);
    float3 rd = normalize(cam.fwd + p.x * cam.right * cam.fov + p.y * cam.up * cam.fov);

    // Ambient fill — prevents pure black, gives the world substance
    col += world.ambientColor * world.ambientLevel * silence;

    // Floor grid — branchless ray-plane intersection
    float tFloor = (world.floorY - cam.pos.y) / (rd.y + 1e-5);
    float floorHit = step(0.0, tFloor) * step(tFloor, 30.0) * step(-0.01, -rd.y);
    {
        float3 hitPos = cam.pos + rd * tFloor;
        float2 gridUV = float2(hitPos.x * world.gridScale, -hitPos.z * world.gridScale * 0.9);
        float2 gridId = abs(frac(gridUV) - 0.5);
        float gridLine = smoothstep(0.47, 0.5, max(gridId.x, gridId.y));
        float gridFade = smoothstep(0.0, 8.0, tFloor) * smoothstep(30.0, 12.0, tFloor);
        float floorMask = floorHit * float(world.flags & 1);
        col += a.brainCol * gridLine * world.gridIntensity * gridFade * floorMask * silence;
        col += a.brainCol2 * gridLine * kickSurge * world.gridIntensity * 1.5 * gridFade * floorMask * silence;
    }

    // Ceiling grid — branchless
    float tCeil = (world.ceilY - cam.pos.y) / (rd.y + 1e-5);
    float ceilHit = step(0.0, tCeil) * step(tCeil, 30.0) * step(0.01, rd.y);
    {
        float3 hitPos = cam.pos + rd * tCeil;
        float2 gridUV = float2(hitPos.x * world.gridScale, -hitPos.z * world.gridScale * 0.9);
        float2 gridId = abs(frac(gridUV) - 0.5);
        float gridLine = smoothstep(0.47, 0.5, max(gridId.x, gridId.y));
        float gridFade = smoothstep(0.0, 8.0, tCeil) * smoothstep(30.0, 12.0, tCeil);
        float ceilMask = ceilHit * float(world.flags & 2);
        col += a.brainCol2 * gridLine * world.gridIntensity * 0.7 * gridFade * ceilMask * silence;
    }

    // Back wall grid — branchless
    float tWall = (world.wallZ - cam.pos.z) / (rd.z + 1e-5);
    float wallHit = step(0.0, tWall) * step(tWall, 30.0) * step(-0.01, -rd.z);
    {
        float3 hitPos = cam.pos + rd * tWall;
        float2 wallUV = float2(hitPos.x * world.gridScale * 0.9, hitPos.y * world.gridScale * 0.9);
        float2 wallId = abs(frac(wallUV) - 0.5);
        float wallLine = smoothstep(0.47, 0.5, max(wallId.x, wallId.y));
        float wallFade = smoothstep(0.0, 5.0, tWall) * smoothstep(30.0, 12.0, tWall);
        float wallMask = wallHit * float(world.flags & 4);
        col += a.brainCol * wallLine * world.gridIntensity * 0.6 * wallFade * wallMask * silence;
    }

    return col;
}

// Depth-resolved glow — applies atmospheric perspective to emitter rendering
// Far emitters: dimmer, desaturated, softer. Near emitters: bright, sharp.
float3 seEmitGlowDepth(float2 p, SeEmitter e, SeWorld world,
                       float lufs, float crest, float beatBright,
                       float beatPhase, float kickLunge, float transientAmt,
                       float silence)
{
    float2 diff = p - e.screenPos;
    float d2 = dot(diff, diff);
    float s = e.screenSize;
    float s2 = s * s;

    float cullRad2 = s2 * 55.2;
    if (d2 > cullRad2) return float3(0, 0, 0);

    // Atmospheric perspective — uses precomputed depthFog from SeEmitter (no exp() here)
    // nearFade clamps objects too close to camera (VR vergence safety)
    float depthFog = e.depthFog;
    float vrSafe = e.nearFade;
    float satFade = lerp(0.3, 1.0, depthFog);  // far objects desaturated
    float brightFade = lerp(0.15, 1.0, depthFog) * vrSafe;  // far objects dimmer, near objects fade for VR

    float d = sqrt(d2);
    float3 col = float3(0, 0, 0);

    float outer = exp(-d2 / (s2 * 8.0));
    float mid = exp(-d2 / (s2 * 2.5));
    float core = exp(-d2 / (s2 * 0.25));

    // Desaturate color for distant objects
    float3 emitCol = lerp(dot(e.color, float3(0.33, 0.33, 0.34)), e.color, satFade);

    col += emitCol * outer * e.intensity * 0.07 * brightFade * (1.0 + lufs * 0.25) * silence;
    col += emitCol * mid * (0.05 + e.intensity * 0.17) * 0.12 * brightFade * silence;
    col += float3(0.9, 0.95, 1.0) * core * e.intensity * (0.5 + beatBright * 0.5) * (1.0 + crest * 0.3) * 0.13 * brightFade * silence;

    // Wave rings — dimmed by fog
    float wp = e.wavePhase;
    float r1 = frac(wp * 0.3) * s * 6.0;
    col += emitCol * exp(-abs(d - r1) * 50.0 / e.depth) * e.intensity * 0.05 * brightFade * silence;
    float r2 = frac(wp * 0.3 + 0.33) * s * 6.0;
    col += emitCol * exp(-abs(d - r2) * 60.0 / e.depth) * e.intensity * 0.03 * brightFade * silence;

    if (e.bandIdx <= 1) {
        col += float3(1.0, 0.5, 0.15) * core * kickLunge * e.intensity * 0.04 * brightFade * silence;
    }

    if (transientAmt > 0.15) {
        float trR = transientAmt * s * 5.0;
        col += emitCol * exp(-abs(d - trR) * 60.0 / e.depth) * transientAmt * 0.05 * brightFade * silence;
    }

    if (beatBright > 0.1) {
        float br = beatPhase * s * 4.0;
        col += emitCol * exp(-abs(d - br) * 100.0 / e.depth) * beatBright * 0.02 * brightFade * silence;
    }

    // Fog tint — blend distant emission toward fog color
    col = lerp(col, col * world.fogColor, (1.0 - depthFog) * 0.3);

    return col;
}

// Listener focal point — gives the viewer a spatial anchor ("where am I")
// Beat pulse ring + kick flash radiate from listener position
float3 seListener(float2 p, SeCamera cam, AudioData a,
                  float beatPulse, float kickSurge, float silence)
{
    float3 col = float3(0, 0, 0);
    float2 listenerPos = seProject(float3(0, 0, -2.0), cam);
    float listenDist = length(p - listenerPos);

    // Steady listener glow
    col += a.brainCol * exp(-listenDist * listenDist * 100.0) * 0.1 * silence;

    // Beat pulse ring — radiates outward from listener
    float beatPulseR = a.beatPhase * 0.2 * a.tempoConf;
    col += a.brainCol2 * exp(-abs(listenDist - beatPulseR) * 35.0) * beatPulse * 0.15 * silence;

    // Kick flash — warm burst from listener
    col += float3(1.0, 0.5, 0.15) * exp(-listenDist * listenDist * 8.0) * a.kick * 0.2 * a.kickConf * silence;

    return col;
}

// Precompute depthFog for all emitters from world fog density
// Call after seComputeEmitters() and before seRenderWorld() — avoids exp() in per-pixel loop
void seApplyWorldFog(inout SeEmitter emit[SE_NUM_OBJ], SeWorld world) {
    [unroll] for (int i = 0; i < SE_NUM_OBJ; i++) {
        emit[i].depthFog = exp(-emit[i].depth * world.fogDensity);
    }
}

// Full render with world environment + depth-resolved emitters + listener
float3 seRenderWorld(float2 p, SeEmitter emit[SE_NUM_OBJ], SeCamera cam, SeWorld world,
                     float lufs, float crest, float beatBright, float beatPhase,
                     float kickLunge, float transientAmt, float phaseCorr, float phaseCoh,
                     AudioData a, float beatPulse, float silence)
{
    float3 col = float3(0, 0, 0);

    // World environment first (background)
    col += seWorldEnvironment(p, cam, world, a, kickLunge, silence);

    // Emitters back-to-front with depth fog
    [loop] for (int ri = SE_NUM_OBJ - 1; ri >= 0; ri--) {
        if (emit[ri].active < 0.01) continue;
        if (emit[ri].depth < 0.1) continue;
        col += seEmitGlowDepth(p, emit[ri], world, lufs, crest, beatBright,
                               beatPhase, kickLunge, transientAmt, silence);
    }

    // L↔R links
    [loop] for (int lb = 0; lb < SE_N_BANDS; lb++) {
        col += seLinkLR(p, emit, lb, phaseCorr, phaseCoh, silence);
    }

    // Listener focal point
    col += seListener(p, cam, a, beatPulse, kickLunge, silence);

    return col;
}

#endif // SPATIAL_ENCODER_HLSL
