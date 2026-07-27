// RS by Resonance — RapidSpectrum Visualizer
// Mode 37: Resonance Field — 4D Chladni standing-wave interference from psychoacoustic sources
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_PSYCHOACOUSTIC.
//
// Sound sources are placed where the listener's brain perceives them in 3D space:
//   Azimuth  ← stereo pan (HRTF-inspired horizontal plane)
//   Elevation ← frequency band (bass=low, treble=high, non-linear pow 0.85)
//   Distance  ← energy (loud=close, quiet=far)
//
// Chladni standing-wave patterns emanate from each psychoacoustic source position.
// Constructive interference = bright antinodes, destructive = dark nodes.
// Depth fog + far-field desaturation give volumetric presence in VR.
//
// World: subtle grid floor, fog density 0.06, dark ambient.
// Camera: listener inside the field, slow orbit, FOV 0.6 (VR: head pose from OpenXR).
// Negative space: only active emitters render, gated aggressively.
//
// DSP additive: LUFS→density, crest→sharpness, THD→turbulence, phase→L/R coherence.
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// Chladni standing-wave pattern — classic plate vibration modes
// Returns interference amplitude at screen-space distance d from source center
float chladni(float d, float freq, float phase, float mode1, float mode2)
{
    float u = d * freq + phase;
    float v = d * freq * 0.7 + phase * 0.5;
    return cos(mode1 * u) * cos(mode2 * v) + sin(mode1 * v) * sin(mode2 * u);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();
    float phaseCorr = phaseCoherence();

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — VR head pose or desktop orbit ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.6;
        float camAng = a.section * 0.2 + a.stereoBal * 0.15;
        float3 camPos = float3(sin(camAng) * 2.5, 1.0 + a.stereoDiff * 0.08, cos(camAng) * 3.0);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder: PSYCHOACOUSTIC profile ──
    SeParams params = seParams(SE_PROFILE_PSYCHOACOUSTIC);
    params.widthScale = 2.0;
    params.heightScale = 3.0;
    params.depthScale = 5.0;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;
    params.motionSpeed = 0.8;
    params.crossOver = 0.35;
    params.jitterAmt = 1.2;

    // ── Compute all 48 emitters from brain data ──
    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment — subtle grid floor, fog, dark ambient ──
    SeWorld world = seWorld(0.06,                          // fog density
                            float3(0.01, 0.008, 0.02),     // fog color (dark blue-purple)
                            -1.2,                          // floor Y
                            0.0,                           // no ceiling
                            0.0);                          // no back wall
    world.gridScale = 2.5;
    world.gridIntensity = 0.03;    // subtle
    world.ambientLevel = 0.003;    // dark
    world.ambientColor = float3(0.08, 0.06, 0.12);
    world.flags = 1;               // floor only

    // Apply fog to all emitters (precomputes depthFog)
    seApplyWorldFog(emit, world);

    // ── Render world + emitters + links + listener ──
    float3 col;
    if (VR_ACTIVE) {
        float3 headPos = VRHeadPos.xyz;
        col = seRenderWorldVR(p, emit, cam, world, headPos,
                              a, beatPulse, kickSurge, phaseCorr, phaseCoh, silence);
    } else {
        col = seRenderWorld(p, emit, cam, world,
                           lufs, crest, beatPulse, a.beatPhase,
                           kickSurge, transientAmt, phaseCorr, phaseCoh,
                           a, beatPulse, silence);
    }

    // ── Chladni standing-wave interference field ──
    // Sum wave patterns from active emitters — this is the signature visual
    float waveTime = Time * 1.2 + a.beatPhase * PI * 2.0;
    float beatCompress = 1.0 - beatPulse * 0.12;

    float fieldVal = 0.0;
    float3 fieldCol = float3(0, 0, 0);
    float weightSum = 0.0;

    [loop] for (int j = 0; j < SE_NUM_OBJ; j++) {
        if (emit[j].active < 0.01) continue;
        if (emit[j].depth < 0.1) continue;

        float2 diff = p - emit[j].screenPos;
        float scrDist2 = dot(diff, diff);

        float bt = float(emit[j].bandIdx) / 7.0;
        float influenceR = lerp(0.7, 0.25, bt) * (0.5 + emit[j].intensity * 0.7);
        float inflR2 = influenceR * influenceR;
        if (scrDist2 > inflR2) continue;

        float scrDist = sqrt(scrDist2);
        // Chladni mode parameters — band-dependent patterns
        float mode1 = lerp(2.0, 6.0, bt) * beatCompress;
        float mode2 = lerp(3.0, 5.0, bt) * beatCompress;
        float waveFreq = lerp(3.0, 12.0, bt);
        float depthPhase = emit[j].depth * 1.5;

        float chlad = chladni(scrDist, waveFreq, waveTime + depthPhase + float(j) * 0.1, mode1, mode2);
        float amp = emit[j].intensity;
        float depthFog = emit[j].depthFog;
        float falloff = exp(-scrDist2 / (inflR2 * 0.3));

        float wave = chlad * amp * (1.0 + crest * 0.3) * falloff * depthFog;

        fieldVal += wave;
        fieldCol += emit[j].color * abs(wave);
        weightSum += abs(wave);
    }

    if (weightSum > 0.001) fieldCol /= weightSum;

    // ── Aggressive negative-space gating — only show meaningful interference ──
    float density = abs(fieldVal) * 0.14;
    density += thd * hash11(r * 17.3 + Time * 3.0) * density * 0.05;
    density += transientAmt * hash21(p * 30.0 + Time * 8.0) * 0.012;
    density += envelope * 0.003;

    // Tight gate — aggressive culling of near-silent regions
    float gate = smoothstep(0.003, 0.015, density);
    float decayGate = max(envelope, a.gated * 0.3);
    density *= gate * decayGate;

    float3 emission = fieldCol * density * (1.0 + lufs * 0.15);
    emission *= (1.0 + beatPulse * 0.08);
    col += emission * silence;

    // ── Mode-specific overlays ──
    col += a.brainCol3 * kickSurge * 0.01 * exp(-r * r * 5.0) * silence;
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.006 * silence;
    col += a.brainCol3 * a.colorPulse * 0.005 * silence;
    col += a.brainCol2 * a.energy * 0.004 * silence;
    col += a.brainCol * a.beatAnt * 0.003 * exp(-r * 2.0) * silence;

    col *= (0.3 + a.gated * 0.7);
    col += standardOverlays(p, r, a) * 0.006;

        // ── Active-emitter normalization — busy music doesn't stack brighter ──
    col *= sqrt(16.0 / seActiveCount(emit));
    // ── Soft tone mapping (Reinhard) — no hard clamp, preserves color ──
    col = softReinhard(col);

    col *= silence;
    return float4(col, 1.0);
}
