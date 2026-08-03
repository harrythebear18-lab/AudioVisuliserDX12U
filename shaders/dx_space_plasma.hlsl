// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 30: Auditory Soundfield Localization — visualizing stereo spatial perception
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_RADIAL.
//
// Psychoacoustic phenomenon: The brain builds a spatial soundstage from two ear signals
// using interaural level differences (ILD), interaural time differences (ITD), and
// spectral cues. This mode makes that localization process visible:
//
//   Direct Sources     → emitter glow at psychoacoustic radial positions
//   ILD Vectors        → visible beams L→R per band, width = level difference
//   ITD Wavefronts     → expanding rings from L and R, offset by time difference
//   Phantom Center     → phase coherence pulls image toward center (focused source)
//   Diffuse Field      → decorrelation spreads sources wide (ambient wash)
//   Precedence Lock    → first-arrival wavefront locks perceived direction
//
// World: grid floor for depth grounding, fog density 0.04, dark ambient.
// Camera: orbiting the soundfield, FOV 0.9 (VR: head pose from OpenXR).
// 16-source culling: only center sub (si=1) renders for VR performance.
//
// DSP: LUFS→source intensity, crest→localization sharpness, THD→spatial jitter,
//      phase→L/R coherence (phantom center vs diffuse). HDR output to Layer 0.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// ── ILD vector — visible beam between L and R emitters showing level difference ──
// The brain uses interaural level differences to localize sound horizontally.
// Wider beam = bigger level difference = sound is more lateralized.
float3 ildVector(float2 p, SeEmitter eL, SeEmitter eR, float phaseCoh,
                 float stereoWid, float silence)
{
    if (eL.active < 0.01 || eR.active < 0.01) return float3(0, 0, 0);
    if (eL.intensity < 0.05 && eR.intensity < 0.05) return float3(0, 0, 0);

    // Line from L to R in screen space
    float2 ab = eR.screenPos - eL.screenPos;
    float lineLen2 = dot(ab, ab);
    if (lineLen2 < 0.0001) return float3(0, 0, 0);

    float t = saturate(dot(p - eL.screenPos, ab) / lineLen2);
    float2 closest = eL.screenPos + ab * t;
    float2 lineDiff = p - closest;
    float lineDist2 = dot(lineDiff, lineDiff);

    // Beam width — wider when level difference is large (more lateralized)
    float levelDiff = abs(eL.intensity - eR.intensity);
    float beamWidth = 0.003 + levelDiff * 0.008 * (1.0 + stereoWid);
    if (lineDist2 > beamWidth * 4.0) return float3(0, 0, 0);

    // Beam intensity — stronger when both sides are active
    float lineDist = sqrt(lineDist2);
    float beamIntensity = exp(-lineDist * lineDist / (beamWidth * beamWidth));
    float avgIntensity = (eL.intensity + eR.intensity) * 0.5;

    // Phase coherence: coherent = tight focused beam (phantom center)
    // Decorrelated = wide diffuse beam (spacious, ambient)
    float coherenceFocus = lerp(0.5, 2.0, phaseCoh);
    beamIntensity *= coherenceFocus;

    // Color: blend L and R colors, shifted by pan position
    float3 beamCol = lerp(eL.color, eR.color, t);

    // Center bright spot — phantom center image when phase is coherent
    float centerGlow = 0.0;
    if (phaseCoh > 0.4) {
        float2 midPt = (eL.screenPos + eR.screenPos) * 0.5;
        float midDist = length(p - midPt);
        centerGlow = exp(-midDist * midDist * 300.0) * phaseCoh * avgIntensity * 0.08;
    }

    float3 col = beamCol * beamIntensity * avgIntensity * 0.03 * silence;
    col += float3(0.85, 0.9, 1.0) * centerGlow * silence;

    return col;
}

// ── ITD wavefront — expanding ring offset by interaural time difference ──
// The brain detects sub-millisecond timing differences between ears.
// We visualize this as wavefronts from L and R that are phase-offset.
float3 itdWavefront(float2 p, SeEmitter e, float stereoDiff, float phaseCoh,
                    float beatPulse, float silence)
{
    if (e.active < 0.01 || e.intensity < 0.05) return float3(0, 0, 0);

    float2 diff = p - e.screenPos;
    float d = length(diff);
    float s = e.screenSize;

    float maxR = s * 6.0;
    if (d > maxR) return float3(0, 0, 0);

    // ITD offset — stereo difference creates timing offset between L and R wavefronts
    float itdOffset = stereoDiff * 0.15 * (1.0 - phaseCoh);

    // Expanding wavefront — phase offset by ITD
    float wp = e.wavePhase + itdOffset * float(e.side * 2 - 1);  // L and R offset oppositely
    float bandFrac = float(e.bandIdx) / 7.0;
    float waveSpeed = lerp(0.4, 1.0, bandFrac);

    float3 col = float3(0, 0, 0);
    [unroll] for (int w = 0; w < 1; w++) {
        float phaseOffset = float(w) * 0.5;
        float ringR = frac(wp * waveSpeed * 0.12 + phaseOffset) * maxR;
        float ringDist = abs(d - ringR);
        float ringWidth = s * 0.3;
        float ringIntensity = exp(-ringDist * ringDist / (ringWidth * ringWidth));

        float amp = e.intensity * e.depthFog * (1.0 + beatPulse * 0.3);
        col += e.color * ringIntensity * amp * 0.025 * silence;
    }

    return col;
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
    float beatBright = a.beat * a.tempoConf;

    // ── Camera — VR head pose or desktop orbit around soundfield ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.9;
        float camAng = a.section * 0.1 + a.stereoBal * 0.05 + Time * 0.003 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 3.0, 1.2 + a.stereoDiff * 0.1, 3.0 + cos(camAng) * 0.8);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder: RADIAL profile ──
    SeParams params = seParams(SE_PROFILE_RADIAL);
    params.widthScale = 2.5;
    params.heightScale = 1.5;
    params.depthScale = 3.5;
    params.jitterAmt = 0.15 + thd * 0.2;
    params.stereoWid = a.stereoWid;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment — floor + back wall ──
    SeWorld world = seWorld(0.04, float3(0.003, 0.002, 0.008), -1.5, 0.0, -6.0);
    world.gridScale = 2.0;
    world.gridIntensity = 0.035;
    world.ambientLevel = 0.004;
    world.ambientColor = float3(0.01, 0.008, 0.02);
    world.flags = 5;  // floor + back wall
    seApplyWorldFog(emit, world);

    // ── Background — world environment + subtle starfield ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.005;

    // ── PRIMARY VISUAL: ILD vectors — interaural level difference beams ──
    // This is the core identity of this mode: visible psychoacoustic localization beams
    [loop] for (int bi = 0; bi < SE_N_BANDS; bi++) {
        int li = bi * SE_N_SUB * 2 + 2;  // si=1, left
        int ri = bi * SE_N_SUB * 2 + 3;  // si=1, right
        col += ildVector(p, emit[li], emit[ri], phaseCoh, a.stereoWid, silence) * 4.0;
    }

    // ── PRIMARY VISUAL: ITD wavefronts — interaural time difference rings ──
    [loop] for (int bi2 = 0; bi2 < SE_N_BANDS; bi2++) {
        int li = bi2 * SE_N_SUB * 2 + 2;
        int ri = bi2 * SE_N_SUB * 2 + 3;
        if (emit[li].active > 0.01 && emit[li].depth > 0.1)
            col += itdWavefront(p, emit[li], a.stereoDiff, phaseCoh, beatPulse, silence) * 3.0;
        if (emit[ri].active > 0.01 && emit[ri].depth > 0.1)
            col += itdWavefront(p, emit[ri], a.stereoDiff, phaseCoh, beatPulse, silence) * 3.0;
    }

    // ── No emitter glow — ILD/ITD beams ARE the visual identity, glow adds latency ──
    // (spatial reference comes from world grid + listener focal point)

    // ── No L↔R links — ILD beams already show L/R relationship ──

    // ── Listener focal point — spatial anchor ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Diffuse field glow — decorrelation creates ambient wash ──
    float diffuseness = (1.0 - phaseCoh) * envelope * 0.01;
    col += a.brainCol2 * diffuseness * exp(-r * 1.5) * silence;

    // ── Dynamic range — quiet passages dark ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays (sparing) ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── Active-emitter normalization — busy music doesn't stack brighter ──
    col *= sqrt(16.0 / seActiveCount(emit));

    // ── HDR limiter per pipeline rules ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
