// Mode 29: Audio Waveform Tunnel — fly through a neon tunnel made of audio
// Polar coordinate approach: r = length(uv), z = 1/r gives forward motion
// Neon rings + angular lanes modulated by spectrum, bass controls speed
// DSP: LUFS→emission density, crest→ring sharpness, THD→wall roughness, phase→twist coherence
// HDR output, no local postfx. Follows DX12U rules.
#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

float tunnelFBM(float2 p) {
    float v = 0.0, am = 0.5;
    [unroll] for (int i = 0; i < 4; i++) {
        v += am * vnoise2(p);
        p = p * 2.03 + 0.3;
        am *= 0.5;
    }
    return v;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float ang = atan2(p.y, p.x);

    // DSP additive
    float dspLUFS = lufsNormalized();
    float dspCrest = crestFactorNormalized();
    float dspTHD = thdNormalized();
    float dspPhaseCoh = phaseCoherence();

    // Bass compressor for speed
    float bassMass = pow(a.b0, 0.5) * (1.0 + dspLUFS * 0.2);

    float3 col = float3(0.001, 0.001, 0.005) * (1.0 - a.isSilent * 0.98);

    // Speed — bass-driven forward motion
    float t = Time * (0.3 + bassMass * 1.2 + a.motSpeed * 0.2);

    // Camera wobble — stereo-driven, not idle
    float2 cam = float2(
        0.08 * sin(t * 0.7) + a.stereoBal * 0.15,
        0.08 * cos(t * 0.53) + a.stereoDiff * 0.1
    );
    // Kick camera shake
    float kickShake = a.kick * a.kickConf * 0.08;
    cam += float2(sin(Time * 37.0), cos(Time * 41.0)) * kickShake;

    float2 pp = p + cam;
    float rr = length(pp);
    float aang = atan2(pp.y, pp.x);

    // Tunnel depth — 1/r gives infinite forward motion toward center
    float z = 1.0 / max(rr, 0.06);
    float forward = t * 2.5;
    float tz = z + forward;

    // Twist — phase coherence makes it coherent, THD adds roughness
    float twist = 0.3 * sin(tz * 0.12 + t * 0.4) + 0.05 * t;
    twist *= lerp(0.5, 1.5, dspPhaseCoh);
    twist += dspTHD * tunnelFBM(float2(tz * 0.04, aang * 2.0)) * 0.15;
    // Transient — tears the tunnel
    twist += a.transient * sin(tz * 0.5 + Time * 15.0) * 0.2;
    aang += twist;

    // Tunnel surface coordinates
    float2 tuv = float2(aang * 2.5, tz * 0.2);

    // Surface detail — THD adds roughness to walls
    float n1 = tunnelFBM(tuv * 2.0 + dspTHD * 0.5);
    float n2 = tunnelFBM(float2(tuv.x * 5.0, tuv.y * 1.2 + t * 0.2));

    // Neon ring structure — crest sharpens rings
    float ringFreq = 1.2 + a.b1 * 0.8 + a.b2 * 0.4;
    float ringSharp = 6.0 + dspCrest * 6.0;
    float rings = sin(tz * ringFreq - n1 * 3.0);
    rings = pow(0.5 + 0.5 * rings, ringSharp);

    // Audio waveform on rings — stereo L/R spectrum
    float specU = saturate(aang / 6.283 + 0.5);
    float specL = u_spectrum.SampleLevel(u_sampler, float2(specU, 0.0), 0).r;
    float specR = u_spectrum.SampleLevel(u_sampler, float2(specU, 1.0), 0).r;
    float specVal = (specL + specR) * 0.5;
    rings *= 0.5 + specVal * 1.5 * a.barScale;

    // Kick: pulse all rings
    rings += a.kick * a.kickConf * pow(0.5 + 0.5 * sin(tz * ringFreq), 4.0) * 0.4;

    // Beat: compression wave down the tunnel
    float beatWave = a.beat * a.tempoConf * pow(0.5 + 0.5 * sin(tz * 0.8 - t * 2.0), 8.0) * 0.3;

    // Angular lane lights — mids drive frequency
    float laneFreq1 = 8.0 + a.b4 * 4.0;
    float laneFreq2 = 5.0 + a.b3 * 3.0;
    float lanes1 = pow(0.5 + 0.5 * sin(aang * laneFreq1 + n2 * 0.3 + tz * 0.05), 14.0);
    float lanes2 = pow(0.5 + 0.5 * sin(aang * laneFreq2 - tz * 0.08), 18.0);

    float grid = rings * lanes1 + 0.5 * rings * lanes2 + beatWave * lanes1;

    // Streaking — bright lines running along the tunnel, highs-driven
    float streaks = pow(1.0 - abs(sin(aang * 12.0 + tz * 0.25)), 16.0);
    streaks *= 0.4 + 0.6 * n1;
    float highShimmer = (a.b6 + a.b7) * 0.5;
    streaks *= 0.5 + highShimmer * 1.5;

    // Central glow / vanishing point — bass-driven
    float core = 0.008 / (rr * rr + 0.003);
    core *= 0.4 + bassMass * 0.5 + a.brightness * 0.3;

    // Tunnel wall mask
    float wall = smoothstep(0.02, 0.15, rr) * (1.0 - smoothstep(0.8, 1.3, rr));

    // Color — shifts with depth and audio
    float hue = tz * 0.02 + n1 * 0.4 + a.hueBase + a.section * 0.05;
    hue += specVal * 0.1 + a.b4 * 0.03;

    float3 baseCol = hsv(hue, 0.8 * a.satur, 1.0);

    // Base tunnel glow — envelope-driven
    col += baseCol * (0.15 + 0.6 * n1) * wall * (0.2 + a.brightness * 0.2 + a.envelope * 0.2);

    // Neon structures — LUFS boosts emission
    float emitBoost = 1.0 + dspLUFS * 0.4;
    col += hsv(hue + 0.08, 0.7, 1.0) * grid * 1.5 * wall * emitBoost;
    col += hsv(hue + 0.15, 0.5, 1.0) * streaks * wall * 1.0 * emitBoost;
    col += hsv(hue + 0.05, 0.6, 1.0) * rings * 0.4 * wall;

    // Moving flashes down the tunnel — beat-driven
    float flash = sin(tz * 0.6 - t * 3.0 + aang * 2.0);
    flash = pow(0.5 + 0.5 * flash, 20.0);
    col += hsv(hue + 0.3, 0.6, 1.0) * flash * 1.5 * wall * (0.2 + a.beat * 0.6 * a.tempoConf);

    // Vanishing point energy
    col += hsv(hue + 0.1, 0.4, 1.0) * core;

    // Bass: radial pulse from center
    float bassPulse = bassMass * 0.12 * exp(-rr * 3.0) * sin(tz * 1.5);
    col += hsv(a.hueCenter, 0.5, 1.0) * bassPulse * wall * (1.0 - a.isSilent);

    // Transient: spark scatter on tunnel walls
    col += hsv(a.hueCenter + 0.5, 0.8, 1.0) * a.transient * streaks * wall * 0.4 * (1.0 - a.isSilent);

    // Beat anticipation — pre-beat tension
    col += hsv(a.hueCenter, 0.3, 1.0) * a.beatAnt * 0.05 * wall * (1.0 - a.isSilent);

    // Foreground overlays
    col += standardOverlays(p, r, a) * 0.02;

    // Brightness limiter — prevent bloom blowout
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.5) col *= 1.5 / maxChannel;

    // Silence suppression
    col *= (1.0 - a.isSilent * 0.98);

    return float4(col, 1.0);
}
