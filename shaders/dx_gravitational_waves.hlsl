// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 31: Acoustic Room Response — visualizing the impulse response of virtual space
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_PSYCHOACOUSTIC.
//
// Psychoacoustic phenomenon: The brain synthesizes room acoustics from visual context.
// This mode makes that mental model visible — you see what the brain hears:
//
//   Direct Sound      → sharp emitter glow at psychoacoustic source position
//   Early Reflections → ghost sources mirrored across floor/walls (image source method)
//   Precedence (Haas) → direct sound dominant, reflections attenuated by delay
//   Room Modes        → standing wave patterns on floor grid (bass-driven)
//   Reverb Tail       → diffuse ambient glow tracking energy decay (T60)
//
// World: grid floor + back wall + ceiling = acoustic room, fog density 0.05, dark ambient.
// Camera: inside the room, FOV 0.65 (VR: head pose from OpenXR).
// 16-source culling: only center sub (si=1) renders for VR performance.
//
// DSP: LUFS→reverb density, crest→reflection sharpness, THD→surface roughness,
//      phase→L/R coherence. HDR output to Layer 0. No local postfx.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// ── Room dimensions — virtual acoustic space ──
#define ROOM_HALF_W 3.0   // half-width  (X: -3..+3)
#define ROOM_CEIL   2.5   // ceiling     (Y: +2.5)
#define ROOM_FLOOR -1.5   // floor       (Y: -1.5)
#define ROOM_BACK  -5.0   // back wall   (Z: -5.0)

// ── Image source method: reflect position across a plane ──
// P_ghost = P_src - 2 * ((P_src - P0) . N) * N
float3 reflectAcrossPlane(float3 src, float3 planePoint, float3 planeNormal)
{
    return src - 2.0 * dot(src - planePoint, planeNormal) * planeNormal;
}

// ── Early reflection ghost — mirrored emitter with frequency-dependent absorption ──
// Visualizes the Haas effect: reflections are dimmer, blurred, and delayed.
float3 earlyReflection(float2 p, SeEmitter e, SeCamera cam, SeWorld world,
                       float3 planePoint, float3 planeNormal, float absorption,
                       float lufs, float silence)
{
    if (e.active < 0.01 || e.intensity < 0.05) return float3(0, 0, 0);

    // Mirror source position across the plane (image source method)
    float3 ghostPos = reflectAcrossPlane(e.worldPos, planePoint, planeNormal);

    // Project ghost to screen space
    float ghostDepth = seDepth(ghostPos, cam);
    if (ghostDepth < 0.1) return float3(0, 0, 0);
    float2 ghostScreen = seProject(ghostPos, cam);

    // Distance from pixel to ghost
    float2 diff = p - ghostScreen;
    float d2 = dot(diff, diff);
    float s = e.screenSize * 1.5;  // reflections are broader (blurred)
    float s2 = s * s;
    if (d2 > s2 * 30.0) return float3(0, 0, 0);

    // Haas effect: attenuation by propagation delay (extra distance traveled)
    float directDist = length(e.worldPos - cam.pos);
    float ghostDist = length(ghostPos - cam.pos);
    float delayDist = ghostDist - directDist;
    float haasAtten = exp(-delayDist * 0.3);  // e^(-alpha * delta_t)

    // Frequency-dependent absorption — highs absorbed more by surfaces
    float bandFrac = float(e.bandIdx) / 7.0;
    float freqAbsorb = lerp(0.9, 0.3, bandFrac);  // bass passes through, highs absorbed
    float surfaceAbsorb = absorption * freqAbsorb;

    // Depth fog for ghost
    float ghostFog = exp(-ghostDist * world.fogDensity);

    // Reflection amplitude: direct intensity * Haas * absorption * fog
    float amp = e.intensity * haasAtten * surfaceAbsorb * ghostFog;

    // Blurred glow — reflections are diffuse, not sharp
    float halo = exp(-d2 / (s2 * 6.0));
    float mid = exp(-d2 / (s2 * 2.0));

    // Desaturate reflection color (high-frequency loss = less color)
    float lum = dot(e.color, float3(0.299, 0.587, 0.114));
    float3 ghostCol = lerp(float3(lum, lum, lum), e.color, freqAbsorb);

    float3 col = float3(0, 0, 0);
    col += ghostCol * halo * amp * 0.05 * silence;
    col += ghostCol * mid * amp * 0.03 * silence;

    // Kick impulse — bright reflection flash on bass bands
    if (e.bandIdx <= 1 && e.intensity > 0.3) {
        col += float3(1.0, 0.5, 0.15) * mid * amp * 0.04 * silence;
    }

    return col;
}

// ── Room mode standing wave pattern on floor grid ──
// P(x,y) = cos(n_x * pi * x / L_x) * cos(n_y * pi * y / L_y) * BassEnergy
float3 roomModePattern(float2 p, SeCamera cam, SeWorld world, AudioData a,
                       float kickSurge, float silence)
{
    float3 col = float3(0, 0, 0);

    // Raycast to floor
    float3 rd = normalize(cam.fwd + p.x * cam.right * cam.fov + p.y * cam.up * cam.fov);
    float tFloor = (ROOM_FLOOR - cam.pos.y) / (rd.y + 1e-5);
    if (tFloor <= 0.0 || tFloor > 30.0) return col;

    float3 hitPos = cam.pos + rd * tFloor;
    float2 floorCoord = hitPos.xz;

    // Only within room bounds
    if (abs(floorCoord.x) > ROOM_HALF_W || floorCoord.y > 0.0 || floorCoord.y < ROOM_BACK)
        return col;

    // Normalize to room dimensions
    float nx = floorCoord.x / ROOM_HALF_W;  // -1..1
    float nz = floorCoord.y / ROOM_BACK;     // 0..1 (0=front, 1=back)

    // Bass energy drives modal intensity
    float bassEnergy = a.b0 * 0.5 + a.b1 * 0.3 + a.energy * 0.2;
    if (bassEnergy < 0.05) return col;

    // Room modes — axial modes in X and Z
    // Mode numbers shift with section changes (different "rooms")
    float modeShift = a.section * 0.5;
    float mode1X = cos((1.0 + modeShift) * PI * nx);
    float mode2X = cos((2.0 + modeShift) * PI * nx);
    float mode1Z = cos((1.0 + modeShift) * PI * nz);
    float mode2Z = cos((2.0 + modeShift) * PI * nz);

    // Combine modal patterns — interference creates nodes/antinodes
    float modalPressure = (mode1X * mode1Z * 0.4 + mode2X * mode2Z * 0.3
                          + mode1X * mode2Z * 0.15 + mode2X * mode1Z * 0.15);
    modalPressure *= bassEnergy;

    // Kick excites room modes — transient energy burst
    modalPressure += kickSurge * mode1X * mode1Z * 0.3;

    // Grid lines on floor
    float2 gridUV = float2(hitPos.x * world.gridScale, -hitPos.z * world.gridScale * 0.9);
    float2 gridId = abs(frac(gridUV) - 0.5);
    float gridLine = smoothstep(0.47, 0.5, max(gridId.x, gridId.y));

    // Depth fade
    float gridFade = smoothstep(0.0, 8.0, tFloor) * smoothstep(30.0, 12.0, tFloor);

    // Modal pressure modulates grid brightness — antinodes glow, nodes stay dark
    float modeIntensity = abs(modalPressure) * 0.08;
    col += a.brainCol * gridLine * world.gridIntensity * gridFade * silence;
    col += a.brainCol * modeIntensity * gridFade * silence;  // modal glow between lines
    col += a.brainCol2 * gridLine * abs(modalPressure) * 0.06 * gridFade * silence;

    // Kick — floor vibration
    col += float3(1.0, 0.5, 0.15) * gridLine * kickSurge * 0.04 * gridFade * silence;

    return col;
}

// ── Diffuse reverb tail — volumetric ambient glow tracking T60 decay ──
float3 reverbTail(float2 p, float r, SeCamera cam, SeWorld world, AudioData a,
                  float envelope, float lufs, float silence)
{
    // Reverb density follows envelope (sustained energy = dense reverb)
    float reverbDensity = envelope * (0.5 + lufs * 0.3);

    // Diffuse glow — no spatial structure, just ambient field
    // Falloff from center (listener position) — reverb is everywhere but denser near sources
    float3 col = a.brainCol2 * reverbDensity * 0.008 * exp(-r * 1.5) * silence;
    col += a.brainCol3 * reverbDensity * 0.005 * exp(-r * 3.0) * silence;

    // High-frequency reverb shimmer — decays faster (air absorption)
    float hfReverb = (a.b6 * 0.3 + a.b7 * 0.2) * envelope;
    col += a.brainCol * hfReverb * 0.003 * exp(-r * 4.0) * silence;

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

    // ── Camera — VR head pose or desktop orbit inside the room ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.9;
        float camAng = a.section * 0.15 + a.stereoBal * 0.08 + Time * 0.005 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 3.0, 1.0 + a.stereoDiff * 0.1, 3.5 + cos(camAng) * 1.0);
        cam = seCamera(camPos, float3(0, 0, -2.0), FOV);
    }

    // ── Spatial encoder: PSYCHOACOUSTIC profile ──
    // Azimuth = stereo pan, elevation = frequency band, distance = energy
    SeParams params = seParams(SE_PROFILE_PSYCHOACOUSTIC);
    params.widthScale = 2.5;
    params.heightScale = 2.0;
    params.depthScale = 4.0;
    params.jitterAmt = 0.1 + thd * 0.15;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment — acoustic room (floor + ceiling + back wall) ──
    SeWorld world = seWorld(0.05, float3(0.003, 0.002, 0.008), ROOM_FLOOR, ROOM_CEIL, ROOM_BACK);
    world.gridScale = 2.0;
    world.gridIntensity = 0.03;
    world.ambientLevel = 0.004;
    world.ambientColor = float3(0.01, 0.008, 0.02);
    world.flags = 7;  // floor + ceiling + back wall
    seApplyWorldFog(emit, world);

    // ── Background — room environment + room mode patterns on floor ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += roomModePattern(p, cam, world, a, kickSurge, silence);

    // ── Early reflections — image source method (16-source culling) ──
    // Reflect emitters across floor, ceiling, back wall, and side walls
    // Surface absorption: floor=0.7, ceiling=0.6, back=0.5, sides=0.4
    // THD increases surface roughness (more scattering, less specular reflection)
    float surfaceRough = 1.0 - thd * 0.2;

    [loop] for (int bi = 0; bi < SE_N_BANDS; bi++) {
        int li = bi * SE_N_SUB * 2 + 2;  // si=1, left (16-source culling)
        int ri = bi * SE_N_SUB * 2 + 3;  // si=1, right

        // Floor reflection
        if (emit[li].active > 0.01 && emit[li].depth > 0.1)
            col += earlyReflection(p, emit[li], cam, world,
                float3(0, ROOM_FLOOR, 0), float3(0, 1, 0), 0.7 * surfaceRough, lufs, silence);
        if (emit[ri].active > 0.01 && emit[ri].depth > 0.1)
            col += earlyReflection(p, emit[ri], cam, world,
                float3(0, ROOM_FLOOR, 0), float3(0, 1, 0), 0.7 * surfaceRough, lufs, silence);

        // Ceiling reflection
        if (emit[li].active > 0.01 && emit[li].depth > 0.1)
            col += earlyReflection(p, emit[li], cam, world,
                float3(0, ROOM_CEIL, 0), float3(0, -1, 0), 0.6 * surfaceRough, lufs, silence);
        if (emit[ri].active > 0.01 && emit[ri].depth > 0.1)
            col += earlyReflection(p, emit[ri], cam, world,
                float3(0, ROOM_CEIL, 0), float3(0, -1, 0), 0.6 * surfaceRough, lufs, silence);

        // Back wall reflection
        if (emit[li].active > 0.01 && emit[li].depth > 0.1)
            col += earlyReflection(p, emit[li], cam, world,
                float3(0, 0, ROOM_BACK), float3(0, 0, 1), 0.5 * surfaceRough, lufs, silence);
        if (emit[ri].active > 0.01 && emit[ri].depth > 0.1)
            col += earlyReflection(p, emit[ri], cam, world,
                float3(0, 0, ROOM_BACK), float3(0, 0, 1), 0.5 * surfaceRough, lufs, silence);
    }

    // ── Direct sound — emitter glow (primary visual, 16-source culling) ──
    // Precedence effect: direct sound is sharp and bright, reflections are dim/blurry
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
        [loop] for (int bi = 0; bi < SE_N_BANDS; bi++) {
            int li = bi * SE_N_SUB * 2 + 2;
            int ri = bi * SE_N_SUB * 2 + 3;
            if (emit[li].active > 0.01 && emit[li].depth > 0.1)
                col += seEmitGlowDepth(p, emit[li], world, lufs, crest, beatBright,
                                       a.beatPhase, kickSurge, transientAmt, silence);
            if (emit[ri].active > 0.01 && emit[ri].depth > 0.1)
                col += seEmitGlowDepth(p, emit[ri], world, lufs, crest, beatBright,
                                       a.beatPhase, kickSurge, transientAmt, silence);
        }
    }

    // ── L↔R links — phase coherence beams ──
    [loop] for (int lb = 0; lb < SE_N_BANDS; lb++) {
        col += seLinkLR(p, emit, lb, phaseCorr, phaseCoh, silence);
    }

    // ── Listener focal point — spatial anchor ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Diffuse reverb tail — T60 decay glow ──
    col += reverbTail(p, r, cam, world, a, envelope, lufs, silence);

    // ── Ambient energy — minimal ──
    col += a.brainCol3 * a.colorPulse * 0.01 * silence;
    col += a.brainCol * a.energy * 0.005 * silence;
    col += a.brainCol2 * a.punch * 0.005 * silence;
    col += a.brainCol * a.beatAnt * 0.008 * exp(-r * 2.0) * silence;

    // ── Dynamic range — quiet passages dark ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays (sparing) ──
    col += standardOverlays(p, r, a) * 0.02;

        // ── Active-emitter normalization — busy music doesn't stack brighter ──
    col *= sqrt(16.0 / seActiveCount(emit));
    // ── Soft tone mapping (Reinhard) — no hard clamp, preserves color ──
    col = softReinhard(col);

    col *= silence;

    return float4(col, 1.0);
}
