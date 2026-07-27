// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 42: Spectral Aurora Cathedral — volumetric aurora in gothic space
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_PSYCHOACOUSTIC.
//
// 48 emitters (8 bands × 3 sub × L/R) placed as psychoacoustic sources.
// Emitters drive aurora curtain positions — each band = one curtain.
// Bass = curtain base width, mids = curtain wave/sway, highs = curtain top shimmer.
// Beat = light pillars through stained glass. Kick = stained glass illumination.
// Transient = aurora ripple.
//
// World: grid floor as cathedral floor, fog density 0.05, dark ambient.
// Camera: looking up at aurora from cathedral floor, FOV 0.8 (VR: head pose from OpenXR).
// Visual: volumetric raymarched aurora curtains at emitter X positions, gothic pillars.
//
// DSP: LUFS→aurora brightness, crest→curtain edge sharpness, THD→atmospheric turbulence, phase→L/R symmetry.
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// ── Aurora curtain derived from emitters (one per band, using first sub L) ──
struct AuroraCurtain {
    float xCenter;
    float yBase;
    float yTop;
    float width;
    float energy;
    float gate;
    float3 color;
};

void computeCurtainsFromEmitters(out AuroraCurtain curtains[SE_N_BANDS], SeEmitter emit[SE_NUM_OBJ], AudioData a)
{
    [unroll] for (int band = 0; band < SE_N_BANDS; band++) {
        // Use first sub L emitter as representative for curtain position
        int idx = band * SE_N_SUB * 2;
        float bt = float(band) / float(SE_N_BANDS - 1);

        curtains[band].gate = emit[idx].active * step(0.05, emit[idx].intensity);
        if (curtains[band].gate < 0.01) {
            curtains[band].xCenter = 100.0;
            curtains[band].yBase = 0.5;
            curtains[band].yTop = 2.0;
            curtains[band].width = 0.5;
            curtains[band].energy = 0.0;
            curtains[band].color = float3(0, 0, 0);
            continue;
        }

        // Average energy across all subs for this band
        float avgEnergy = 0.0;
        [unroll] for (int sub = 0; sub < SE_N_SUB; sub++) {
            avgEnergy += emit[band * SE_N_SUB * 2 + sub * 2].intensity;
            avgEnergy += emit[band * SE_N_SUB * 2 + sub * 2 + 1].intensity;
        }
        avgEnergy /= float(SE_N_SUB * 2);

        curtains[band].xCenter = emit[idx].worldPos.x * 1.2;
        curtains[band].yBase = 0.5;
        curtains[band].yTop = lerp(2.0, 4.0, bt) + avgEnergy * 0.5;
        curtains[band].width = lerp(0.8, 0.3, bt) * (1.0 + a.stereoWid * 0.3);
        curtains[band].energy = avgEnergy;
        curtains[band].color = emit[idx].color;
    }
}

// Aurora curtain density at a 3D point
float auroraDensity(float3 p, AuroraCurtain curtains[SE_N_BANDS], float bands[8],
                    float envelope, float thd, float beatPulse, float silence)
{
    float density = 0.0;

    [unroll] for (int n = 0; n < SE_N_BANDS; n++) {
        if (curtains[n].gate < 0.01) continue;

        float xDist = p.x - curtains[n].xCenter;
        float yFrac = (p.y - curtains[n].yBase) / max(curtains[n].yTop - curtains[n].yBase, 0.1);

        if (yFrac < 0.0 || yFrac > 1.0) continue;

        float w = curtains[n].width * (1.0 - yFrac * 0.3);

        // Wave displacement — envelope-driven sway
        float bt = float(n) / float(SE_N_BANDS - 1);
        float sway = sin(p.y * 2.0 + Time * 1.5 * (0.5 + bt)) * envelope * 0.3;
        sway += cos(p.y * 3.5 + Time * 2.0) * bands[2] * 0.2;
        xDist += sway;

        // THD turbulence
        float turb = fbm2_4(float2(p.y * 3.0 + Time * 0.5, xDist * 2.0)) * thd * 0.15;
        xDist += turb;

        float xFalloff = exp(-xDist * xDist / (w * w));
        float yFalloff = sin(yFrac * PI);
        float shimmer = bands[7] * pow(yFrac, 3.0) * 0.3;

        density += (xFalloff * yFalloff * curtains[n].energy + shimmer * xFalloff) * 0.3;
    }

    density += beatPulse * 0.02 * exp(-p.y * 0.3) * silence;

    return density * silence;
}

float3 auroraColor(float3 p, AuroraCurtain curtains[SE_N_BANDS], AudioData a)
{
    float3 col = float3(0, 0, 0);
    float totalWeight = 0.0;

    [unroll] for (int n = 0; n < SE_N_BANDS; n++) {
        if (curtains[n].gate < 0.01) continue;
        float xDist = p.x - curtains[n].xCenter;
        float yFrac = (p.y - curtains[n].yBase) / max(curtains[n].yTop - curtains[n].yBase, 0.1);
        if (yFrac < 0.0 || yFrac > 1.0) continue;
        float w = curtains[n].width * (1.0 - yFrac * 0.3);
        float weight = exp(-xDist * xDist / (w * w)) * curtains[n].energy;
        col += curtains[n].color * weight;
        totalWeight += weight;
    }

    return totalWeight > 0.001 ? col / totalWeight : a.brainCol;
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

    // ── Camera — VR head pose or desktop looking up ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.8;
        float camAng = a.section * 0.3 + a.stereoBal * 0.15;
        float3 camPos = float3(sin(camAng) * 1.0, 0.0, cos(camAng) * 1.0);
        cam = seCamera(camPos, float3(0, 2.5, 0), FOV);
    }

    // ── Spatial encoder: PSYCHOACOUSTIC profile ──
    SeParams params = seParams(SE_PROFILE_PSYCHOACOUSTIC);
    params.widthScale = 3.0;
    params.heightScale = 2.5;
    params.depthScale = 2.0;
    params.jitterAmt = 0.15 + thd * 0.25;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.05, float3(0.01, 0.003, 0.015), 0.0, 0.0, 0.0);
    world.gridIntensity = 0.02;
    world.ambientLevel = 0.003;
    world.ambientColor = float3(0.015, 0.008, 0.02);
    seApplyWorldFog(emit, world);

    // ── Derive curtains from emitters ──
    AuroraCurtain curtains[SE_N_BANDS];
    computeCurtainsFromEmitters(curtains, emit, a);

    // ── Background — dark cathedral + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.003;

    // ── Volumetric raymarch through aurora ──
    float3 rd = normalize(cam.fwd + p.x * cam.right * cam.fov + p.y * cam.up * cam.fov);
    float t = 0.1;
    float3 accum = float3(0, 0, 0);
    float transmittance = 1.0;
    float stepSize = 0.1;

    [loop] for (int i = 0; i < 16; i++) {
        float3 sp = cam.pos + rd * t;
        if (sp.y > 5.0 || length(sp.xz) > 4.0) break;

        float density = auroraDensity(sp, curtains, bands, envelope, thd, beatPulse, silence);
        density *= smoothstep(0.002, 0.02, density);

        if (density > 0.003) {
            float3 pointCol = auroraColor(sp, curtains, a);
            pointCol *= density * (0.3 + envelope * 0.2) * (1.0 + lufs * 0.15);

            float sigma = density * 0.15 + 0.005;
            transmittance *= exp(-sigma * stepSize);
            accum += pointCol * transmittance * stepSize * 1.0;
        }
        t += stepSize;
    }

    col += accum * silence;

    // ── Cathedral pillars — gothic arches at edges ──
    {
        float3 pillarPos = float3(3.0, 2.0, 0);
        float3 toPillar = pillarPos - cam.pos;
        float pillarDepth = dot(toPillar, cam.fwd);
        if (pillarDepth > 0.1) {
            float2 scrPillar = float2(dot(toPillar, cam.right) / (pillarDepth * cam.fov),
                                      dot(toPillar, cam.up) / (pillarDepth * cam.fov));
            float pillarDist = length(p - scrPillar);
            float pillarGlow = exp(-pillarDist * pillarDist * 10.0) * 0.015;
            col += a.brainCol3 * pillarGlow * silence;
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

    // ── Beat — light pillars through stained glass ──
    col += a.brainCol * beatPulse * exp(-a.beatPhase * 4.0) * exp(-p.x * p.x * 2.0) * 0.06 * silence;

    // ── Kick — stained glass illumination ──
    col += a.brainCol3 * kickSurge * 0.05 * exp(-r * r * 3.0) * silence;

    // ── Transient — aurora ripple ──
    col += a.brainCol2 * transientAmt * 0.025 * sin(r * 20.0 - Time * 10.0) * silence;

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
