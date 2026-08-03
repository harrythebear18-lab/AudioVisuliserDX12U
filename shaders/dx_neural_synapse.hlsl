// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 39: Spectral Bloom — 3D mandala flower of frequency band petals
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_HEMISPHERE.
//
// Concept: A 3D flower/mandala blooms in space. 8 petals, one per frequency
// band, extend outward from a central core. Each petal is a curved parametric
// surface that glows with its band energy. Beat sends a pulse radiating through
// all petals. Kick creates a central flash. Transient adds edge shimmer.
// Camera orbits the bloom. Phase coherence makes opposite petals mirror.
// Stereo balance rotates which petals face you. Very organic and distinct.
//
// Audio-to-visual mapping:
//   b0-b7       -> 8 petal glow intensity and extension
//   beat        -> pulse radiating through petals
//   kick        -> central core flash
//   transient   -> petal edge shimmer
//   envelope    -> overall bloom brightness
//   stereoBal   -> bloom rotation
//   stereoWid   -> petal spread
//   stereoDiff  -> vertical tilt
//   phaseCoh    -> opposite petal mirroring
//   section     -> rotation offset
//   phraseBeat  -> slow bloom breathing
//   speechMode  -> vocal petal brightening
//   calmMode    -> reduced shimmer, slower rotation
//   brightness  -> petal glow
//   glow        -> ambient bloom glow
//   colorPulse  -> hue shift
//   beatAnt     -> anticipatory petal swell
//
// DSP: LUFS->brightness, crest->petal edge sharpness, THD->surface noise,
//      phase->opposite petal sync. HDR output to Layer 0. No local postfx.
// Performance: 8 petal projections with 12 samples each = 96 per pixel.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define PETAL_N 12

// ── Petal point — parametric position on a curved petal surface ──
float3 petalPoint(float petalAng, float u, float v, float bandEnergy,
                  float beatPulse, float kickSurge, float phraseBeat)
{
    // u: along petal length (0=center, 1=tip)
    // v: across petal width (0=left edge, 0.5=center, 1=right edge)

    // Petal extends outward in its angular direction
    float radius = u * 2.5 * (0.7 + bandEnergy * 0.4);

    // Petal width narrows toward tip — leaf shape
    float widthShape = sin(u * PI) * 0.6;
    float lateral = (v - 0.5) * widthShape;

    // Curve the petal — slight upward bow
    float bow = sin(u * PI) * 0.5;

    // Beat pulse extends petals outward
    radius += beatPulse * 0.3 * sin(u * PI);

    // Phrase breathing
    radius *= 1.0 + sin(phraseBeat * PI * 2.0) * 0.08;

    // Position in petal's local frame
    float3 local = float3(
        cos(petalAng) * radius - sin(petalAng) * lateral,
        bow + kickSurge * 0.1 * sin(u * PI),
        sin(petalAng) * radius + cos(petalAng) * lateral
    );

    return local;
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
    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — orbiting the bloom ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.95;
        float camAng = a.section * 0.3 + a.stereoBal * 0.3 + Time * 0.04 * a.motSpeed;
        float camHeight = 2.5 + sin(Time * 0.03) * 0.5 + a.stereoDiff * 0.2;
        float camDist = 3.0;
        float3 camPos = float3(sin(camAng) * camDist, camHeight, cos(camAng) * camDist);
        float3 camTarget = float3(0.0, sin(Time * 0.02) * 0.3, 0.0);
        cam = seCamera(camPos, camTarget, FOV);
    }

    // ── Spatial encoder for normalization ──
    SeParams params = seParams(SE_PROFILE_HEMISPHERE);
    params.widthScale = 2.0;
    params.heightScale = 2.0;
    params.depthScale = 2.0;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;
    params.motionSpeed = 0.8 * (1.0 - a.calmMode * 0.3);
    params.jitterAmt = 0.2 + thd * 0.3;

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── Background ──
    float3 col = float3(0.003, 0.002, 0.005) * silence;
    col += starfield(uv, a) * 0.006;
    float nebula = fbm2_4(p * 0.5 + Time * 0.002 * a.motSpeed);
    col += a.brainCol * nebula * 0.005 * a.ambient * a.ambActive * silence;

    // ── Bloom rotation ──
    float bloomRot = Time * 0.02 * a.motSpeed + a.section * 0.2;
    float bloomTilt = a.stereoDiff * 0.15 + sin(Time * 0.015) * 0.05;

    // ── Petal color helper ──
    // 8 petals with cohesive brain palette
    float3 petalColors[8] = {
        lerp(a.brainCol, a.brainCol2, 0.0),
        lerp(a.brainCol, a.brainCol2, 0.07),
        lerp(a.brainCol, a.brainCol2, 0.14),
        lerp(a.brainCol, a.brainCol2, 0.21),
        lerp(a.brainCol, a.brainCol2, 0.29),
        lerp(a.brainCol, a.brainCol2, 0.36),
        lerp(a.brainCol, a.brainCol2, 0.43),
        lerp(a.brainCol, a.brainCol2, 0.5),
    };
    [unroll] for (int ci = 0; ci < 8; ci++) {
        petalColors[ci] = lerp(petalColors[ci], a.brainCol3, float(ci) / 7.0 * 0.2);
        petalColors[ci] = lerp(petalColors[ci], petalColors[ci].bgr, a.colorPulse * 0.02);
    }

    // ── PRIMARY: 8 petals ──
    [loop] for (int petal = 0; petal < 8; petal++) {
        float bandFrac = float(petal) / 7.0;
        float petalAng = bandFrac * PI * 2.0 + bloomRot;
        float bandE = bands[petal];

        // Intensity
        float intensity = bandE * (1.0 + lufs * 0.3);
        intensity += envelope * 0.08;
        intensity += a.glow * 0.04;
        intensity += a.beatAnt * 0.15;
        intensity *= (0.7 + a.brightness * 0.3);
        intensity *= (1.0 - a.calmMode * 0.3);

        // Vocal band boost
        float vocalWeight = smoothstep(2.5, 3.5, float(petal)) * (1.0 - smoothstep(5.0, 6.0, float(petal)));
        intensity += a.speechMode * vocalWeight * 0.2;

        if (intensity < 0.02) continue;

        float3 petalCol = petalColors[petal];
        petalCol = lerp(petalCol, a.brainCol2, a.speechMode * vocalWeight * 0.3);

        // Sample petal as a grid of points — project each to screen
        // Use sparse sampling for performance: PETAL_N points along length, 3 across
        [loop] for (int si = 0; si < PETAL_N; si++) {
            float u = (float(si) + 0.5) / float(PETAL_N);
            [unroll] for (int sv = 0; sv < 3; sv++) {
                float v = (float(sv) + 0.5) / 3.0;

                float3 worldPos = petalPoint(petalAng, u, v, bandE, beatPulse, kickSurge, a.phraseBeat);
                // Apply tilt
                worldPos.y = worldPos.y * cos(bloomTilt) - worldPos.z * sin(bloomTilt);
                worldPos.z = worldPos.y * sin(bloomTilt) + worldPos.z * cos(bloomTilt);

                float3 toPt = worldPos - cam.pos;
                float depth = dot(toPt, cam.fwd);
                if (depth < 0.1) continue;

                float sx = dot(toPt, cam.right) / depth * cam.fov;
                float sy = dot(toPt, cam.up) / depth * cam.fov;
                float2 screenPos = float2(sx, sy);

                float2 diff = p - screenPos;
                float dist2 = dot(diff, diff);

                // Point size scales with band energy and depth
                float ptSize = 0.008 + bandE * 0.02;
                ptSize /= max(depth * 0.2, 0.1);
                float ptSize2 = ptSize * ptSize;

                if (dist2 > ptSize2 * 4.0) continue;

                float depthFade = exp(-depth * 0.08);

                // FBM texture on petal surface
                float2 surfUV = float2(u * 4.0, v * 3.0 + float(petal));
                float texture = fbm2_4(surfUV + Time * 0.2 * a.motSpeed);
                texture += transientAmt * fbm2_4(surfUV * 2.0 + Time * 5.0) * 0.3;
                texture += thd * fbm2_4(surfUV * 4.0) * 0.1;
                texture = lerp(texture, 0.5, a.calmMode * 0.5);

                // Glow profile
                float glow = exp(-dist2 / (ptSize2 * 0.5));
                float core = exp(-dist2 / (ptSize2 * 0.15));

                // Edge brightness — petal edges glow more
                float edgeFactor = smoothstep(0.3, 0.5, abs(v - 0.5));
                float tipFactor = smoothstep(0.7, 1.0, u);

                float3 ptCol = petalCol * (glow * 0.15 + core * 0.25) * intensity * depthFade * silence;
                ptCol += petalCol * texture * glow * intensity * 0.08 * depthFade * silence;
                ptCol += petalCol * edgeFactor * glow * intensity * 0.06 * depthFade * silence;
                ptCol += petalCol * tipFactor * core * intensity * 0.1 * depthFade * silence;

                // Beat pulse radiating from center to tip
                float beatRad = a.beatPhase;
                float beatDist = abs(u - beatRad);
                float beatWave = exp(-beatDist * beatDist * 20.0) * beatPulse;
                ptCol += petalCol * core * beatWave * intensity * 0.2 * depthFade * silence;

                // Crest sharpens edges
                ptCol += petalCol * core * crest * intensity * 0.05 * depthFade * silence;

                col += ptCol;
            }
        }
    }

    // ── Central core — glowing center of the bloom ──
    {
        float3 corePos = float3(0.0, 0.0, 0.0);
        float3 toCore = corePos - cam.pos;
        float coreDepth = dot(toCore, cam.fwd);
        if (coreDepth > 0.1) {
            float2 coreScreen = float2(dot(toCore, cam.right) / coreDepth * cam.fov,
                                        dot(toCore, cam.up) / coreDepth * cam.fov);
            float2 coreDiff = p - coreScreen;
            float coreD2 = dot(coreDiff, coreDiff);
            float coreSize = 0.02 / max(coreDepth * 0.2, 0.1);
            float coreGlow = exp(-coreD2 / (coreSize * coreSize * 0.3));
            float coreHalo = exp(-coreD2 / (coreSize * coreSize * 5.0));

            float coreIntensity = (a.b0 + a.b1) * 0.5 * (1.0 + lufs * 0.3);
            coreIntensity += envelope * 0.1;
            coreIntensity += a.glow * 0.05;
            coreIntensity *= (0.7 + a.brightness * 0.3);

            float3 coreCol = lerp(a.brainCol, a.brainCol3, 0.3);
            col += coreCol * (coreGlow * 0.3 + coreHalo * 0.08) * coreIntensity * silence;
            col += coreCol * coreGlow * kickSurge * 0.15 * silence;
            col += coreCol * coreGlow * beatPulse * 0.08 * silence;
        }
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Beat — radial pulse ──
    float ringDist = abs(r - a.beatPhase * 0.5);
    col += a.brainCol * exp(-ringDist * ringDist * 50.0) * beatPulse * 0.03 * silence;

    // ── Kick — central flash ──
    col += float3(0.8, 0.4, 0.1) * kickSurge * 0.06 * exp(-r * r * 4.0) * silence;

    // ── Transient shimmer ──
    if (transientAmt > 0.05) {
        col += a.brainCol3 * transientAmt * fbm2_4(p * 12.0 + Time * 5.0) * 0.015 * silence;
    }

    // ── Phrase breathing ──
    float phraseMod = sin(a.phraseBeat * PI * 2.0) * 0.02 + 0.02;
    col += a.brainCol * phraseMod * silence;

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
