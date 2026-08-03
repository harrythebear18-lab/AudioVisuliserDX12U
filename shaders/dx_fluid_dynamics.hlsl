// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 33: Fluid Dynamics — audio-reactive liquid surface with specular shading
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_PSYCHOACOUSTIC.
//
// Concept: A dark reflective liquid pool where each audio source creates ripples.
// Bass = large swells, mids = vortex ripples, highs = capillary turbulence.
// The surface is shaded with fresnel + specular highlights + subsurface glow.
// No raymarching — direct floor-plane projection + 3-sample normals for performance.
//
// Audio-to-visual mapping:
//   b0 (sub)    → tidal swells (large amplitude, long wavelength)
//   b1 (bass)   → pressure waves (medium amplitude)
//   b2-b5 (mids)→ vortex ripples (short wavelength, band-colored)
//   b6-b7 (highs)→ capillary turbulence (fine ripple, high freq)
//   beat/kick   → central eruption + expanding ring
//   transient   → surface disruption
//   envelope    → surface breathing
//   stereoBal   → flow direction tilt
//   stereoWid   → ripple spread
//   phaseCoh    → coherent (smooth) vs chaotic (rough) surface
//   section     → pool size / camera repositioning
//   phraseBeat  → slow evolution of flow pattern
//   speechMode  → vocal band emphasis on mids
//   calmMode    → reduced turbulence
//   brightness  → specular intensity
//   glow        → subsurface glow
//
// DSP: LUFS→surface level, crest→wave sharpness, THD→roughness, phase→symmetry.
// HDR output to Layer 0. No local postfx.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// ── Fluid heightfield — wave sources from 16-source culled emitters ──
float fluidHeight(float2 xz, SeEmitter emit[SE_NUM_OBJ], float poolR,
                  float beatPulse, float beatPhase, float transientAmt, float envelope,
                  float kickSurge, float lufs, float thd, float phaseCoh, float silence)
{
    float r = length(xz);
    if (r > poolR) return -1.0;

    // Base surface — LUFS additive
    float surface = (0.02 + lufs * 0.02) * silence;

    // Envelope breathing
    surface += envelope * 0.015 * sin(beatPhase * PI * 2.0) * silence;

    // Per-emitter radial ripples — 16-source culling (si=1 only)
    [loop] for (int bi = 0; bi < SE_N_BANDS; bi++) {
        int li = bi * SE_N_SUB * 2 + 2;
        int ri = bi * SE_N_SUB * 2 + 3;

        // Left emitter ripple
        if (emit[li].active > 0.01 && emit[li].intensity > 0.05) {
            float2 srcPos = emit[li].worldPos.xz;
            float d = length(xz - srcPos);
            float bandFrac = float(bi) / 7.0;
            float wavelength = lerp(3.0, 0.4, bandFrac);
            float sharpness = lerp(15.0, 40.0, bandFrac);
            float wave = emit[li].intensity * exp(-d * d * sharpness * 0.01);
            wave *= sin(d * (2.0 * PI / wavelength) - Time * 3.0 * (1.0 + bandFrac));
            surface += wave * 0.12;
        }

        // Right emitter ripple
        if (emit[ri].active > 0.01 && emit[ri].intensity > 0.05) {
            float2 srcPos = emit[ri].worldPos.xz;
            float d = length(xz - srcPos);
            float bandFrac = float(bi) / 7.0;
            float wavelength = lerp(3.0, 0.4, bandFrac);
            float sharpness = lerp(15.0, 40.0, bandFrac);
            float wave = emit[ri].intensity * exp(-d * d * sharpness * 0.01);
            wave *= sin(d * (2.0 * PI / wavelength) - Time * 3.0 * (1.0 + bandFrac));
            surface += wave * 0.12;
        }
    }

    // Curl noise advection — bass-driven large-scale flow
    float2 flowUV = xz * 0.5 + float2(Time * 0.2, Time * 0.15);
    float2 flow = curlN(float3(flowUV, 0)).xy;
    surface += (flow.x + flow.y) * 0.03 * silence;

    // FBM turbulence — mids + highs, THD roughens
    float2 turbUV = xz * 2.0 + float2(Time * 0.5, Time * 0.3);
    surface += fbm2_4(turbUV) * 0.04 * silence * (1.0 + thd * 0.5);

    // Phase coherence: smooth when coherent, rough when decorrelated
    surface += (1.0 - phaseCoh) * fbm2_4(turbUV * 3.0) * 0.02 * silence;

    // Beat ripple rings
    float ringPhase = beatPhase * PI * 2.0;
    surface += beatPulse * 0.04 * sin(r * 6.0 - ringPhase * 3.0) * smoothstep(poolR, 0.0, r) * silence;

    // Kick — central eruption
    surface += kickSurge * 0.08 * exp(-r * r * 3.0) * silence;

    // Transient — surface jitter
    if (transientAmt > 0.02)
        surface += transientAmt * 0.025 * sin(xz.x * 25.0 + xz.y * 22.0 + beatPhase * 30.0) * smoothstep(poolR, 0.0, r) * silence;

    // Pool edge — curve down
    surface -= smoothstep(poolR * 0.6, poolR, r) * 0.2;

    return surface;
}

// ── 3-sample normal from heightfield (3 emitter loops total, not 5) ──
float3 fluidNormal(float2 xz, SeEmitter emit[SE_NUM_OBJ], float poolR,
                   float beatPulse, float beatPhase, float transientAmt, float envelope,
                   float kickSurge, float lufs, float thd, float phaseCoh, float silence,
                   out float h0)
{
    float eps = 0.03;
    h0 = fluidHeight(xz, emit, poolR, beatPulse, beatPhase, transientAmt, envelope, kickSurge, lufs, thd, phaseCoh, silence);
    float hX = fluidHeight(xz + float2(eps, 0), emit, poolR, beatPulse, beatPhase, transientAmt, envelope, kickSurge, lufs, thd, phaseCoh, silence);
    float hZ = fluidHeight(xz + float2(0, eps), emit, poolR, beatPulse, beatPhase, transientAmt, envelope, kickSurge, lufs, thd, phaseCoh, silence);
    return normalize(float3(h0 - hX, eps, h0 - hZ));
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
        float FOV = 0.65;
        float camAng = a.section * 0.5 + a.stereoBal * 0.15 + Time * 0.015 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 3.5, 2.3, cos(camAng) * 3.5);
        cam = seCamera(camPos, float3(0.0, 0.15, 0.0), FOV);
    }

    // ── Spatial encoder: PSYCHOACOUSTIC profile ──
    SeParams params = seParams(SE_PROFILE_PSYCHOACOUSTIC);
    params.widthScale = 3.0 + a.stereoWid * 0.5;
    params.heightScale = 2.0;
    params.depthScale = 2.5 - a.calmMode * 0.3;
    params.jitterAmt = 0.2 + thd * 0.3;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.06, float3(0.01, 0.005, 0.02), -1.5, 0.0, 0.0);
    world.gridIntensity = 0.025;
    world.ambientLevel = 0.003 + a.calmMode * 0.002;
    world.ambientColor = float3(0.02, 0.015, 0.05);
    seApplyWorldFog(emit, world);

    float poolR = 3.6 + lufs * 0.08 + a.section * 0.1;

    // ── Background — world environment + starfield ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.005;

    // ── Direct floor-plane projection (no raymarching) ──
    // Cast ray to y=0 plane (fluid surface rest height)
    float3 rd = normalize(cam.fwd + p.x * cam.right * cam.fov + p.y * cam.up * cam.fov);
    float tFloor = (0.0 - cam.pos.y) / (rd.y + 1e-5);

    if (tFloor > 0.0 && tFloor < 30.0) {
        float3 hp = cam.pos + rd * tFloor;
        float2 xz = hp.xz;

        // Sample fluid height + normal in one call (3 emitter loops = 48 exp total)
        float h;
        float3 n = fluidNormal(xz, emit, poolR, beatPulse, a.beatPhase, transientAmt, envelope,
                               kickSurge, lufs, thd, phaseCoh, silence, h);

        if (h > -0.9) {
            float3 vDir = normalize(cam.pos - hp);

            // ── Liquid shading — dark glossy with colored dye ──
            float fres = pow(1.0 - max(dot(n, vDir), 0.0), 5.0);

            // Two lights — one fixed, one stereo-positioned
            float3 lDir = normalize(float3(0.4, 0.8, 0.5));
            float3 lDir2 = normalize(float3(-0.5 + a.stereoBal * 0.3, 0.6, 0.3));
            float diff = max(dot(n, lDir), 0.0);
            float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
            float spec = pow(max(dot(reflect(-lDir, n), vDir), 0.0), 80.0);
            float spec2 = pow(max(dot(reflect(-lDir2, n), vDir), 0.0), 60.0) * 0.5;

            // Height-based color — brain palette + hue cycling
            float heightFrac = clamp(h * 1.5, 0.0, 1.0);
            float3 darkFluid = float3(0.02, 0.015, 0.04);
            float3 dyeCol = lerp(a.brainCol, a.brainCol2, heightFrac);
            dyeCol = lerp(dyeCol, hsv(a.hueBase + heightFrac * a.hueRange, 0.6 * a.satur, 0.9), 0.3);
            float3 hotPeak = lerp(dyeCol, a.brainCol3, pow(heightFrac, 3.0) * 0.5);

            float3 baseCol = lerp(darkFluid, hotPeak, smoothstep(0.02, 0.3, h));
            baseCol = lerp(baseCol, dyeCol, 0.2);
            // Phase coherence shifts color subtly
            baseCol = lerp(baseCol, baseCol.gbr, phaseCoh * 0.03);

            // Lighting — brightness and dynLight from brain
            float3 litCol = baseCol * (diff + diff2) * (0.2 + a.brightness * 0.2 + a.dynamic * 0.15);
            litCol += float3(0.9, 0.85, 0.8) * (spec + spec2) * (0.3 + a.dynLight * 0.4);
            // Fresnel rim — envelope and glow sustain it
            litCol += lerp(baseCol, hotPeak, 0.5) * fres * (0.25 + envelope * 0.25 + a.glow * 0.15);

            // Wave peak glow — emissive
            float peakGlow = smoothstep(0.1, 0.5, h);
            litCol += hotPeak * peakGlow * (0.05 + envelope * 0.2) * silence;
            // Kick flash on peaks
            litCol += float3(1.0, 0.4, 0.08) * kickSurge * peakGlow * 0.2 * silence;
            // Transient sparks
            if (transientAmt > 0.02)
                litCol += float3(1.0, 0.85, 0.6) * transientAmt * peakGlow * 0.1 * silence;
            // Beat pulse glow
            litCol += hotPeak * beatPulse * peakGlow * 0.04 * silence;
            // Color pulse from brain
            litCol += a.brainCol3 * a.colorPulse * peakGlow * 0.015 * silence;
            // Punch from kick
            litCol += hotPeak * a.punch * peakGlow * 0.03 * silence;
            // Speech mode — vocal bands create brighter mids
            litCol += a.brainCol2 * a.speechMode * peakGlow * 0.02 * silence;

            litCol *= (0.5 + a.dynamic * 0.3);

            // Depth fog on liquid surface
            float depthFog = exp(-tFloor * world.fogDensity);
            litCol *= depthFog;

            col = blendScreen(col, litCol);
        }
    }

    // ── Subsurface glow — envelope + glow sustain ──
    float ssg = a.glow * 0.02 + envelope * 0.01;
    col += a.brainCol * ssg * (0.5 + envelope * 0.5) * silence;
    col += a.brainCol2 * a.calmMode * 0.005 * silence;

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

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
