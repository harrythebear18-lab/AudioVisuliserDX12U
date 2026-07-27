// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 33: Spectral Masking Cascade — visualizing auditory masking
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_SPHERICAL.
//
// Psychoacoustic phenomenon: Loud sounds mask quiet sounds at nearby frequencies.
// The auditory system raises the hearing threshold in a "critical band" around
// each active source. This mode makes that masking visible:
//
//   Direct Sources       → emitter glow at psychoacoustic positions
//   Masking Shadows      → active emitters cast cones that dim neighbors (simultaneous masking)
//   Temporal Masking     → after kick/beat, decaying "deafness zone" from bass (forward masking)
//   Critical Band Edges  → visible frequency boundaries where masking operates
//   Binaural Unmasking   → phase decorrelation lets masked sources "escape" (the brain can hear through)
//   Beat = masking threshold surge, Kick = forward masking pulse
//
// World: grid floor + back wall, fog density 0.04, dark ambient.
// Camera: orbiting the masking field, FOV 0.9 (VR: head pose from OpenXR).
// 16-source culling: only center sub (si=1) renders for VR performance.
//
// DSP: LUFS→masking strength, crest→masking sharpness, THD→critical band width,
//      phase→binaural unmasking (decorrelation = escape from masker).
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// ── Masking shadow — active emitter dims nearby frequency-band sources ──
// Visualizes simultaneous spectral masking: a loud source raises the hearing
// threshold for nearby frequencies. We render this as a darkening cone from
// the masker toward adjacent-band emitters.
float3 maskingShadow(float2 p, SeEmitter masker, SeEmitter masked,
                     float thd, float phaseCoh, float silence)
{
    if (masker.active < 0.01 || masked.active < 0.01) return float3(0, 0, 0);
    if (masker.intensity < 0.2) return float3(0, 0, 0);  // only loud sources mask
    if (masker.bandIdx == masked.bandIdx) return float3(0, 0, 0);  // don't mask self

    // Only mask adjacent bands (critical band width)
    int bandDist = abs(masker.bandIdx - masked.bandIdx);
    if (bandDist > 2) return float3(0, 0, 0);

    // Masking strength: louder masker + closer band = stronger masking
    float maskStrength = masker.intensity * exp(-float(bandDist) * 1.5);
    // THD widens critical bands (more masking spread)
    maskStrength *= (1.0 + thd * 0.3);
    // Binaural unmasking: phase decorrelation lets masked source escape
    maskStrength *= lerp(0.3, 1.0, phaseCoh);

    // Cone from masker toward masked source
    float2 ab = masked.screenPos - masker.screenPos;
    float lineLen2 = dot(ab, ab);
    if (lineLen2 < 0.0001) return float3(0, 0, 0);

    float t = saturate(dot(p - masker.screenPos, ab) / lineLen2);
    float2 closest = masker.screenPos + ab * t;
    float2 lineDiff = p - closest;
    float lineDist2 = dot(lineDiff, lineDiff);

    // Cone widens toward the masked source
    float coneWidth = lerp(0.005, 0.02, t);
    if (lineDist2 > coneWidth * 4.0) return float3(0, 0, 0);

    float lineDist = sqrt(lineDist2);
    float coneIntensity = exp(-lineDist * lineDist / (coneWidth * coneWidth));

    // Darkening effect — subtract from the scene (return negative-weighted color)
    // We render this as a dark purple wash that visually "eats" nearby sources
    float darken = coneIntensity * maskStrength * 0.04;
    return float3(-darken * 0.5, -darken * 0.4, -darken * 0.6) * silence;
}

// ── Temporal masking — decaying deafness zone after kick/beat ──
// After a loud transient, the hearing threshold is elevated for 50-200ms.
// We visualize this as an expanding dark ring from bass emitters.
float3 temporalMasking(float2 p, SeEmitter e, float kickSurge, float beatPulse,
                       float beatPhase, float silence)
{
    if (e.active < 0.01 || e.intensity < 0.1) return float3(0, 0, 0);
    if (e.bandIdx > 2) return float3(0, 0, 0);  // only bass creates forward masking

    float2 diff = p - e.screenPos;
    float d = length(diff);
    float s = e.screenSize;

    // Forward masking radius grows then decays with beatPhase
    float maskR = s * (2.0 + beatPhase * 4.0);
    float maskDecay = exp(-beatPhase * 2.5);  // decays over time
    float maskStrength = (kickSurge * 0.7 + beatPulse * 0.3) * maskDecay;

    if (maskStrength < 0.01) return float3(0, 0, 0);

    // Ring of darkness — expanding deafness zone
    float ringDist = abs(d - maskR);
    float ringWidth = s * 0.5;
    float ringIntensity = exp(-ringDist * ringDist / (ringWidth * ringWidth));

    // Also a solid disk of slight darkening inside the ring
    float diskIntensity = smoothstep(maskR, 0.0, d) * maskStrength * 0.02;

    float darken = (ringIntensity * 0.05 + diskIntensity) * maskStrength;
    return float3(-darken * 0.4, -darken * 0.3, -darken * 0.5) * silence;
}

// ── Critical band boundary — screen-space frequency region edges ──
// The cochlea processes sound in critical bands. We render subtle radial
// boundaries between frequency regions using screen-space angular position.
float3 criticalBandEdges(float2 p, AudioData a, float thd, float silence)
{
    // Angular position in screen space maps to frequency band
    // Use atan2 approximation: atan2(y,x) = atan(y/x) adjusted by quadrant
    float angle;
    if (abs(p.x) > 0.001) {
        angle = atan(p.y / p.x);
        if (p.x < 0.0) angle += (p.y >= 0.0) ? PI : -PI;
    } else {
        angle = (p.y >= 0.0) ? (PI * 0.5) : -(PI * 0.5);
    }
    float bandFrac = (angle + PI) / (2.0 * PI);
    float bandPos = bandFrac * 8.0;

    // Critical band edges — 8 boundaries
    float edgeDist = abs(frac(bandPos) - 0.5);
    float edge = smoothstep(0.46, 0.5, edgeDist);

    // Band width varies with THD (roughness widens bands)
    edge *= (1.0 + thd * 0.3);

    // Subtle colored edges — each band region gets a hint of color
    int bandIdx = int(bandPos) % 8;
    float3 bandCol = hsv(a.hueBase + bandFrac * a.hueRange, 0.4 * a.satur, 0.5);

    float r = length(p);
    float radialFade = exp(-r * 1.5) * smoothstep(0.1, 0.5, r);

    float3 col = bandCol * edge * 0.012 * radialFade * silence;

    // Active bands glow brighter
    float bandArr[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    float bandEnergy = bandArr[bandIdx];
    col += bandCol * bandEnergy * 0.008 * radialFade * (1.0 - abs(frac(bandPos) - 0.5) * 2.0) * silence;

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

    // ── Camera — VR head pose or desktop orbit ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.9;
        float camAng = a.section * 0.1 + a.stereoBal * 0.05 + Time * 0.003 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 3.0, 1.2 + a.stereoDiff * 0.1, 3.0 + cos(camAng) * 0.8);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder: SPHERICAL profile ──
    SeParams params = seParams(SE_PROFILE_SPHERICAL);
    params.widthScale = 2.5;
    params.heightScale = 2.0;
    params.depthScale = 3.0;
    params.jitterAmt = 0.1 + thd * 0.15;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment — floor + back wall ──
    SeWorld world = seWorld(0.04, float3(0.003, 0.002, 0.008), -1.5, 0.0, -6.0);
    world.gridScale = 2.0;
    world.gridIntensity = 0.03;
    world.ambientLevel = 0.004;
    world.ambientColor = float3(0.01, 0.008, 0.02);
    world.flags = 5;  // floor + back wall
    seApplyWorldFog(emit, world);

    // ── Background — world environment + critical band edges on floor ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += criticalBandEdges(p, a, thd, silence);

    // ── Direct sound — emitter glow (primary visual, 16-source culling) ──
    if (VR_ACTIVE) {
        float3 headPos = float3(VRHeadPos.xyz);
        [loop] for (int bi = 0; bi < SE_N_BANDS; bi++) {
            int li = bi * SE_N_SUB * 2 + 2;
            int ri = bi * SE_N_SUB * 2 + 3;
            if (emit[li].active > 0.01 && emit[li].depth > 0.1)
                col += seEmitGlowVR(p, emit[li], world, headPos, silence);
            if (emit[ri].active > 0.01 && emit[ri].depth > 0.1)
                col += seEmitGlowVR(p, emit[ri], world, headPos, silence);
        }
    } else {
        [loop] for (int bi2 = 0; bi2 < SE_N_BANDS; bi2++) {
            int li = bi2 * SE_N_SUB * 2 + 2;
            int ri = bi2 * SE_N_SUB * 2 + 3;
            if (emit[li].active > 0.01 && emit[li].depth > 0.1)
                col += seEmitGlowDepth(p, emit[li], world, lufs, crest, beatBright,
                                       a.beatPhase, kickSurge, transientAmt, silence);
            if (emit[ri].active > 0.01 && emit[ri].depth > 0.1)
                col += seEmitGlowDepth(p, emit[ri], world, lufs, crest, beatBright,
                                       a.beatPhase, kickSurge, transientAmt, silence);
        }
    }

    // ── Simultaneous masking — only L per band masks adjacent L (8 calls, not 64) ──
    // Masking is a band-proximity effect, L/R side doesn't change the physics
    [loop] for (int bi3 = 0; bi3 < SE_N_BANDS; bi3++) {
        int li = bi3 * SE_N_SUB * 2 + 2;
        if (emit[li].active < 0.01 || emit[li].intensity < 0.2) continue;
        if (bi3 > 0) {
            int nli = (bi3 - 1) * SE_N_SUB * 2 + 2;
            col += maskingShadow(p, emit[li], emit[nli], thd, phaseCoh, silence);
        }
        if (bi3 < SE_N_BANDS - 1) {
            int nli = (bi3 + 1) * SE_N_SUB * 2 + 2;
            col += maskingShadow(p, emit[li], emit[nli], thd, phaseCoh, silence);
        }
    }

    // ── Temporal masking — only bass bands 0-1 (4 calls, not 16) ──
    if (kickSurge > 0.01 || beatPulse > 0.01) {
        [loop] for (int bi4 = 0; bi4 < 2; bi4++) {
            int li = bi4 * SE_N_SUB * 2 + 2;
            int ri = bi4 * SE_N_SUB * 2 + 3;
            if (emit[li].active > 0.01 && emit[li].depth > 0.1)
                col += temporalMasking(p, emit[li], kickSurge, beatPulse, a.beatPhase, silence);
            if (emit[ri].active > 0.01 && emit[ri].depth > 0.1)
                col += temporalMasking(p, emit[ri], kickSurge, beatPulse, a.beatPhase, silence);
        }
    }

    // ── L↔R links — phase coherence beams ──
    [loop] for (int lb = 0; lb < SE_N_BANDS; lb++) {
        col += seLinkLR(p, emit, lb, phaseCorr, phaseCoh, silence);
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Ambient energy — minimal ──
    col += a.brainCol3 * a.colorPulse * 0.01 * silence;
    col += a.brainCol * a.energy * 0.005 * silence;
    col += a.brainCol2 * a.punch * 0.005 * silence;
    col += a.brainCol * a.beatAnt * 0.008 * exp(-r * 2.0) * silence;

    // ── Dynamic range — quiet passages dark ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays (sparing) ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── HDR limiter — 1.0 cap for VR comfort ──
        // ── Active-emitter normalization — busy music doesn't stack brighter ──
    col *= sqrt(16.0 / seActiveCount(emit));
    // ── Soft tone mapping (Reinhard) — no hard clamp, preserves color ──
    col = softReinhard(col);

    col *= silence;

    return float4(col, 1.0);
}
