// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 44: Phonon Crystal Lattice — 3D phononic crystal wave propagation
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_SPHERICAL.
//
// 48 emitters (8 bands × 3 sub × L/R) placed on a sphere as lattice atoms.
// Emitters become crystal lattice points with phonon wave displacement.
// Beat = wave packet injection. Kick = lattice compression wave.
// Transient = defect scattering. THD = lattice disorder. Phase = wave coherence.
//
// World: grid floor for depth grounding, fog density 0.06, dark ambient.
// Camera: inside the crystal, FOV 0.7 (VR: head pose from OpenXR).
// Visual: glowing lattice atoms at emitter positions + bonds between nearby pairs.
//
// DSP: LUFS→wave amplitude, crest→lattice stiffness, THD→lattice disorder, phase→wave coherence.
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

    // ── Camera — VR head pose or desktop inside the crystal ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.7;
        float camAng = a.section * 0.5 + a.stereoBal * 0.2;
        float3 camPos = float3(sin(camAng) * 3.0, 1.0 + a.stereoDiff * 0.1, cos(camAng) * 3.0);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder: SPHERICAL profile ──
    SeParams params = seParams(SE_PROFILE_SPHERICAL);
    params.widthScale = 2.0;
    params.heightScale = 2.0;
    params.depthScale = 2.0;
    params.jitterAmt = 0.1 + thd * 0.25;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.06, float3(0.01, 0.005, 0.02), -1.5, 0.0, 0.0);
    world.gridIntensity = 0.02;
    world.ambientLevel = 0.003;
    world.ambientColor = float3(0.015, 0.01, 0.03);
    seApplyWorldFog(emit, world);

    // ── Background — dark crystal void + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.005;

    // ── Lattice bonds — connect nearby emitters ──
    [loop] for (int i = 0; i < SE_NUM_OBJ; i++) {
        if (emit[i].active < 0.01) continue;
        if (emit[i].depth < 0.1) continue;

        [loop] for (int j = i + 1; j < SE_NUM_OBJ; j++) {
            if (emit[j].active < 0.01) continue;
            if (emit[j].depth < 0.1) continue;

            // Only connect emitters within same band or adjacent band
            int bandDiff = abs(emit[i].bandIdx - emit[j].bandIdx);
            if (bandDiff > 1) continue;

            float3 restDelta = emit[j].worldPos - emit[i].worldPos;
            float restDist = length(restDelta);
            if (restDist > 1.5) continue;

            float2 ab = emit[j].screenPos - emit[i].screenPos;
            float abLen2 = dot(ab, ab);
            if (abLen2 > 0.04) continue;

            float t = clamp(dot(p - emit[i].screenPos, ab) / max(abLen2, 0.0001), 0.0, 1.0);
            float2 closest = emit[i].screenPos + ab * t;
            float bondDist = length(p - closest);
            float bondWidth = 0.0015;
            float bondGlow = exp(-bondDist * bondDist / (bondWidth * bondWidth));

            // Strain-based bond color
            float strain = restDist / max(restDist, 0.1) - 1.0;
            float3 bondCol = lerp(emit[i].color, emit[j].color, 0.5);
            bondCol = lerp(bondCol, float3(1.0, 0.3, 0.1), abs(strain) * 2.0);

            float avgDepth = (emit[i].depth + emit[j].depth) * 0.5;
            float depthFade = exp(-avgDepth * world.fogDensity);
            float bondInt = (emit[i].intensity + emit[j].intensity) * 0.5 * (1.0 + lufs * 0.15);

            col += bondCol * bondGlow * bondInt * depthFade * 0.03 * silence;
        }
    }

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
            col += seEmitGlowDepth(p, emit[j], world, lufs, crest, beatPulse,
                                   a.beatPhase, kickSurge, transientAmt, silence);
        }
    }

    // ── L↔R links ──
    [loop] for (int lb = 0; lb < SE_N_BANDS; lb++) {
        col += seLinkLR(p, emit, lb, phaseCorr, phaseCoh, silence);
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Mode-specific overlays — subtle ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;
    col += a.brainCol3 * kickSurge * 0.04 * exp(-r * r * 5.0) * silence;
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.02 * silence;
    col += a.brainCol3 * a.colorPulse * 0.015 * silence;
    col += a.brainCol2 * a.energy * 0.01 * silence;
    col += a.brainCol * a.punch * 0.01 * silence;
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
