// Mode 1: Plasma Field — flowing plasma fluid with audio-driven turbulence
// 3-layer domain-warped plasma: bass=large waves, mid=swirls, treble=filaments
// Beat shockwaves, kick radial distortion, brain-driven palette, bright HDR
// Starfield + godrays, standard overlays, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float ang = atan2(p.y, p.x);

    // ── Background ──
    float3 col = float3(0.01, 0.008, 0.02) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.4;
    col += godRays(p, r, a) * 0.25;

    float bpm = a.bpm > 1.0 ? a.bpm / 120.0 : 0.5;
    float t = Time * (0.15 + a.motSpeed * 0.2) * bpm;

    // Stereo balance shifts flow direction
    float2 flowDir = float2(cos(t * 0.3 + a.stereoBal * 2.0), sin(t * 0.2 + a.stereoWid));

    // ── Layer 1: Bass — large slow plasma waves ──
    float2 uvw1 = p * 1.2 + flowDir * t * 0.4;
    float2 q1 = float2(fbm2_4(uvw1 + t * 0.08), fbm2_4(uvw1 + 5.2 + t * 0.1));
    float2 q1b = float2(fbm2_4(uvw1 + 3.0 * q1 + 1.7 + t * 0.05), fbm2_4(uvw1 + 3.0 * q1 + 8.3 + t * 0.07));
    float plasma1 = fbm2_4(uvw1 + 4.0 * q1b);
    plasma1 *= (0.4 + a.profBass * 0.6);
    // Bass radial pulse
    plasma1 += sin(r * 4.0 - t * 3.0) * a.b0 * 0.2;
    plasma1 += sin(r * 6.0 - t * 4.0) * a.b1 * 0.15;

    // ── Layer 2: Mid — turbulent swirls ──
    float2 uvw2 = p * 2.5 + flowDir * t * 0.6 + q1b * 0.5;
    float2 q2 = float2(fbm2_4(uvw2 + t * 0.15), fbm2_4(uvw2 + 3.1 + t * 0.18));
    float plasma2 = fbm2_4(uvw2 + 3.0 * q2);
    plasma2 *= (0.3 + (a.b2 + a.b3 + a.b4) * 0.33 * 0.7);
    // Mid swirl — angular modulation
    plasma2 += sin(ang * 4.0 + t * 2.0) * a.b3 * 0.15;
    plasma2 += sin(ang * 7.0 - t * 3.0) * a.b4 * 0.1;

    // ── Layer 3: Treble — fine filaments ──
    float2 uvw3 = p * 5.0 + flowDir * t * 0.8 + q2 * 0.3;
    float plasma3 = fbm2_4(uvw3 + t * 0.3);
    plasma3 *= (0.2 + a.profTreb * 0.8);
    plasma3 += fbm2_4(uvw3 * 2.0 + t * 0.5) * a.transient * 0.3;

    // ── Combine layers ──
    float plasma = plasma1 * 0.5 + plasma2 * 0.3 + plasma3 * 0.2;
    plasma += a.envelope * 0.08;
    plasma = saturate(plasma);

    // ── Brain-driven palette ──
    float3 col1 = a.brainCol * 0.5;
    float3 col2 = a.brainCol2 * 0.7;
    float3 col3 = hsv(a.hueCenter, 0.7 * a.satur, 0.8);
    float3 col4 = hsv(a.hueBase + a.hueRange, 0.5 * a.satur, 0.9);

    float3 plasmaCol = lerp(col1, col2, smoothstep(0.2, 0.5, plasma));
    plasmaCol = lerp(plasmaCol, col3, smoothstep(0.5, 0.75, plasma));
    plasmaCol = lerp(plasmaCol, col4, smoothstep(0.75, 0.95, plasma));

    // Main plasma fill
    float bright = smoothstep(0.25, 0.8, plasma) * (0.3 + a.envelope * 0.2);
    col += plasmaCol * bright * 0.5 * (1.0 - a.isSilent);

    // ── Spectrum-driven radial glow — subtle frequency hints ──
    [loop] for (int si = 0; si < 16; si++) {
        float sFrac = si / 16.0;
        float specVal = u_spectrum.SampleLevel(u_sampler, float2(sFrac, 0.5), 0).r;
        float sAng = sFrac * 6.28318 + t * 0.1;
        float sR = 0.3 + specVal * 0.8;
        float2 sPos = float2(cos(sAng), sin(sAng)) * sR;
        float sDist = length(p - sPos);
        float sGlow = exp(-sDist * sDist * 8.0) * specVal * 0.04;
        float sHue = a.hueBase + sFrac * a.hueRange;
        col += hsv(sHue, 0.7 * a.satur, 0.8) * sGlow * (1.0 - a.isSilent);
    }

    // ── Edge filaments — bright where plasma gradient is steep ──
    float edge1 = abs(fbm2_4(uvw1 + 4.0 * q1b + 0.02) - plasma1);
    float edge2 = abs(fbm2_4(uvw2 + 3.0 * q2 + 0.02) - plasma2);
    float edge = max(edge1, edge2);
    float filaments = smoothstep(0.04, 0.1, edge) * (a.brightness + a.b5 * 0.3);
    col += plasmaCol * filaments * 0.3 * a.dynActive * (1.0 - a.isSilent);

    // ── Beat shockwave — visible expanding ring ──
    float beatPhase = frac(Time * bpm * 0.5 * a.motSpeed);
    float beatR = beatPhase * 1.8;
    float beatFade = 1.0 - beatPhase;
    float beatRing = exp(-abs(r - beatR) * abs(r - beatR) * 30.0) * beatFade;
    col += hsv(a.hueCenter, 0.5 * a.satur, 0.9) * beatRing * a.beat * 0.4 * a.tempoConf * (1.0 - a.isSilent);

    // ── Kick radial distortion — bright flash + ring ──
    float kickFlash = exp(-r * r * 4.0) * a.kick * 0.3 * a.kickConf;
    col += a.brainCol2 * kickFlash * a.bloomActive * (1.0 - a.isSilent);
    float kickR = frac(Time * 0.8 * a.motSpeed) * 1.5 + 0.1;
    float kickRing = exp(-abs(r - kickR) * 15.0) * a.kick * 0.3 * a.kickConf;
    col += a.brainCol * kickRing * (1.0 - a.isSilent);

    // ── Transient sparks — bright white flecks ──
    float sparkN = hash21(floor(p * 30.0) + floor(Time * 20.0));
    float sparks = step(0.98, sparkN) * a.transient * 0.4;
    col += float3(0.9, 0.95, 1.0) * sparks * a.beamActive * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.5;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
