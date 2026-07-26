// Mode 39: Acoustic Hologram Projector — sci-fi volumetric hologram table
// A glowing pedestal projects a 3D frequency surface that morphs with audio.
// Bass = base geometry shape, mids = surface displacement/waves,
// highs = particle details/sparkles above surface.
// Beat = hologram pulse ring. Kick = geometry spike.
// Transient = glitch/scan distortion. LUFS = hologram opacity/brightness.
// Crest = edge sharpness. THD = scan line jitter. Phase = L/R surface symmetry.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define GRID_RES 6
#define MARCH_STEPS 32

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

float hologramHeight(float2 xz, float bands[8], float beatPulse, float beatPhase,
                     float transient, float envelope, float kickSurge, float thd, float silence)
{
    float r = length(xz);
    if (r > 2.0) return -1.0;

    float h = 0.0;

    // Bass — base dome shape
    h += bands[0] * 0.3 * smoothstep(2.0, 0.0, r);
    h += bands[1] * 0.2 * sin(r * 3.0 - Time * 1.5);

    // Mids — surface ripples
    h += bands[2] * 0.15 * sin(xz.x * 4.0 + Time * 2.0) * cos(xz.y * 4.0 + Time * 1.5);
    h += bands[3] * 0.12 * fbm2_4(xz * 3.0 + Time * 0.5);
    h += bands[4] * 0.10 * sin(xz.x * 8.0 + Time * 3.0) * sin(xz.y * 8.0 - Time * 2.0);

    // Highs — fine detail
    h += bands[5] * 0.06 * fbm2_4(xz * 8.0 + Time * 1.0);
    h += bands[6] * 0.04 * sin(xz.x * 16.0 + Time * 5.0) * sin(xz.y * 16.0 - Time * 4.0);
    h += bands[7] * 0.02 * hash21(xz * 50.0 + Time * 10.0);

    // Beat — radial pulse
    h += beatPulse * 0.08 * sin(r * 5.0 - beatPhase * 6.0) * exp(-r * 0.5) * silence;

    // Kick — central spike
    h += kickSurge * 0.15 * exp(-r * r * 4.0) * silence;

    // Transient — glitch displacement
    if (transient > 0.02)
        h += transient * 0.04 * sin(xz.x * 30.0 + xz.y * 28.0 + beatPhase * 40.0) * silence;

    // Envelope — global swell
    h += envelope * 0.03 * smoothstep(2.0, 0.0, r) * silence;

    // THD — scan line jitter
    h += thd * 0.015 * sin(xz.y * 80.0 + Time * 20.0) * silence;

    return h;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    // Spectrum L/R — augment brain bands with stereo spectrum data
    float specL[8]; float specR[8];
    [unroll] for (int sb = 0; sb < 8; sb++) {
        specL[sb] = u_spectrum.SampleLevel(u_sampler, float2(bandFreq[sb], 0.166), 0).r;
        specR[sb] = u_spectrum.SampleLevel(u_sampler, float2(bandFreq[sb], 0.833), 0).r;
        bands[sb] = max(bands[sb], max(specL[sb], specR[sb]) * 0.5);
    }
    float panMod = (specL[0] + specL[1] - specR[0] - specR[1]) * 0.25;
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;
    float phrase = phrasePulse(a);

    // ── Camera — orbit around hologram table ──
    float FOV = 0.6;
    float camAng = a.section * 0.8 + a.stereoBal * 0.2 + panMod * 0.3;
    float3 camPos = float3(sin(camAng) * 3.0, 2.0, cos(camAng) * 3.0);
    float3 camTarget = float3(0, 0.5, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Background — dark tech room ──
    float3 col = float3(0.001, 0.002, 0.004) * silence;
    col += starfield(uv, a) * 0.005;

    // ── Pedestal — glowing base disc ──
    {
        float3 pedPos = float3(0, 0, 0);
        float3 toPed = pedPos - camPos;
        float pedDepth = dot(toPed, fwd);
        if (pedDepth > 0.1) {
            float2 scrPed = float2(dot(toPed, right) / (pedDepth * FOV), dot(toPed, up) / (pedDepth * FOV));
            float pedR = 2.2 / (pedDepth * FOV);
            float pedDist = length(p - scrPed);
            // Disc edge glow
            float edgeDist = abs(pedDist - pedR);
            col += a.brainCol * exp(-edgeDist * edgeDist * 30.0) * 0.15 * (0.5 + envelope * 0.5) * silence;
            // Disc surface — concentric rings
            float ringPattern = sin(pedDist * 20.0 - Time * 2.0) * 0.5 + 0.5;
            col += a.brainCol2 * ringPattern * exp(-pedDist * pedDist / (pedR * pedR)) * 0.02 * silence;
        }
    }

    // ── Hologram surface — grid of projected points ──
    [loop] for (int gx = 0; gx <= GRID_RES; gx++) {
        [loop] for (int gz = 0; gz <= GRID_RES; gz++) {
            float2 gridUV = float2(float(gx), float(gz)) / float(GRID_RES);
            float2 xz = (gridUV - 0.5) * 4.0;

            float h = hologramHeight(xz, bands, beatPulse, a.beatPhase, transientAmt, envelope, kickSurge, thd, silence);
            if (h < -0.5) continue;

            float3 hp = float3(xz.x, h + 0.5, xz.y);
            float3 toHP = hp - camPos;
            float hpDepth = dot(toHP, fwd);
            if (hpDepth < 0.1) continue;
            float2 scrHP = float2(dot(toHP, right) / (hpDepth * FOV), dot(toHP, up) / (hpDepth * FOV));
            float scrDist = length(p - scrHP);

            // Frequency-positioned color
            float freqFrac = length(xz) / 2.0;
            float3 holoCol = hsv(a.hueBase + freqFrac * a.hueRange, 0.6 * a.satur, 0.9);
            holoCol = lerp(holoCol, lerp(a.brainCol, a.brainCol2, freqFrac), 0.3);

            // Point glow
            float ptSize = 0.008 / max(hpDepth * 0.15, 0.3) * 3.0;
            float ptGlow = exp(-scrDist * scrDist / (ptSize * ptSize));

            // Height-based intensity
            float intensity = (abs(h) * 3.0 + 0.1) * (1.0 + lufs * 0.2);
            float depthFade = exp(-hpDepth * 0.06);

            // Scan line effect — THD
            float scanLine = sin(hp.y * 50.0 + Time * 10.0) * 0.5 + 0.5;
            scanLine = lerp(1.0, scanLine, thd * 0.3);

            col += holoCol * ptGlow * intensity * depthFade * scanLine * 0.4 * silence;

            // Wireframe connections to neighbors
            if (gx < GRID_RES) {
                float2 xz2 = float2(float(gx + 1), float(gz)) / float(GRID_RES);
                xz2 = (xz2 - 0.5) * 4.0;
                float h2 = hologramHeight(xz2, bands, beatPulse, a.beatPhase, transientAmt, envelope, kickSurge, thd, silence);
                if (h2 > -0.5) {
                    float3 hp2 = float3(xz2.x, h2 + 0.5, xz2.y);
                    float3 toHP2 = hp2 - camPos;
                    float hp2Depth = dot(toHP2, fwd);
                    if (hp2Depth > 0.1) {
                        float2 scrHP2 = float2(dot(toHP2, right) / (hp2Depth * FOV), dot(toHP2, up) / (hp2Depth * FOV));
                        float2 ab = scrHP2 - scrHP;
                        float t = clamp(dot(p - scrHP, ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
                        float2 closest = scrHP + ab * t;
                        float wireDist = length(p - closest);
                        float wireGlow = exp(-wireDist * wireDist * 200.0);
                        col += holoCol * wireGlow * intensity * depthFade * 0.1 * silence;
                    }
                }
            }
            if (gz < GRID_RES) {
                float2 xz2 = float2(float(gx), float(gz + 1)) / float(GRID_RES);
                xz2 = (xz2 - 0.5) * 4.0;
                float h2 = hologramHeight(xz2, bands, beatPulse, a.beatPhase, transientAmt, envelope, kickSurge, thd, silence);
                if (h2 > -0.5) {
                    float3 hp2 = float3(xz2.x, h2 + 0.5, xz2.y);
                    float3 toHP2 = hp2 - camPos;
                    float hp2Depth = dot(toHP2, fwd);
                    if (hp2Depth > 0.1) {
                        float2 scrHP2 = float2(dot(toHP2, right) / (hp2Depth * FOV), dot(toHP2, up) / (hp2Depth * FOV));
                        float2 ab = scrHP2 - scrHP;
                        float t = clamp(dot(p - scrHP, ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
                        float2 closest = scrHP + ab * t;
                        float wireDist = length(p - closest);
                        float wireGlow = exp(-wireDist * wireDist * 200.0);
                        col += holoCol * wireGlow * intensity * depthFade * 0.1 * silence;
                    }
                }
            }
        }
    }

    // ── High-band sparkles above surface ──
    float sparkle = (bands[6] + bands[7]) * hash21(p * 80.0 + Time * 30.0) * 0.03;
    col += float3(0.8, 0.9, 1.0) * sparkle * silence;

    // ── Beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.025 * silence;

    // ── Kick flash ──
    col += a.brainCol3 * kickSurge * 0.05 * exp(-r * r * 5.0) * silence;

    // ── Transient — glitch scan ──
    if (transientAmt > 0.02) {
        float glitch = sin(p.y * 100.0 + Time * 50.0) * transientAmt * 0.03;
        col += a.brainCol2 * abs(glitch) * silence;
    }

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.02 * silence;

    // ── Energy + punch ──
    col += a.brainCol2 * a.energy * 0.015 * silence;
    col += a.brainCol * a.punch * 0.015 * silence;

    // ── Beat anticipation ──
    col += a.brainCol * a.beatAnt * 0.01 * exp(-r * 2.0) * silence;

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── HDR limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.14) col *= 1.14 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
