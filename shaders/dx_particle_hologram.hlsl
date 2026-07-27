// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 47: Acoustic Particle Hologram — GPU particles forming 3D audio shapes
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_PSYCHOACOUSTIC.
//
// 48 emitters (8 bands × 3 sub × L/R) placed as psychoacoustic sources.
// Each emitter spawns a particle cluster that converges on beats,
// dissolves on transients, and explodes on kicks.
// Stereo = particle distribution L/R. Beat = convergence.
// Kick = explosion outward. Transient = dissolution + reformation.
//
// World: grid floor for depth grounding, fog density 0.05, dark ambient.
// Camera: inside the particle cloud, FOV 0.75 (VR: head pose from OpenXR).
// Visual: glowing particle clusters with trails between same-band emitters.
//
// DSP: LUFS→particle brightness, crest→particle focus, THD→particle jitter, phase→cluster coherence.
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_PARTICLES 48

struct Particle {
    float3 pos;
    float energy;
    float gate;
    float freqFrac;
    float3 color;
};

void computeParticlesFromEmitters(out Particle particles[N_PARTICLES], SeEmitter emit[SE_NUM_OBJ],
                                  float kickSurge, float beatPulse, float transientAmt,
                                  float thd, float envelope, float crest, AudioData a)
{
    [unroll] for (int n = 0; n < N_PARTICLES; n++)
    {
        float3 targetPos = emit[n].worldPos;
        float energy = emit[n].intensity;
        float gate = emit[n].active * step(0.05, emit[n].intensity);
        float bt = float(emit[n].bandIdx) / float(SE_N_BANDS - 1);

        // Transient — dissolution: scatter particles
        float dissolve = transientAmt * 2.0;
        float3 scatter = float3(
            hash11(float(n) * 7.3 + Time * 10.0) - 0.5,
            hash11(float(n) * 13.7 + Time * 8.0) - 0.5,
            hash11(float(n) * 21.1 + Time * 12.0) - 0.5
        ) * dissolve;

        // Kick — explosion outward
        float3 explode = normalize(targetPos + float3(0.01, 0, 0)) * kickSurge * 1.5;

        // Beat — convergence pulse toward target
        float converge = beatPulse * exp(-a.beatPhase * 4.0);

        // Final position — lerp between scattered and target
        float3 finalPos = lerp(targetPos + scatter, targetPos, converge);
        finalPos += explode * (1.0 - converge);

        // THD jitter
        finalPos += float3(
            thd * (hash11(float(n) * 5.1 + Time * 20.0) - 0.5) * 0.1,
            thd * (hash11(float(n) * 9.3 + Time * 18.0) - 0.5) * 0.1,
            thd * (hash11(float(n) * 17.5 + Time * 22.0) - 0.5) * 0.1
        );

        // Envelope breathing
        finalPos *= (1.0 + envelope * 0.1 * sin(Time * 2.0 + float(n)));

        particles[n].pos = finalPos;
        particles[n].energy = energy * gate;
        particles[n].gate = gate;
        particles[n].freqFrac = bt;
        particles[n].color = emit[n].color;
    }
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

    // ── Camera — VR head pose or desktop inside particle cloud ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.75;
        float camAng = a.section * 0.5 + a.stereoBal * 0.2 + Time * 0.02 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 2.0, 0.5 + a.stereoDiff * 0.1, cos(camAng) * 2.0);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder: PSYCHOACOUSTIC profile ──
    SeParams params = seParams(SE_PROFILE_PSYCHOACOUSTIC);
    params.widthScale = 2.5;
    params.heightScale = 2.5;
    params.depthScale = 3.0;
    params.jitterAmt = 0.12 + thd * 0.2;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.05, float3(0.003, 0.002, 0.01), -1.8, 0.0, 0.0);
    world.gridIntensity = 0.02;
    world.ambientLevel = 0.003;
    world.ambientColor = float3(0.008, 0.006, 0.015);
    seApplyWorldFog(emit, world);

    // ── Derive particles from emitters ──
    Particle particles[N_PARTICLES];
    computeParticlesFromEmitters(particles, emit, kickSurge, beatPulse, transientAmt,
                                 thd, envelope, crest, a);

    // ── Background — dark hologram space + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.003;

    // ── Project particles ──
    float2 scrPos[N_PARTICLES];
    float scrDepth[N_PARTICLES];

    [unroll] for (int n = 0; n < N_PARTICLES; n++) {
        float3 toP = particles[n].pos - cam.pos;
        scrDepth[n] = dot(toP, cam.fwd);
        if (scrDepth[n] < 0.1) { scrPos[n] = float2(999, 999); scrDepth[n] = 0.0; continue; }
        scrPos[n] = float2(dot(toP, cam.right) / (scrDepth[n] * cam.fov),
                           dot(toP, cam.up) / (scrDepth[n] * cam.fov));
    }

    // ── Particle trails — connect to nearest neighbor in same band ──
    [loop] for (int i = 0; i < N_PARTICLES; i++) {
        if (particles[i].gate < 0.01 || scrDepth[i] < 0.1) continue;

        int band = i / (SE_N_SUB * 2);
        int nextIdx = (band * SE_N_SUB * 2) + ((i % (SE_N_SUB * 2)) + 1) % (SE_N_SUB * 2);
        if (particles[nextIdx].gate < 0.01 || scrDepth[nextIdx] < 0.1) continue;

        float2 ab = scrPos[nextIdx] - scrPos[i];
        float t = clamp(dot(p - scrPos[i], ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
        float2 closest = scrPos[i] + ab * t;
        float trailDist = length(p - closest);
        float trailWidth = 0.002 + particles[i].energy * 0.003;
        float trailGlow = exp(-trailDist * trailDist / (trailWidth * trailWidth));

        float3 trailCol = lerp(particles[i].color, particles[nextIdx].color, 0.5);
        float avgDepth = (scrDepth[i] + scrDepth[nextIdx]) * 0.5;
        float depthFade = exp(-avgDepth * world.fogDensity);
        float trailInt = (particles[i].energy + particles[nextIdx].energy) * 0.5 * (1.0 + lufs * 0.15);

        col += trailCol * trailGlow * trailInt * depthFade * 0.06 * silence;
    }

    // ── Particles — glowing points with multi-layer glow ──
    [loop] for (int m = 0; m < N_PARTICLES; m++) {
        if (particles[m].gate < 0.01 || scrDepth[m] < 0.1) continue;

        float scrDist = length(p - scrPos[m]);
        float sz = (0.015 + particles[m].energy * 0.04) / max(scrDepth[m] * 0.15, 0.3) * 3.0;

        float coreGlow = exp(-scrDist * scrDist / (sz * sz * 0.08));
        float midGlow = exp(-scrDist * scrDist / (sz * sz * 0.8));
        float haloGlow = exp(-scrDist * scrDist / (sz * sz * 5.0));

        float intensity = particles[m].energy * (1.0 + lufs * 0.2);
        float depthFade = exp(-scrDepth[m] * world.fogDensity);

        float focus = lerp(0.5, 1.5, crest);

        col += float3(0.9, 0.95, 1.0) * coreGlow * intensity * focus * depthFade * 0.35 * silence;
        col += particles[m].color * midGlow * intensity * depthFade * 0.15 * silence;
        col += particles[m].color * haloGlow * intensity * depthFade * 0.03 * silence;
    }

    // ── Emitter glow — depth-aware, VR or desktop ──
    if (VR_ACTIVE) {
        float3 headPos = float3(VRHeadPos.xyz);
        [loop] for (int j = 0; j < SE_NUM_OBJ; j++) {
            if (emit[j].active < 0.01 || emit[j].depth < 0.1) continue;
            col += seEmitGlowVR(p, emit[j], world, headPos, silence);
        }
    } else {
        [loop] for (int j = 0; j < SE_NUM_OBJ; j++) {
            if (emit[j].active < 0.01 || emit[j].depth < 0.1) continue;
            col += seEmitGlowDepth(p, emit[j], world, lufs, crest, beatPulse,
                                   a.beatPhase, kickSurge, transientAmt, silence);
        }
    }

    // ── L↔R links ──
    [loop] for (int lb = 0; lb < SE_N_BANDS; lb++) {
        col += seLinkLR(p, emit, lb, phaseCorr, phaseCoh, silence);
    }

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Mode-specific overlays — subtle ──
    col += a.brainCol * beatPulse * exp(-a.beatPhase * 4.0) * 0.01 * silence;
    col += float3(1.0, 0.6, 0.2) * kickSurge * 0.02 * exp(-r * r * 3.0) * silence;
    if (transientAmt > 0.02) {
        float shimmer = transientAmt * hash21(p * 100.0 + Time * 40.0) * 0.03;
        col += a.brainCol3 * shimmer * silence;
    }
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;
    col += a.brainCol3 * a.colorPulse * 0.015 * silence;
    col += a.brainCol2 * a.energy * 0.01 * silence;
    col += a.brainCol * a.punch * 0.01 * silence;
    col += a.brainCol * a.beatAnt * 0.008 * exp(-r * 2.0) * silence;

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02;

        // ── Active-emitter normalization — busy music doesn't stack brighter ──
    col *= sqrt(16.0 / seActiveCount(emit));
    // ── Soft tone mapping (Reinhard) — no hard clamp, preserves color ──
    col = softReinhard(col);

    col *= silence;

    return float4(col, 1.0);
}
