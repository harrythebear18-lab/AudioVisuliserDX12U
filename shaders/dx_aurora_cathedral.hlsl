// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 42: Spectral Aurora Cathedral — volumetric aurora curtains
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_PSYCHOACOUSTIC.
//
// Optimized: direct curtain projection (no raymarch), no seEmitGlowDepth/VR,
// no seLinkLR, no softReinhard. Full audio brain data.
//
// Audio-to-visual mapping:
//   b0-b7       -> 8 aurora curtain positions and energy
//   beat        -> light pillars through stained glass
//   kick        -> stained glass illumination
//   transient   -> aurora ripple
//   envelope    -> curtain sway
//   stereoBal   -> camera orbit
//   stereoWid   -> curtain spread
//   stereoDiff  -> camera height
//   phaseCoh    -> L/R curtain symmetry
//   section     -> camera repositioning
//   phraseBeat  -> slow curtain breathing
//   speechMode  -> vocal curtain boost
//   calmMode    -> reduced turbulence
//   brightness  -> curtain glow
//   glow        -> ambient aurora glow
//   colorPulse  -> hue shift
//   beatAnt     -> anticipatory swell
//
// DSP: LUFS->brightness, crest->edge sharpness, THD->turbulence, phase->symmetry.
// HDR output to Layer 0. No local postfx.

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

        // Spread curtains across full width — band 0 at far left, band 7 at far right
        // with stereo balance offset and emitter-derived jitter
        curtains[band].xCenter = lerp(-3.0, 3.0, bt) + a.stereoBal * 0.5 + emit[idx].worldPos.x * 0.3;
        curtains[band].yBase = 0.0;
        curtains[band].yTop = lerp(3.0, 5.0, bt) + avgEnergy * 0.8;
        curtains[band].width = lerp(1.0, 0.4, bt) * (1.0 + a.stereoWid * 0.4);
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
        float FOV = 0.85;
        float camAng = a.section * 0.3 + a.stereoBal * 0.15 + Time * 0.02 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 1.5, 0.0 + a.stereoDiff * 0.1, cos(camAng) * 1.5);
        cam = seCamera(camPos, float3(0, 2.5, 0), FOV);
    }

    // ── Spatial encoder: PSYCHOACOUSTIC profile ──
    SeParams params = seParams(SE_PROFILE_PSYCHOACOUSTIC);
    params.widthScale = 3.0;
    params.heightScale = 2.5;
    params.depthScale = 2.0;
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
    col += starfield(uv, a) * 0.005;
    float nebula = fbm2_4(p * 0.5 + Time * 0.002 * a.motSpeed);
    col += a.brainCol * nebula * 0.004 * a.ambient * a.ambActive * silence;

    // ── Aurora curtains — direct projection (no raymarch) ──
    // Each curtain is a vertical sheet at a specific X position in world space.
    // Project curtain as a line from yBase to yTop at xCenter, sample at multiple heights.
    [unroll] for (int band = 0; band < SE_N_BANDS; band++) {
        if (curtains[band].gate < 0.01) continue;

        float bt = float(band) / float(SE_N_BANDS - 1);
        float3 curCol = curtains[band].color;
        curCol = lerp(curCol, curCol.bgr, a.colorPulse * 0.02);

        // Vocal band boost
        float vocalWeight = smoothstep(2.5, 3.5, float(band)) * (1.0 - smoothstep(5.0, 6.0, float(band)));
        float curEnergy = curtains[band].energy;
        curEnergy += a.speechMode * vocalWeight * 0.2;
        curEnergy += a.beatAnt * 0.15;
        curEnergy += a.glow * 0.04;
        curEnergy *= (0.7 + a.brightness * 0.3);
        curEnergy *= (1.0 - a.calmMode * 0.3);

        if (curEnergy < 0.02) continue;

        // Sample curtain at 8 heights — project each to screen
        [unroll] for (int yi = 0; yi < 8; yi++) {
            float yFrac = (float(yi) + 0.5) / 8.0;
            float worldY = lerp(curtains[band].yBase, curtains[band].yTop, yFrac);

            // Sway — envelope-driven horizontal displacement
            float sway = sin(worldY * 2.0 + Time * 1.5 * (0.5 + bt)) * envelope * 0.3;
            sway += cos(worldY * 3.5 + Time * 2.0) * bands[2] * 0.2;
            sway *= (1.0 - a.calmMode * 0.5);

            // THD turbulence
            float turb = fbm2_4(float2(worldY * 3.0 + Time * 0.5, curtains[band].xCenter * 2.0)) * thd * 0.15;
            turb *= (1.0 - a.calmMode * 0.5);

            float worldX = curtains[band].xCenter + sway + turb;
            float3 worldPos = float3(worldX, worldY, 0.0);

            float3 toPt = worldPos - cam.pos;
            float depth = dot(toPt, cam.fwd);
            if (depth < 0.1) continue;

            float sx = dot(toPt, cam.right) / (depth * cam.fov);
            float sy = dot(toPt, cam.up) / (depth * cam.fov);
            float2 scrPos = float2(sx, sy);

            float2 diff = p - scrPos;
            float dist2 = dot(diff, diff);

            // Curtain width narrows toward top
            float curW = curtains[band].width * (1.0 - yFrac * 0.3);
            curW /= max(depth * 0.3, 0.2);
            float curW2 = curW * curW;

            if (dist2 > curW2 * 6.0) continue;

            float depthFade = exp(-depth * 0.04);

            // Glow profile
            float glow = exp(-dist2 / (curW2 * 0.5));
            float core = exp(-dist2 / (curW2 * 0.15));

            // Y falloff — curtain fades at base and top
            float yFade = sin(yFrac * PI);

            // Shimmer at top — high band driven
            float shimmer = bands[7] * pow(yFrac, 3.0) * 0.3;

            // FBM texture on curtain
            float2 surfUV = float2(yFrac * 4.0, worldX * 2.0 + Time * 0.3);
            float texture = fbm2_4(surfUV);
            texture += transientAmt * fbm2_4(surfUV * 3.0 + Time * 5.0) * 0.3;
            texture = lerp(texture, 0.5, a.calmMode * 0.5);

            float intensity = curEnergy * yFade * (1.0 + lufs * 0.2);

            col += curCol * (glow * 0.2 + core * 0.3) * intensity * depthFade * silence;
            col += curCol * texture * glow * intensity * 0.08 * depthFade * silence;
            col += curCol * shimmer * core * intensity * 0.1 * depthFade * silence;

            // Beat pulse traveling up curtain
            float beatPos = a.beatPhase;
            float beatDist = abs(yFrac - beatPos);
            float beatWave = exp(-beatDist * beatDist * 20.0) * beatPulse;
            col += curCol * core * beatWave * intensity * 0.2 * depthFade * silence;

            // Crest sharpens edges
            col += curCol * core * crest * intensity * 0.05 * depthFade * silence;
        }
    }

    // ── Cathedral pillars — gothic arches at edges ──
    {
        float3 pillarPos = float3(3.0, 2.0, 0);
        float3 toPillar = pillarPos - cam.pos;
        float pillarDepth = dot(toPillar, cam.fwd);
        if (pillarDepth > 0.1) {
            float2 scrPillar = float2(dot(toPillar, cam.right) / (pillarDepth * cam.fov),
                                      dot(toPillar, cam.up) / (pillarDepth * cam.fov));
            float pillarDist = length(p - scrPillar);
            float pillarGlow = exp(-pillarDist * pillarDist * 10.0) * 0.02;
            col += a.brainCol3 * pillarGlow * silence;
        }
        // Mirror pillar
        float3 pillarPos2 = float3(-3.0, 2.0, 0);
        float3 toPillar2 = pillarPos2 - cam.pos;
        float pillarDepth2 = dot(toPillar2, cam.fwd);
        if (pillarDepth2 > 0.1) {
            float2 scrPillar2 = float2(dot(toPillar2, cam.right) / (pillarDepth2 * cam.fov),
                                       dot(toPillar2, cam.up) / (pillarDepth2 * cam.fov));
            float pillarDist2 = length(p - scrPillar2);
            float pillarGlow2 = exp(-pillarDist2 * pillarDist2 * 10.0) * 0.02;
            col += a.brainCol3 * pillarGlow2 * silence;
        }
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Beat — light pillars through stained glass ──
    col += a.brainCol * beatPulse * exp(-a.beatPhase * 4.0) * exp(-p.x * p.x * 2.0) * 0.06 * silence;

    // ── Kick — stained glass illumination ──
    col += a.brainCol3 * kickSurge * 0.05 * exp(-r * r * 3.0) * silence;

    // ── Transient — aurora ripple ──
    col += a.brainCol2 * transientAmt * 0.025 * sin(r * 20.0 - Time * 10.0) * silence;

    // ── Phrase breathing ──
    float phraseMod = sin(a.phraseBeat * PI * 2.0) * 0.02 + 0.02;
    col += a.brainCol * phraseMod * silence;

    // ── Beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;

    // ── Dynamic range ──
    col *= (0.5 + a.gated * 0.5);

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
