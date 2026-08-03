// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 40: Acoustic Hologram Projector — sci-fi volumetric hologram table
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_WAVE_FIELD.
//
// Optimized: analytic heightfield (no emitter loop), 5x5 grid, no seRenderWorld,
// no seEmitGlowDepth/VR, no seLinkLR, no softReinhard.
//
// Audio-to-visual mapping:
//   b0-b7       -> 8 band wave contributions on hologram surface
//   beat        -> radial pulse ring on surface
//   kick        -> central spike
//   transient   -> glitch/scan distortion
//   envelope    -> global surface swell
//   stereoBal   -> camera orbit
//   stereoWid   -> surface spread
//   stereoDiff  -> camera height
//   phaseCoh    -> L/R surface symmetry
//   section     -> camera repositioning
//   phraseBeat  -> slow breathing
//   speechMode  -> vocal band wave boost
//   calmMode    -> reduced distortion
//   brightness  -> hologram opacity
//   glow        -> ambient glow
//   colorPulse  -> hue shift
//   beatAnt     -> anticipatory swell
//
// DSP: LUFS->opacity, crest->edge sharpness, THD->scan jitter, phase->symmetry.
// HDR output to Layer 0. No local postfx.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define GRID_RES 5

// ── Hologram heightfield — analytic, no emitter loop ──
float hologramHeight(float2 xz, float b0, float b1, float b2, float b3,
                     float b4, float b5, float b6, float b7,
                     float beatPulse, float beatPhase, float transientAmt, float envelope,
                     float kickSurge, float thd, float silence, float calmMode,
                     float beatAnt, float speechMode)
{
    float r = length(xz);
    if (r > 2.0) return -1.0;

    float h = 0.0;

    // 8 band wave contributions — analytic, no loop
    // Bass = long wavelength dome, highs = fine ripples
    float2 dir0 = normalize(float2(1.0, 0.0));
    float2 dir1 = normalize(float2(0.7, 0.7));
    float2 dir2 = normalize(float2(0.0, 1.0));
    float2 dir3 = normalize(float2(-0.7, 0.7));
    float2 dir4 = normalize(float2(-1.0, 0.0));
    float2 dir5 = normalize(float2(-0.7, -0.7));
    float2 dir6 = normalize(float2(0.0, -1.0));
    float2 dir7 = normalize(float2(0.7, -0.7));

    h += b0 * 0.15 * sin(dot(xz, dir0) * 2.0 - Time * 1.0);
    h += b1 * 0.12 * sin(dot(xz, dir1) * 3.0 - Time * 1.5);
    h += b2 * 0.10 * sin(dot(xz, dir2) * 4.0 - Time * 2.0);
    h += b3 * 0.08 * sin(dot(xz, dir3) * 5.0 - Time * 2.5);
    // Vocal band boost
    float vocalBoost = 1.0 + speechMode * 0.5;
    h += b4 * 0.06 * sin(dot(xz, dir4) * 7.0 - Time * 3.0) * vocalBoost;
    h += b5 * 0.05 * sin(dot(xz, dir5) * 9.0 - Time * 3.5) * vocalBoost;
    h += b6 * 0.03 * sin(dot(xz, dir6) * 12.0 - Time * 4.0);
    h += b7 * 0.02 * sin(dot(xz, dir7) * 16.0 - Time * 5.0);

    // Beat — radial pulse
    h += beatPulse * 0.08 * sin(r * 5.0 - beatPhase * 6.0) * exp(-r * 0.5) * silence;

    // Kick — central spike
    h += kickSurge * 0.15 * exp(-r * r * 4.0) * silence;

    // Transient — glitch displacement
    if (transientAmt > 0.02)
        h += transientAmt * 0.04 * sin(xz.x * 30.0 + xz.y * 28.0 + beatPhase * 40.0) * silence * (1.0 - calmMode * 0.5);

    // Envelope — global swell
    h += envelope * 0.03 * smoothstep(2.0, 0.0, r) * silence;

    // Beat anticipation
    h += beatAnt * 0.04 * smoothstep(2.0, 0.0, r) * silence;

    // THD — scan line jitter
    h += thd * 0.015 * sin(xz.y * 80.0 + Time * 20.0) * silence * (1.0 - calmMode * 0.5);

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
        float FOV = 0.65;
        float camAng = a.section * 0.8 + a.stereoBal * 0.2 + Time * 0.03 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 3.0, 2.0 + a.stereoDiff * 0.15, cos(camAng) * 3.0);
        cam = seCamera(camPos, float3(0, 0.5, 0), FOV);
    }

    // ── Spatial encoder: WAVE_FIELD profile ──
    SeParams params = seParams(SE_PROFILE_WAVE_FIELD);
    params.widthScale = 2.5;
    params.heightScale = 1.5;
    params.depthScale = 2.5;
    params.jitterAmt = 0.15 + thd * 0.25;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;
    params.motionSpeed = 0.8 * (1.0 - a.calmMode * 0.3);

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

            float h = hologramHeight(xz, a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7,
                                     beatPulse, a.beatPhase, transientAmt, envelope, kickSurge, thd, silence,
                                     a.calmMode, a.beatAnt, a.speechMode);
            if (h < -0.5) continue;

            float3 hp = float3(xz.x, h + 0.5, xz.y);
            float3 toHP = hp - cam.pos;
            float hpDepth = dot(toHP, cam.fwd);
            if (hpDepth < 0.1) continue;
            float2 scrHP = float2(dot(toHP, cam.right) / (hpDepth * cam.fov),
                                  dot(toHP, cam.up) / (hpDepth * cam.fov));
            float scrDist = length(p - scrHP);

            float freqFrac = length(xz) / 2.0;
            float3 holoCol = lerp(a.brainCol, a.brainCol2, freqFrac);
            holoCol = lerp(holoCol, a.brainCol3, freqFrac * 0.3);
            holoCol = lerp(holoCol, holoCol.bgr, a.colorPulse * 0.02);

            float ptSize = 0.012 / max(hpDepth * 0.15, 0.3) * 3.0;
            float ptGlow = exp(-scrDist * scrDist / (ptSize * ptSize));
            float ptCore = exp(-scrDist * scrDist / (ptSize * ptSize * 0.2));

            // Intensity driven by actual band energy at this grid point
            float gridR = length(xz);
            float bandWeight = lerp(a.b0, a.b7, freqFrac);
            bandWeight += a.glow * 0.05;
            bandWeight += a.beatAnt * 0.15;
            bandWeight *= (0.7 + a.brightness * 0.3);
            bandWeight *= (1.0 - a.calmMode * 0.3);
            float intensity = (abs(h) * 5.0 + 0.3 + bandWeight * 1.5) * (1.0 + lufs * 0.3);
            float depthFade = exp(-hpDepth * world.fogDensity);

            // Scan line effect — THD
            float scanLine = sin(hp.y * 50.0 + Time * 10.0) * 0.5 + 0.5;
            scanLine = lerp(1.0, scanLine, thd * 0.3);

            col += holoCol * (ptGlow * 0.3 + ptCore * 0.4) * intensity * depthFade * scanLine * silence;

            // Beat pulse on surface
            float beatDist = abs(gridR - a.beatPhase * 1.5);
            float beatWave = exp(-beatDist * beatDist * 10.0) * beatPulse;
            col += holoCol * ptCore * beatWave * intensity * 0.3 * depthFade * silence;

            // Wireframe connections to neighbors
            if (gx < GRID_RES) {
                float2 xz2 = float2(float(gx + 1), float(gz)) / float(GRID_RES);
                xz2 = (xz2 - 0.5) * 4.0;
                float h2 = hologramHeight(xz2, a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7,
                                         beatPulse, a.beatPhase, transientAmt, envelope, kickSurge, thd, silence,
                                         a.calmMode, a.beatAnt, a.speechMode);
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
                        col += holoCol * wireGlow * intensity * depthFade * 0.08 * silence;
                    }
                }
            }
            if (gz < GRID_RES) {
                float2 xz2 = float2(float(gx), float(gz + 1)) / float(GRID_RES);
                xz2 = (xz2 - 0.5) * 4.0;
                float h2 = hologramHeight(xz2, a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7,
                                         beatPulse, a.beatPhase, transientAmt, envelope, kickSurge, thd, silence,
                                         a.calmMode, a.beatAnt, a.speechMode);
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
                        col += holoCol * wireGlow * intensity * depthFade * 0.08 * silence;
                    }
                }
            }
        }
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

    // ── Beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;

    // ── Kick flash ──
    col += float3(0.8, 0.4, 0.1) * kickSurge * 0.04 * exp(-r * r * 5.0) * silence;

    // ── Phrase breathing ──
    float phraseMod = sin(a.phraseBeat * PI * 2.0) * 0.02 + 0.02;
    col += a.brainCol * phraseMod * silence;

    // ── Dynamic range ──
    col *= (0.6 + a.gated * 0.4);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.015;

    // ── Active-emitter normalization ──
    col *= sqrt(16.0 / seActiveCount(emit));

    // ── HDR limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
