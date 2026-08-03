// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 35: Spectral Strata — audio as glowing atmospheric layers in a 3D canyon
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_TUNNEL.
//
// Concept: Sound has spectral depth — bass sits low, highs float high. This mode
// visualizes that as geological-style strata: 8 horizontal fog layers at different
// heights, each driven by a frequency band. The camera drifts through a canyon
// of glowing layers. Bass = thick dense low strata, highs = thin wispy high strata.
// Beat = vertical pulse traveling up through layers. Kick = ground eruption glow.
// Stereo = layers tilt L/R. Phase = layer coherence. Transient = layer disruption.
//
// Audio-to-visual mapping:
//   b0 (sub)    → lowest stratum (thick, dense, warm)
//   b1 (bass)   → low stratum (thick, warm)
//   b2-b5 (mids)→ middle strata (medium, brain palette)
//   b6-b7 (highs)→ high strata (thin, wispy, cool)
//   beat        → vertical pulse traveling up through all layers
//   kick        → ground eruption glow from canyon floor
//   transient   → layer disruption (FBM turbulence spike)
//   envelope    → overall strata density
//   stereoBal   → layers tilt L/R
//   stereoWid   → canyon width
//   phaseCoh    → coherent (flat layers) vs turbulent (wavy layers)
//   section     → camera drift repositioning
//   phraseBeat  → slow evolution of layer pattern
//   speechMode  → vocal band (b3-b5) layer brightening
//   calmMode    → reduced turbulence, thinner layers
//   brightness  → strata glow intensity
//   glow        → ambient canyon glow
//   colorPulse  → subtle hue shift
//   beatAnt     → anticipatory layer swell before beats
//
// DSP: LUFS→strata density, crest→layer edge sharpness, THD→turbulence,
//      phase→layer coherence. HDR output to Layer 0. No local postfx.
// Performance: 8 plane intersections + FBM per pixel. No raymarching.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// ── Stratum layer — one frequency band rendered as a horizontal fog plane ──
float3 stratumLayer(float2 p, float r, SeCamera cam, int bandIdx, float bandEnergy,
                    float bandFrac, AudioData a, float lufs, float crest, float thd,
                    float phaseCoh, float beatPulse, float beatPhase, float kickSurge,
                    float transientAmt, float envelope, float silence)
{
    float3 col = float3(0, 0, 0);

    // Layer height — bass at bottom, highs at top
    float layerY = lerp(-1.2, 2.8, bandFrac);
    // Layer thickness — bass = thick, highs = thin
    float layerThickness = lerp(0.6, 0.15, bandFrac);
    // Stereo tilt — layers lean with stereo balance
    float tiltOffset = a.stereoBal * 0.4 * (layerY + 1.2) * 0.3;

    // Ray-plane intersection for this layer
    float3 rd = normalize(cam.fwd + p.x * cam.right * cam.fov + p.y * cam.up * cam.fov);
    float tLayer = (layerY + tiltOffset - cam.pos.y) / (rd.y + 1e-5);
    if (tLayer <= 0.0 || tLayer > 40.0) return col;

    float3 hitPos = cam.pos + rd * tLayer;
    float2 layerUV = hitPos.xz;

    // Canyon boundaries — fade out beyond walls
    float canyonHalfW = 3.0 + a.stereoWid * 1.0;
    float canyonFade = smoothstep(canyonHalfW, canyonHalfW * 0.5, abs(layerUV.x));
    if (canyonFade < 0.01) return col;

    // Depth fade
    float depthFade = exp(-tLayer * 0.06) * smoothstep(0.0, 3.0, tLayer);

    // FBM noise for layer texture — THD and phase coherence modulate turbulence
    float2 noiseUV = layerUV * lerp(0.3, 1.0, bandFrac) + float2(Time * 0.15, Time * 0.1);
    float turbulence = fbm2_4(noiseUV);
    // Phase incoherence adds waviness
    float waveAmt = (1.0 - phaseCoh) * 0.3;
    float wavy = fbm2_4(noiseUV * 2.0 + Time * 0.2) * waveAmt;
    // THD adds roughness
    turbulence *= (1.0 + thd * 0.4);
    // Calm mode reduces turbulence
    turbulence *= (1.0 - a.calmMode * 0.5);

    // Layer density from band energy + enrichment
    float density = bandEnergy * (1.0 + lufs * 0.3);
    // Envelope sustains
    density += envelope * 0.15;
    // Glow modifier
    density += a.glow * 0.08;
    // Beat anticipation swell
    density += a.beatAnt * (0.3 + bandFrac * 0.2) * 0.2;
    // Speech mode boosts vocal bands
    float vocalWeight = smoothstep(2.5, 3.5, float(bandIdx)) * (1.0 - smoothstep(5.0, 6.0, float(bandIdx)));
    density += a.speechMode * vocalWeight * 0.25;
    // Brightness scales
    density *= (0.7 + a.brightness * 0.3);
    // Calm mode reduces
    density *= (1.0 - a.calmMode * 0.3);

    if (density < 0.02) return col;

    // Layer edge falloff — soft top and bottom
    float layerProfile = exp(-abs(turbulence - 0.5) * 2.0) * (1.0 + wavy);
    // Crest sharpens edges
    layerProfile = pow(layerProfile, lerp(0.7, 1.5, crest));

    // Canyon depth — fade with distance into canyon
    float canyonDepth = smoothstep(0.0, 10.0, -layerUV.y) * smoothstep(-40.0, -10.0, layerUV.y);

    // Color — cohesive brain palette with subtle band variation
    float3 layerCol = lerp(a.brainCol, a.brainCol2, bandFrac * 0.5);
    layerCol = lerp(layerCol, a.brainCol3, bandFrac * 0.2);
    // Color pulse subtle hue shift
    layerCol = lerp(layerCol, layerCol.bgr, a.colorPulse * 0.02);
    // Speech mode shifts vocal bands
    layerCol = lerp(layerCol, a.brainCol2, a.speechMode * vocalWeight * 0.3);

    // Base layer glow
    float glowAmt = density * layerProfile * canyonFade * canyonDepth * depthFade * silence;
    col += layerCol * glowAmt * 0.06 * layerThickness;

    // Bright core where density is high
    float coreAmt = pow(glowAmt, 1.5) * 0.1;
    col += layerCol * coreAmt;

    // Beat pulse traveling up through layers — phase offset by height
    float beatOffset = bandFrac * 0.4;
    float beatWave = exp(-abs(frac(beatPhase + beatOffset) - 0.5) * 6.0) * beatPulse;
    col += layerCol * beatWave * glowAmt * 0.15;

    // Kick flash on lowest layers
    if (bandIdx <= 1) {
        col += float3(0.8, 0.4, 0.1) * kickSurge * glowAmt * 0.1;
    }

    // Transient disruption — bright spots in layer
    if (transientAmt > 0.08) {
        float disrupt = fbm2_4(noiseUV * 3.0 + Time * 0.5) * transientAmt;
        col += layerCol * disrupt * glowAmt * 0.08;
    }

    // Phrase evolution — slow intensity breathing
    float phraseMod = sin(a.phraseBeat * PI * 2.0 + bandFrac * PI) * 0.1 + 0.1;
    col += layerCol * phraseMod * glowAmt * 0.03;

    return col;
}

// ── Canyon floor — ground plane with bass-driven glow ──
float3 canyonFloor(float2 p, SeCamera cam, AudioData a, float kickSurge,
                   float beatPulse, float beatPhase, float lufs, float silence)
{
    float3 col = float3(0, 0, 0);
    float3 rd = normalize(cam.fwd + p.x * cam.right * cam.fov + p.y * cam.up * cam.fov);
    float tFloor = (-1.5 - cam.pos.y) / (rd.y + 1e-5);
    if (tFloor <= 0.0 || tFloor > 40.0) return col;

    float3 hitPos = cam.pos + rd * tFloor;
    float2 floorUV = hitPos.xz;

    // Canyon floor grid
    float2 gridUV = float2(floorUV.x * 2.0, -floorUV.y * 1.5);
    float2 gridId = abs(frac(gridUV) - 0.5);
    float gridLine = smoothstep(0.4, 0.5, max(gridId.x, gridId.y));
    float gridFade = smoothstep(0.0, 5.0, tFloor) * smoothstep(35.0, 10.0, tFloor);

    // Bass energy drives floor glow
    float bassE = (a.b0 + a.b1) * 0.5 * (1.0 + lufs * 0.3);
    col += a.brainCol * gridLine * 0.03 * gridFade * silence;
    col += a.brainCol * bassE * gridLine * 0.12 * gridFade * silence;

    // Kick eruption — central glow on floor
    float floorR = length(floorUV);
    float kickGlow = exp(-floorR * floorR * 0.5) * kickSurge;
    col += float3(0.8, 0.4, 0.1) * kickGlow * gridLine * 0.15 * gridFade * silence;
    col += float3(0.8, 0.4, 0.1) * kickGlow * 0.04 * gridFade * silence;

    // Beat ripple on floor
    float beatR = beatPhase * 4.0;
    float beatRing = exp(-abs(floorR - beatR) * 3.0) * beatPulse;
    col += a.brainCol2 * beatRing * gridLine * 0.08 * gridFade * silence;

    // Wet reflection look — subtle
    float reflFade = smoothstep(0.0, 3.0, tFloor) * smoothstep(30.0, 5.0, tFloor);
    col += a.brainCol3 * a.glow * 0.01 * reflFade * silence;

    return col;
}

// ── Canyon walls — subtle vertical glow on side walls ──
float3 canyonWalls(float2 p, SeCamera cam, AudioData a, float envelope,
                   float lufs, float silence)
{
    float3 col = float3(0, 0, 0);
    float3 rd = normalize(cam.fwd + p.x * cam.right * cam.fov + p.y * cam.up * cam.fov);

    float canyonHalfW = 3.0 + a.stereoWid * 1.0;

    // Left wall
    float tLeft = (-canyonHalfW - cam.pos.x) / (rd.x + 1e-5);
    if (tLeft > 0.0 && tLeft < 40.0) {
        float3 hitPos = cam.pos + rd * tLeft;
        float2 wallUV = float2(hitPos.y * 1.5, -hitPos.z * 1.2);
        float2 wallId = abs(frac(wallUV) - 0.5);
        float wallLine = smoothstep(0.42, 0.5, max(wallId.x, wallId.y));
        float wallFade = smoothstep(0.0, 5.0, tLeft) * smoothstep(35.0, 8.0, tLeft);
        float wallGlow = envelope * (0.3 + lufs * 0.2) * (1.0 + a.b2 * 0.3 + a.b3 * 0.3);
        col += a.brainCol * wallLine * wallGlow * 0.04 * wallFade * silence;
    }

    // Right wall
    float tRight = (canyonHalfW - cam.pos.x) / (rd.x + 1e-5);
    if (tRight > 0.0 && tRight < 40.0) {
        float3 hitPos = cam.pos + rd * tRight;
        float2 wallUV = float2(hitPos.y * 1.5, -hitPos.z * 1.2);
        float2 wallId = abs(frac(wallUV) - 0.5);
        float wallLine = smoothstep(0.42, 0.5, max(wallId.x, wallId.y));
        float wallFade = smoothstep(0.0, 5.0, tRight) * smoothstep(35.0, 8.0, tRight);
        float wallGlow = envelope * (0.3 + lufs * 0.2) * (1.0 + a.b4 * 0.3 + a.b5 * 0.3);
        col += a.brainCol2 * wallLine * wallGlow * 0.04 * wallFade * silence;
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

    // ── Camera — VR head pose or slow drift through canyon ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.7;
        // Very slow forward drift with gentle sway — VR-safe
        float driftSpeed = 0.5 * a.motSpeed * (1.0 - a.calmMode * 0.3);
        float3 camPos = float3(
            sin(Time * 0.02 * driftSpeed + a.stereoBal * 0.5) * 1.5,
            0.5 + a.stereoDiff * 0.1 + sin(Time * 0.01) * 0.2,
            -Time * 0.15 * driftSpeed
        );
        // Wrap Z for infinite canyon
        camPos.z = fmod(camPos.z, 30.0) - 15.0;
        cam = seCamera(camPos, float3(a.stereoBal * 0.1, 0.3, camPos.z - 5.0), FOV);
    }

    // ── Spatial encoder for emitter data (world fog + listener) ──
    SeParams params = seParams(SE_PROFILE_TUNNEL);
    params.widthScale = 2.0 + a.stereoWid * 0.5;
    params.heightScale = 2.0;
    params.depthScale = 8.0 - a.calmMode * 0.5;
    params.jitterAmt = 0.1 + thd * 0.15;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.06, float3(0.003, 0.002, 0.008), -1.5, 0.0, 0.0);
    world.gridScale = 2.0;
    world.gridIntensity = 0.02;
    world.ambientLevel = 0.003 + a.calmMode * 0.002;
    world.ambientColor = float3(0.008, 0.006, 0.015);
    seApplyWorldFog(emit, world);

    // ── Background: world environment + starfield ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.003;

    // ── Canyon walls — subtle vertical glow ──
    col += canyonWalls(p, cam, a, envelope, lufs, silence) * 2.0;

    // ── Canyon floor — bass-driven grid glow + kick eruption ──
    col += canyonFloor(p, cam, a, kickSurge, beatPulse, a.beatPhase, lufs, silence) * 2.0;

    // ── PRIMARY: 8 spectral strata — one per frequency band ──
    [loop] for (int bi = 0; bi < SE_N_BANDS; bi++) {
        float bandFrac = float(bi) / 7.0;
        col += stratumLayer(p, r, cam, bi, bands[bi], bandFrac, a, lufs, crest, thd,
                            phaseCoh, beatPulse, a.beatPhase, kickSurge,
                            transientAmt, envelope, silence) * 3.0;
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
