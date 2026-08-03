// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 46: Sonic Topology Mapper — audio-driven topographic contour map
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_TUNNEL.
//
// Concept: A 2D height field where each of the 8 brain bands creates a moving
// Gaussian peak in the terrain. Rendered as topographic contour lines
// (isosurfaces of height) with color gradients between them. The terrain
// morphs dramatically with music — peaks rise and fall, move and merge.
//
// ALL AudioData fields used:
//   b0-b7: 8 Gaussian peaks (height + position)
//   energy/overall: global terrain amplitude
//   beat/beatPhase/beatDet: seismic ripple + contour pulse
//   beatAnt: pre-beat terrain swell
//   kick/kickConf/punch: earthquake spike + impact crater
//   transient/dynamic: terrain crack/discontinuity
//   envelope: terrain breathing
//   bpm/tempo/tempoConf: contour line spacing + clarity
//   motSpeed/motionSpd: peak rotation speed
//   stereoBal/stereoWid/stereoDiff: terrain shift + stretch
//   leftEn/rightEn: L/R peak intensity modulation
//   phaseCorr/phaseCoh: L/R peak convergence + terrain smoothness
//   crest: contour line sharpness
//   thd: terrain roughness/noise
//   lufs: overall terrain brightness
//   brightness/glow/bloom/beam/dynLight: visual modifiers
//   speechMode/voiceActivity: vocal band peak boost
//   calmMode: reduce terrain amplitude
//   phraseBeat: slow terrain breathing
//   section/sectionConf: terrain rotation offset
//   colorPulse: hue shift
//   brainCol/2/3: contour line colors by height
//   hueBase/Center/Range/satur: HSV color mapping
//   gated/isSilent: gating
//   specCent/specSpread: contour color weighting + spread
//   domFreq/domBand: dominant frequency highlight
//   burstTrig/burstType/burstInt: burst event terrain spike
//   effectInt: secondary feature scale
//   ambient/ambientLevel: ambient terrain glow
//   profBass/profTreb: bass/treble terrain expansion
//   barScale/persp/motionPers: scale + perspective
//   tempoPulse: tempo-driven contour pulse
//
// No seEmitGlowDepth/VR, no seLinkLR, no softReinhard. Full audio brain.
// HDR output to Layer 0. No local postfx.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// Procedural terrain height field — 8 band-driven peaks + all audio dynamics
float terrainHeight(float2 p, float bands[8], AudioData a,
                    float crest, float thd, float phaseCoh, float lufs,
                    float beatPulse, float kickSurge, float transientAmt,
                    float envelope, float time)
{
    float h = 0.0;
    float r = length(p);

    // Stereo shift — terrain drifts with stereo balance
    float2 terrainShift = float2(a.stereoBal * 0.15, 0.0);
    // Stereo width stretch
    float stretchX = 1.0 + a.stereoWid * 0.2;
    float2 sp = float2(p.x / stretchX, p.y) - terrainShift;

    // ── 8 band-driven Gaussian peaks ──
    [unroll] for (int i = 0; i < 8; i++) {
        float bandVal = bands[i];
        if (bandVal < 0.005) continue;

        // Peak position — rotates slowly, each band at different speed
        float ang = float(i) / 8.0 * PI * 2.0
                  + time * (0.08 + float(i) * 0.025) * a.motSpeed
                  + a.section * 0.5;
        // Stereo balance shifts low bands more than highs
        ang += a.stereoBal * 0.3 * (1.0 - float(i) / 7.0);

        // Peak radius — outer bands further out, bass bands central
        float peakR = 0.15 + float(i) / 8.0 * 0.3;
        peakR += a.profBass * 0.05 * (1.0 - float(i) / 7.0);  // bass expands inner
        peakR += a.profTreb * 0.05 * (float(i) / 7.0);        // treble expands outer

        float2 peakPos = float2(cos(ang), sin(ang)) * peakR;

        // L/R peak intensity modulation
        float lrMod = 1.0;
        if (i < 4) lrMod = lerp(a.leftEn, a.rightEn, float(i) / 3.0) / max(a.overall, 0.01);
        else lrMod = lerp(a.leftEn, a.rightEn, float(i - 4) / 3.0) / max(a.overall, 0.01);
        lrMod = clamp(lrMod, 0.5, 2.0);

        // Peak height — band energy is primary driver
        float peakH = bandVal * 1.8 * a.gated * lrMod;
        peakH *= (1.0 + lufs * 0.3);
        peakH *= (0.8 + envelope * 0.4);
        peakH *= (1.0 - a.calmMode * 0.4);

        // Vocal band boost
        float vocalW = smoothstep(2.5, 3.5, float(i)) * (1.0 - smoothstep(5.0, 6.0, float(i)));
        peakH += a.speechMode * vocalW * bandVal * 0.5 * a.gated;
        peakH += a.voiceActivity * vocalW * 0.2 * a.gated;

        // Peak width — narrower for high bands (sharper features)
        float peakW = 0.28 - float(i) * 0.018;
        peakW *= (1.0 + phaseCoh * 0.3);    // phase coherence widens (smoother)
        peakW *= (1.0 - thd * 0.2 * vrFlickerScale());  // THD narrows (rougher)
        peakW *= (1.0 + a.specSpread * 0.2);  // spectral spread widens

        // Gaussian peak
        float d = length(sp - peakPos);
        h += peakH * exp(-d * d / (peakW * peakW));

        // Secondary ripple from each peak — wave spreading outward
        h += peakH * 0.2 * sin(d * 14.0 - time * 3.0 - float(i)) * exp(-d * d * 2.5);

        // Dominant band highlight — extra glow on dominant frequency
        if (abs(float(i) - a.domBand) < 0.5 && a.domBand > 0.01) {
            h += peakH * 0.3 * exp(-d * d / (peakW * peakW * 1.5));
        }
    }

    // ── Beat seismic ripple — radial wave from center ──
    h += beatPulse * 0.4 * sin(r * 16.0 - a.beatPhase * PI * 8.0) * exp(-r * r * 2.0);
    h += a.beatDet * 0.15 * sin(r * 25.0 - a.beatPhase * PI * 12.0) * exp(-r * r * 3.0);

    // ── Tempo pulse — continuous contour breathing ──
    h += a.tempoPulse * 0.1 * sin(r * 8.0 - time * 2.0) * exp(-r * r * 1.5);

    // ── Beat anticipation — pre-beat terrain swell ──
    h += a.beatAnt * 0.25 * exp(-r * r * 3.0) * a.gated;

    // ── Kick earthquake — central spike + crater ──
    h += kickSurge * 0.6 * exp(-r * r * 5.0);
    h -= kickSurge * 0.25 * sin(r * 22.0 - a.beatPhase * 30.0) * exp(-r * r * 3.0);
    // Punch — impact crater ring
    h += a.punch * 0.15 * exp(-pow(r - 0.3, 2.0) * 15.0) * a.gated;

    // ── Transient crack — sharp linear discontinuity ──
    if (transientAmt > 0.02) {
        float crack = sin(sp.x * 3.5 + sp.y * 2.5 + time * 25.0) * transientAmt;
        h += crack * 0.15 * exp(-r * r * 2.0) * a.gated;
    }
    // Dynamic — same as transient but continuous
    h += a.dynamic * 0.05 * sin(sp.x * 5.0 + sp.y * 4.0 + time * 15.0) * exp(-r * r * 3.0);

    // ── Envelope breathing — terrain rises and falls ──
    h += envelope * 0.2 * sin(r * 6.0 - time * 1.5) * exp(-r * r * 1.0);

    // ── Phrase breathing — slow terrain swell/contraction ──
    h += sin(a.phraseBeat * PI * 2.0) * 0.15 * a.gated * exp(-r * r * 1.5);

    // ── Burst event — terrain spike ──
    if (a.burstTrig > 0.5) {
        float burstAng = a.burstType * PI * 0.5 + time;
        float2 burstPos = float2(cos(burstAng), sin(burstAng)) * 0.3;
        h += a.burstInt * 0.4 * exp(-length(sp - burstPos) * length(sp - burstPos) * 8.0) * a.gated;
    }

    // ── Effect intensity — secondary terrain features ──
    h += a.effectInt * 0.08 * sin(sp.x * 4.0 + sp.y * 3.0 + time * 5.0) * exp(-r * r * 2.0);

    // ── THD roughness — high-frequency terrain noise ──
    float thdNoise = sin(sp.x * 20.0 + time * 8.0) * thd * 0.06 * vrFlickerScale();
    thdNoise += sin(sp.y * 18.0 - time * 6.0) * thd * 0.04 * vrFlickerScale();
    thdNoise += (vnoise2(sp * 15.0 + time * 2.0) - 0.5) * thd * 0.08 * vrFlickerScale();
    thdNoise *= (1.0 - a.calmMode * 0.6);
    h += thdNoise;

    // ── Phase coherence smooths terrain (reduces noise) ──
    h *= (0.7 + phaseCoh * 0.3);

    // ── Crest sharpens terrain features ──
    h *= (1.0 + crest * 0.2);

    // ── LUFS boosts overall terrain height ──
    h *= (1.0 + lufs * 0.15);

    // ── Bar scale ──
    h *= a.barScale;

    return h;
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
    float flickerScale = vrFlickerScale();

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
        float camAng = a.section * 0.5 + a.stereoBal * 0.15 + Time * vrMotionScale(0.02) * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 3.0, 1.0 + a.stereoDiff * 0.08, cos(camAng) * 3.0);
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

    // ── Spatial encoder color per band ──
    float3 emitCol[8];
    [unroll] for (int bi = 0; bi < 8; bi++) {
        int n = bi * SE_N_SUB * 2;
        emitCol[bi] = (emit[n].active > 0.01) ? emit[n].color : a.brainCol;
    }

    // ── Background — dark topological space + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.003;

    // ── Compute terrain height at this pixel ──
    float h = terrainHeight(p, bands, a, crest, thd, phaseCoh, lufs,
                            beatPulse, kickSurge, transientAmt,
                            envelope, Time);

    // ── Contour line rendering ──
    // Contour spacing — tighter with higher BPM, wider with calm mode
    float contourSpacing = 0.15 + a.tempo * 0.05;
    contourSpacing *= (1.0 + a.calmMode * 0.5);
    contourSpacing *= (1.0 - a.tempoConf * 0.15);  // confident tempo = tighter

    // Contour line position
    float contourNum = h / contourSpacing;
    float contourFrac = frac(contourNum);
    float contourDist = min(contourFrac, 1.0 - contourFrac) * contourSpacing;

    // Contour line sharpness — crest makes lines crisper
    float lineWidth = 0.004 / (1.0 + crest * 1.5);
    float contourGlow = exp(-contourDist * contourDist / (lineWidth * lineWidth));
    float contourCore = exp(-contourDist * contourDist / (lineWidth * lineWidth * 0.15));
    float contourHalo = exp(-contourDist * contourDist / (lineWidth * lineWidth * 5.0));

    // ── Contour color — height-based gradient ──
    // Map height to color: low = brainCol, mid = brainCol2, high = brainCol3
    float hNorm = saturate(h * 0.5 + 0.5);
    float3 contourCol;
    if (hNorm < 0.5) {
        contourCol = lerp(a.brainCol, a.brainCol2, hNorm * 2.0);
    } else {
        contourCol = lerp(a.brainCol2, a.brainCol3, (hNorm - 0.5) * 2.0);
    }
    // Spectral centroid shifts color weighting
    contourCol = lerp(contourCol, hsv(a.hueBase + a.specCent * a.hueRange, a.satur, 1.0), 0.15);
    // Color pulse hue shift
    contourCol = lerp(contourCol, contourCol.bgr, a.colorPulse * 0.03);

    // ── Contour intensity — all audio data drives brightness ──
    float intensity = a.gated;
    intensity *= (0.7 + a.brightness * 0.3);
    intensity *= (1.0 - a.calmMode * 0.4);
    intensity *= (1.0 + lufs * 0.3);
    intensity *= (0.8 + envelope * 0.4);
    intensity += a.glow * 0.05 * a.gated;
    intensity += a.beatAnt * 0.12 * a.gated;
    // Bloom softens contours
    intensity *= (1.0 + a.bloom * 0.2);
    // Ambient level adds baseline
    intensity += a.ambientLevel * 0.03;

    // ── Render contour lines ──
    if (intensity > 0.01 && abs(h) > 0.01) {
        col += contourCol * (contourGlow * 0.12 + contourCore * 0.3) * intensity * silence;
        col += contourCol * contourHalo * intensity * 0.06 * silence;

        // ── Beat seismic pulse — contour lines brighten on beat ──
        float beatSeismic = sin(r * 16.0 - a.beatPhase * PI * 8.0) * beatPulse;
        col += contourCol * contourCore * abs(beatSeismic) * intensity * 0.2 * silence;

        // ── Beat anticipation — contours swell before beat ──
        col += contourCol * contourCore * a.beatAnt * 0.15 * a.gated * silence;

        // ── Kick earthquake — contour flash ──
        col += float3(1.0, 0.5, 0.2) * contourCore * kickSurge * intensity * 0.25 * flashScale * silence;
        col += float3(1.0, 0.6, 0.3) * contourHalo * a.punch * 0.1 * flashScale * silence;

        // ── Transient crack — bright contour disruption ──
        if (transientAmt > 0.02) {
            float crack = sin(p.x * 3.5 + p.y * 2.5 + Time * 25.0) * transientAmt;
            col += float3(1.0, 0.8, 0.5) * contourGlow * abs(crack) * intensity * 0.12 * silence;
        }

        // ── Crest ridge sharpening ──
        col += contourCol * contourCore * crest * intensity * 0.08 * silence;

        // ── Beam — directional light across terrain ──
        if (a.beamActive > 0.5) {
            float beamDir = dot(normalize(p), float2(cos(a.hueCenter * PI * 2.0), sin(a.hueCenter * PI * 2.0)));
            col += contourCol * contourCore * smoothstep(0.6, 1.0, beamDir) * a.beam * 0.1 * silence;
        }

        // ── Dynamic light — beat-synced lighting ──
        col += contourCol * contourCore * a.dynLight * 0.06 * silence;

        // ── Section change flash ──
        if (a.shouldChg > 0.5) {
            col += hsv(a.hueCenter, 0.2, 1.0) * contourCore * smoothstep(1.0, 0.0, r) * 0.08 * silence;
        }

        // ── Burst event — bright contour spike ──
        if (a.burstTrig > 0.5) {
            col += hsv(a.hueCenter + 0.1, 0.4, 1.0) * contourCore * a.burstInt * 0.15 * silence;
        }
    }

    // ── Terrain fill — subtle color between contour lines ──
    float fillIntensity = abs(h) * a.gated * 0.04;
    fillIntensity *= (1.0 + lufs * 0.2);
    fillIntensity *= (1.0 - a.calmMode * 0.5);
    col += contourCol * fillIntensity * silence;

    // ── Inner terrain glow — hot center ──
    float innerGlow = exp(-r * r * 6.0);
    col += a.brainCol * innerGlow * a.energy * 0.06 * a.gated * silence;
    col += float3(1.0, 0.6, 0.3) * innerGlow * kickSurge * 0.08 * flashScale * silence;
    col += a.brainCol3 * innerGlow * a.ambient * 0.03 * a.ambActive * silence;

    // ── Ambient atmosphere glow ──
    col += ambientGlow(r, a) * 0.5 * silence;

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Kick — earthquake ring ──
    if (kickSurge > 0.05) {
        float kickR = a.beatPhase * 0.5;
        float kickDist = abs(r - kickR);
        col += a.brainCol * exp(-kickDist * kickDist * 30.0) * kickSurge * 0.05 * silence;
    }

    // ── Beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.6);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;

    // ── Phrase breathing ──
    float phraseMod = sin(a.phraseBeat * PI * 2.0) * 0.02 * a.gated;
    col += a.brainCol * phraseMod * silence;

    // ── Motion persistence — subtle afterimage glow ──
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
