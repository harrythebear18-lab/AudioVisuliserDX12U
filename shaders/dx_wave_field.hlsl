// Mode 48: Spatiotemporal Wave Field — 3D wave propagation from audio sources
// Reference implementation of the Spatial Pipeline architecture.
// 48 pre-computed 3D emitters (8 bands × 3 sub-freq × L/R) from stereo spectrum.
// X = stereo side (L/R cross-over), Y = frequency band, Z = amplitude depth.
// Visual identity: 3D wave grid with expanding spherical wavefronts and interference links.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"
#include "include/spatial_pipeline.hlsl"

#define PI 3.14159265

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
    float beatBright = a.beat * a.tempoConf;

    // ── Camera ──
    float camAng = a.section * 0.15 + a.stereoBal * 0.08 + Time * 0.005 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 1.5, 1.5 + a.stereoDiff * 0.08, 2.8 + cos(camAng) * 0.3);
    SpCamera cam = spCamera(camPos, float3(0, -0.3, -2.0), 0.75);

    float3 col = float3(0.002, 0.002, 0.006) * silence;
    col += starfield(uv, a) * 0.008;

    // ── Floor and wall grid (wave_field visual identity) ──
    {
        float3 rd = normalize(cam.fwd + p.x * cam.right * cam.fov + p.y * cam.up * cam.fov);
        float tFloor = (-1.8 - cam.pos.y) / rd.y;
        if (tFloor > 0.0 && tFloor < 25.0) {
            float3 hitPos = cam.pos + rd * tFloor;
            float2 gridUV = float2(hitPos.x * 2.0, -hitPos.z * 1.8);
            float2 gridId = abs(frac(gridUV) - 0.5);
            float gridLine = smoothstep(0.47, 0.5, max(gridId.x, gridId.y));
            float gridFade = smoothstep(0.0, 8.0, tFloor) * smoothstep(25.0, 12.0, tFloor);
            col += a.brainCol * gridLine * 0.04 * gridFade * silence;
            col += a.brainCol2 * gridLine * kickSurge * 0.06 * gridFade * silence;
        }
        float tWall = (-6.0 - cam.pos.z) / rd.z;
        if (tWall > 0.0) {
            float3 hitPos = cam.pos + rd * tWall;
            float2 wallUV = float2(hitPos.x * 1.8, hitPos.y * 1.8);
            float2 wallId = abs(frac(wallUV) - 0.5);
            float wallLine = smoothstep(0.47, 0.5, max(wallId.x, wallId.y));
            float wallFade = smoothstep(0.0, 5.0, tWall) * smoothstep(25.0, 12.0, tWall);
            col += a.brainCol2 * wallLine * 0.02 * wallFade * silence;
        }
    }

    // ── Compute 48 spatial emitters from spectrum L/R ──
    SpEmitter emit[SP_NUM_OBJ];
    spComputeEmitters(emit, bands, a, cam, lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── Render all emitters + links via shared pipeline ──
    col += spRenderAll(p, emit, lufs, crest, beatBright, a.beatPhase,
                       kickSurge * 1.5, transientAmt, a.phaseCorr, phaseCoh, silence);

    // ── Listener position — the "player" in the audio world ──
    float2 listenerPos = spProject(float3(0, 0, -2.0), cam);
    float listenDist = length(p - listenerPos);
    col += a.brainCol * exp(-listenDist * listenDist * 100.0) * 0.1 * silence;

    float beatPulseR = a.beatPhase * 0.2 * a.tempoConf;
    col += a.brainCol2 * exp(-abs(listenDist - beatPulseR) * 35.0) * beatPulse * 0.15 * silence;
    col += float3(1.0, 0.5, 0.15) * exp(-listenDist * listenDist * 8.0) * a.kick * 0.2 * a.kickConf * silence;

    // ── Ambient energy ──
    col += a.brainCol2 * envelope * 0.006 * exp(-r * 2.5) * silence;
    col += a.brainCol3 * a.colorPulse * 0.01 * silence;
    col += a.brainCol * a.energy * 0.005 * silence;
    col += a.brainCol2 * a.punch * 0.005 * silence;
    col += a.brainCol * a.beatAnt * 0.008 * exp(-r * 2.0) * silence;

    col *= (0.3 + a.gated * 0.7);
    col += standardOverlays(p, r, a) * 0.02;

    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.14) col *= 1.14 / maxC;

    col *= silence;
    return float4(col, 1.0);
}
