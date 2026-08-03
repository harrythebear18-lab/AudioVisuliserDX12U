// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 44: Phonon Crystal Lattice — procedurally generated crystal
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_SPHERICAL.
//
// Concept: 8 atoms arranged on a ring, positions procedurally displaced by
// band energy. Bonds connect adjacent atoms. The lattice shape morphs with
// music — atoms move outward when their band is active, compress on kick,
// scatter on transient. Brain band values are the primary driver.
// Spatial encoder provides color and spatial modulation.
// Beat = wave packet traveling along bonds. Kick = compression wave.
// Transient = defect scattering. Phase coherence = lattice ordering.
//
// No seEmitGlowDepth/VR, no seLinkLR, no softReinhard. Full audio brain.
// HDR output to Layer 0. No local postfx.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// Compute atom screen position for band i, procedurally from audio data
float2 atomPos(int i, float bands[8], AudioData a, float lufs, float thd,
               float kickSurge, float transientAmt, float beatPulse,
               float orbitAng, float spatialMod[8])
{
    float ang = float(i) / 8.0 * PI * 2.0 + orbitAng;
    float bandVal = bands[i];

    // Base radius modulated by band energy — atom pushes outward when active
    float radius = 0.22 + bandVal * 0.13 * a.gated;
    radius += a.energy * 0.03 * a.gated;
    radius += a.beatAnt * 0.015 * a.gated;
    radius += beatPulse * 0.02;
    radius *= (1.0 + lufs * 0.08);
    radius *= spatialMod[i];

    // THD disorder — angular jitter
    float disorder = sin(ang * 3.0 + Time * 2.0) * thd * 0.04 * vrFlickerScale();
    disorder += sin(ang * 7.0 - Time * 4.0) * thd * 0.02 * vrFlickerScale();
    disorder *= (1.0 - a.calmMode * 0.5);
    ang += disorder;

    // Kick compression — atoms squeeze inward
    radius -= kickSurge * 0.04 * (1.0 - bandVal);

    // Transient scatter — radial spikes
    radius += transientAmt * sin(ang * 10.0 + Time * 8.0) * 0.015 * a.gated;

    // Stereo width stretches horizontally
    float x = cos(ang) * radius * (1.0 + a.stereoWid * 0.15);
    float y = sin(ang) * radius * (1.0 - a.calmMode * 0.1);

    // Phrase breathing
    float phraseBreath = sin(a.phraseBeat * PI * 2.0) * 0.015 * a.gated;
    x += cos(ang) * phraseBreath;
    y += sin(ang) * phraseBreath;

    return float2(x, y);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    // VR parallax — shift screen coords per eye for fake stereo depth
    p += vrParallax(2.0);  // lattice at ~2 units depth
    float r = length(p);
    float silence = 1.0 - a.isSilent;
    float flashScale = vrFlashScale();
    float flickerScale = vrFlickerScale();

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

    // ── Camera — VR head pose or desktop orbit ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 1.0;
        float camAng = a.section * 0.5 + a.stereoBal * 0.2 + Time * vrMotionScale(0.03) * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 8.0, 3.0 + a.stereoDiff * 0.1, cos(camAng) * 8.0);
        cam = seCamera(camPos, float3(0, 0, 0), FOV);
    }

    // ── Spatial encoder: SPHERICAL profile ──
    SeParams params = seParams(SE_PROFILE_SPHERICAL);
    params.widthScale = 2.0;
    params.heightScale = 2.0;
    params.depthScale = 2.0;
    params.jitterAmt = 0.1 + thd * 0.25;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;
    params.motionSpeed = 0.8 * (1.0 - a.calmMode * 0.3);

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.06, float3(0.01, 0.005, 0.02), -1.5, 0.0, 0.0);
    world.gridIntensity = 0.02;
    world.ambientLevel = 0.003;
    world.ambientColor = float3(0.015, 0.01, 0.03);
    seApplyWorldFog(emit, world);

    // ── Background — dark crystal void + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.005;

    // ── Spatial encoder modulation per band ──
    float spatialMod[8];
    float3 emitCol[8];
    [unroll] for (int bi = 0; bi < 8; bi++) {
        int n = bi * SE_N_SUB * 2;
        spatialMod[bi] = (emit[n].active > 0.01) ? (emit[n].intensity + 0.5) : 1.0;
        emitCol[bi] = (emit[n].active > 0.01) ? emit[n].color : a.brainCol;
    }

    // ── Orbital rotation ──
    float orbitAng = Time * 0.1 * a.motSpeed;

    // ── Compute all 8 atom positions ──
    float2 atoms[8];
    [unroll] for (int ai = 0; ai < 8; ai++) {
        atoms[ai] = atomPos(ai, bands, a, lufs, thd, kickSurge, transientAmt,
                           beatPulse, orbitAng, spatialMod);
    }

    // ── Lattice bonds — connect adjacent atoms (8 bonds around ring) ──
    [unroll] for (int b = 0; b < 8; b++) {
        int b2 = (b + 1) % 8;

        // Bond brightness from both endpoint band values
        float bondEnergy = (bands[b] + bands[b2]) * 0.5 * a.gated;
        float bondInt = bondEnergy;
        bondInt *= (spatialMod[b] + spatialMod[b2]) * 0.5;
        bondInt *= (0.7 + a.brightness * 0.3);
        bondInt *= (1.0 - a.calmMode * 0.3);
        bondInt *= (1.0 + lufs * 0.2);
        bondInt += a.beatAnt * 0.1 * a.gated;
        bondInt += a.glow * 0.04 * a.gated;

        // Phase coherence strengthens bonds
        bondInt *= (0.5 + phaseCoh * 0.5);

        if (bondInt < 0.01) continue;

        // Bond color — interpolate between endpoint colors
        float3 bondCol = lerp(emitCol[b], emitCol[b2], 0.5);
        float bt = float(b) / 7.0;
        bondCol = lerp(bondCol, a.brainCol2, bt * 0.3);
        bondCol = lerp(bondCol, bondCol.bgr, a.colorPulse * 0.02);

        // Distance from pixel to bond line segment
        float2 ab = atoms[b2] - atoms[b];
        float abLen2 = dot(ab, ab);
        float t = clamp(dot(p - atoms[b], ab) / max(abLen2, 0.0001), 0.0, 1.0);
        float2 closest = atoms[b] + ab * t;
        float bondDist = length(p - closest);

        // Bond width — thinner when crest is high (sharper)
        float bondWidth = 0.003 / (1.0 + crest * 0.5);
        bondWidth *= (1.0 + thd * 0.3 * (1.0 - a.calmMode * 0.5));
        float bondGlow = exp(-bondDist * bondDist / (bondWidth * bondWidth));
        float bondCore = exp(-bondDist * bondDist / (bondWidth * bondWidth * 0.2));

        col += bondCol * (bondGlow * 0.08 + bondCore * 0.15) * bondInt * silence;

        // Beat wave packet traveling along bond
        float2 sigPoint = lerp(atoms[b], atoms[b2], a.beatPhase);
        float sigDist = length(p - sigPoint);
        col += float3(0.9, 0.95, 1.0) * exp(-sigDist * sigDist * 80.0) * beatPulse * bondInt * 0.12 * silence;

        // Kick compression flash on bond
        col += bondCol * bondCore * kickSurge * bondInt * 0.08 * flashScale * silence;
    }

    // ── Lattice atoms — 8 with inline glow ──
    [unroll] for (int at = 0; at < 8; at++) {
        float bandVal = bands[at] * a.gated;
        float atomInt = bandVal;
        atomInt *= spatialMod[at];
        atomInt *= (0.7 + a.brightness * 0.3);
        atomInt *= (1.0 - a.calmMode * 0.3);
        atomInt *= (1.0 + lufs * 0.2);
        atomInt += a.beatAnt * 0.12 * a.gated;
        atomInt += a.glow * 0.04 * a.gated;

        // Vocal band boost
        float vocalWeight = smoothstep(2.5, 3.5, float(at)) * (1.0 - smoothstep(5.0, 6.0, float(at)));
        atomInt += a.speechMode * vocalWeight * 0.2 * a.gated;

        if (atomInt < 0.01) continue;

        float2 diff = p - atoms[at];
        float d2 = dot(diff, diff);
        float atomSize = 0.025 + bandVal * 0.02;
        float s2 = atomSize * atomSize;
        if (d2 > s2 * 16.0) continue;

        float core = exp(-d2 / (s2 * 0.3));
        float halo = exp(-d2 / (s2 * 5.0));

        // Atom color
        float bt = float(at) / 7.0;
        float3 atomCol = lerp(float3(1.0, 0.6, 0.3), a.brainCol2, bt);
        atomCol = lerp(atomCol, emitCol[at], 0.4);
        atomCol = lerp(atomCol, a.brainCol, 0.2);
        atomCol = lerp(atomCol, atomCol.bgr, a.colorPulse * 0.02);

        col += atomCol * (core * 0.2 + halo * 0.05) * atomInt * silence;
        col += atomCol * core * beatPulse * atomInt * 0.1 * silence;
        col += atomCol * core * kickSurge * atomInt * 0.08 * flashScale * silence;

        // Transient defect scattering
        if (transientAmt > 0.02) {
            col += float3(1.0, 0.8, 0.5) * halo * transientAmt * atomInt * 0.03 * silence;
        }
    }

    // ── Inner lattice glow — phonon field ──
    float innerGlow = exp(-r * r * 8.0);
    col += a.brainCol * innerGlow * a.energy * 0.04 * a.gated * silence;
    col += float3(0.8, 0.4, 0.1) * innerGlow * kickSurge * 0.06 * flashScale * silence;

    // ── Listener focal point ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Kick — lattice compression wave (expanding ring) ──
    if (kickSurge > 0.05) {
        float gwR = a.beatPhase * 0.6;
        float gwDist = abs(r - gwR);
        col += a.brainCol * exp(-gwDist * gwDist * 30.0) * kickSurge * 0.04 * silence;
    }

    // ── Transient — defect scattering flash ──
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.01 * silence;

    // ── Beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;

    // ── Phrase breathing ──
    float phraseMod = sin(a.phraseBeat * PI * 2.0) * 0.015 * a.gated;
    col += a.brainCol * phraseMod * silence;

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.015;

    // ── Active-emitter normalization ──
    col *= sqrt(16.0 / seActiveCount(emit));

    // ── Dynamic HDR limiter ──
    col = hdrLimiter(col);

    col *= silence;

    return float4(col, 1.0);
}
