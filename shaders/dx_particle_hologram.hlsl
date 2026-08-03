// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 47: Acoustic Particle Hologram — procedural holographic interference field
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_PSYCHOACOUSTIC.
//
// Concept: A hologram is an interference pattern between two coherent wavefronts.
// Left and right stereo channels are the two wavefronts. Each of the 8 brain
// bands generates a ring of coherent emitters around the hologram plate.
// Where wavefronts constructively interfere = bright particle clusters.
// Where they destructively interfere = dark fringes. The pattern shifts and
// morphs with stereo balance, phase correlation, and band energy.
//
// ALL AudioData fields used:
//   b0-b7: 8 ring interference amplitude + frequency
//   energy/overall: global hologram brightness
//   beat/beatPhase/beatDet: beat wavefront pulse
//   beatAnt: pre-beat fringe shift
//   kick/kickConf/punch: hologram disruption + flash
//   transient/dynamic: fringe scatter
//   envelope: hologram breathing
//   bpm/tempo/tempoConf: fringe spacing + clarity
//   motSpeed/motionSpd: ring rotation speed
//   stereoBal/stereoWid/stereoDiff: wavefront angle + separation
//   leftEn/rightEn: L/R wavefront amplitude
//   phaseCorr/phaseCoh: fringe contrast + coherence
//   crest: fringe sharpness
//   thd: hologram noise/static
//   lufs: overall brightness
//   brightness/glow/bloom/beam/dynLight: visual modifiers
//   speechMode/voiceActivity: vocal band fringe boost
//   calmMode: reduce interference amplitude
//   phraseBeat: slow fringe drift
//   section/sectionConf: ring rotation offset
//   colorPulse: hue shift
//   brainCol/2/3: fringe colors by band
//   hueBase/Center/Range/satur: HSV color mapping
//   gated/isSilent: gating
//   specCent/specSpread: fringe color weighting + frequency spread
//   domFreq/domBand: dominant band fringe highlight
//   burstTrig/burstType/burstInt: burst fringe spike
//   effectInt: secondary fringe modulation
//   ambient/ambientLevel: ambient hologram glow
//   profBass/profTreb: bass/treble ring expansion
//   barScale/persp/motionPers: scale + perspective
//   tempoPulse: tempo-driven fringe pulse
//
// No seEmitGlowDepth/VR, no seLinkLR, no softReinhard. Full audio brain.
// HDR output to Layer 0. No local postfx.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// Procedural holographic interference field
// Returns interference intensity at screen position p
float hologramInterference(float2 p, float bands[8], AudioData a,
                           float crest, float thd, float phaseCoh, float lufs,
                           float beatPulse, float kickSurge, float transientAmt,
                           float envelope, float time)
{
    float r = length(p);
    float ang = atan2(p.y, p.x);

    // Stereo wavefront separation — L and R sources at different angles
    float waveAngleL = a.stereoBal * PI * 0.3 - PI * 0.15;
    float waveAngleR = a.stereoBal * PI * 0.3 + PI * 0.15;
    waveAngleL += a.stereoDiff * 0.1;
    waveAngleR -= a.stereoDiff * 0.1;

    // Wavefront source positions (simulated)
    float2 srcL = float2(cos(waveAngleL), sin(waveAngleL)) * 3.0;
    float2 srcR = float2(cos(waveAngleR), sin(waveAngleR)) * 3.0;

    // Distance from each source — path length difference = interference
    float distL = length(p - srcL);
    float distR = length(p - srcR);
    float pathDiff = distL - distR;

    // L/R wavefront amplitudes
    float ampL = a.leftEn / max(a.overall, 0.01);
    float ampR = a.rightEn / max(a.overall, 0.01);
    ampL = clamp(ampL, 0.3, 2.0);
    ampR = clamp(ampR, 0.3, 2.0);

    float interference = 0.0;

    // ── 8 band-driven interference rings ──
    [unroll] for (int i = 0; i < 8; i++) {
        float bandVal = bands[i];
        if (bandVal < 0.005) continue;

        // Each band has a different spatial frequency (fringe spacing)
        float freq = 3.0 + float(i) * 2.5;
        freq *= (1.0 + a.specSpread * 0.3);  // spectral spread widens frequency range
        freq *= (1.0 - a.calmMode * 0.3);

        // Ring radius — each band at different distance from center
        float ringR = 0.1 + float(i) / 8.0 * 0.35;
        ringR += a.profBass * 0.04 * (1.0 - float(i) / 7.0);
        ringR += a.profTreb * 0.04 * (float(i) / 7.0);
        ringR += a.beatAnt * 0.02 * a.gated;

        // Ring rotation — each band rotates at different speed
        float ringAng = ang + time * (0.1 + float(i) * 0.04) * a.motSpeed
                      + a.section * 0.3;
        ringAng += a.stereoBal * 0.2 * (1.0 - float(i) / 7.0);

        // Interference pattern — cos of path difference × frequency
        float fringe = cos(pathDiff * freq + ringAng * float(i));

        // Band amplitude — L/R modulated
        float bandAmp = bandVal * a.gated;
        if (i < 4) bandAmp *= lerp(ampL, ampR, float(i) / 3.0);
        else bandAmp *= lerp(ampL, ampR, float(i - 4) / 3.0);
        bandAmp *= (1.0 + lufs * 0.3);
        bandAmp *= (0.8 + envelope * 0.4);
        bandAmp *= (1.0 - a.calmMode * 0.4);

        // Vocal band boost
        float vocalW = smoothstep(2.5, 3.5, float(i)) * (1.0 - smoothstep(5.0, 6.0, float(i)));
        bandAmp += a.speechMode * vocalW * bandVal * 0.4 * a.gated;
        bandAmp += a.voiceActivity * vocalW * 0.15 * a.gated;

        // Ring envelope — Gaussian around ring radius
        float ringDist = abs(r - ringR);
        float ringWidth = 0.08 - float(i) * 0.005;
        ringWidth *= (1.0 + phaseCoh * 0.3);
        ringWidth *= (1.0 - thd * 0.15 * vrFlickerScale());
        float ringEnv = exp(-ringDist * ringDist / (ringWidth * ringWidth));

        // Dominant band highlight
        if (abs(float(i) - a.domBand) < 0.5 && a.domBand > 0.01) {
            ringEnv *= 1.4;
        }

        // Add interference fringe × ring envelope
        interference += bandAmp * fringe * ringEnv;

        // Secondary ripple — wave spreading from each ring
        interference += bandAmp * 0.15 * sin(r * freq * 0.5 - time * 2.0 - float(i)) * ringEnv;
    }

    // ── Beat wavefront pulse — traveling interference fringe ──
    interference += beatPulse * 0.3 * cos(pathDiff * 8.0 - a.beatPhase * PI * 6.0) * exp(-r * r * 2.0);
    interference += a.beatDet * 0.1 * cos(pathDiff * 12.0 - a.beatPhase * PI * 10.0) * exp(-r * r * 3.0);

    // ── Tempo pulse — continuous fringe breathing ──
    interference += a.tempoPulse * 0.08 * cos(r * 6.0 - time * 1.5) * exp(-r * r * 1.5);

    // ── Beat anticipation — pre-beat fringe shift ──
    interference += a.beatAnt * 0.2 * cos(pathDiff * 5.0) * exp(-r * r * 2.5) * a.gated;

    // ── Kick hologram disruption — central flash + radial break ──
    interference += kickSurge * 0.5 * cos(pathDiff * 15.0 - a.beatPhase * 30.0) * exp(-r * r * 4.0);
    interference -= kickSurge * 0.2 * exp(-r * r * 5.0);
    interference += a.punch * 0.12 * cos(r * 18.0) * exp(-pow(r - 0.3, 2.0) * 12.0) * a.gated;

    // ── Transient fringe scatter ──
    if (transientAmt > 0.02) {
        float scatter = sin(p.x * 4.0 + p.y * 3.0 + time * 30.0) * transientAmt;
        interference += scatter * 0.15 * exp(-r * r * 2.0) * a.gated;
    }
    interference += a.dynamic * 0.06 * sin(p.x * 6.0 + p.y * 5.0 + time * 18.0) * exp(-r * r * 3.0);

    // ── Envelope breathing ──
    interference += envelope * 0.15 * cos(r * 5.0 - time * 1.2) * exp(-r * r * 1.0);

    // ── Phrase breathing — slow fringe drift ──
    interference += sin(a.phraseBeat * PI * 2.0) * 0.12 * a.gated * cos(pathDiff * 3.0) * exp(-r * r * 1.5);

    // ── Burst event — fringe spike ──
    if (a.burstTrig > 0.5) {
        float burstAng = a.burstType * PI * 0.5 + time;
        float2 burstPos = float2(cos(burstAng), sin(burstAng)) * 0.3;
        interference += a.burstInt * 0.35 * cos(length(p - burstPos) * 20.0) * exp(-length(p - burstPos) * length(p - burstPos) * 6.0) * a.gated;
    }

    // ── Effect intensity — secondary fringe modulation ──
    interference += a.effectInt * 0.07 * cos(p.x * 5.0 + p.y * 4.0 + time * 6.0) * exp(-r * r * 2.0);

    // ── THD hologram static — noise overlay ──
    float thdNoise = sin(p.x * 25.0 + time * 10.0) * thd * 0.05 * vrFlickerScale();
    thdNoise += sin(p.y * 22.0 - time * 8.0) * thd * 0.04 * vrFlickerScale();
    thdNoise += (vnoise2(p * 18.0 + time * 3.0) - 0.5) * thd * 0.06 * vrFlickerScale();
    thdNoise *= (1.0 - a.calmMode * 0.6);
    interference += thdNoise;

    // ── Phase coherence — fringe contrast ──
    interference *= (0.6 + phaseCoh * 0.4);

    // ── Crest — fringe sharpness ──
    interference *= (1.0 + crest * 0.2);

    // ── LUFS — overall brightness ──
    interference *= (1.0 + lufs * 0.15);

    // ── Bar scale ──
    interference *= a.barScale;

    return interference;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    // VR parallax — shift screen coords per eye for fake stereo depth
    p += vrParallax(2.0);
    float r = length(p);
    float silence = 1.0 - a.isSilent;
    float flashScale = vrFlashScale();

    // ── DSP ──
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
        float camAng = a.section * 0.4 + a.stereoBal * 0.15 + Time * vrMotionScale(0.02) * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 2.5, 0.8 + a.stereoDiff * 0.08, cos(camAng) * 2.5);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder: PSYCHOACOUSTIC profile ──
    SeParams params = seParams(SE_PROFILE_PSYCHOACOUSTIC);
    params.widthScale = 2.5;
    params.heightScale = 2.5;
    params.depthScale = 3.0;
    params.jitterAmt = 0.12 + thd * 0.2;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.05, float3(0.003, 0.002, 0.01), -1.8, 0.0, 0.0);
    world.gridIntensity = 0.02;
    world.ambientLevel = 0.003;
    world.ambientColor = float3(0.008, 0.006, 0.015);
    seApplyWorldFog(emit, world);

    // ── Spatial encoder color per band ──
    float3 emitCol[8];
    [unroll] for (int bi = 0; bi < 8; bi++) {
        int n = bi * SE_N_SUB * 2;
        emitCol[bi] = (emit[n].active > 0.01) ? emit[n].color : a.brainCol;
    }

    // ── Background — dark hologram space + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.003;

    // ── Compute holographic interference ──
    float interference = hologramInterference(p, bands, a, crest, thd, phaseCoh, lufs,
                                               beatPulse, kickSurge, transientAmt,
                                               envelope, Time);

    // ── Interference → visual ──
    // Positive interference = bright constructive fringes (particles)
    // Negative interference = dark destructive fringes
    float constructive = max(interference, 0.0);
    float destructive = max(-interference, 0.0);

    // ── Band angle for color ──
    float ang = atan2(p.y, p.x);
    float bandPos = frac(ang / (PI * 2.0)) * 8.0;
    int band0 = int(bandPos) % 8;
    int band1 = (band0 + 1) % 8;
    float bandFrac = bandPos - floor(bandPos);
    float bandFracSmooth = bandFrac * bandFrac * (3.0 - 2.0 * bandFrac);

    // ── Color — blend band colors + height-based gradient ──
    float3 fringeCol = lerp(emitCol[band0], emitCol[band1], bandFracSmooth);
    float bt = lerp(float(band0) / 7.0, float(band1) / 7.0, bandFracSmooth);
    fringeCol = lerp(fringeCol, lerp(a.brainCol, a.brainCol2, bt), 0.4);
    fringeCol = lerp(fringeCol, a.brainCol3, constructive * 0.15);
    // Spectral centroid shifts color
    fringeCol = lerp(fringeCol, hsv(a.hueBase + a.specCent * a.hueRange, a.satur, 1.0), 0.12);
    // Color pulse hue shift
    fringeCol = lerp(fringeCol, fringeCol.bgr, a.colorPulse * 0.03);

    // ── Intensity — all audio data drives brightness ──
    float intensity = a.gated;
    intensity *= (0.7 + a.brightness * 0.3);
    intensity *= (1.0 - a.calmMode * 0.4);
    intensity *= (1.0 + lufs * 0.3);
    intensity *= (0.8 + envelope * 0.4);
    intensity += a.glow * 0.05 * a.gated;
    intensity += a.beatAnt * 0.12 * a.gated;
    intensity *= (1.0 + a.bloom * 0.2);
    intensity += a.ambientLevel * 0.03;

    // ── Render constructive interference as particle clusters ──
    if (intensity > 0.01 && constructive > 0.01) {
        // Particle cluster glow — multi-layer
        float particleSize = 0.015 / (1.0 + crest * 0.8);
        float coreGlow = exp(-pow(constructive - 1.0, 2.0) / (particleSize * particleSize));
        float midGlow = exp(-pow(constructive - 0.5, 2.0) / (particleSize * particleSize * 4.0));
        float haloGlow = exp(-pow(constructive - 0.3, 2.0) / (particleSize * particleSize * 16.0));

        col += float3(0.9, 0.95, 1.0) * coreGlow * intensity * 0.25 * silence;
        col += fringeCol * midGlow * intensity * 0.18 * silence;
        col += fringeCol * haloGlow * intensity * 0.05 * silence;

        // ── Beat fringe pulse ──
        float beatFringe = cos(r * 16.0 - a.beatPhase * PI * 8.0) * beatPulse;
        col += fringeCol * max(beatFringe, 0.0) * intensity * 0.15 * silence;

        // ── Beat anticipation swell ──
        col += fringeCol * a.beatAnt * 0.12 * a.gated * constructive * silence;

        // ── Kick hologram flash ──
        col += float3(1.0, 0.5, 0.2) * kickSurge * intensity * 0.2 * flashScale * silence;
        col += float3(1.0, 0.6, 0.3) * a.punch * 0.08 * flashScale * silence;

        // ── Transient fringe scatter ──
        if (transientAmt > 0.02) {
            float scatter = sin(p.x * 4.0 + p.y * 3.0 + Time * 30.0) * transientAmt;
            col += float3(1.0, 0.8, 0.5) * max(scatter, 0.0) * intensity * 0.1 * silence;
        }

        // ── Crest fringe sharpening ──
        col += fringeCol * crest * intensity * constructive * 0.06 * silence;

        // ── Beam — directional light across hologram ──
        if (a.beamActive > 0.5) {
            float beamDir = dot(normalize(p), float2(cos(a.hueCenter * PI * 2.0), sin(a.hueCenter * PI * 2.0)));
            col += fringeCol * smoothstep(0.6, 1.0, beamDir) * a.beam * 0.08 * silence;
        }

        // ── Dynamic light ──
        col += fringeCol * a.dynLight * 0.05 * silence;

        // ── Section change flash ──
        if (a.shouldChg > 0.5) {
            col += hsv(a.hueCenter, 0.2, 1.0) * smoothstep(1.0, 0.0, r) * 0.06 * silence;
        }

        // ── Burst event ──
        if (a.burstTrig > 0.5) {
            col += hsv(a.hueCenter + 0.1, 0.4, 1.0) * a.burstInt * 0.12 * silence;
        }
    }

    // ── Destructive interference — subtle dark fringes (depth) ──
    // Don't subtract — just don't add. The absence creates the fringe pattern.

    // ── Hologram fill — subtle color between fringes ──
    float fillIntensity = abs(interference) * a.gated * 0.03;
    fillIntensity *= (1.0 + lufs * 0.2);
    fillIntensity *= (1.0 - a.calmMode * 0.5);
    col += fringeCol * fillIntensity * silence;

    // ── Inner hologram glow ──
    float innerGlow = exp(-r * r * 6.0);
    col += a.brainCol * innerGlow * a.energy * 0.05 * a.gated * silence;
    col += float3(1.0, 0.6, 0.3) * innerGlow * kickSurge * 0.07 * flashScale * silence;
    col += a.brainCol3 * innerGlow * a.ambient * 0.03 * a.ambActive * silence;

    // ── Ambient atmosphere glow ──
    col += ambientGlow(r, a) * 0.5 * silence;

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Kick ring ──
    if (kickSurge > 0.05) {
        float kickR = a.beatPhase * 0.5;
        float kickDist = abs(r - kickR);
        col += a.brainCol * exp(-kickDist * kickDist * 30.0) * kickSurge * 0.04 * silence;
    }

    // ── Beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.6);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;

    // ── Phrase breathing ──
    float phraseMod = sin(a.phraseBeat * PI * 2.0) * 0.02 * a.gated;
    col += a.brainCol * phraseMod * silence;

    // ── Motion persistence ──
    col *= (1.0 + a.motionPers * 0.05);

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
