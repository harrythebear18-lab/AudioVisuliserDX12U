// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 34: Spectral Vortex — cochlear decomposition as a 3D swirling funnel
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_SPHERICAL.
//
// Concept: The cochlea decomposes sound into frequency bands — wider at low
// frequencies, narrower at high. This mode visualizes that as a spectral vortex:
// a 3D funnel where each band is a horizontal ring at a different height.
// Bass = wide base, highs = narrow top. Rings rotate at band-dependent speeds.
// The vortex tilts with stereo balance, tightens with phase coherence, and
// pulses vertically with the beat. Transients create debris spiraling outward.
//
// Audio-to-visual mapping:
//   b0 (sub)    → base ring (widest, slowest rotation, warm color)
//   b1 (bass)   → second ring (wide, slow)
//   b2-b5 (mids)→ middle rings (medium width/speed, brain palette)
//   b6-b7 (highs)→ top rings (narrow, fast, cool color)
//   beat        → vertical pulse traveling up the vortex
//   kick        → base flash eruption
//   transient   → debris particles spiraling outward
//   envelope    → overall vortex density/opacity
//   stereoBal   → vortex axis tilt L/R
//   stereoWid   → vortex spread
//   phaseCoh    → tight spiral (coherent) vs diffuse (decorrelated)
//   section     → vortex height/camera repositioning
//   phraseBeat  → slow evolution of rotation pattern
//   speechMode  → vocal bands (b3-b5) ring brightening
//   calmMode    → reduced turbulence, slower rotation
//   brightness  → ring glow intensity
//   glow        → ambient vortex glow
//   colorPulse  → hue cycling
//   beatAnt     → anticipatory ring swell before beats
//
// DSP: LUFS→vortex density, crest→ring edge sharpness, THD→turbulence,
//      phase→spiral coherence. HDR output to Layer 0. No local postfx.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// ── Vortex ring — one frequency band rendered as a 3D rotating ring ──
float3 vortexRing(float2 p, SeCamera cam, int bandIdx, float bandEnergy,
                  float bandFrac, AudioData a, float lufs, float crest, float thd,
                  float phaseCoh, float beatPulse, float beatPhase, float kickSurge,
                  float transientAmt, float envelope, float silence)
{
    float3 col = float3(0, 0, 0);

    // Ring parameters — funnel shape: wide at bottom (bass), narrow at top (highs)
    float ringRadius = lerp(2.8, 0.4, bandFrac);
    // Height: bass at bottom, highs at top
    float ringHeight = lerp(-1.5, 2.5, bandFrac);
    // Rotation speed: bass = slow, highs = fast
    float rotSpeed = lerp(0.5, 4.0, bandFrac) * a.motSpeed * (1.0 - a.calmMode * 0.5);
    // Phase evolution with phrase
    float phrasePhase = a.phraseBeat * PI * 2.0 + bandFrac * PI;
    float ringAngle = Time * rotSpeed + float(bandIdx) * 0.8 + phrasePhase * 0.3;

    // Stereo tilt — vortex axis leans with stereo balance
    float3 tiltAxis = float3(a.stereoBal * 0.3, 0.0, 0.0);
    float3 ringCenter = float3(tiltAxis.x * ringHeight * 0.3, ringHeight, tiltAxis.z);

    // Ring thickness — crest sharpens, THD roughens
    float ringThickness = lerp(0.04, 0.015, bandFrac);
    ringThickness *= (1.0 + thd * 0.3);
    float edgeSharp = lerp(0.5, 1.0, crest);

    // Phase coherence tightens the spiral (more turns visible)
    float spiralTightness = lerp(0.5, 2.0, phaseCoh);

    // Energy from band + emitter enrichment proxies
    float intensity = bandEnergy * (1.0 + lufs * 0.3);
    // Beat anticipation swell
    intensity += a.beatAnt * (0.3 + bandFrac * 0.2) * 0.3;
    // Glow sustains
    intensity += a.glow * 0.1;
    // Speech mode boosts vocal bands
    float vocalWeight = smoothstep(2.5, 3.5, float(bandIdx)) * (1.0 - smoothstep(5.0, 6.0, float(bandIdx)));
    intensity += a.speechMode * vocalWeight * 0.3;
    // Brightness scales
    intensity *= (0.7 + a.brightness * 0.3);
    // Calm mode reduces
    intensity *= (1.0 - a.calmMode * 0.4);

    if (intensity < 0.02) return col;

    // Cohesive color — mostly brainCol with subtle band variation
    float3 ringCol = lerp(a.brainCol, a.brainCol2, bandFrac * 0.4);
    ringCol = lerp(ringCol, a.brainCol3, bandFrac * 0.15);
    // Speech mode shifts vocal bands slightly
    ringCol = lerp(ringCol, a.brainCol2, a.speechMode * vocalWeight * 0.3);

    [unroll] for (int seg = 0; seg < 12; seg++) {
        float segAngle = ringAngle + float(seg) / 12.0 * PI * 2.0;
        float3 worldPos = ringCenter + float3(
            cos(segAngle) * ringRadius,
            sin(segAngle * spiralTightness + phrasePhase) * 0.15,  // vertical wobble = spiral
            sin(segAngle) * ringRadius * 0.6  // elliptical for 3D look
        );

        float2 screenPos = seProject(worldPos, cam);
        float depth = seDepth(worldPos, cam);
        if (depth < 0.1) continue;

        float2 diff = p - screenPos;
        float dist = length(diff);
        float segThickness = ringThickness / max(depth * 0.3, 0.3);
        float segGlow = exp(-dist * dist / (segThickness * segThickness * 6.0));
        float segCore = exp(-dist * dist / (segThickness * segThickness * 0.8)) * edgeSharp;

        // Depth fade
        float depthFade = exp(-depth * 0.08);

        // Ring glow — visible but cohesive
        col += ringCol * segGlow * intensity * 0.06 * depthFade * silence;
        col += ringCol * segCore * intensity * 0.15 * depthFade * silence;

        // Beat pulse traveling up the vortex — phase offset by band height
        float beatOffset = bandFrac * 0.3;
        float beatWave = exp(-abs(frac(beatPhase + beatOffset) - 0.5) * 8.0) * beatPulse;
        col += ringCol * segCore * beatWave * intensity * 0.08 * depthFade * silence;

        // Kick flash on bass rings
        if (bandIdx <= 1) {
            col += float3(0.8, 0.4, 0.1) * segCore * kickSurge * intensity * 0.08 * depthFade * silence;
        }
    }

    return col;
}

// ── Storm clouds — FBM noise canopy above the vortex ──
float3 stormClouds(float2 p, float r, AudioData a, float envelope, float lufs,
                   float thd, float silence)
{
    // Cloud density from envelope + LUFS
    float cloudDensity = envelope * (0.3 + lufs * 0.4);
    if (cloudDensity < 0.02) return float3(0, 0, 0);

    // FBM clouds — THD adds turbulence
    float2 cloudUV = p * 1.5 + float2(Time * 0.1, Time * 0.07);
    float clouds = fbm2_4(cloudUV) * (1.0 + thd * 0.5);
    clouds *= smoothstep(0.0, 0.5, r) * smoothstep(4.0, 1.5, r);  // donut shape

    // Color — dark, cohesive with brain palette
    float3 cloudCol = lerp(float3(0.015, 0.008, 0.03), a.brainCol2, 0.2);
    cloudCol += a.brainCol * a.glow * 0.05;

    return cloudCol * clouds * cloudDensity * 0.04 * silence;
}

// ── Vortex core glow — central column of light ──
float3 vortexCore(float2 p, SeCamera cam, AudioData a, float envelope, float lufs,
                  float kickSurge, float beatPulse, float silence)
{
    // Project vortex center axis (from base to top)
    float3 basePos = float3(a.stereoBal * 0.3, -1.5, 0.0);
    float3 topPos = float3(a.stereoBal * 0.3 * 1.5, 2.5, 0.0);
    float2 baseScreen = seProject(basePos, cam);
    float2 topScreen = seProject(topPos, cam);

    // Distance from pixel to vortex axis line
    float2 ab = topScreen - baseScreen;
    float len2 = dot(ab, ab);
    if (len2 < 0.0001) return float3(0, 0, 0);
    float t = saturate(dot(p - baseScreen, ab) / len2);
    float2 closest = baseScreen + ab * t;
    float dist = length(p - closest);

    // Core glow — narrow column
    float coreWidth = 0.03 + envelope * 0.02;
    float coreGlow = exp(-dist * dist / (coreWidth * coreWidth * 2.0));
    float coreBright = exp(-dist * dist / (coreWidth * coreWidth * 0.3));

    // Intensity from envelope + LUFS
    float intensity = envelope * (0.4 + lufs * 0.3) + a.glow * 0.2;

    // Color gradient: warm at base, cool at top
    float3 coreCol = lerp(a.brainCol, a.brainCol3, t);

    float3 col = coreCol * coreGlow * intensity * 0.12 * silence;
    col += coreCol * coreBright * intensity * 0.25 * silence;

    // Kick flash at base
    col += float3(1.0, 0.5, 0.15) * coreBright * kickSurge * 0.3 * (1.0 - t) * silence;

    // Beat pulse traveling up core
    float beatWave = exp(-abs(frac(a.beatPhase) - t) * 10.0) * beatPulse;
    col += coreCol * coreBright * beatWave * 0.15 * silence;

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

    // ── Audio dynamics — full brain data ──
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — VR head pose or desktop orbit ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.75;
        float camAng = a.section * 0.3 + a.stereoBal * 0.1 + Time * 0.01 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 4.0, 1.0 + a.stereoDiff * 0.1, cos(camAng) * 4.0);
        cam = seCamera(camPos, float3(0, 0.5, 0), FOV);
    }

    // ── Spatial encoder for emitter data (world fog + listener) ──
    SeParams params = seParams(SE_PROFILE_SPHERICAL);
    params.widthScale = 2.5 + a.stereoWid * 0.5;
    params.heightScale = 2.0;
    params.depthScale = 3.0 - a.calmMode * 0.3;
    params.jitterAmt = 0.1 + thd * 0.15;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.05, float3(0.003, 0.002, 0.008), -1.5, 0.0, -6.0);
    world.gridScale = 2.0;
    world.gridIntensity = 0.025;
    world.ambientLevel = 0.003 + a.calmMode * 0.002;
    world.ambientColor = float3(0.008, 0.006, 0.015);
    world.flags = 5;  // floor + back wall
    seApplyWorldFog(emit, world);

    // ── Background: world environment + starfield ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.003;

    // ── Storm clouds — FBM canopy ──
    col += stormClouds(p, r, a, envelope, lufs, thd, silence);

    // ── PRIMARY: Vortex core glow — central column ──
    col += vortexCore(p, cam, a, envelope, lufs, kickSurge, beatPulse, silence) * 4.0;

    // ── PRIMARY: 8 vortex rings — frequency band structure ──
    [loop] for (int bi = 0; bi < SE_N_BANDS; bi++) {
        float bandFrac = float(bi) / 7.0;
        col += vortexRing(p, cam, bi, bands[bi], bandFrac, a, lufs, crest, thd,
                          phaseCoh, beatPulse, a.beatPhase, kickSurge,
                          transientAmt, envelope, silence) * 2.5;
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Dynamic range ──
    col *= (0.25 + a.gated * 0.75);

    // ── Standard overlays (sparing) ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── Active-emitter normalization ──
    col *= sqrt(16.0 / seActiveCount(emit));

    // ── HDR limiter per pipeline rules ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
