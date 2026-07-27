// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 33: Fluid Dynamics — SDF heightfield liquid with curl-noise advection
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_PSYCHOACOUSTIC.
//
// 48 emitters (8 bands × 3 sub × L/R) placed psychoacoustically around listener.
// Dark reflective liquid surface with audio-driven wave sources at emitter positions.
// Bass = large swells/tidal waves, mids = vortex ripples, highs = capillary turbulence.
// Beat = pressure wave ring. Kick = central eruption. Transient = surface disruption.
//
// World: grid floor for depth grounding, fog density 0.06, dark ambient.
// Camera: inside fluid volume, FOV 0.65 (VR: head pose from OpenXR).
// Visual: SDF raymarched liquid surface with specular shading + subsurface glow.
//
// DSP: LUFS→surface level, crest→wave sharpness, THD→roughness, phase→symmetry.
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define MARCH_STEPS 48

// ── Fluid heightfield — wave sources from emitter positions ──
float fluidHeight(float2 xz, SeEmitter emit[SE_NUM_OBJ], float poolR,
                  float beatPulse, float beatPhase, float transientAmt, float envelope,
                  float kickSurge, float lufs, float thd, float silence)
{
    float r = length(xz);
    if (r > poolR) return -1.0;

    // Base surface — LUFS additive
    float surface = (0.02 + lufs * 0.02) * silence;

    // Envelope breathing
    surface += envelope * 0.015 * sin(beatPhase * PI * 2.0) * silence;

    // Per-emitter radial ripples — only active emitters
    [loop] for (int n = 0; n < SE_NUM_OBJ; n++) {
        if (emit[n].active < 0.01) continue;
        if (emit[n].intensity < 0.05) continue;

        float2 srcPos = emit[n].worldPos.xz;
        float d = length(xz - srcPos);

        // Wavelength: bass = long, highs = short
        float bandFrac = float(emit[n].bandIdx) / 7.0;
        float wavelength = lerp(3.0, 0.4, bandFrac);
        float sharpness = lerp(15.0, 40.0, bandFrac);

        float wave = emit[n].intensity * exp(-d * d * sharpness * 0.01);
        wave *= sin(d * (2.0 * PI / wavelength) - Time * 3.0 * (1.0 + bandFrac));
        surface += wave * 0.15;
    }

    // Curl noise advection — bass-driven large-scale flow
    float2 flowUV = xz * 0.5 + float2(Time * 0.2, Time * 0.15);
    float2 flow = curlN(float3(flowUV, 0)).xy;
    surface += (flow.x + flow.y) * 0.03 * silence;

    // FBM turbulence — mids + highs
    float2 turbUV = xz * 2.0 + float2(Time * 0.5, Time * 0.3);
    surface += fbm2_4(turbUV) * 0.04 * silence * (1.0 + thd * 0.5);

    // Beat ripple rings
    float ringPhase = beatPhase * PI * 2.0;
    surface += beatPulse * 0.04 * sin(r * 6.0 - ringPhase * 3.0) * smoothstep(poolR, 0.0, r) * silence;

    // Kick — central eruption
    surface += kickSurge * 0.08 * exp(-r * r * 3.0) * silence;

    // Transient — surface jitter
    if (transientAmt > 0.02)
        surface += transientAmt * 0.025 * sin(xz.x * 25.0 + xz.y * 22.0 + beatPhase * 30.0) * smoothstep(poolR, 0.0, r) * silence;

    // Pool edge — curve down
    surface -= smoothstep(poolR * 0.6, poolR, r) * 0.2;

    return surface;
}

float fluidSDF(float3 p, SeEmitter emit[SE_NUM_OBJ], float poolR,
               float beatPulse, float beatPhase, float transientAmt, float envelope,
               float kickSurge, float lufs, float thd, float silence)
{
    float h = fluidHeight(p.xz, emit, poolR, beatPulse, beatPhase, transientAmt, envelope,
                          kickSurge, lufs, thd, silence);
    return p.y - h;
}

float3 fluidNormal(float3 p, SeEmitter emit[SE_NUM_OBJ], float poolR,
                   float beatPulse, float beatPhase, float transientAmt, float envelope,
                   float kickSurge, float lufs, float thd, float silence)
{
    float eps = 0.008;
    return normalize(float3(
        fluidSDF(p + float3(eps, 0, 0), emit, poolR, beatPulse, beatPhase, transientAmt, envelope, kickSurge, lufs, thd, silence)
          - fluidSDF(p - float3(eps, 0, 0), emit, poolR, beatPulse, beatPhase, transientAmt, envelope, kickSurge, lufs, thd, silence),
        2.0 * eps,
        fluidSDF(p + float3(0, 0, eps), emit, poolR, beatPulse, beatPhase, transientAmt, envelope, kickSurge, lufs, thd, silence)
          - fluidSDF(p - float3(0, 0, eps), emit, poolR, beatPulse, beatPhase, transientAmt, envelope, kickSurge, lufs, thd, silence)
    ));
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
        float3 camPos = float3(sin(camAng) * 3.5, 2.3, cos(camAng) * 3.5);
        cam = seCamera(camPos, float3(0.0, 0.15, 0.0), FOV);
    }

    // ── Spatial encoder: PSYCHOACOUSTIC profile ──
    SeParams params = seParams(SE_PROFILE_PSYCHOACOUSTIC);
    params.widthScale = 3.0;
    params.heightScale = 2.0;
    params.depthScale = 2.5;
    params.jitterAmt = 0.2 + thd * 0.3;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.06, float3(0.01, 0.005, 0.02), -1.5, 0.0, 0.0);
    world.gridIntensity = 0.025;
    world.ambientLevel = 0.003;
    world.ambientColor = float3(0.02, 0.015, 0.05);
    seApplyWorldFog(emit, world);

    float poolR = 3.6 + lufs * 0.08;

    // ── Background — world environment + starfield ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.005;

    // ── Raymarch to fluid surface ──
    float3 rd = normalize(cam.fwd + p.x * cam.right * cam.fov + p.y * cam.up * cam.fov);
    float t = 0.05;
    float marchGlow = 0.0;
    bool hit = false;

    [loop] for (int i = 0; i < MARCH_STEPS; i++) {
        float3 sp = cam.pos + rd * t;
        float d = fluidSDF(sp, emit, poolR, beatPulse, a.beatPhase, transientAmt, envelope,
                           kickSurge, lufs, thd, silence);
        marchGlow += 0.008 / (1.0 + d * d * 50.0);
        if (d < 0.003) { hit = true; break; }
        t += d * 0.5;
        if (t > 5.0) break;
    }

    if (hit) {
        float3 hp = cam.pos + rd * t;
        float3 n = fluidNormal(hp, emit, poolR, beatPulse, a.beatPhase, transientAmt, envelope,
                               kickSurge, lufs, thd, silence);
        float3 vDir = normalize(cam.pos - hp);

        // ── Liquid shading — dark glossy with colored dye ──
        float fres = pow(1.0 - max(dot(n, vDir), 0.0), 5.0);

        float3 lDir = normalize(float3(0.4, 0.8, 0.5));
        float3 lDir2 = normalize(float3(-0.5 + a.stereoBal * 0.3, 0.6, 0.3));
        float diff = max(dot(n, lDir), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
        float spec = pow(max(dot(reflect(-lDir, n), vDir), 0.0), 80.0);
        float spec2 = pow(max(dot(reflect(-lDir2, n), vDir), 0.0), 60.0) * 0.5;

        float heightFrac = clamp(hp.y * 1.5, 0.0, 1.0);

        float3 darkFluid = float3(0.02, 0.015, 0.04);
        float3 dyeCol = lerp(a.brainCol, a.brainCol2, heightFrac);
        dyeCol = lerp(dyeCol, hsv(a.hueBase + heightFrac * a.hueRange, 0.6 * a.satur, 0.9), 0.3);
        float3 hotPeak = lerp(dyeCol, a.brainCol3, pow(heightFrac, 3.0) * 0.5);

        float3 baseCol = lerp(darkFluid, hotPeak, smoothstep(0.02, 0.3, hp.y));
        baseCol = lerp(baseCol, dyeCol, 0.2);
        baseCol = lerp(baseCol, baseCol.gbr, phaseCoh * 0.03);

        float3 litCol = baseCol * (diff + diff2) * (0.2 + a.brightness * 0.2 + a.dynamic * 0.15);
        litCol += float3(0.9, 0.85, 0.8) * (spec + spec2) * (0.3 + a.dynLight * 0.4);
        litCol += lerp(baseCol, hotPeak, 0.5) * fres * (0.25 + envelope * 0.25 + a.glow * 0.15);

        // Wave peak glow — emissive
        float peakGlow = smoothstep(0.1, 0.5, hp.y);
        litCol += hotPeak * peakGlow * (0.05 + envelope * 0.2) * silence;
        litCol += float3(1.0, 0.4, 0.08) * kickSurge * peakGlow * 0.2 * silence;
        if (transientAmt > 0.02)
            litCol += float3(1.0, 0.85, 0.6) * transientAmt * peakGlow * 0.1 * silence;
        litCol += hotPeak * beatPulse * peakGlow * 0.04 * silence;
        litCol += a.brainCol3 * a.colorPulse * peakGlow * 0.015 * silence;
        litCol *= (0.5 + a.dynamic * 0.3);
        litCol += hotPeak * a.punch * peakGlow * 0.03 * silence;

        // Depth fog on liquid surface
        float depthFog = exp(-t * world.fogDensity);
        litCol *= depthFog;

        col = blendScreen(col, litCol);
    }

    // ── Subsurface glow ──
    col += a.brainCol * marchGlow * (0.015 + a.glow * 0.02) * (0.5 + envelope * 0.5) * silence;

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

    // ── Mode-specific overlays — subtle, distributed ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;
    col += float3(1.0, 0.5, 0.1) * kickSurge * 0.04 * exp(-r * r * 5.0) * silence;
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.02 * silence;
    col += a.brainCol3 * a.colorPulse * 0.015 * silence;
    col += a.brainCol2 * a.energy * 0.01 * silence;
    col += a.brainCol * a.punch * 0.01 * silence;
    col += a.brainCol * a.beatAnt * 0.008 * exp(-r * 2.0) * silence;

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays (sparing) ──
    col += standardOverlays(p, r, a) * 0.02;

        // ── Active-emitter normalization — busy music doesn't stack brighter ──
    col *= sqrt(16.0 / seActiveCount(emit));
    // ── Soft tone mapping (Reinhard) — no hard clamp, preserves color ──
    col = softReinhard(col);

    col *= silence;

    return float4(col, 1.0);
}
