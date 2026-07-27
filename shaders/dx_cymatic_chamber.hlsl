// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 45: Cymatic Resonance Chamber — 3D Chladni patterns on parallel surfaces
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_PSYCHOACOUSTIC.
//
// 48 emitters (8 bands × 3 sub × L/R) placed as psychoacoustic sources.
// Each band = a different resonance frequency on a parallel surface.
// Emitters drive surface positions and Chladni nodal patterns.
// Kick = surface impact. Transient = pattern rearrangement.
// Beat = standing wave pulse.
//
// World: grid floor for depth grounding, fog density 0.05, dark ambient.
// Camera: looking into the chamber from front, FOV 0.65 (VR: head pose from OpenXR).
// Visual: parallel surfaces at emitter-driven depths with Chladni particle patterns.
//
// DSP: LUFS→surface brightness, crest→pattern sharpness, THD→surface noise, phase→pattern symmetry.
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define GRID_N 8

// Chladni pattern — nodal lines where particles collect
float chladniPattern(float2 uv, float freq, float phase)
{
    float x = uv.x * PI * freq;
    float y = uv.y * PI * freq;
    float n = freq;
    float m = freq * 0.7 + 1.0;
    float pattern = sin(n * x + phase) * sin(m * y) - sin(m * x) * sin(n * y + phase);
    return abs(pattern);
}

// ── Cymatic surface derived from emitters (one per band) ──
struct CymaticSurface {
    float zDepth;
    float yOffset;
    float frequency;
    float amplitude;
    float gate;
    float3 color;
};

void computeSurfacesFromEmitters(out CymaticSurface surfaces[SE_N_BANDS], SeEmitter emit[SE_NUM_OBJ], AudioData a)
{
    [unroll] for (int band = 0; band < SE_N_BANDS; band++) {
        int idx = band * SE_N_SUB * 2;
        float bt = float(band) / float(SE_N_BANDS - 1);

        surfaces[band].gate = emit[idx].active * step(0.05, emit[idx].intensity);
        if (surfaces[band].gate < 0.01) {
            surfaces[band].zDepth = 100.0;
            surfaces[band].yOffset = 0.0;
            surfaces[band].frequency = 4.0;
            surfaces[band].amplitude = 0.0;
            surfaces[band].color = float3(0, 0, 0);
            continue;
        }

        // Average energy across all subs for this band
        float avgEnergy = 0.0;
        [unroll] for (int sub = 0; sub < SE_N_SUB; sub++) {
            avgEnergy += emit[band * SE_N_SUB * 2 + sub * 2].intensity;
            avgEnergy += emit[band * SE_N_SUB * 2 + sub * 2 + 1].intensity;
        }
        avgEnergy /= float(SE_N_SUB * 2);

        surfaces[band].zDepth = lerp(-3.0, 0.5, bt);
        surfaces[band].frequency = lerp(2.0, 16.0, bt) * (1.0 + a.tempo * 0.2);
        surfaces[band].yOffset = emit[idx].worldPos.y * 0.5;
        surfaces[band].amplitude = avgEnergy;
        surfaces[band].color = emit[idx].color;
    }
}

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

    // ── Camera — VR head pose or desktop looking into chamber ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.65;
        float camAng = a.section * 0.3 + a.stereoBal * 0.15 + Time * 0.02 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 1.5, 0.5 + a.stereoDiff * 0.05, 3.0);
        cam = seCamera(camPos, float3(0, 0, -1.5), FOV);
    }

    // ── Spatial encoder: PSYCHOACOUSTIC profile ──
    SeParams params = seParams(SE_PROFILE_PSYCHOACOUSTIC);
    params.widthScale = 2.5;
    params.heightScale = 2.0;
    params.depthScale = 2.5;
    params.jitterAmt = 0.12 + thd * 0.2;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.05, float3(0.01, 0.003, 0.015), -1.5, 0.0, 0.0);
    world.gridIntensity = 0.02;
    world.ambientLevel = 0.003;
    world.ambientColor = float3(0.012, 0.008, 0.02);
    seApplyWorldFog(emit, world);

    // ── Derive surfaces from emitters ──
    CymaticSurface surfaces[SE_N_BANDS];
    computeSurfacesFromEmitters(surfaces, emit, a);

    // ── Background — dark resonance chamber + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.003;

    // ── Cymatic surfaces — parallel planes at different depths ──
    [loop] for (int s = 0; s < SE_N_BANDS; s++) {
        if (surfaces[s].gate < 0.01) continue;

        float3 surfCenter = float3(0, surfaces[s].yOffset, surfaces[s].zDepth);
        float3 toSurf = surfCenter - cam.pos;
        float surfDepth = dot(toSurf, cam.fwd);
        if (surfDepth < 0.1) continue;
        float2 scrSurf = float2(dot(toSurf, cam.right) / (surfDepth * cam.fov),
                                dot(toSurf, cam.up) / (surfDepth * cam.fov));
        float surfSize = 2.5 / (surfDepth * cam.fov);

        // Grid of particles on surface showing Chladni pattern
        [loop] for (int gx = 0; gx <= GRID_N; gx++) {
            [loop] for (int gy = 0; gy <= GRID_N; gy++) {
                float2 gridUV = float2(float(gx), float(gy)) / float(GRID_N) - 0.5;
                gridUV *= 4.0;

                float bt = float(s) / float(SE_N_BANDS - 1);
                float vertPhase = Time * 0.5 + bt * PI;
                vertPhase += surfaces[s].yOffset * 2.0;
                vertPhase += a.beatPhase * bt * 3.0;
                float pattern = chladniPattern(gridUV, surfaces[s].frequency, vertPhase);

                float nodal = exp(-pattern * pattern * 5.0 * (1.0 + crest * 0.5));
                nodal *= (1.0 - thd * 0.3 * hash21(gridUV * 50.0 + Time * 10.0));

                float impactDist = length(gridUV);
                nodal += kickSurge * exp(-impactDist * impactDist * 3.0) * 0.3;

                nodal *= (1.0 - transientAmt * 0.2 * sin(gridUV.x * 20.0 + Time * 30.0));

                if (nodal < 0.01) continue;

                float3 particlePos = float3(gridUV.x, gridUV.y + surfaces[s].yOffset, surfaces[s].zDepth);
                particlePos.y += a.stereoBal * 0.1 * gridUV.x;
                particlePos.y += sin(gridUV.x * 3.0 + Time * 2.0 + bt * PI) * surfaces[s].amplitude * 0.15;

                float3 toPart = particlePos - cam.pos;
                float partDepth = dot(toPart, cam.fwd);
                if (partDepth < 0.1) continue;
                float2 scrPart = float2(dot(toPart, cam.right) / (partDepth * cam.fov),
                                        dot(toPart, cam.up) / (partDepth * cam.fov));
                float scrDist = length(p - scrPart);

                float ptSize = 0.01 / max(partDepth * 0.15, 0.3);
                float coreGlow = exp(-scrDist * scrDist / (ptSize * ptSize * 0.1));
                float midGlow = exp(-scrDist * scrDist / (ptSize * ptSize * 0.5));

                float intensity = nodal * surfaces[s].amplitude * (1.0 + lufs * 0.3);
                float depthFade = exp(-partDepth * world.fogDensity);

                col += surfaces[s].color * coreGlow * intensity * depthFade * 0.25 * silence;
                col += surfaces[s].color * midGlow * intensity * depthFade * 0.08 * silence;
            }
        }

        // Surface frame — edge glow
        float2 frameDist = abs(p - scrSurf);
        float frameEdge = max(abs(frameDist.x - surfSize), abs(frameDist.y - surfSize));
        col += surfaces[s].color * exp(-frameEdge * frameEdge * 50.0) * surfaces[s].amplitude * 0.015 * silence;
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

    // ── Beat — standing wave pulse ──
    col += a.brainCol * beatPulse * exp(-a.beatPhase * 4.0) * 0.025 * silence;

    // ── Mode-specific overlays — subtle ──
    col += a.brainCol3 * kickSurge * 0.04 * exp(-r * r * 5.0) * silence;
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.02 * silence;
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
