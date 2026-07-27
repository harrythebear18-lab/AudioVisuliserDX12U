// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 43: Gravitational Lens Observatory — black hole with audio-driven accretion disk
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_SPHERICAL.
//
// 48 emitters (8 bands × 3 sub × L/R) placed on a sphere around the black hole.
// Emitters become accretion disk segments — each band = a ring radius.
// Kick = gravitational wave ripple. THD = disk turbulence.
// Phase = relativistic jet alignment. Beat = orbital pulse.
//
// World: grid floor for depth grounding, fog density 0.04, dark ambient.
// Camera: orbit the black hole, FOV 0.6 (VR: head pose from OpenXR).
// Visual: black hole event horizon + photon sphere + accretion disk from emitter positions + lensing.
//
// DSP: LUFS→disk brightness, crest→disk edge sharpness, THD→disk turbulence, phase→jet alignment.
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

    // ── Camera — VR head pose or desktop orbit ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.6;
        float camAng = a.section * 0.8 + a.stereoBal * 0.2 + Time * 0.03 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 5.0, 2.0 + a.stereoDiff * 0.1, cos(camAng) * 5.0);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder: SPHERICAL profile ──
    SeParams params = seParams(SE_PROFILE_SPHERICAL);
    params.widthScale = 3.5;
    params.heightScale = 3.5;
    params.depthScale = 3.5;
    params.jitterAmt = 0.1 + thd * 0.2;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.04, float3(0.01, 0.005, 0.02), -1.5, 0.0, 0.0);
    world.gridIntensity = 0.02;
    world.ambientLevel = 0.003;
    world.ambientColor = float3(0.01, 0.005, 0.02);
    seApplyWorldFog(emit, world);

    // ── Background — starfield with gravitational lensing + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);

    // Gravitational lensing — distort starfield near black hole
    float eventHorizon = 0.15;
    if (r > eventHorizon) {
        float bend = 0.3 / (r * r + 0.1);
        float2 lensP = p * (1.0 + bend);
        col += starfield(uv + lensP * 0.1, a) * 0.04;
    }

    // Event horizon — pure black disc
    if (r < eventHorizon) {
        col = float3(0, 0, 0);
    } else {
        // Photon sphere — bright ring at 1.5x event horizon
        float photonR = eventHorizon * 1.5;
        float photonDist = abs(r - photonR);
        col += float3(1.0, 0.8, 0.5) * exp(-photonDist * photonDist * 200.0) * 0.1 * silence;
    }

    // ── Accretion disk — emitters projected as disk segments ──
    [loop] for (int n = 0; n < SE_NUM_OBJ; n++) {
        if (emit[n].active < 0.01) continue;
        if (emit[n].intensity < 0.05) continue;
        if (emit[n].depth < 0.1) continue;

        // Use emitter world position as accretion disk segment
        float3 ringPos = emit[n].worldPos;
        // Flatten to disk plane (y ≈ 0) with THD turbulence
        ringPos.y = thd * fbm2_4(float2(emit[n].screenPos.x * 3.0, Time * 2.0)) * 0.2;

        float3 toRing = ringPos - cam.pos;
        float ringDepth = dot(toRing, cam.fwd);
        if (ringDepth < 0.1) continue;
        float2 scrRing = float2(dot(toRing, cam.right) / (ringDepth * cam.fov),
                                dot(toRing, cam.up) / (ringDepth * cam.fov));
        float scrDist = length(p - scrRing);

        // Doppler beaming — approaching side brighter
        float segAng = atan2(emit[n].worldPos.z, emit[n].worldPos.x);
        float doppler = 1.0 + sin(segAng + Time * 0.5) * 0.5;
        doppler = clamp(doppler, 0.3, 1.5);

        float segSize = 0.008 / max(ringDepth * 0.15, 0.3);
        float segGlow = exp(-scrDist * scrDist / (segSize * segSize * 0.3));

        float intensity = emit[n].intensity * doppler * (1.0 + lufs * 0.2);
        float depthFade = exp(-ringDepth * world.fogDensity);

        // Hot inner rings = white-orange, cool outer = blue
        float3 diskCol = emit[n].color;
        if (emit[n].bandIdx < 2) diskCol = lerp(diskCol, float3(1.0, 0.6, 0.2), 0.3);

        col += diskCol * segGlow * intensity * depthFade * 0.2 * silence;
    }

    // ── Relativistic jets — phase coherence aligned ──
    if (phaseCoh > 0.3) {
        float3 jetPos = float3(0, 2.0, 0);
        float3 toJet = jetPos - cam.pos;
        float jetDepth = dot(toJet, cam.fwd);
        if (jetDepth > 0.1) {
            float2 scrJet = float2(dot(toJet, cam.right) / (jetDepth * cam.fov),
                                   dot(toJet, cam.up) / (jetDepth * cam.fov));
            float jetDist = length(p - scrJet);
            float jetGlow = exp(-jetDist * jetDist * 20.0) * phaseCoh * 0.08;
            col += a.brainCol3 * jetGlow * silence;
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

    // ── Kick — gravitational wave ripple ──
    if (kickSurge > 0.05) {
        float gwR = a.beatPhase * 0.8;
        float gwDist = abs(r - gwR);
        col += a.brainCol * exp(-gwDist * gwDist * 30.0) * kickSurge * 0.05 * silence;
    }

    // ── Mode-specific overlays — subtle ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;
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
