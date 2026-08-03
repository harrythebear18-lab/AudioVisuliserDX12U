// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 41: Quantum Field Interferometer — wave-particle duality in 3D
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_WAVE_FIELD.
//
// Concept: You are inside an interference chamber. 8 coherent wave sources
// at the back wall create interference patterns on a virtual screen plane.
// Phase coherence = fringe visibility (high = sharp fringes, low = blur).
// Stereo = dual-slit geometry (L/R sources). Beat = wave packet emission.
// Kick = quantum jump flash. Transient = measurement collapse.
//
// Audio-to-visual mapping:
//   b0-b7       -> 8 wave source amplitudes
//   beat        -> wave packet pulse
//   kick        -> quantum jump flash
//   transient   -> measurement collapse (sharp flash)
//   envelope    -> field intensity
//   stereoBal   -> source L/R positioning
//   stereoWid   -> slit separation
//   stereoDiff  -> camera height
//   phaseCoh    -> fringe visibility (coherence)
//   section     -> camera repositioning
//   phraseBeat  -> slow field breathing
//   speechMode  -> vocal source boost
//   calmMode    -> reduced noise
//   brightness  -> field intensity
//   glow        -> ambient field glow
//   colorPulse  -> hue shift
//   beatAnt     -> anticipatory swell
//
// DSP: LUFS->intensity, crest->fringe sharpness, THD->quantum noise, phase->coherence.
// HDR output to Layer 0. No local postfx. No texture sampling.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

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

    // ── Audio dynamics ──
    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — inside the chamber looking at sources ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.7;
        float camAng = a.section * 0.5 + a.stereoBal * 0.2 + Time * 0.02 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 1.0, 0.5 + a.stereoDiff * 0.1, 2.5);
        float3 camTarget = float3(0, 0, -1.0);
        cam = seCamera(camPos, camTarget, FOV);
    }

    // ── Spatial encoder for normalization ──
    SeParams params = seParams(SE_PROFILE_WAVE_FIELD);
    params.widthScale = 2.0;
    params.heightScale = 2.0;
    params.depthScale = 2.0;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;
    params.motionSpeed = 0.8 * (1.0 - a.calmMode * 0.3);
    params.jitterAmt = 0.1 + thd * 0.2;

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── Background — quantum vacuum ──
    float3 col = float3(0.002, 0.002, 0.006) * silence;
    col += starfield(uv, a) * 0.005;
    float vacuum = fbm2_4(p * 5.0 + Time * 0.5) * 0.004 * (1.0 + lufs * 0.1);
    col += float3(0.1, 0.15, 0.2) * vacuum * silence;
    float nebula = fbm2_4(p * 0.6 + Time * 0.002 * a.motSpeed);
    col += a.brainCol * nebula * 0.004 * a.ambient * a.ambActive * silence;

    // ── 8 wave sources at back of chamber — no texture sampling ──
    // Dual-slit: L/R sources per band, stereo width controls separation
    float slitSep = 0.5 + a.stereoWid * 0.5;

    // Source positions and properties (unrolled, no loop)
    float3 srcPos[8];
    float srcFreq[8];
    float srcAmp[8];
    float srcPhase[8];
    float srcGate[8];
    float3 srcCol[8];

    [unroll] for (int n = 0; n < 8; n++) {
        int band = n / 2;
        int slit = n % 2;
        float bt = float(band) / 7.0;

        float energy = bands[band];
        float gate = smoothstep(0.02, 0.08, energy);

        // Vocal band boost
        float vocalWeight = smoothstep(2.5, 3.5, float(band)) * (1.0 - smoothstep(5.0, 6.0, float(band)));
        energy += a.speechMode * vocalWeight * 0.2;

        float slitSign = (slit == 0) ? -1.0 : 1.0;
        float xPos = slitSign * slitSep * 0.5 + a.stereoBal * 0.3;
        float yPos = lerp(-1.5, 1.5, bt);
        float zPos = -2.0 + sin(float(n) * 1.7) * 0.3;

        srcPos[n] = float3(xPos, yPos, zPos);
        srcFreq[n] = lerp(2.0, 12.0, bt) * (1.0 + a.tempo * 0.3);
        srcAmp[n] = energy * gate;
        srcPhase[n] = float(n) * 0.7 + Time * srcFreq[n];
        srcGate[n] = gate;

        float3 c = lerp(a.brainCol, a.brainCol2, bt);
        c = lerp(c, a.brainCol3, bt * 0.3);
        if (slit == 0) c = lerp(c, a.brainCol, 0.3);
        else c = lerp(c, a.brainCol2, 0.3);
        c = lerp(c, c.bgr, a.colorPulse * 0.02);
        srcCol[n] = c;
    }

    // ── Interference field — project virtual screen at z=0 ──
    float3 screenCenter = float3(0, 0, 0);
    float3 toScreen = screenCenter - cam.pos;
    float screenDepth = dot(toScreen, cam.fwd);
    if (screenDepth > 0.1) {
        // Convert screen point to world position on virtual screen plane
        float3 worldP = cam.pos + cam.fwd * screenDepth
            + cam.right * p.x * screenDepth * cam.fov
            + cam.up * p.y * screenDepth * cam.fov;

        // Compute wave amplitude from each source (unrolled)
        float totalAmp = 0.0;
        float3 totalCol = float3(0, 0, 0);

        [unroll] for (int s = 0; s < 8; s++) {
            if (srcGate[s] < 0.01) continue;

            float dist = length(worldP - srcPos[s]);
            float wavelength = 2.0 * PI / srcFreq[s];
            float wave = sin(dist / wavelength * 2.0 * PI - srcPhase[s]);
            wave *= srcAmp[s] / max(dist * 0.3, 0.5);

            // Phase coherence — high = sharp interference, low = decoherence
            wave *= lerp(0.3, 1.0, phaseCoh);

            // THD — quantum noise
            wave += thd * hash21(p * 200.0 + float(s) * 13.7) * 0.02 * (1.0 - a.calmMode * 0.5);

            totalAmp += wave;
            totalCol += srcCol[s] * abs(wave) * srcGate[s];
        }

        // Interference intensity — |amplitude|^2 (quantum probability)
        float intensity = totalAmp * totalAmp * (1.0 + lufs * 0.3);
        intensity *= (1.0 + crest * 0.3);
        intensity += envelope * 0.05;
        intensity += a.beatAnt * 0.1;
        intensity *= (0.7 + a.brightness * 0.3);
        intensity *= (1.0 - a.calmMode * 0.3);

        // Color from interference
        float3 fieldCol = totalCol / max(length(totalCol), 0.001);
        fieldCol = lerp(fieldCol, a.brainCol, 0.2);

        // Fringe visibility — phase coherence
        float fringeVis = lerp(0.2, 1.0, phaseCoh);

        col += fieldCol * intensity * fringeVis * 0.4 * silence;

        // Beat — wave packet pulse
        col += a.brainCol * beatPulse * exp(-a.beatPhase * 4.0) * 0.05 * silence;

        // Kick — quantum jump flash
        col += float3(0.9, 0.8, 1.0) * kickSurge * 0.08 * exp(-r * r * 3.0) * silence;

        // Transient — measurement collapse
        if (transientAmt > 0.02) {
            col += float3(1.0, 1.0, 0.9) * transientAmt * 0.05 * exp(-r * r * 8.0) * silence;
        }

        // Phrase breathing
        float phraseMod = sin(a.phraseBeat * PI * 2.0) * 0.02 + 0.02;
        col += a.brainCol * phraseMod * silence;
    }

    // ── Source glows — visible emitters at back of chamber ──
    [unroll] for (int s2 = 0; s2 < 8; s2++) {
        if (srcGate[s2] < 0.01) continue;
        float3 toSrc = srcPos[s2] - cam.pos;
        float srcDepth = dot(toSrc, cam.fwd);
        if (srcDepth < 0.1) continue;
        float2 scrSrc = float2(dot(toSrc, cam.right) / (srcDepth * cam.fov),
                               dot(toSrc, cam.up) / (srcDepth * cam.fov));
        float scrDist = length(p - scrSrc);
        float srcSize = 0.012 / max(srcDepth * 0.15, 0.3) * 3.0;
        float srcGlow = exp(-scrDist * scrDist / (srcSize * srcSize));
        float srcCore = exp(-scrDist * scrDist / (srcSize * srcSize * 0.2));
        float srcIntensity = srcAmp[s2] * (0.7 + a.brightness * 0.3) + a.glow * 0.03;
        col += srcCol[s2] * (srcGlow * 0.15 + srcCore * 0.25) * srcIntensity * silence;
        col += srcCol[s2] * srcCore * beatPulse * srcIntensity * 0.1 * silence;
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.025 * silence;

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
