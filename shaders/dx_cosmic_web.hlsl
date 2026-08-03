// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 37: Spectral Ribbon — a flowing 3D river of light
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_SPHERICAL.
//
// Concept: A continuous ribbon of light flows through 3D space in a serpentine
// path. 8 frequency band segments along its length, each glowing with its
// band energy. The ribbon has width and twists as it flows. Beat sends pulses
// traveling along it. Kick creates a sharp flex. Transient adds turbulence.
// Camera flies alongside the ribbon. Depth fog gives real 3D perspective.
//
// Audio-to-visual mapping:
//   b0-b7       -> 8 segments along ribbon length
//   beat        -> pulse traveling along ribbon
//   kick        -> sharp flex/displacement
//   transient   -> turbulence in ribbon path
//   envelope    -> overall ribbon brightness
//   stereoBal   -> ribbon shifts L/R
//   stereoWid   -> ribbon amplitude
//   stereoDiff  -> ribbon asymmetry
//   phaseCoh    -> ribbon coherence (smooth vs chaotic)
//   section     -> camera position along ribbon
//   phraseBeat  -> slow ribbon breathing
//   speechMode  -> vocal segment brightening
//   calmMode    -> reduced turbulence
//   brightness  -> ribbon glow
//   glow        -> ambient glow
//   colorPulse  -> hue shift
//   beatAnt     -> anticipatory swell
//
// DSP: LUFS->brightness, crest->edge sharpness, THD->turbulence,
//      phase->smoothness. HDR output to Layer 0. No local postfx.
// Performance: 48 point projections along ribbon = 48 per pixel.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define RIBBON_N 48

// ── 3D ribbon point — parametric position along the flowing ribbon ──
float3 ribbonPoint(float t, AudioData a, float kickSurge, float transientAmt,
                   float thd, float phaseCoh, float phraseBeat)
{
    // Serpentine path — flows forward in Z, waves in X and Y
    float z = (t - 0.5) * 12.0;  // -6 to +6

    // X displacement — stereo width + band-driven waves
    float xWave = sin(t * PI * 3.0 + Time * 0.5 * a.motSpeed) * 2.5;
    xWave *= (0.6 + a.stereoWid * 0.4);
    xWave += a.stereoBal * 1.5;

    // Y displacement — vertical undulation
    float yWave = sin(t * PI * 2.0 + Time * 0.3 * a.motSpeed + 1.5) * 1.5;
    yWave += cos(t * PI * 5.0 + Time * 0.4) * 0.3 * (1.0 - a.calmMode);

    // Kick flex — sharp displacement near t=0.3
    float kickFlex = exp(-pow(t - 0.3, 2.0) * 20.0) * kickSurge * 2.0;
    yWave += kickFlex;

    // Transient turbulence
    float turb = sin(t * 30.0 + Time * 10.0) * transientAmt * 0.5;
    turb += sin(t * 50.0 + Time * 15.0) * thd * 0.3;
    turb *= (1.0 - a.calmMode * 0.5);
    xWave += turb;

    // Phase coherence — low coherence adds chaos
    float chaos = sin(t * 20.0 + Time * 3.0) * (1.0 - phaseCoh) * 0.5;
    xWave += chaos;

    // Phrase breathing — slow amplitude modulation
    float breathe = 1.0 + sin(phraseBeat * PI * 2.0) * 0.15;
    xWave *= breathe;
    yWave *= breathe;

    return float3(xWave, yWave, z);
}

// ── Band lookup for ribbon segment ──
float bandAt(float t, float b0, float b1, float b2, float b3, float b4, float b5, float b6, float b7)
{
    float s = saturate(t) * 7.0;
    if (s < 1.0) return lerp(b0, b1, frac(s));
    if (s < 2.0) return lerp(b1, b2, frac(s));
    if (s < 3.0) return lerp(b2, b3, frac(s));
    if (s < 4.0) return lerp(b3, b4, frac(s));
    if (s < 5.0) return lerp(b4, b5, frac(s));
    if (s < 6.0) return lerp(b5, b6, frac(s));
    return lerp(b6, b7, frac(s));
}

float3 bandColorAt(float t, AudioData a)
{
    float s = saturate(t) * 7.0;
    float frac_s = frac(s);
    float3 c0, c1;
    if (s < 1.0) { c0 = a.brainCol; c1 = lerp(a.brainCol, a.brainCol2, 0.071); }
    else if (s < 2.0) { c0 = lerp(a.brainCol, a.brainCol2, 0.071); c1 = lerp(a.brainCol, a.brainCol2, 0.143); }
    else if (s < 3.0) { c0 = lerp(a.brainCol, a.brainCol2, 0.143); c1 = lerp(a.brainCol, a.brainCol2, 0.214); }
    else if (s < 4.0) { c0 = lerp(a.brainCol, a.brainCol2, 0.214); c1 = lerp(a.brainCol, a.brainCol2, 0.286); }
    else if (s < 5.0) { c0 = lerp(a.brainCol, a.brainCol2, 0.286); c1 = lerp(a.brainCol, a.brainCol2, 0.357); }
    else if (s < 6.0) { c0 = lerp(a.brainCol, a.brainCol2, 0.357); c1 = lerp(a.brainCol, a.brainCol2, 0.429); }
    else { c0 = lerp(a.brainCol, a.brainCol2, 0.429); c1 = lerp(a.brainCol, a.brainCol2, 0.5); }
    c0 = lerp(c0, a.brainCol3, s / 7.0 * 0.2);
    c1 = lerp(c1, a.brainCol3, (s + 1.0) / 7.0 * 0.2);
    return lerp(c0, c1, frac_s);
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

    // ── Audio dynamics ──
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — flying alongside the ribbon ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.7;
        // Camera offset to the side, slowly drifting
        float camSide = 4.0 + sin(Time * 0.04) * 0.5;
        float camHeight = 1.0 + sin(Time * 0.03) * 0.5 + a.stereoDiff * 0.3;
        float3 camPos = float3(camSide, camHeight, 0.0);
        // Look at center of ribbon, slight drift
        float3 camTarget = float3(a.stereoBal * 0.5, 0.0, sin(Time * 0.02) * 1.0);
        cam = seCamera(camPos, camTarget, FOV);
    }

    // ── Spatial encoder for normalization ──
    SeParams params = seParams(SE_PROFILE_SPHERICAL);
    params.widthScale = 2.0;
    params.heightScale = 2.0;
    params.depthScale = 2.0;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;
    params.motionSpeed = 1.0;
    params.jitterAmt = 0.3;

    float bandsArr[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bandsArr, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── Background ──
    float3 col = float3(0.003, 0.002, 0.005) * silence;
    col += starfield(uv, a) * 0.006;
    float nebula = fbm2_4(p * 0.6 + Time * 0.002 * a.motSpeed);
    col += a.brainCol * nebula * 0.005 * a.ambient * a.ambActive * silence;

    // ── PRIMARY: Ribbon rendering ──
    // Project all ribbon points to screen space
    float3 ribbonPos[RIBBON_N];
    float2 ribbonScreen[RIBBON_N];
    float ribbonDepth[RIBBON_N];

    [unroll] for (int i = 0; i < RIBBON_N; i++) {
        float t = float(i) / float(RIBBON_N - 1);
        ribbonPos[i] = ribbonPoint(t, a, kickSurge, transientAmt, thd, phaseCoh, a.phraseBeat);
        float3 toPt = ribbonPos[i] - cam.pos;
        float depth = dot(toPt, cam.fwd);
        ribbonDepth[i] = depth;
        if (depth > 0.1) {
            float sx = dot(toPt, cam.right) / depth * cam.fov;
            float sy = dot(toPt, cam.up) / depth * cam.fov;
            ribbonScreen[i] = float2(sx, sy);
        } else {
            ribbonScreen[i] = float2(999.0, 999.0);
            ribbonDepth[i] = 0.01;
        }
    }

    // Render ribbon as connected segments with width
    [loop] for (int seg = 0; seg < RIBBON_N - 1; seg++) {
        float t0 = float(seg) / float(RIBBON_N - 1);
        float t1 = float(seg + 1) / float(RIBBON_N - 1);

        if (ribbonDepth[seg] < 0.1 || ribbonDepth[seg + 1] < 0.1) continue;

        float2 s0 = ribbonScreen[seg];
        float2 s1 = ribbonScreen[seg + 1];
        float avgDepth = (ribbonDepth[seg] + ribbonDepth[seg + 1]) * 0.5;
        float depthFade = exp(-avgDepth * 0.06);

        // Distance from pixel to ribbon segment
        float2 ab = s1 - s0;
        float lenSq = dot(ab, ab);
        if (lenSq < 0.0001) continue;
        float tt = clamp(dot(p - s0, ab) / lenSq, 0.0, 1.0);
        float2 closest = s0 + ab * tt;
        float dist = length(p - closest);
        float dist2 = dist * dist;

        // Ribbon width — scales with band energy and depth
        float bandE0 = bandAt(t0, a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7);
        float bandE1 = bandAt(t1, a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7);
        float bandE = lerp(bandE0, bandE1, tt);
        float ribbonW = 0.015 + bandE * 0.03;
        ribbonW /= max(avgDepth * 0.15, 0.1);

        if (dist2 > ribbonW * ribbonW * 4.0) continue;

        // Intensity
        float intensity = bandE * (1.0 + lufs * 0.3);
        intensity += envelope * 0.1;
        intensity += a.glow * 0.05;
        intensity += a.beatAnt * 0.2;
        intensity *= (0.7 + a.brightness * 0.3);
        intensity *= (1.0 - a.calmMode * 0.3);

        // Vocal band boost
        float vocalWeight = smoothstep(0.3, 0.4, t0) * (1.0 - smoothstep(0.6, 0.7, t0));
        intensity += a.speechMode * vocalWeight * 0.25;

        // Color
        float3 ribCol = bandColorAt(lerp(t0, t1, tt), a);
        ribCol = lerp(ribCol, ribCol.bgr, a.colorPulse * 0.02);
        ribCol = lerp(ribCol, a.brainCol2, a.speechMode * vocalWeight * 0.3);

        // Glow profile — core + halo
        float core = exp(-dist2 / (ribbonW * ribbonW * 0.3));
        float halo = exp(-dist2 / (ribbonW * ribbonW * 3.0));

        float3 segCol = ribCol * (core * 0.4 + halo * 0.15) * intensity * depthFade * silence;

        // Beat pulse traveling along ribbon
        float beatPos = frac(a.beatPhase);
        float beatDist = abs(tt - beatPos);
        float beatWave = exp(-beatDist * beatDist * 30.0) * beatPulse;
        segCol += ribCol * core * beatWave * intensity * 0.3 * depthFade * silence;

        // Kick flash on bass segment
        if (t0 < 0.2) {
            segCol += float3(0.8, 0.4, 0.1) * kickSurge * core * 0.15 * depthFade * silence;
        }

        // Crest sharpens core
        segCol += ribCol * core * crest * intensity * 0.08 * depthFade * silence;

        // Phrase breathing
        float phraseMod = sin(a.phraseBeat * PI * 2.0 + t0 * PI * 3.0) * 0.08 + 0.08;
        segCol += ribCol * halo * phraseMod * intensity * 0.05 * depthFade * silence;

        col += segCol;
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Beat — radial pulse ──
    float ringDist = abs(r - a.beatPhase * 0.5);
    col += a.brainCol * exp(-ringDist * ringDist * 50.0) * beatPulse * 0.03 * silence;

    // ── Kick — central flash ──
    col += float3(0.8, 0.4, 0.1) * kickSurge * 0.06 * exp(-r * r * 5.0) * silence;

    // ── Transient shimmer ──
    if (transientAmt > 0.05) {
        col += a.brainCol3 * transientAmt * fbm2_4(p * 12.0 + Time * 5.0) * 0.015 * silence;
    }

    // ── Dynamic range ──
    col *= (0.5 + a.gated * 0.5);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.015;

    // ── Active-emitter normalization ──
    col *= sqrt(24.0 / seActiveCount(emit));

    // ── HDR limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
