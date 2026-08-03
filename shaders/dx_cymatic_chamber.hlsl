// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 45: Cymatic Resonance Chamber — procedurally generated Chladni patterns
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_PSYCHOACOUSTIC.
//
// Concept: A vibrating plate where Chladni nodal patterns form procedurally.
// All 8 band values superimpose as different vibration modes — the pattern
// shape itself is generated from the audio, not just brightness modulation.
// DSP data (LUFS, crest, THD, phase) shapes pattern deformation.
// Spatial encoder provides per-band color and spatial modulation.
// Beat = standing wave pulse. Kick = impact ripple. Transient = pattern scatter.
// Brain band values are the primary driver — silent bands = no pattern.
//
// No seEmitGlowDepth/VR, no seLinkLR, no softReinhard. Full audio brain.
// HDR output to Layer 0. No local postfx.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// Procedural Chladni pattern — superposition of vibration modes
// Each band contributes a mode with frequency proportional to band index.
// Band energy controls amplitude, frequency shift, and plate warping.
// No normalization — raw sum means more active bands = brighter pattern.
float proceduralChladni(float2 uv, float bands[8], float time,
                        float crest, float thd, float phaseCoh,
                        float beatPulse, float beatPhase,
                        float kickSurge, float transientAmt,
                        float envelope, float lufs)
{
    float total = 0.0;

    [unroll] for (int i = 0; i < 8; i++) {
        float bandVal = bands[i];
        if (bandVal < 0.01) continue;

        // Each band = a different (n,m) vibration mode
        // Band energy shifts frequency — active bands vibrate faster
        float n = float(i + 2) + bandVal * 0.8;
        float m = float(i + 2) * 0.7 + 1.0 + bandVal * 0.5;

        // Phase evolves with time + beat, each band at different speed
        float phase = time * (0.3 + float(i) * 0.1) + beatPhase * float(i) * 0.5;
        // Envelope adds breathing to phase
        phase += envelope * float(i) * 0.3;

        // Band-driven plate warping — each band displaces the plate differently
        float2 warpedUV = uv;
        warpedUV.x += sin(uv.y * 3.0 + time * 2.0 + float(i)) * bandVal * 0.15;
        warpedUV.y += cos(uv.x * 3.0 + time * 1.5 + float(i) * 2.0) * bandVal * 0.12;

        // Kick compression — squeezes plate inward
        float kickWarp = kickSurge * 0.1 * (1.0 - bandVal);
        warpedUV *= (1.0 - kickWarp);

        // Transient scatter — sharp displacement spikes
        warpedUV += float2(sin(uv.x * 20.0 + time * 15.0), cos(uv.y * 18.0 + time * 12.0)) * transientAmt * 0.05;

        // Chladni nodal pattern for this mode
        float x = warpedUV.x * PI * n;
        float y = warpedUV.y * PI * m;
        float mode = sin(n * x + phase) * sin(m * y) - sin(m * x) * sin(n * y + phase);
        mode = abs(mode);

        // Nodal lines — particles collect where mode ≈ 0
        // Band energy makes nodal lines sharper (higher energy = more defined)
        float nodal = exp(-mode * mode * (2.0 + crest * 2.0 + bandVal * 2.0));

        // THD adds noise to pattern
        nodal *= (1.0 - thd * 0.25 * sin(uv.x * 30.0 + time * 10.0 + float(i)) * vrFlickerScale());

        // Phase coherence sharpens patterns
        nodal *= (0.6 + phaseCoh * 0.4);

        // LUFS boosts overall pattern strength
        nodal *= (1.0 + lufs * 0.3);

        // Raw sum — no normalization, more active bands = brighter
        total += nodal * bandVal * 2.0;
    }

    return total;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    // VR parallax — shift screen coords per eye for fake stereo depth
    p += vrParallax(1.5);  // plate at ~1.5 units depth
    float r = length(p);
    float silence = 1.0 - a.isSilent;
    float flashScale = vrFlashScale();
    float flickerScale = vrFlickerScale();

    // ── DSP additive ──
    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();

    // ── Audio dynamics ──
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — VR head pose or desktop ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.85;
        float camAng = a.section * 0.3 + a.stereoBal * 0.15 + Time * vrMotionScale(0.02) * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 2.0, 0.5 + a.stereoDiff * 0.05, 4.0);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
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

    // ── Spatial encoder color per band ──
    float3 emitCol[8];
    float spatialMod[8];
    [unroll] for (int bi = 0; bi < 8; bi++) {
        int n = bi * SE_N_SUB * 2;
        emitCol[bi] = (emit[n].active > 0.01) ? emit[n].color : a.brainCol;
        spatialMod[bi] = (emit[n].active > 0.01) ? (emit[n].intensity + 0.5) : 1.0;
    }

    // ── Background — dark resonance chamber + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.003;

    // ── Procedural Chladni pattern on vibrating plate ──
    // Map screen position to plate coordinates
    float2 plateUV = p * 2.0;  // scale to plate

    // Plate rotation — slow drift with stereo balance
    float plateRot = Time * 0.05 * a.motSpeed + a.stereoBal * 0.2;
    float ca = cos(plateRot), sa = sin(plateRot);
    float2 plateP = float2(plateUV.x * ca - plateUV.y * sa,
                           plateUV.x * sa + plateUV.y * ca);

    // Procedural pattern — all 8 bands superimposed (raw sum, no normalization)
    float pattern = proceduralChladni(plateP, bands, Time, crest, thd, phaseCoh,
                                      beatPulse, a.beatPhase,
                                      kickSurge, transientAmt,
                                      envelope, lufs);

    // Overall intensity from total band energy
    float totalBand = (bands[0] + bands[1] + bands[2] + bands[3] +
                       bands[4] + bands[5] + bands[6] + bands[7]) * 0.125;
    float intensity = totalBand * a.gated;
    intensity *= (0.7 + a.brightness * 0.3);
    intensity *= (1.0 - a.calmMode * 0.3);
    intensity *= (1.0 + lufs * 0.3);
    intensity += a.glow * 0.04 * a.gated;
    intensity += a.beatAnt * 0.1 * a.gated;
    // Envelope adds breathing
    intensity *= (0.8 + envelope * 0.4);

    if (intensity > 0.01 && pattern > 0.01) {
        // Procedural color — blend band colors weighted by band values
        float3 patternCol = float3(0, 0, 0);
        float colorWeight = 0.0;
        [unroll] for (int ci = 0; ci < 8; ci++) {
            float bw = bands[ci] * a.gated;
            if (bw < 0.01) continue;
            float3 bc = lerp(float3(1.0, 0.6, 0.3), a.brainCol2, float(ci) / 7.0);
            bc = lerp(bc, emitCol[ci], 0.4);
            patternCol += bc * bw;
            colorWeight += bw;
        }
        if (colorWeight > 0.01) patternCol /= colorWeight;
        else patternCol = a.brainCol;
        patternCol = lerp(patternCol, patternCol.bgr, a.colorPulse * 0.02);

        // Pattern glow — nodal lines are bright (pattern is raw sum, can be > 1)
        float patternGlow = pattern * intensity * 0.15;
        col += patternCol * patternGlow * silence;

        // Beat standing wave — visible pulse traveling through pattern
        float beatWave = sin(r * 15.0 - a.beatPhase * PI * 6.0) * beatPulse;
        col += patternCol * pattern * abs(beatWave) * intensity * 0.15 * silence;

        // Beat anticipation — pre-beat swell brightens pattern
        col += patternCol * pattern * a.beatAnt * 0.08 * a.gated * silence;

        // Kick impact — radial ripple distorts pattern visibly
        float kickRipple = sin(r * 25.0 - a.beatPhase * 15.0) * kickSurge;
        col += float3(1.0, 0.5, 0.2) * pattern * abs(kickRipple) * intensity * 0.12 * flashScale * silence;

        // Kick flash — bright center impact
        col += float3(1.0, 0.6, 0.3) * pattern * kickSurge * exp(-r * r * 8.0) * 0.1 * flashScale * silence;

        // Transient scatter — disrupts pattern with sharp spikes
        if (transientAmt > 0.02) {
            float scatter = sin(plateP.x * 15.0 + plateP.y * 12.0 + Time * 25.0) * transientAmt;
            col += float3(1.0, 0.8, 0.5) * pattern * abs(scatter) * intensity * 0.08 * silence;
        }

        // Crest sharpens nodal lines
        col += patternCol * pattern * crest * intensity * 0.06 * silence;

        // Vocal band boost — speech mode brightens vocal-range patterns
        float vocalWeight = smoothstep(2.5, 3.5, 3.0) * (1.0 - smoothstep(5.0, 6.0, 3.0));
        col += patternCol * pattern * a.speechMode * vocalWeight * 0.1 * a.gated * silence;
    }

    // ── Surface edge glow — chamber boundary ──
    float chamberR = 0.7;
    float edgeDist = abs(r - chamberR);
    float edgeGlow = exp(-edgeDist * edgeDist * 80.0);
    col += a.brainCol3 * edgeGlow * totalBand * 0.08 * a.gated * silence;

    // ── Inner resonance glow ──
    float innerGlow = exp(-r * r * 6.0);
    col += a.brainCol * innerGlow * a.energy * 0.05 * a.gated * silence;
    col += float3(1.0, 0.6, 0.3) * innerGlow * kickSurge * 0.06 * flashScale * silence;

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Beat — standing wave pulse ──
    col += a.brainCol * beatPulse * exp(-a.beatPhase * 4.0) * 0.02 * silence;

    // ── Kick — impact ring ──
    if (kickSurge > 0.05) {
        float kickR = a.beatPhase * 0.6;
        float kickDist = abs(r - kickR);
        col += a.brainCol * exp(-kickDist * kickDist * 30.0) * kickSurge * 0.04 * silence;
    }

    // ── Phrase breathing ──
    float phraseMod = sin(a.phraseBeat * PI * 2.0) * 0.015 * a.gated;
    col += a.brainCol * phraseMod * silence;

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.015;

    // ── Active-emitter normalization ──
    col *= sqrt(16.0 / seActiveCount(emit));

    // ── Dynamic HDR limiter ──
    col = hdrLimiter(col);

    col *= silence;

    return float4(col, 1.0);
}
