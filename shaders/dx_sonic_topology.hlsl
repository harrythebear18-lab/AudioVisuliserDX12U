// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 46: Sonic Topology Mapper — 4D topological manifold from audio
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_TUNNEL.
//
// 48 emitters (8 bands × 3 sub × L/R) placed in a tunnel corridor.
// Emitter positions drive manifold deformation — genus shifts with bass,
// surface displacement from mid/high emitters. Wireframe mesh connects
// grid points. Kick = curvature spike. Transient = topology shift.
// Beat = surface ripple.
//
// World: grid floor for depth grounding, fog density 0.04, dark ambient.
// Camera: orbiting the manifold, FOV 0.6 (VR: head pose from OpenXR).
// Visual: parametric manifold grid with emitter-driven displacement + wireframe.
//
// DSP: LUFS→surface brightness, crest→ridge sharpness, THD→surface roughness, phase→displacement symmetry.
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define GRID_N 10

// Find nearest emitter influence at a manifold point
float3 emitterInfluence(float3 manifoldPos, SeEmitter emit[SE_NUM_OBJ],
                        float beatPulse, float kickSurge, float transientAmt,
                        float thd, float envelope, AudioData a)
{
    float3 disp = float3(0, 0, 0);
    float totalWeight = 0.0;

    [loop] for (int i = 0; i < SE_NUM_OBJ; i++) {
        if (emit[i].active < 0.01) continue;
        float dist = length(manifoldPos - emit[i].worldPos);
        float weight = exp(-dist * dist * 2.0) * emit[i].intensity;
        disp += emit[i].worldPos * weight * 0.15;
        totalWeight += weight;
    }

    if (totalWeight > 0.001) {
        disp /= totalWeight;
        disp = (disp - manifoldPos) * 0.3;
    }

    // Beat ripple
    disp += float3(0, 1, 0) * beatPulse * 0.04 * sin(manifoldPos.y * 5.0 - a.beatPhase * 8.0);

    // Kick curvature spike
    disp += normalize(manifoldPos) * kickSurge * 0.06 * exp(-length(manifoldPos) * 2.0) * sin(length(manifoldPos) * 10.0);

    // Transient — topology shift jitter
    disp += float3(
        sin(manifoldPos.x * 20.0 + Time * 20.0),
        sin(manifoldPos.y * 18.0 + Time * 18.0),
        sin(manifoldPos.z * 22.0 + Time * 22.0)
    ) * transientAmt * 0.02;

    // THD roughness
    disp += float3(
        hash11(manifoldPos.x * 50.0 + Time * 10.0) - 0.5,
        hash11(manifoldPos.y * 50.0 + Time * 10.0) - 0.5,
        hash11(manifoldPos.z * 50.0 + Time * 10.0) - 0.5
    ) * thd * 0.015;

    // Envelope breathing
    disp += float3(0, 1, 0) * envelope * 0.015 * sin(Time + manifoldPos.x * 2.0);

    return disp;
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

    // ── Camera — VR head pose or desktop orbiting manifold ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.6;
        float camAng = a.section * 0.8 + a.stereoBal * 0.2 + Time * 0.03 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 3.5, 1.5 + a.stereoDiff * 0.1, cos(camAng) * 3.5);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder: TUNNEL profile ──
    SeParams params = seParams(SE_PROFILE_TUNNEL);
    params.widthScale = 2.0;
    params.heightScale = 3.0;
    params.depthScale = 4.0;
    params.jitterAmt = 0.1 + thd * 0.15;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.04, float3(0.005, 0.003, 0.012), -2.0, 0.0, 0.0);
    world.gridIntensity = 0.02;
    world.ambientLevel = 0.003;
    world.ambientColor = float3(0.008, 0.005, 0.015);
    seApplyWorldFog(emit, world);

    // ── Background — dark topological space + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.003;

    // ── Manifold surface — parametric grid driven by emitters ──
    float genus = bands[0] * 2.0 + bands[1] * 1.0;
    float globalScale = 1.0 + bands[0] * 0.3;

    [loop] for (int gu = 0; gu <= GRID_N; gu++) {
        [loop] for (int gv = 0; gv <= GRID_N; gv++) {
            float u = float(gu) / float(GRID_N) * PI * 2.0;
            float v = float(gv) / float(GRID_N) * PI;

            // Base sphere
            float3 sphPos = float3(sin(v) * cos(u), cos(v), sin(v) * sin(u)) * globalScale;

            // Torus transformation — genus >= 1
            float torusBlend = smoothstep(0.5, 1.5, genus);
            float R = 1.2, r2 = 0.5;
            float3 torusPos = float3(
                (R + r2 * cos(v)) * cos(u),
                r2 * sin(v),
                (R + r2 * cos(v)) * sin(u)
            );
            float3 manifoldPos = lerp(sphPos, torusPos, torusBlend);

            // Double torus — genus >= 2
            float doubleBlend = smoothstep(1.5, 2.5, genus);
            float3 dTorusPos = torusPos;
            dTorusPos.x += sin(u * 2.0) * 0.5 * doubleBlend;
            dTorusPos.y += cos(u * 2.0) * 0.3 * doubleBlend;
            manifoldPos = lerp(manifoldPos, dTorusPos, doubleBlend);

            // Emitter-driven displacement
            float3 disp = emitterInfluence(manifoldPos, emit, beatPulse, kickSurge,
                                           transientAmt, thd, envelope, a);
            manifoldPos += disp;

            // Project to screen
            float3 toMP = manifoldPos - cam.pos;
            float mpDepth = dot(toMP, cam.fwd);
            if (mpDepth < 0.1) continue;
            float2 scrMP = float2(dot(toMP, cam.right) / (mpDepth * cam.fov),
                                  dot(toMP, cam.up) / (mpDepth * cam.fov));
            float scrDist = length(p - scrMP);

            // Color — frequency-positioned by displacement magnitude
            float dispMag = length(disp);
            float freqFrac = clamp(dispMag * 3.0, 0.0, 1.0);
            float3 ptCol = hsv(a.hueBase + freqFrac * a.hueRange, 0.6 * a.satur, 0.9);
            ptCol = lerp(ptCol, lerp(a.brainCol, a.brainCol2, freqFrac), 0.3);
            ptCol = lerp(ptCol, a.brainCol3, pow(dispMag * 2.0, 2.0) * crest * 0.3);

            // Point glow — tight core + crisp mid, minimal halo
            float ptSize = 0.006 / max(mpDepth * 0.15, 0.3);
            float coreGlow = exp(-scrDist * scrDist / (ptSize * ptSize * 0.05));
            float midGlow = exp(-scrDist * scrDist / (ptSize * ptSize * 0.3));
            float haloGlow = exp(-scrDist * scrDist / (ptSize * ptSize * 1.5));

            float intensity = (dispMag * 2.0 + 0.2) * (1.0 + lufs * 0.3);
            float depthFade = exp(-mpDepth * world.fogDensity);

            col += ptCol * coreGlow * intensity * depthFade * 0.35 * silence;
            col += ptCol * midGlow * intensity * depthFade * 0.12 * silence;
            col += ptCol * haloGlow * intensity * depthFade * 0.02 * silence;

            // Wireframe to neighbors
            if (gu < GRID_N) {
                float u2 = float(gu + 1) / float(GRID_N) * PI * 2.0;
                float3 pos2 = float3(sin(v) * cos(u2), cos(v), sin(v) * sin(u2)) * globalScale;
                float3 torusPos2 = float3((R + r2 * cos(v)) * cos(u2), r2 * sin(v), (R + r2 * cos(v)) * sin(u2));
                pos2 = lerp(pos2, torusPos2, torusBlend);
                pos2 = lerp(pos2, torusPos2 + float3(sin(u2 * 2.0) * 0.5, cos(u2 * 2.0) * 0.3, 0) * doubleBlend, doubleBlend);
                pos2 += emitterInfluence(pos2, emit, beatPulse, kickSurge, transientAmt, thd, envelope, a) * 0.7;

                float3 toP2 = pos2 - cam.pos;
                float d2 = dot(toP2, cam.fwd);
                if (d2 > 0.1) {
                    float2 s2 = float2(dot(toP2, cam.right) / (d2 * cam.fov), dot(toP2, cam.up) / (d2 * cam.fov));
                    float2 ab = s2 - scrMP;
                    float t2 = clamp(dot(p - scrMP, ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
                    float2 cl = scrMP + ab * t2;
                    float wd = length(p - cl);
                    col += ptCol * exp(-wd * wd * 500.0) * intensity * depthFade * 0.04 * silence;
                }
            }
            if (gv < GRID_N) {
                float v2 = float(gv + 1) / float(GRID_N) * PI;
                float3 pos2 = float3(sin(v2) * cos(u), cos(v2), sin(v2) * sin(u)) * globalScale;
                float3 torusPos2 = float3((R + r2 * cos(v2)) * cos(u), r2 * sin(v2), (R + r2 * cos(v2)) * sin(u));
                pos2 = lerp(pos2, torusPos2, torusBlend);
                pos2 = lerp(pos2, torusPos2 + float3(sin(u * 2.0) * 0.5, cos(u * 2.0) * 0.3, 0) * doubleBlend, doubleBlend);
                pos2 += emitterInfluence(pos2, emit, beatPulse, kickSurge, transientAmt, thd, envelope, a) * 0.7;

                float3 toP2 = pos2 - cam.pos;
                float d2 = dot(toP2, cam.fwd);
                if (d2 > 0.1) {
                    float2 s2 = float2(dot(toP2, cam.right) / (d2 * cam.fov), dot(toP2, cam.up) / (d2 * cam.fov));
                    float2 ab = s2 - scrMP;
                    float t2 = clamp(dot(p - scrMP, ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
                    float2 cl = scrMP + ab * t2;
                    float wd = length(p - cl);
                    col += ptCol * exp(-wd * wd * 500.0) * intensity * depthFade * 0.04 * silence;
                }
            }
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
