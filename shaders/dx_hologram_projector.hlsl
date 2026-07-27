// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 40: Acoustic Hologram Projector — sci-fi volumetric hologram table
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_WAVE_FIELD.
//
// 48 emitters (8 bands × 3 sub × L/R) placed as wave field sources.
// A glowing pedestal projects a 3D frequency surface that morphs with audio.
// Bass = base geometry shape, mids = surface displacement/waves,
// highs = particle details/sparkles above surface.
// Beat = hologram pulse ring. Kick = geometry spike.
// Transient = glitch/scan distortion.
//
// World: grid floor as pedestal, fog density 0.06, dark ambient.
// Camera: orbit around hologram table, FOV 0.6 (VR: head pose from OpenXR).
// Visual: projected grid points with height from emitter-driven wave field + wireframe.
//
// DSP: LUFS→hologram opacity, crest→edge sharpness, THD→scan line jitter, phase→L/R symmetry.
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define GRID_RES 6

// ── Hologram heightfield — driven by emitter positions ──
float hologramHeight(float2 xz, SeEmitter emit[SE_NUM_OBJ],
                     float beatPulse, float beatPhase, float transientAmt, float envelope,
                     float kickSurge, float thd, float silence)
{
    float r = length(xz);
    if (r > 2.0) return -1.0;

    float h = 0.0;

    // Per-emitter wave contributions
    [loop] for (int n = 0; n < SE_NUM_OBJ; n++) {
        if (emit[n].active < 0.01) continue;
        if (emit[n].intensity < 0.05) continue;

        float2 srcPos = emit[n].worldPos.xz;
        float d = length(xz - srcPos);
        float bandFrac = float(emit[n].bandIdx) / 7.0;

        // Bass = long wavelength dome, highs = fine ripples
        float wavelength = lerp(3.0, 0.3, bandFrac);
        float amp = emit[n].intensity * lerp(0.15, 0.03, bandFrac);

        h += amp * sin(d * (2.0 * PI / wavelength) - Time * (1.0 + bandFrac * 3.0));
    }

    // Beat — radial pulse
    h += beatPulse * 0.08 * sin(r * 5.0 - beatPhase * 6.0) * exp(-r * 0.5) * silence;

    // Kick — central spike
    h += kickSurge * 0.15 * exp(-r * r * 4.0) * silence;

    // Transient — glitch displacement
    if (transientAmt > 0.02)
        h += transientAmt * 0.04 * sin(xz.x * 30.0 + xz.y * 28.0 + beatPhase * 40.0) * silence;

    // Envelope — global swell
    h += envelope * 0.03 * smoothstep(2.0, 0.0, r) * silence;

    // THD — scan line jitter
    h += thd * 0.015 * sin(xz.y * 80.0 + Time * 20.0) * silence;

    return h;
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

    // ── Camera — VR head pose or desktop orbit ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.6;
        float camAng = a.section * 0.8 + a.stereoBal * 0.2;
        float3 camPos = float3(sin(camAng) * 3.0, 2.0, cos(camAng) * 3.0);
        cam = seCamera(camPos, float3(0, 0.5, 0), FOV);
    }

    // ── Spatial encoder: WAVE_FIELD profile ──
    SeParams params = seParams(SE_PROFILE_WAVE_FIELD);
    params.widthScale = 2.5;
    params.heightScale = 1.5;
    params.depthScale = 2.5;
    params.jitterAmt = 0.15 + thd * 0.25;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.06, float3(0.01, 0.008, 0.02), -1.0, 0.0, 0.0);
    world.gridIntensity = 0.03;
    world.ambientLevel = 0.004;
    world.ambientColor = float3(0.02, 0.02, 0.04);
    seApplyWorldFog(emit, world);

    // ── Background — dark tech room + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.005;

    // ── Pedestal — glowing base disc ──
    {
        float3 toPed = float3(0, 0, 0) - cam.pos;
        float pedDepth = dot(toPed, cam.fwd);
        if (pedDepth > 0.1) {
            float2 scrPed = float2(dot(toPed, cam.right) / (pedDepth * cam.fov),
                                   dot(toPed, cam.up) / (pedDepth * cam.fov));
            float pedR = 2.2 / (pedDepth * cam.fov);
            float pedDist = length(p - scrPed);
            float edgeDist = abs(pedDist - pedR);
            col += a.brainCol * exp(-edgeDist * edgeDist * 30.0) * 0.12 * (0.5 + envelope * 0.5) * silence;
            float ringPattern = sin(pedDist * 20.0 - Time * 2.0) * 0.5 + 0.5;
            col += a.brainCol2 * ringPattern * exp(-pedDist * pedDist / (pedR * pedR)) * 0.015 * silence;
        }
    }

    // ── Hologram surface — grid of projected points ──
    [loop] for (int gx = 0; gx <= GRID_RES; gx++) {
        [loop] for (int gz = 0; gz <= GRID_RES; gz++) {
            float2 gridUV = float2(float(gx), float(gz)) / float(GRID_RES);
            float2 xz = (gridUV - 0.5) * 4.0;

            float h = hologramHeight(xz, emit, beatPulse, a.beatPhase, transientAmt, envelope, kickSurge, thd, silence);
            if (h < -0.5) continue;

            float3 hp = float3(xz.x, h + 0.5, xz.y);
            float3 toHP = hp - cam.pos;
            float hpDepth = dot(toHP, cam.fwd);
            if (hpDepth < 0.1) continue;
            float2 scrHP = float2(dot(toHP, cam.right) / (hpDepth * cam.fov),
                                  dot(toHP, cam.up) / (hpDepth * cam.fov));
            float scrDist = length(p - scrHP);

            float freqFrac = length(xz) / 2.0;
            float3 holoCol = hsv(a.hueBase + freqFrac * a.hueRange, 0.6 * a.satur, 0.9);
            holoCol = lerp(holoCol, lerp(a.brainCol, a.brainCol2, freqFrac), 0.3);

            float ptSize = 0.008 / max(hpDepth * 0.15, 0.3) * 3.0;
            float ptGlow = exp(-scrDist * scrDist / (ptSize * ptSize));

            float intensity = (abs(h) * 3.0 + 0.1) * (1.0 + lufs * 0.2);
            float depthFade = exp(-hpDepth * world.fogDensity);

            // Scan line effect — THD
            float scanLine = sin(hp.y * 50.0 + Time * 10.0) * 0.5 + 0.5;
            scanLine = lerp(1.0, scanLine, thd * 0.3);

            col += holoCol * ptGlow * intensity * depthFade * scanLine * 0.15 * silence;

            // Wireframe connections to neighbors
            if (gx < GRID_RES) {
                float2 xz2 = float2(float(gx + 1), float(gz)) / float(GRID_RES);
                xz2 = (xz2 - 0.5) * 4.0;
                float h2 = hologramHeight(xz2, emit, beatPulse, a.beatPhase, transientAmt, envelope, kickSurge, thd, silence);
                if (h2 > -0.5) {
                    float3 hp2 = float3(xz2.x, h2 + 0.5, xz2.y);
                    float3 toHP2 = hp2 - cam.pos;
                    float hp2Depth = dot(toHP2, cam.fwd);
                    if (hp2Depth > 0.1) {
                        float2 scrHP2 = float2(dot(toHP2, cam.right) / (hp2Depth * cam.fov),
                                              dot(toHP2, cam.up) / (hp2Depth * cam.fov));
                        float2 ab = scrHP2 - scrHP;
                        float t = clamp(dot(p - scrHP, ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
                        float2 closest = scrHP + ab * t;
                        float wireDist = length(p - closest);
                        float wireGlow = exp(-wireDist * wireDist * 200.0);
                        col += holoCol * wireGlow * intensity * depthFade * 0.03 * silence;
                    }
                }
            }
            if (gz < GRID_RES) {
                float2 xz2 = float2(float(gx), float(gz + 1)) / float(GRID_RES);
                xz2 = (xz2 - 0.5) * 4.0;
                float h2 = hologramHeight(xz2, emit, beatPulse, a.beatPhase, transientAmt, envelope, kickSurge, thd, silence);
                if (h2 > -0.5) {
                    float3 hp2 = float3(xz2.x, h2 + 0.5, xz2.y);
                    float3 toHP2 = hp2 - cam.pos;
                    float hp2Depth = dot(toHP2, cam.fwd);
                    if (hp2Depth > 0.1) {
                        float2 scrHP2 = float2(dot(toHP2, cam.right) / (hp2Depth * cam.fov),
                                              dot(toHP2, cam.up) / (hp2Depth * cam.fov));
                        float2 ab = scrHP2 - scrHP;
                        float t = clamp(dot(p - scrHP, ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
                        float2 closest = scrHP + ab * t;
                        float wireDist = length(p - closest);
                        float wireGlow = exp(-wireDist * wireDist * 200.0);
                        col += holoCol * wireGlow * intensity * depthFade * 0.03 * silence;
                    }
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

    // ── High-band sparkles above surface ──
    float sparkle = (a.b6 + a.b7) * hash21(p * 80.0 + Time * 30.0) * 0.025;
    col += float3(0.8, 0.9, 1.0) * sparkle * silence;

    // ── Transient — glitch scan ──
    if (transientAmt > 0.02) {
        float glitch = sin(p.y * 100.0 + Time * 50.0) * transientAmt * 0.025;
        col += a.brainCol2 * abs(glitch) * silence;
    }

    // ── Mode-specific overlays — subtle ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;
    col += a.brainCol3 * kickSurge * 0.04 * exp(-r * r * 5.0) * silence;
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
