// Mode 37: Resonance Field — 3D Chladni standing wave patterns at spatial audio positions
// Uses Spatial Encoder: 48 SeEmitters placed by stereo spectrum using SPHERICAL profile.
// Each emitter is a resonance node with Chladni-patterned glow — nodal lines and antinodes
// modulated by band frequency and beat phase. Visible from all angles in VR.
// Bass = simple resonance modes, highs = complex nodal patterns.
// Beat = mode shift. Kick = resonance burst ring. Transient = surface ripple.
// DSP: LUFS→brightness, crest→pattern sharpness, THD→noise, phase→L/R coherence.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"
#include "include/spatial_encoder.hlsl"

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — orbiting inside the resonance field ──
    float camAng = a.section * 0.4 + a.stereoBal * 0.2 + Time * 0.015 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 2.5, 1.0 + a.stereoDiff * 0.15, cos(camAng) * 2.5);
    SeCamera cam = seCamera(camPos, float3(0, 0, 0), 0.75);

    // ── Encoder params — spherical distribution around listener ──
    SeParams params = seParams(SE_PROFILE_SPHERICAL);
    params.widthScale = 2.5;
    params.heightScale = 2.5;
    params.depthScale = 3.0;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;
    params.motionSpeed = a.motSpeed;
    params.crossOver = 0.3;
    params.jitterAmt = 0.8;

    // ── Background — dark resonance chamber ──
    float3 col = float3(0.002, 0.002, 0.006) * silence;
    col += starfield(uv, a) * 0.01;

    float ambient = fbm2_4(p * 3.0 + Time * 0.05) * 0.003 * (1.0 + lufs * 0.1);
    col += float3(0.1, 0.08, 0.15) * ambient * silence;

    // ── Encode 48 spatial emitters from stereo spectrum ──
    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params, lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── Render resonance nodes using fused glow with Chladni modulation ──
    // Instead of computing expensive 3D Chladni per pixel, modulate the glow
    // intensity with a cheap 2D standing wave pattern centered on each emitter
    [loop] for (int i = 0; i < SE_NUM_OBJ; i++) {
        if (emit[i].active < 0.01 || emit[i].depth < 0.1) continue;

        float2 diff = p - emit[i].screenPos;
        float d2 = dot(diff, diff);
        float s = emit[i].screenSize;
        float s2 = s * s;

        // Distance cull — same as seEmitGlow
        if (d2 > s2 * 55.2) continue;

        float d = sqrt(d2);
        float bt = float(emit[i].bandIdx) / float(SE_N_BANDS - 1);

        // Cheap 2D Chladni-like pattern — nodal lines via sin/cos product
        // Mode number increases with band (more complex patterns at high freqs)
        float modeN = 2.0 + float(emit[i].bandIdx) * 0.8 + floor(a.beatPhase * 3.0) * 0.5;
        float angle = atan2(diff.y, diff.x);
        float chladni = sin(modeN * angle + Time * (1.0 + bt * 2.0)) *
                        cos(modeN * d / s * 2.0 + a.beatPhase * PI);
        // Nodal lines (near zero) = bright edges, antinodes = surface fill
        float nodal = exp(-abs(chladni) * 4.0);
        float antinode = abs(chladni) * 0.4;

        // Standard glow layers (fused — 3 exp calls)
        float outer = exp(-d2 / (s2 * 8.0));
        float mid = exp(-d2 / (s2 * 2.5));
        float core = exp(-d2 / (s2 * 0.25));

        float intensity = emit[i].intensity * (1.0 + lufs * 0.2);
        float depthFade = exp(-emit[i].depth * 0.08);

        // Modulate glow with Chladni pattern — nodal lines brighten the surface
        float surfaceMod = 0.7 + nodal * 0.5 + antinode * 0.3;

        col += emit[i].color * outer * intensity * 0.07 * surfaceMod * depthFade * silence;
        col += emit[i].color * mid * (0.05 + intensity * 0.17) * 0.12 * surfaceMod * depthFade * silence;
        col += float3(0.9, 0.95, 1.0) * core * intensity * (0.5 + beatPulse * 0.5) * (1.0 + crest * 0.3) * 0.13 * depthFade * silence;

        // Wave rings — Chladni-patterned
        float wp = emit[i].wavePhase;
        float r1 = frac(wp * 0.3) * s * 6.0;
        col += emit[i].color * exp(-abs(d - r1) * 50.0 / emit[i].depth) * intensity * 0.05 * nodal * silence;

        // Kick — resonance burst ring (bass bands only)
        if (emit[i].bandIdx <= 1 && kickSurge > 0.1) {
            float burstR = a.beatPhase * s * 5.0;
            col += emit[i].color * exp(-abs(d - burstR) * 30.0 / emit[i].depth) * kickSurge * 0.04 * silence;
        }

        // Transient — surface ripple
        if (transientAmt > 0.15) {
            float trR = transientAmt * s * 5.0;
            col += emit[i].color * exp(-abs(d - trR) * 60.0 / emit[i].depth) * transientAmt * 0.05 * silence;
        }

        // THD — surface noise
        col += emit[i].color * thd * hash21(emit[i].screenPos * 30.0 + Time * 10.0) * mid * 0.03 * silence;
    }

    // ── L↔R resonance links — phase coherence connections ──
    [loop] for (int lb = 0; lb < SE_N_BANDS; lb++) {
        col += seLinkLR(p, emit, lb, 1.0, phaseCoh, silence) * 0.5;
    }

    // ── Mode-specific overlays ──
    float ringDist = abs(r - a.beatPhase * 0.6);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;
    col += a.brainCol3 * kickSurge * 0.04 * exp(-r * r * 4.0) * silence;
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.02 * silence;
    col += a.brainCol3 * a.colorPulse * 0.015 * silence;
    col += a.brainCol2 * a.energy * 0.01 * silence;
    col += a.brainCol * a.punch * 0.01 * silence;
    col += a.brainCol * a.beatAnt * 0.008 * exp(-r * 2.0) * silence;

    col *= (0.3 + a.gated * 0.7);
    col += standardOverlays(p, r, a) * 0.015;

    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;
    return float4(col, 1.0);
}
