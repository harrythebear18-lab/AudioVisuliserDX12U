// ============================================================================
// HUD 14: Acoustic Holography (dx_neural_network.hlsl)
// DX12U Layer 0 Rewrite — Volumetric Interference Field
//
// 3D volumetric wave interference field from converging acoustic emitters.
// 3 emitters (L, R, vertical) superpose wavefronts → standing wave nodes +
// dynamic fringe patterns. Bass = field scale/mass, mids = carrier frequency/
// topology, highs = micro-filaments/glints. Stereo = beam steering. Kick =
// shockwave impulse. Transient = phase breaks. No applyPostFX, no postfx include.
// ============================================================================

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define MARCH_STEPS 48

// 3D acoustic interference field — 3 emitter superposition
float acousticField(float3 p, AudioData a, float lufs, float crest, float thd, float phaseCoh)
{
    // Bass = mass & field scale (compressor on bass)
    float bassMass = (pow(a.b0, 0.5) + pow(a.b1, 0.5)) * 0.5;
    bassMass *= (1.0 + lufs * 0.2);

    // Mids = carrier frequency / wave topology
    float waveFreq = 3.0 + a.b2 * 4.0 + a.b3 * 2.0;

    // Phase steering — stereo + beat phase + transient phase breaks
    float phaseShift = a.beatPhase * PI * 2.0 + a.stereoDiff * 0.8 * phaseCoh;
    float transientTr = a.transient * 1.5;

    // Asymmetric emitter positions — stereo balance steers beams
    float3 emitterA = float3(-1.2 - a.stereoBal * 0.5, 0.0, 0.0);
    float3 emitterB = float3( 1.2 - a.stereoBal * 0.5, 0.0, 0.0);
    float3 emitterC = float3(0.0, 1.5 * (1.0 + bassMass * 0.3), 0.0);

    // Distances from acoustic emitters
    float dA = length(p - emitterA);
    float dB = length(p - emitterB);
    float dC = length(p - emitterC);

    // Superposition of wave fronts from 3 emitters
    float waveA = sin(dA * waveFreq - phaseShift + transientTr);
    float waveB = sin(dB * waveFreq + phaseShift);
    float waveC = cos(dC * (waveFreq * 0.5) - a.beatPhase * PI);

    // Constructive/destructive interference
    float interference = (waveA + waveB + waveC) / 3.0;

    // Micro-filaments from brilliance/air — high-frequency shimmer on peaks
    float microFilament = sin(p.x * 20.0 + p.y * 20.0 + p.z * 18.0) * (a.b6 + a.b7) * 0.15;

    // THD additive — controlled roughness on interference
    interference += thd * 0.05 * sin(dA * waveFreq * 2.0 + dB * waveFreq * 1.5);

    // Crest additive — sharpens constructive nodes
    interference *= (1.0 + crest * 0.25);

    return interference + microFilament;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();

    // Noise gate + silence
    float gate = smoothstep(0.02, 0.08, a.overall);
    float silence = 1.0 - a.isSilent;

    // ── Background — dark void ──
    float3 col = float3(0.001, 0.001, 0.003) * silence;
    col += starfield(uv, a) * 0.01;

    // ── Camera — 3/4 angle, stereo drift ──
    float camAng = a.stereoBal * 0.2 + a.section * 0.15;
    float3 camPos = float3(sin(camAng) * 3.0, 1.2, cos(camAng) * 3.0);
    float3 camTarget = float3(0.0, 0.3, 0.0);
    float3 rd = cameraRay(camPos, camTarget, float2(-p.x, -p.y), 0.35);

    // ── Volumetric raymarch — accumulate interference field ──
    float t = 0.2;
    float3 accum = float3(0.0, 0.0, 0.0);
    float totalGlow = 0.0;

    [loop] for (int i = 0; i < MARCH_STEPS; i++)
    {
        float3 sp = camPos + rd * t;

        // Bounding sphere
        if (length(sp) > 4.0) break;

        // Domain warp driven by low-mids — organic field distortion
        sp.xz += float2(sin(sp.y * 2.0 + a.beatPhase * PI * 2.0),
                        cos(sp.y * 2.0 + a.beatPhase * PI * 2.0)) * a.b2 * 0.2;

        float fieldVal = acousticField(sp, a, lufs, crest, thd, phaseCoh);

        // Focus peak interference — pow sharpens constructive nodes
        float density = pow(max(0.0, fieldVal), 3.0);

        if (density > 0.01)
        {
            // Palette blending — brain colors + DSP crest color
            float3 baseCol = lerp(a.brainCol, a.brainCol2, fieldVal * 0.5 + 0.5);
            float3 crestCol = a.brainCol3 * (1.0 + crest * 0.3);
            float3 nodeGlow = lerp(baseCol, crestCol, density);

            // Kick shockwave — localized high-density pressure front
            float kickBoost = 1.0 + a.kick * a.kickConf * 2.0;

            // Additive light accumulation — distance attenuated
            accum += nodeGlow * density * (0.04 / (t * t + 0.1)) * kickBoost * silence;
            totalGlow += density * 0.003;
        }

        // Variable step length — denser regions sampled finer
        t += max(0.04, 0.08 - density * 0.03);
        if (t > 8.0) break;
    }

    col += accum * gate;

    // ── Volumetric glow — subsurface scatter ──
    col += a.brainCol * totalGlow * (0.02 + a.glow * 0.03) * (0.5 + a.envelope * 0.5) * silence;

    // ── Beat shockwave — expanding ring through field ──
    float beatPulse = a.beat * a.tempoConf;
    float ringDist = abs(r - a.beatPhase * 0.8);
    col += a.brainCol * exp(-ringDist * ringDist * 30.0) * beatPulse * 0.03 * silence;

    // ── Kick flash — central pressure burst ──
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    col += float3(1.0, 0.6, 0.2) * kickSurge * 0.04 * exp(-r * r * 4.0) * silence;

    // ── Transient pop — phase break scatter ──
    col += float3(1.0, 0.85, 0.6) * a.transient * 0.02 * silence;

    // ── Envelope swell ──
    col += a.brainCol2 * a.envelope * 0.015 * exp(-r * 2.0) * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.015 * silence;

    // ── Energy + punch ──
    col += a.brainCol * a.energy * 0.01 * silence;
    col += a.brainCol2 * a.punch * 0.01 * silence;

    col += standardOverlays(p, r, a) * 0.02;

    // ── HDR brightness limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    return float4(col, 1.0);
}
