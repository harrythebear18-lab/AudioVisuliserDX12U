// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 36: Spectral Helix — audio as a 3D DNA-style double helix
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_SPHERICAL.
//
// Concept: Audio encoded as a living double helix — two strands spiraling around
// a central axis. Strand A = left channel, Strand B = right channel. 8 frequency
// bands map to node positions along the axis (bass at base, highs at top). Each
// node glows and expands with band energy. Cross-rungs connect the strands at
// each band position, brightening with phase coherence. The helix extends into
// deep space with depth fog. Beat sends a pulse traveling up the axis. Kick
// flashes the base. Transient wobbles the backbone.
//
// Audio-to-visual mapping:
//   b0-b7       → 8 band nodes along helix axis (bass=base, highs=top)
//   L/R stereo  → two strands (A=left, B=right), offset by stereoDiff
//   beat        → pulse traveling up the helix axis
//   kick        → base flash eruption
//   transient   → backbone wobble distortion
//   envelope    → overall helix radius and glow
//   stereoBal   → axis tilt L/R
//   stereoWid   → strand separation distance
//   stereoDiff  → strand asymmetry
//   phaseCoh    → cross-rung brightness (high=bright connections, low=dim)
//   section     → rotation phase offset
//   phraseBeat  → slow breathing of helix radius
//   speechMode  → vocal band node brightening
//   calmMode    → slower rotation, reduced wobble
//   brightness  → node glow intensity
//   glow        → ambient helix glow
//   colorPulse  → subtle hue shift
//   beatAnt     → anticipatory node swell before beats
//
// DSP: LUFS→node brightness, crest→node edge sharpness, THD→backbone distortion,
//      phase→cross-rung coupling. HDR output to Layer 0. No local postfx.
// Performance: 8 nodes × 2 strands + 8 rungs + 2 backbones = ~28 projections/pixel.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define HELIX_LEN 4.0
#define N_SEG 10

// ── Helix backbone — continuous spiral curve for one strand ──
float3 helixBackbone(float2 p, SeCamera cam, int strand, AudioData a, float bands[8],
                     float phaseCoh, float thd, float transientAmt, float envelope,
                     float lufs, float silence)
{
    float3 col = float3(0, 0, 0);

    float strandSign = strand == 0 ? 1.0 : -1.0;
    float strandPhase = strand == 0 ? 0.0 : PI;  // opposite sides

    // Rotation — slow, VR-safe
    float rotSpeed = 0.08 * a.motSpeed * (1.0 - a.calmMode * 0.4);
    float baseRot = Time * rotSpeed + a.section * 0.5 + strandPhase;

    // Stereo tilt
    float tiltX = a.stereoBal * 0.3;

    // Base radius — envelope and phrase breathing
    float baseR = 0.5 + envelope * 0.3 + a.stereoWid * 0.2;
    float phraseBreath = sin(a.phraseBeat * PI * 2.0) * 0.08 + 0.08;
    baseR += phraseBreath;

    // Strand color
    float3 strandCol = strand == 0 ? a.brainCol : a.brainCol2;
    strandCol = lerp(strandCol, a.brainCol3, a.colorPulse * 0.02);

    [unroll] for (int seg = 0; seg < N_SEG; seg++) {
        float segFrac = float(seg) / float(N_SEG - 1);
        float axisY = lerp(-HELIX_LEN * 0.5, HELIX_LEN * 0.5, segFrac);

        // Which band does this segment belong to?
        int bandIdx = int(segFrac * 7.0 + 0.5);
        bandIdx = clamp(bandIdx, 0, 7);
        float bandEnergy = bands[bandIdx];

        // Helix angle at this height
        float angle = baseRot + segFrac * PI * 3.0;  // 1.5 turns over full length

        // Transient wobble
        float wobble = transientAmt * sin(segFrac * 20.0 + Time * 5.0) * 0.08;
        wobble *= (1.0 - a.calmMode * 0.7);

        // THD distortion
        float distort = thd * fbm2_4(float2(segFrac * 5.0, Time * 0.3)) * 0.05;

        // Radius at this point — band energy expands locally
        float segR = baseR * (1.0 + bandEnergy * 0.4) + wobble + distort;

        // Position in 3D
        float3 worldPos = float3(
            cos(angle) * segR + tiltX * segFrac,
            axisY,
            sin(angle) * segR
        );

        // Project to screen
        float2 scrPos = seProject(worldPos, cam);
        float depth = seDepth(worldPos, cam);
        if (depth < 0.1) continue;

        float2 diff = p - scrPos;
        float dist = length(diff);

        // Backbone thickness
        float thickness = 0.006 / max(depth * 0.15, 0.3);
        float glow = exp(-dist * dist / (thickness * thickness * 4.0));
        float core = exp(-dist * dist / (thickness * thickness * 0.5));

        // Depth fade
        float depthFade = exp(-depth * 0.06);

        // Intensity from band energy + envelope
        float intensity = (0.15 + bandEnergy * 0.5) * (1.0 + lufs * 0.2);
        intensity *= (0.7 + a.brightness * 0.3);
        intensity *= (1.0 - a.calmMode * 0.3);

        col += strandCol * glow * intensity * 0.04 * depthFade * silence;
        col += strandCol * core * intensity * 0.08 * depthFade * silence;
    }

    return col;
}

// ── Helix node — glowing sphere at each band position on each strand ──
float3 helixNode(float2 p, SeCamera cam, int bandIdx, int strand, float bandEnergy,
                 float bandFrac, AudioData a, float lufs, float crest, float thd,
                 float phaseCoh, float beatPulse, float beatPhase, float kickSurge,
                 float transientAmt, float envelope, float silence)
{
    float3 col = float3(0, 0, 0);

    float strandSign = strand == 0 ? 1.0 : -1.0;
    float strandPhase = strand == 0 ? 0.0 : PI;

    // Position along axis
    float axisY = lerp(-HELIX_LEN * 0.5, HELIX_LEN * 0.5, bandFrac);
    float tiltX = a.stereoBal * 0.3 * (bandFrac - 0.5) * 0.5;

    // Rotation
    float rotSpeed = 0.08 * a.motSpeed * (1.0 - a.calmMode * 0.4);
    float angle = Time * rotSpeed + a.section * 0.5 + strandPhase + bandFrac * PI * 3.0;

    // Transient wobble
    float wobble = transientAmt * sin(bandFrac * 20.0 + Time * 5.0) * 0.06;
    wobble *= (1.0 - a.calmMode * 0.7);

    // THD distortion
    float distort = thd * fbm2_4(float2(bandFrac * 5.0, Time * 0.3)) * 0.04;

    // Radius — band energy expands, envelope sustains, phrase breathes
    float baseR = 0.5 + envelope * 0.3 + a.stereoWid * 0.2;
    float phraseBreath = sin(a.phraseBeat * PI * 2.0 + bandFrac * PI) * 0.06;
    float nodeR = baseR * (1.0 + bandEnergy * 0.5) + wobble + distort + phraseBreath;

    // Stereo asymmetry — strand B slightly offset
    if (strand == 1) nodeR += a.stereoDiff * 0.05;

    // 3D position
    float3 worldPos = float3(
        cos(angle) * nodeR + tiltX,
        axisY,
        sin(angle) * nodeR
    );

    // Project
    float2 scrPos = seProject(worldPos, cam);
    float depth = seDepth(worldPos, cam);
    if (depth < 0.1) return col;

    float2 diff = p - scrPos;
    float dist = length(diff);

    // Node size — band energy makes it bigger
    float nodeSize = (0.015 + bandEnergy * 0.04) / max(depth * 0.15, 0.3);
    float glow = exp(-dist * dist / (nodeSize * nodeSize * 4.0));
    float core = exp(-dist * dist / (nodeSize * nodeSize * 0.4));

    // Crest sharpens node
    core *= (0.6 + crest * 0.4);

    // Depth fade
    float depthFade = exp(-depth * 0.06);

    // Intensity
    float intensity = bandEnergy * (1.0 + lufs * 0.3);
    intensity += envelope * 0.1;
    intensity += a.glow * 0.05;
    intensity += a.beatAnt * (0.3 + bandFrac * 0.2) * 0.15;
    // Speech mode boosts vocal bands
    float vocalWeight = smoothstep(2.5, 3.5, float(bandIdx)) * (1.0 - smoothstep(5.0, 6.0, float(bandIdx)));
    intensity += a.speechMode * vocalWeight * 0.25;
    intensity *= (0.7 + a.brightness * 0.3);
    intensity *= (1.0 - a.calmMode * 0.3);

    if (intensity < 0.02) return col;

    // Color — strand A = brainCol, strand B = brainCol2, subtle band variation
    float3 nodeCol = strand == 0 ? a.brainCol : a.brainCol2;
    nodeCol = lerp(nodeCol, a.brainCol3, bandFrac * 0.15);
    nodeCol = lerp(nodeCol, nodeCol.bgr, a.colorPulse * 0.02);
    nodeCol = lerp(nodeCol, a.brainCol2, a.speechMode * vocalWeight * 0.3);

    // Base glow
    col += nodeCol * glow * intensity * 0.08 * depthFade * silence;
    col += nodeCol * core * intensity * 0.18 * depthFade * silence;

    // Beat pulse traveling up the helix
    float beatOffset = bandFrac * 0.4;
    float beatWave = exp(-abs(frac(beatPhase + beatOffset) - 0.5) * 6.0) * beatPulse;
    col += nodeCol * core * beatWave * intensity * 0.12 * depthFade * silence;

    // Kick flash on bass nodes
    if (bandIdx <= 1) {
        col += float3(0.8, 0.4, 0.1) * core * kickSurge * intensity * 0.1 * depthFade * silence;
    }

    return col;
}

// ── Cross-rung — connection between strands at each band position ──
float3 helixRung(float2 p, SeCamera cam, int bandIdx, float bandEnergy, float bandFrac,
                 AudioData a, float phaseCoh, float thd, float envelope,
                 float transientAmt, float lufs, float silence)
{
    float3 col = float3(0, 0, 0);

    float axisY = lerp(-HELIX_LEN * 0.5, HELIX_LEN * 0.5, bandFrac);
    float tiltX = a.stereoBal * 0.3 * (bandFrac - 0.5) * 0.5;

    // Rotation — same as nodes
    float rotSpeed = 0.08 * a.motSpeed * (1.0 - a.calmMode * 0.4);
    float angle = Time * rotSpeed + a.section * 0.5 + bandFrac * PI * 3.0;

    // Transient wobble
    float wobble = transientAmt * sin(bandFrac * 20.0 + Time * 5.0) * 0.06;
    wobble *= (1.0 - a.calmMode * 0.7);
    float distort = thd * fbm2_4(float2(bandFrac * 5.0, Time * 0.3)) * 0.04;

    float baseR = 0.5 + envelope * 0.3 + a.stereoWid * 0.2;
    float phraseBreath = sin(a.phraseBeat * PI * 2.0 + bandFrac * PI) * 0.06;
    float nodeR = baseR * (1.0 + bandEnergy * 0.5) + wobble + distort + phraseBreath;

    // Strand A position
    float3 posA = float3(cos(angle) * nodeR + tiltX, axisY, sin(angle) * nodeR);
    // Strand B position (opposite side)
    float3 posB = float3(cos(angle + PI) * nodeR + tiltX, axisY, sin(angle + PI) * nodeR);

    // Draw line between posA and posB — sample 4 points along the rung
    float rungIntensity = bandEnergy * phaseCoh * (1.0 + lufs * 0.2);
    rungIntensity *= (0.7 + a.brightness * 0.3);
    rungIntensity *= (1.0 - a.calmMode * 0.3);

    if (rungIntensity < 0.02) return col;

    // Rung color — blend of both strand colors
    float3 rungCol = lerp(a.brainCol, a.brainCol2, 0.5);
    rungCol = lerp(rungCol, a.brainCol3, bandFrac * 0.15);

    [unroll] for (int ri = 0; ri <= 4; ri++) {
        float rt = float(ri) / 4.0;
        float3 rungPos = lerp(posA, posB, rt);
        float2 scrPos = seProject(rungPos, cam);
        float depth = seDepth(rungPos, cam);
        if (depth < 0.1) continue;

        float2 diff = p - scrPos;
        float dist = length(diff);
        float thickness = 0.004 / max(depth * 0.15, 0.3);
        float glow = exp(-dist * dist / (thickness * thickness * 3.0));
        float depthFade = exp(-depth * 0.06);

        col += rungCol * glow * rungIntensity * 0.06 * depthFade * silence;
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

    // ── Audio dynamics — full brain data ──
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — VR head pose or desktop slow orbit ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.6;
        // Very slow orbit around helix — VR-safe
        float camAng = a.section * 0.3 + Time * 0.01 * a.motSpeed;
        float3 camPos = float3(
            sin(camAng) * 3.5,
            0.5 + a.stereoDiff * 0.1 + sin(Time * 0.008) * 0.3,
            cos(camAng) * 3.5
        );
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder for emitter data ──
    SeParams params = seParams(SE_PROFILE_SPHERICAL);
    params.widthScale = 2.0;
    params.heightScale = 2.0;
    params.depthScale = 4.0;
    params.jitterAmt = 0.05 + thd * 0.1;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.05, float3(0.003, 0.004, 0.008), -2.0, 0.0, 0.0);
    world.gridIntensity = 0.01;
    world.ambientLevel = 0.003 + a.calmMode * 0.002;
    world.ambientColor = float3(0.005, 0.006, 0.012);
    seApplyWorldFog(emit, world);

    // ── Background ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.003;

    // ── Backbones — continuous spiral curves for both strands ──
    col += helixBackbone(p, cam, 0, a, bands, phaseCoh, thd, transientAmt, envelope, lufs, silence) * 2.0;
    col += helixBackbone(p, cam, 1, a, bands, phaseCoh, thd, transientAmt, envelope, lufs, silence) * 2.0;

    // ── Cross-rungs — connections between strands at each band ──
    [unroll] for (int ri = 0; ri < SE_N_BANDS; ri++) {
        float bandFrac = float(ri) / 7.0;
        col += helixRung(p, cam, ri, bands[ri], bandFrac, a, phaseCoh, thd,
                         envelope, transientAmt, lufs, silence) * 2.5;
    }

    // ── PRIMARY: 8 band nodes on each strand ──
    [unroll] for (int bi = 0; bi < SE_N_BANDS; bi++) {
        float bandFrac = float(bi) / 7.0;
        // Strand A (left)
        col += helixNode(p, cam, bi, 0, bands[bi], bandFrac, a, lufs, crest, thd,
                         phaseCoh, beatPulse, a.beatPhase, kickSurge,
                         transientAmt, envelope, silence) * 3.0;
        // Strand B (right)
        col += helixNode(p, cam, bi, 1, bands[bi], bandFrac, a, lufs, crest, thd,
                         phaseCoh, beatPulse, a.beatPhase, kickSurge,
                         transientAmt, envelope, silence) * 3.0;
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Kick — base flash ──
    col += float3(0.8, 0.4, 0.1) * exp(-r * r * 4.0) * kickSurge * 0.08 * silence;

    // ── Transient — subtle spark shimmer ──
    if (transientAmt > 0.05) {
        float spark = transientAmt * fbm2_4(p * 20.0 + Time * 8.0) * 0.03;
        col += a.brainCol3 * spark * silence;
    }

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
