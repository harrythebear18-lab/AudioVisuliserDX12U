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

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    // ── DSP additive ──
    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();
    float phaseCorr = phaseCoherence();

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
        float camAng = a.section * 0.15 + a.stereoBal * 0.08 + Time * 0.005 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 1.5, 1.5 + a.stereoDiff * 0.08, 2.8 + cos(camAng) * 0.3);
        cam = seCamera(camPos, float3(0, -0.3, -2.0), 0.75);
    }

    // ── Spatial encoder: WAVE_FIELD profile ──
    SeParams params = seParams(SE_PROFILE_WAVE_FIELD);
    params.widthScale = 1.8;
    params.heightScale = 4.5;
    params.depthScale = 5.0;
    params.jitterAmt = 0.1 + thd * 0.15;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment — floor + back wall (wave_field visual identity) ──
    SeWorld world = seWorld(0.04, float3(0.003, 0.002, 0.008), -1.8, 0.0, -6.0);
    world.gridScale = 2.0;
    world.gridIntensity = 0.04;
    world.ambientLevel = 0.004;
    world.ambientColor = float3(0.01, 0.008, 0.02);
    world.flags = 5;  // floor + back wall
    seApplyWorldFog(emit, world);

    // ── Background — dark wave field space + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.005;

    // ── Emitter glow — depth-aware, VR or desktop ──
    if (VR_ACTIVE) {
        float3 headPos = float3(VRHeadPos.xyz);
        [loop] for (int j = 0; j < SE_NUM_OBJ; j++) {
            if (emit[j].active < 0.01 || emit[j].depth < 0.1) continue;
            col += seEmitGlowVR(p, emit[j], world, headPos, silence);
        }
    } else {
        [loop] for (int j = 0; j < SE_NUM_OBJ; j++) {
            if (emit[j].active < 0.01 || emit[j].depth < 0.1) continue;
            col += seEmitGlowDepth(p, emit[j], world, lufs, crest, beatBright,
                                   a.beatPhase, kickSurge, transientAmt, silence);
        }
    }

    // ── L↔R links ──
    [loop] for (int lb = 0; lb < SE_N_BANDS; lb++) {
        col += seLinkLR(p, emit, lb, phaseCorr, phaseCoh, silence);
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

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

        // ── Active-emitter normalization — busy music doesn't stack brighter ──
    col *= sqrt(16.0 / seActiveCount(emit));
    // ── Soft tone mapping (Reinhard) — no hard clamp, preserves color ──
    col = softReinhard(col);

    col *= silence;

    return float4(col, 1.0);
}
