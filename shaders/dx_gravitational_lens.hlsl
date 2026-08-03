// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 43: Gravitational Lens Observatory
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_SPHERICAL.
//
// Concept: Black hole at center. Accretion disk = tilted ellipse in screen space.
// 8 frequency bands map to 8 angular segments around the disk circumference.
// Spatial encoder provides emitter 3D positions → disk tilt/orientation + color.
// Brain band values → per-segment brightness (primary audio driver).
// Beat pulse travels around the disk. Doppler beaming brightens approaching side.
// Kick = gravitational wave ripple. Phase coherence = relativistic jets.
//
// No seEmitGlowDepth/VR, no seLinkLR, no softReinhard. Full audio brain data.
// HDR output to Layer 0. No local postfx.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    // VR parallax — shift screen coords per eye for fake stereo depth
    p += vrParallax(2.0);  // disk at ~2 units depth
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

    // ── Camera — VR head pose or desktop orbit ──
    SeCamera cam;
    float camOrbitAng;
    if (VR_ACTIVE) {
        cam = seCameraVR();
        camOrbitAng = 0.0;
    } else {
        float FOV = 0.85;
        camOrbitAng = a.section * 0.8 + a.stereoBal * 0.2 + Time * vrMotionScale(0.03) * a.motSpeed;
        float3 camPos = float3(sin(camOrbitAng) * 7.0, 2.5 + a.stereoDiff * 0.15, cos(camOrbitAng) * 7.0);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder: SPHERICAL profile ──
    // Emitters give us spatial positions + colors. We use sub-0 L emitter per band
    // to derive disk tilt and color, but brightness comes from brain band values.
    SeParams params = seParams(SE_PROFILE_SPHERICAL);
    params.widthScale = 3.5;
    params.heightScale = 3.5;
    params.depthScale = 3.5;
    params.jitterAmt = 0.1 + thd * 0.2;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;
    params.motionSpeed = 0.8 * (1.0 - a.calmMode * 0.3);

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
    float eventHorizon = 0.12;
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
        col += float3(1.0, 0.8, 0.5) * exp(-photonDist * photonDist * 200.0) * 0.15 * silence;
    }

    // ── Accretion disk — procedurally generated from all audio data ──
    // The disk is a continuous ring where radius, brightness, and color at each
    // angle are computed by interpolating band values around the circumference.
    // DSP data (LUFS, crest, THD, phase) shapes the disk deformation.
    // Spatial encoder provides per-band color and spatial modulation.
    // Beat creates radial waves. Kick compresses the disk. Transient scatters.

    float diskRot = camOrbitAng * 0.3;
    float diskTilt = 0.35;  // perspective tilt (ellipse aspect)
    float orbitAng = Time * 0.15 * a.motSpeed;

    // Pixel angle relative to disk center
    float pAng = atan2(p.y, p.x) - diskRot;
    float pAngNorm = frac(pAng / (PI * 2.0));  // 0..1 around the disk

    // ── Procedural radius: interpolate 8 band values around the ring ──
    // Each band sits at 1/8 positions around the circumference. Between bands,
    // smoothstep interpolates. This makes the disk shape itself morph with music.
    float bandPos = pAngNorm * 8.0;  // 0..8
    int band0 = int(bandPos) % 8;
    int band1 = (band0 + 1) % 8;
    float bandFrac = bandPos - floor(bandPos);  // 0..1 between adjacent bands
    float bandFracSmooth = bandFrac * bandFrac * (3.0 - 2.0 * bandFrac);  // smoothstep

    // Band energy at this angle (interpolated)
    float bandEnergyHere = lerp(bands[band0], bands[band1], bandFracSmooth);

    // Spatial encoder intensity at this angle (interpolated)
    float spatialHere = 1.0;
    float3 emitColHere = a.brainCol;
    {
        int n0 = band0 * SE_N_SUB * 2;
        int n1 = band1 * SE_N_SUB * 2;
        float s0 = 1.0, s1 = 1.0;
        float3 c0 = a.brainCol, c1 = a.brainCol;
        if (emit[n0].active > 0.01) { s0 = emit[n0].intensity + 0.5; c0 = emit[n0].color; }
        if (emit[n1].active > 0.01) { s1 = emit[n1].intensity + 0.5; c1 = emit[n1].color; }
        spatialHere = lerp(s0, s1, bandFracSmooth);
        emitColHere = lerp(c0, c1, bandFracSmooth);
    }

    // Base radius modulated by band energy — disk bulges where music is active
    float baseR = 0.45;
    float procRadius = baseR + bandEnergyHere * 0.25 * a.gated;
    procRadius += a.energy * 0.06 * a.gated;       // overall energy expands disk
    procRadius += a.beatAnt * 0.03 * a.gated;       // anticipatory swell
    procRadius += beatPulse * 0.04;                 // beat pulse expansion
    procRadius *= (1.0 + lufs * 0.1);               // LUFS pushes disk out

    // THD turbulence — procedural radial displacement
    float thdWarp = sin(pAng * 4.0 + Time * 2.0) * thd * 0.05 * flickerScale;
    thdWarp += sin(pAng * 7.0 - Time * 3.0) * thd * 0.03 * flickerScale;
    thdWarp *= (1.0 - a.calmMode * 0.5);
    procRadius += thdWarp;

    // Kick compression — disk squeezes inward on kick
    procRadius -= kickSurge * 0.08 * (1.0 - bandEnergyHere);

    // Transient scatter — sharp radial spikes
    float transScatter = transientAmt * sin(pAng * 12.0 + Time * 8.0) * 0.02;
    procRadius += transScatter * a.gated;

    // Crest sharpness — high crest = tighter ring
    procRadius *= (1.0 - crest * 0.05);

    // Stereo width — disk wider on stereo width
    float stereoStretch = 1.0 + a.stereoWid * 0.15;
    float diskRadiusX = procRadius * stereoStretch;
    float diskRadiusY = procRadius * diskTilt;

    // Phase coherence — converges disk toward circle (less elliptical)
    diskRadiusY = lerp(diskRadiusY, diskRadiusX, phaseCoh * 0.3);

    // Beat wave — radial pulse traveling around the disk
    float beatWavePos = a.beatPhase;
    float beatAngDist = abs(pAngNorm - beatWavePos);
    beatAngDist = min(beatAngDist, 1.0 - beatAngDist);
    float beatWave = exp(-beatAngDist * beatAngDist * 25.0) * beatPulse;
    diskRadiusX += beatWave * 0.04;
    diskRadiusY += beatWave * 0.03;

    // Phrase breathing — slow expansion/contraction
    float phraseBreath = sin(a.phraseBeat * PI * 2.0) * 0.02 * a.gated;
    diskRadiusX += phraseBreath;
    diskRadiusY += phraseBreath * 0.5;

    // ── Compute distance from pixel to procedural disk ring ──
    // Elliptical distance: transform p into disk-local space
    float ca = cos(diskRot), sa = sin(diskRot);
    float2 localP = float2(p.x * ca + p.y * sa, -p.x * sa + p.y * ca);

    // Normalized radius — 1.0 = on the ring
    float2 normP = float2(localP.x / max(diskRadiusX, 0.01), localP.y / max(diskRadiusY, 0.01));
    float normR = length(normP);
    float ringDist = abs(normR - 1.0) * min(diskRadiusX, diskRadiusY);

    // ── Procedural brightness from all data ──
    float intensity = bandEnergyHere * a.gated;
    intensity *= spatialHere;
    intensity *= (0.7 + a.brightness * 0.3);
    intensity *= (1.0 - a.calmMode * 0.3);
    intensity *= (1.0 + lufs * 0.3);
    intensity += a.glow * 0.04 * a.gated;
    intensity += a.beatAnt * 0.12 * a.gated;

    // Vocal band boost — interpolate vocal weight around ring
    float vocalW0 = smoothstep(2.5, 3.5, float(band0)) * (1.0 - smoothstep(5.0, 6.0, float(band0)));
    float vocalW1 = smoothstep(2.5, 3.5, float(band1)) * (1.0 - smoothstep(5.0, 6.0, float(band1)));
    float vocalHere = lerp(vocalW0, vocalW1, bandFracSmooth);
    intensity += a.speechMode * vocalHere * 0.2 * a.gated;

    // Doppler beaming — approaching side brighter
    float doppler = 1.0 + sin(pAng + orbitAng + Time * 0.5) * 0.4;
    doppler = clamp(doppler, 0.4, 1.6);
    intensity *= doppler;

    if (intensity > 0.01) {
        // Procedural color — interpolate between band colors around ring
        float bt = lerp(float(band0) / 7.0, float(band1) / 7.0, bandFracSmooth);
        float3 diskCol = lerp(float3(1.0, 0.6, 0.2), a.brainCol2, bt);
        diskCol = lerp(diskCol, emitColHere, 0.4);
        diskCol = lerp(diskCol, a.brainCol, 0.2);
        diskCol = lerp(diskCol, diskCol.bgr, a.colorPulse * 0.02);

        // Ring thickness — varies with crest (sharper when high crest)
        float ringThick = 0.01 / (1.0 + crest * 0.5);
        ringThick *= (1.0 + thd * 0.3 * (1.0 - a.calmMode * 0.5));

        float ringGlow = exp(-ringDist * ringDist / (ringThick * ringThick));
        float ringCore = exp(-ringDist * ringDist / (ringThick * ringThick * 0.15));

        col += diskCol * (ringGlow * 0.12 + ringCore * 0.22) * intensity * silence;

        // Beat pulse on ring
        col += diskCol * ringCore * beatWave * intensity * 0.25 * silence;

        // Kick flash — hotter color, stronger on bass-heavy angles
        float kickFlash = kickSurge * (0.5 + bandEnergyHere * 0.5);
        col += float3(1.0, 0.5, 0.2) * ringCore * kickFlash * intensity * 0.15 * flashScale * silence;

        // Transient ripple — radial wave pattern
        if (transientAmt > 0.02) {
            float transRipple = sin(ringDist * 50.0 - Time * 25.0) * transientAmt;
            col += diskCol * ringGlow * abs(transRipple) * intensity * 0.03 * silence;
        }

        // Crest edge sharpening
        col += diskCol * ringCore * crest * intensity * 0.04 * silence;
    }

    // ── Inner disk glow — hot material near event horizon ──
    float innerR = eventHorizon * 1.5;
    float innerDist = abs(r - innerR);
    float innerGlow = exp(-innerDist * innerDist * 100.0);
    col += float3(1.0, 0.7, 0.3) * innerGlow * a.energy * 0.08 * a.gated * silence;
    col += float3(1.0, 0.5, 0.2) * innerGlow * kickSurge * 0.1 * flashScale * silence;

    // ── Relativistic jets — phase coherence aligned, top and bottom ──
    if (phaseCoh > 0.3) {
        float jetStrength = phaseCoh * a.gated;
        // Up jet
        float jetUpDist = length(float2(p.x, max(p.y - 0.3, 0.0)));
        col += a.brainCol3 * exp(-jetUpDist * jetUpDist * 15.0) * jetStrength * 0.06 * silence;
        // Down jet
        float jetDownDist = length(float2(p.x, min(p.y + 0.3, 0.0)));
        col += a.brainCol3 * exp(-jetDownDist * jetDownDist * 15.0) * jetStrength * 0.06 * silence;
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Kick — gravitational wave ripple (expanding ring) ──
    if (kickSurge > 0.05) {
        float gwR = a.beatPhase * 0.8;
        float gwDist = abs(r - gwR);
        col += a.brainCol * exp(-gwDist * gwDist * 30.0) * kickSurge * 0.05 * silence;
    }

    // ── Phrase breathing ──
    float phraseMod = sin(a.phraseBeat * PI * 2.0) * 0.015 * a.gated;
    col += a.brainCol * phraseMod * silence;

    // ── Dynamic range ──
    col *= (0.4 + a.gated * 0.6);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.015;

    // ── Active-emitter normalization ──
    col *= sqrt(16.0 / seActiveCount(emit));

    // ── Dynamic HDR limiter ──
    col = hdrLimiter(col);

    col *= silence;

    return float4(col, 1.0);
}
