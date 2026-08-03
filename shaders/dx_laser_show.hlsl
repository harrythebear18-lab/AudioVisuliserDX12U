// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 38: Resonance Field — Chladni standing-wave interference
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_PSYCHOACOUSTIC.
//
// Chladni standing-wave patterns emanate from psychoacoustic source positions.
// Constructive interference = bright antinodes, destructive = dark nodes.
// Only sub-0 emitters (16) used for performance — no seRenderWorld overhead.
//
// Audio-to-visual mapping:
//   b0-b7       -> 8 band positions with Chladni wave patterns
//   beat        -> wave compression + pulse
//   kick        -> central flash
//   transient   -> turbulence noise
//   envelope    -> field density
//   stereoBal   -> camera orbit
//   stereoWid   -> field spread
//   stereoDiff  -> vertical offset
//   phaseCoh    -> wave coherence
//   section     -> camera repositioning
//   phraseBeat  -> slow breathing
//   speechMode  -> vocal band boost
//   calmMode    -> reduced turbulence
//   brightness  -> field intensity
//   glow        -> ambient field glow
//   colorPulse  -> hue shift
//   beatAnt     -> anticipatory swell
//
// DSP: LUFS->density, crest->sharpness, THD->turbulence, phase->coherence.
// HDR output to Layer 0. No local postfx. 16-emitter Chladni loop.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// Chladni standing-wave pattern — classic plate vibration modes
// Returns interference amplitude at screen-space distance d from source center
float chladni(float d, float freq, float phase, float mode1, float mode2)
{
    float u = d * freq + phase;
    float v = d * freq * 0.7 + phase * 0.5;
    return cos(mode1 * u) * cos(mode2 * v) + sin(mode1 * v) * sin(mode2 * u);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();
    float phaseCorr = phaseCoherence();

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
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
        float camAng = a.section * 0.2 + a.stereoBal * 0.15 + Time * 0.03 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 2.5, 1.0 + a.stereoDiff * 0.08, cos(camAng) * 3.0);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder: PSYCHOACOUSTIC profile ──
    SeParams params = seParams(SE_PROFILE_PSYCHOACOUSTIC);
    params.widthScale = 2.0;
    params.heightScale = 3.0;
    params.depthScale = 5.0;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;
    params.motionSpeed = 0.8 * (1.0 - a.calmMode * 0.3);
    params.crossOver = 0.35;
    params.jitterAmt = 0.8 + thd * 0.3;

    // ── Compute all 48 emitters from brain data ──
    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment — subtle grid floor, fog, dark ambient ──
    SeWorld world = seWorld(0.06,                          // fog density
                            float3(0.01, 0.008, 0.02),     // fog color (dark blue-purple)
                            -1.2,                          // floor Y
                            0.0,                           // no ceiling
                            0.0);                          // no back wall
    world.gridScale = 2.5;
    world.gridIntensity = 0.03;    // subtle
    world.ambientLevel = 0.003;    // dark
    world.ambientColor = float3(0.08, 0.06, 0.12);
    world.flags = 1;               // floor only

    // Apply fog to all emitters (precomputes depthFog)
    seApplyWorldFog(emit, world);

    // ── World environment only (no emitter glow — Chladni field IS the visual) ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.005;
    float nebula = fbm2_4(p * 0.7 + Time * 0.002 * a.motSpeed);
    col += a.brainCol * nebula * 0.004 * a.ambient * a.ambActive * silence;

    // ── Chladni standing-wave interference field ──
    // Sum wave patterns from active emitters — this is the signature visual
    float waveTime = Time * 1.2 + a.beatPhase * PI * 2.0;
    float beatCompress = 1.0 - beatPulse * 0.12;

    float fieldVal = 0.0;
    float3 fieldCol = float3(0, 0, 0);
    float weightSum = 0.0;

    // Only sub-0 emitters (16 instead of 48) for performance
    [loop] for (int bi = 0; bi < SE_N_BANDS; bi++) {
        for (int side = 0; side < 2; side++) {
            int j = bi * SE_N_SUB * 2 + side;
            if (emit[j].active < 0.01) continue;
            if (emit[j].depth < 0.1) continue;

        float2 diff = p - emit[j].screenPos;
        float scrDist2 = dot(diff, diff);

        float bt = float(emit[j].bandIdx) / 7.0;
        float influenceR = lerp(0.7, 0.25, bt) * (0.5 + emit[j].intensity * 0.7);
        float inflR2 = influenceR * influenceR;
        if (scrDist2 > inflR2) continue;

        float scrDist = sqrt(scrDist2);
        // Chladni mode parameters — band-dependent patterns
        float mode1 = lerp(2.0, 6.0, bt) * beatCompress;
        float mode2 = lerp(3.0, 5.0, bt) * beatCompress;
        float waveFreq = lerp(3.0, 12.0, bt);
        float depthPhase = emit[j].depth * 1.5;

        float chlad = chladni(scrDist, waveFreq, waveTime + depthPhase + float(bi) * 0.1, mode1, mode2);
        float amp = emit[j].intensity;
        amp += a.beatAnt * 0.15;
        amp += a.glow * 0.03;
        amp *= (0.7 + a.brightness * 0.3);
        amp *= (1.0 - a.calmMode * 0.3);
        // Speech mode boosts vocal bands
        float vocalWeight = smoothstep(2.5, 3.5, float(bi)) * (1.0 - smoothstep(5.0, 6.0, float(bi)));
        amp += a.speechMode * vocalWeight * 0.2;

        float depthFog = emit[j].depthFog;
        float falloff = exp(-scrDist2 / (inflR2 * 0.3));

        float wave = chlad * amp * (1.0 + crest * 0.3) * falloff * depthFog;

        fieldVal += wave;
        fieldCol += emit[j].color * abs(wave);
        weightSum += abs(wave);
        }
    }

    if (weightSum > 0.001) fieldCol /= weightSum;

    // ── Aggressive negative-space gating — only show meaningful interference ──
    float density = abs(fieldVal) * 0.14;
    density += thd * hash11(r * 17.3 + Time * 3.0) * density * 0.05;
    density += transientAmt * hash21(p * 30.0 + Time * 8.0) * 0.012;
    density += envelope * 0.003;

    // Tight gate — aggressive culling of near-silent regions
    float gate = smoothstep(0.003, 0.015, density);
    float decayGate = max(envelope, a.gated * 0.3);
    density *= gate * decayGate;

    float3 emission = fieldCol * density * (1.0 + lufs * 0.15);
    emission *= (1.0 + beatPulse * 0.08);
    col += emission * silence;

    // ── Kick flash ──
    col += float3(0.8, 0.4, 0.1) * kickSurge * 0.04 * exp(-r * r * 5.0) * silence;

    // ── Phrase breathing ──
    float phraseMod = sin(a.phraseBeat * PI * 2.0) * 0.03 + 0.03;
    col += a.brainCol * phraseMod * silence;

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    col *= (0.5 + a.gated * 0.5);
    col += standardOverlays(p, r, a) * 0.01;

    // ── Active-emitter normalization ──
    col *= sqrt(16.0 / seActiveCount(emit));

    // ── HDR limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;
    return float4(col, 1.0);
}
