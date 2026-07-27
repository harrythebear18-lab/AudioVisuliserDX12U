// RS by Resonance — RapidSpectrum Visualizer
// Mode 36: Gravitational Wavefield — Cosmic Web
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_SPHERICAL.
//
// 48 emitters distributed on a golden-ratio sphere via SPHERICAL profile.
// Filaments connect nearby emitters — a cosmic web of gravitational links.
// Each emitter is a gravitational well; filaments show spacetime curvature.
// Beat = omnidirectional gravitational wave event. Kick = spacetime tear.
//
// World: grid floor for spatial grounding, fog density 0.04, dark ambient.
// Camera: outside looking in at the web, FOV 0.5 (VR: head pose from OpenXR).
// Filaments: distance-to-segment rendering with depth fog, culled by proximity.
//
// DSP additive: LUFS→well depth, crest→filament sharpness, THD→jitter,
// phase→L/R filament coherence.
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// ── Distance from point to line segment in 2D ──
float distToSeg2D(float2 p, float2 a, float2 b, out float2 closest)
{
    float2 ab = b - a;
    float lenSq = dot(ab, ab);
    if (lenSq < 0.0001) { closest = a; return length(p - a); }
    float t = clamp(dot(p - a, ab) / lenSq, 0.0, 1.0);
    closest = a + ab * t;
    return length(p - closest);
}

// ── Filament rendering — connect two emitters with a glowing filament ──
// Uses distance-to-segment with depth fog from both endpoints
float3 renderFilament(float2 p, SeEmitter a, SeEmitter b,
                      float phaseCorr, float phaseCoh, float silence)
{
    if (a.active < 0.05 || b.active < 0.05) return float3(0, 0, 0);
    if (a.depth < 0.1 || b.depth < 0.1) return float3(0, 0, 0);
    if (a.intensity < 0.06 || b.intensity < 0.06) return float3(0, 0, 0);

    // Screen-space distance to segment
    float2 closest;
    float segDist = distToSeg2D(p, a.screenPos, b.screenPos, closest);
    float segDist2 = segDist * segDist;
    if (segDist2 > 0.015) return float3(0, 0, 0);

    // Average depth fog — both endpoints contribute
    float avgDepthFog = (a.depthFog + b.depthFog) * 0.5;

    // Filament strength — based on proximity in world space + phase correlation
    float worldDist = length(a.worldPos - b.worldPos);
    float proximity = exp(-worldDist * 0.8);
    float linkStr = proximity * a.intensity * b.intensity * (0.3 + phaseCorr * 0.4);
    linkStr *= avgDepthFog;

    // Filament color — blend both emitter colors
    float3 linkCol = lerp(a.color, b.color, 0.5);

    // Thin glowing line
    float lineWidth = 0.0015 / max(avgDepthFog, 0.1);
    float lineIntensity = exp(-segDist2 / (lineWidth * lineWidth * 3.0));

    float3 col = linkCol * lineIntensity * linkStr * 0.15 * silence;

    // Phase coherence bright spot at midpoint
    if (phaseCoh > 0.4) {
        float2 midPt = (a.screenPos + b.screenPos) * 0.5;
        float midDist = length(p - midPt);
        col += float3(0.85, 0.9, 1.0) * exp(-midDist * midDist * 500.0) *
               phaseCoh * a.intensity * b.intensity * 0.04 * avgDepthFog * silence;
    }

    return col;
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
    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — VR head pose or desktop orbit outside the web ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.5;
        float camAng = a.section * 0.08 + a.stereoBal * 0.12;
        float camDist = 6.0;
        float camHeight = 2.0 + a.stereoDiff * 0.1;
        float3 camPos = float3(sin(camAng) * camDist, camHeight, cos(camAng) * camDist);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder: SPHERICAL profile ──
    SeParams params = seParams(SE_PROFILE_SPHERICAL);
    params.widthScale = 3.0;
    params.heightScale = 3.0;
    params.depthScale = 3.0;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;
    params.motionSpeed = 0.5;
    params.crossOver = 0.3;
    params.jitterAmt = 0.8;

    // ── Compute all 48 emitters from brain data ──
    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment — grid floor for spatial grounding, moderate fog ──
    SeWorld world = seWorld(0.04,                          // fog density
                            float3(0.008, 0.006, 0.015),   // fog color (deep space)
                            -2.0,                          // floor Y (below the web)
                            0.0,                           // no ceiling
                            0.0);                          // no back wall
    world.gridScale = 3.0;
    world.gridIntensity = 0.02;    // subtle
    world.ambientLevel = 0.002;    // very dark
    world.ambientColor = float3(0.05, 0.04, 0.1);
    world.flags = 1;               // floor only

    // Apply fog to all emitters
    seApplyWorldFog(emit, world);

    // ── Render world environment ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);

    // ── Background — deep spacetime void ──
    col += float3(0.002, 0.001, 0.004) * silence;
    col += starfield(uv, a) * 0.012;
    float nebula = fbm2_4(p * 0.8 + Time * 0.003 * a.motSpeed);
    col += a.brainCol * nebula * 0.006 * a.ambient * a.ambActive * silence;

    // ── Filament rendering — cosmic web connections ──
    // Connect emitters that are near each other in 3D space
    // L↔R links per band (standard spatial encoder links)
    [loop] for (int lb = 0; lb < SE_N_BANDS; lb++) {
        col += seLinkLR(p, emit, lb, phaseCorr, phaseCoh, silence);
    }

    // Filament connections between adjacent sub-frequencies within same band+side
    // This creates the web-like structure
    [loop] for (int bi = 0; bi < SE_N_BANDS; bi++) {
        [unroll] for (int si = 0; si < SE_N_SUB - 1; si++) {
            for (int side = 0; side < 2; side++) {
                int idx0 = bi * SE_N_SUB * 2 + si * 2 + side;
                int idx1 = bi * SE_N_SUB * 2 + (si + 1) * 2 + side;
                col += renderFilament(p, emit[idx0], emit[idx1],
                                      phaseCorr, phaseCoh, silence);
            }
        }
    }

    // Filament connections between adjacent bands (same sub+side)
    [loop] for (int bi = 0; bi < SE_N_BANDS - 1; bi++) {
        [unroll] for (int si = 0; si < SE_N_SUB; si++) {
            for (int side = 0; side < 2; side++) {
                int idx0 = bi * SE_N_SUB * 2 + si * 2 + side;
                int idx1 = (bi + 1) * SE_N_SUB * 2 + si * 2 + side;
                col += renderFilament(p, emit[idx0], emit[idx1],
                                      phaseCorr, phaseCoh, silence);
            }
        }
    }

    // Cross-side filaments for dominant bands (creates 3D web structure)
    [loop] for (int bi = 0; bi < SE_N_BANDS; bi++) {
        [unroll] for (int si = 0; si < SE_N_SUB; si++) {
            int li = bi * SE_N_SUB * 2 + si * 2;
            int ri = bi * SE_N_SUB * 2 + si * 2 + 1;
            // Only render cross-side filaments when both are active and close
            float worldDist = length(emit[li].worldPos - emit[ri].worldPos);
            if (worldDist < 3.0) {
                col += renderFilament(p, emit[li], emit[ri],
                                      phaseCorr, phaseCoh, silence);
            }
        }
    }

    // ── Emitter glow — gravitational wells ──
    if (VR_ACTIVE) {
        float3 headPos = VRHeadPos.xyz;
        [loop] for (int ri2 = 0; ri2 < SE_NUM_OBJ; ri2++) {
            if (emit[ri2].active < 0.01) continue;
            if (emit[ri2].depth < 0.1) continue;
            col += seEmitGlowVR(p, emit[ri2], world, headPos, silence);
        }
    } else {
        [loop] for (int ri2 = SE_NUM_OBJ - 1; ri2 >= 0; ri2--) {
            if (emit[ri2].active < 0.01) continue;
            if (emit[ri2].depth < 0.1) continue;
            col += seEmitGlowDepth(p, emit[ri2], world, lufs, crest, beatPulse,
                                   a.beatPhase, kickSurge, transientAmt, silence);
        }
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Beat — gravitational wave pulse through web ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.015 * silence;

    // ── Kick — spacetime tear ──
    col += float3(1.0, 0.4, 0.1) * kickSurge * 0.03 * exp(-r * r * 5.0) * silence;

    // ── Transient — quantum fluctuation ──
    col += float3(0.8, 0.9, 1.0) * transientAmt * 0.01 * silence;

    // ── Mode-specific overlays ──
    col += a.brainCol3 * a.colorPulse * 0.01 * silence;
    col += a.brainCol2 * a.energy * 0.008 * silence;
    col += a.brainCol * a.punch * 0.008 * silence;
    col += a.brainCol * a.beatAnt * 0.006 * exp(-r * 2.0) * silence;

    col += standardOverlays(p, r, a) * 0.015 * silence;

    // ── Active-emitter normalization — busy music doesn't stack brighter ──
    col *= sqrt(16.0 / seActiveCount(emit));
    // ── Soft tone mapping (Reinhard) — no hard clamp, preserves color ──
    col = softReinhard(col);

    return float4(col, 1.0);
}
