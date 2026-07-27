// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 35: Neon Cityscape — synthwave skyline with SDF buildings
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_TUNNEL.
//
// 48 emitters (8 bands × 3 sub × L/R) placed in corridor depth.
// Emitters become neon buildings along both sides of a flythrough corridor.
// Bass = building height/mass, mids = window illumination/neon flicker,
// highs = particle shimmer/edge highlights. Beat = sun pulse. Kick = ground flash.
// Transient = neon glitch.
//
// World: grid floor as road, fog density 0.08 (thick), dark ambient.
// Camera: flythrough corridor, FOV 0.6 (VR: head pose from OpenXR).
// Visual: SDF raymarched buildings + ground plane, neon window glow, wet reflections.
//
// DSP: LUFS→emission, crest→neon edge, THD→flicker, phase→coherence.
// HDR output to Layer 0. No local postfx. Pipeline owns bloom/tonemap.

#include "include/spatial_encoder.hlsl"
#include "include/sdf.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define MAX_STEPS 40

// ── Building data derived from emitters ──
struct Building {
    float3 pos;
    float3 dims;
    float energy;
    float gate;
    float3 color;
};

void computeBuildingsFromEmitters(out Building bld[SE_NUM_OBJ], SeEmitter emit[SE_NUM_OBJ], AudioData a)
{
    [loop] for (int n = 0; n < SE_NUM_OBJ; n++) {
        bld[n].gate = emit[n].active * step(0.05, emit[n].intensity);
        if (bld[n].gate < 0.01) {
            bld[n].pos = float3(100, 100, 100);
            bld[n].dims = float3(0.01, 0.01, 0.01);
            bld[n].energy = 0.0;
            bld[n].color = float3(0, 0, 0);
            continue;
        }

        // Use emitter world position — TUNNEL profile puts L on left wall, R on right
        float3 ep = emit[n].worldPos;
        float bandFrac = float(emit[n].bandIdx) / 7.0;

        // Height — bass drives taller buildings
        float height = 1.0 + emit[n].intensity * 2.5;
        float width = 0.6 + a.b1 * 0.2;
        float depth = 0.6 + a.b0 * 0.2;

        bld[n].pos = float3(ep.x, height * 0.5 - 1.0, ep.z);
        bld[n].dims = float3(width * 0.5, height * 0.5, depth * 0.5);
        bld[n].energy = emit[n].intensity;
        bld[n].color = emit[n].color;
    }
}

float sceneSDF(float3 p, Building bld[SE_NUM_OBJ])
{
    float minDist = 1e10;
    [loop] for (int i = 0; i < SE_NUM_OBJ; i++) {
        if (bld[i].gate < 0.01) continue;
        float3 local = p - bld[i].pos;
        float d = sdBox(local, bld[i].dims);
        minDist = smin(minDist, d, 0.1);
    }
    // Ground plane
    float ground = sdPlane(p, float3(0, 1, 0), 1.0);
    minDist = smin(minDist, ground, 0.05);
    return minDist;
}

float3 windowGlow(float3 p, Building bld[SE_NUM_OBJ], float thd, AudioData a)
{
    float3 winCol = float3(0, 0, 0);
    [loop] for (int j = 0; j < SE_NUM_OBJ; j++) {
        if (bld[j].gate < 0.01) continue;

        float2 winUV = float2(p.x, p.y + 1.0) * 5.0;
        float2 winCell = floor(winUV);
        float2 winFrac = frac(winUV);

        float winHash = hash21(winCell + float(j) * 17.3);
        float winOn = step(0.5, winHash) * bld[j].gate;

        float flicker = 0.8 + 0.2 * sin(Time * 10.0 + winHash * 100.0) * thd;

        float winShape = smoothstep(0.15, 0.25, winFrac.x) * smoothstep(0.15, 0.25, winFrac.y) *
                         smoothstep(0.85, 0.75, winFrac.x) * smoothstep(0.85, 0.75, winFrac.y);

        winCol += bld[j].color * winOn * winShape * flicker * bld[j].energy * 0.15;
    }
    return winCol;
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

    // ── Camera — VR head pose or desktop flythrough ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.6;
        float camAng = a.section * 0.8 + a.stereoBal * 0.2 + Time * 0.03 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 0.5, -0.3 + a.stereoDiff * 0.15, -4.0);
        cam = seCamera(camPos, float3(a.stereoBal * 0.2, 0.5, 0), FOV);
    }

    // ── Spatial encoder: TUNNEL profile ──
    SeParams params = seParams(SE_PROFILE_TUNNEL);
    params.widthScale = 2.0;
    params.heightScale = 2.0;
    params.depthScale = 8.0;
    params.jitterAmt = 0.15 + thd * 0.2;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.08, float3(0.02, 0.005, 0.04), -1.0, 0.0, 0.0);
    world.gridIntensity = 0.04;
    world.ambientLevel = 0.005;
    world.ambientColor = float3(0.04, 0.01, 0.06);
    seApplyWorldFog(emit, world);

    // ── Derive buildings from emitters ──
    Building bld[SE_NUM_OBJ];
    computeBuildingsFromEmitters(bld, emit, a);

    // ── Background — synthwave sky + world env ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);

    // Setting sun — beat-pulsing
    float2 sunPos = float2(0, 0.3);
    float sunDist = length(p - sunPos);
    float sunPulse = 0.5 + beatPulse * 0.5;
    col += hsv(0.08, 0.6 * a.satur, 0.9) * exp(-sunDist * 3.0) * sunPulse * 0.15 * silence;

    // Sun bands
    float sunBands = step(0.5, frac((p.y - 0.3) * 20.0)) * exp(-sunDist * 2.0) * 0.15;
    col += float3(1.0, 0.4, 0.1) * sunBands * sunPulse * silence;

    col += starfield(uv, a) * 0.02;

    // ── SDF raymarch — buildings and ground ──
    float3 rd = normalize(cam.fwd + p.x * cam.right * cam.fov + p.y * cam.up * cam.fov);
    float t = 0.05;
    float marchGlow = 0.0;
    float steps = 0.0;
    bool hit = false;
    float3 hitPos = float3(0, 0, 0);

    [loop] for (int i = 0; i < MAX_STEPS; i++) {
        float3 sp = cam.pos + rd * t;
        float d = sceneSDF(sp, bld);
        marchGlow += 0.01 / (1.0 + d * d * 50.0);
        steps += 1.0;
        if (d < 0.001) { hit = true; hitPos = sp; break; }
        t += d * 0.5;
        if (t > 30.0) break;
    }

    if (hit) {
        float eps = 0.001;
        float3 n = normalize(float3(
            sceneSDF(hitPos + float3(eps, 0, 0), bld) - sceneSDF(hitPos - float3(eps, 0, 0), bld),
            sceneSDF(hitPos + float3(0, eps, 0), bld) - sceneSDF(hitPos - float3(0, eps, 0), bld),
            sceneSDF(hitPos + float3(0, 0, eps), bld) - sceneSDF(hitPos - float3(0, 0, eps), bld)
        ));

        float ao = 1.0 - steps / float(MAX_STEPS) * 0.5;
        bool isGround = hitPos.y < -0.95;

        if (isGround) {
            // Wet street reflection
            float3 reflDir = reflect(rd, n);
            float3 reflCol = float3(0.02, 0.005, 0.04);
            reflCol += hsv(0.08, 0.6 * a.satur, 0.9) * exp(-length(p - float2(0, 0.3)) * 3.0) * sunPulse * 0.3;
            float reflStrength = 0.3 + a.b0 * 0.4 + a.b1 * 0.3;
            col = lerp(col, reflCol, reflStrength * 0.5) * ao;

            // Street neon lines
            float2 streetUV = float2(p.x / (1.0 - p.y * 0.5), p.y);
            float streetLine = smoothstep(0.48, 0.5, abs(frac(streetUV.x * 3.0) - 0.5));
            col += a.brainCol * streetLine * 0.1 * silence;
            col += a.brainCol3 * kickSurge * 0.08 * silence;
        } else {
            float3 baseCol = float3(0.03, 0.02, 0.05);
            float fres = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
            float3 edgeCol = lerp(a.brainCol, a.brainCol2, a.section * 0.1);
            baseCol += edgeCol * fres * (0.4 + a.b4 * 0.3) * (1.0 + crest * 0.2);

            float3 winCol = windowGlow(hitPos, bld, thd, a);
            float3 litCol = (baseCol + winCol) * ao * (1.0 + lufs * 0.15);

            float neonFlicker = transientAmt * hash21(hitPos.xz * 10.0 + Time * 20.0) * 0.1;
            litCol += a.brainCol3 * neonFlicker * silence;

            // Depth fog on buildings
            float depthFog = exp(-t * world.fogDensity);
            litCol *= depthFog;

            col = blendScreen(col, litCol);
        }
    }

    // March glow — atmospheric haze
    col += a.brainCol * marchGlow * 0.04 * silence;

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

    // ── Flying particles — high-band driven ──
    [unroll] for (int k = 0; k < 8; k++) {
        float kf = float(k) / 8.0;
        float2 partPos = float2(
            sin(kf * PI * 2.0 + Time * 0.5 * a.motSpeed) * 2.0,
            cos(kf * PI * 3.0 + Time * 0.3 * a.motSpeed) * 1.5
        );
        float partDist = length(p - partPos);
        float partGlow = exp(-partDist * partDist * 50.0) * (a.b6 + a.b7) * 0.03;
        col += a.brainCol2 * partGlow * silence;
    }

    // ── Mode-specific overlays — subtle ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;
    col += a.brainCol2 * kickSurge * 0.04 * exp(-r * r * 5.0) * silence;
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.02 * silence;
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
