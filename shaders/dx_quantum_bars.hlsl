// Mode 1: Quantum Bars — 3D frequency bars with quantum probability clouds
// 48 bars in 3D perspective, brain-colored, glowing tops on beat
// Kick floor flash, quantum cloud halos, floor reflection, beat shockwave
// Starfield + godrays, standard overlays, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define NUM_BARS 128.0

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Background ──
    float3 col = float3(0.01, 0.008, 0.02) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.4;
    col += godRays(p, r, a) * 0.25;

    // Quantum vacuum shimmer — brain-colored
    float vacuum = fbm2_4(p * 3.0 + Time * 0.08 * a.motSpeed);
    col += a.brainCol * vacuum * 0.08 * a.ambient * a.ambActive * (1.0 - a.isSilent);

    float halfArea = Aspect;
    float barW = (2.0 * halfArea) / NUM_BARS;  // full screen width divided by bar count
    float barGap = barW * 0.2;
    float maxH = 1.3 * (0.7 + a.kick * 0.4 * a.kickConf) * a.barScale;
    float floorY = 0.85;  // bottom of screen (p.y=+1 is bottom)

    [loop] for (float i = 0.0; i < NUM_BARS; i += 1.0) {
        float bF = i / NUM_BARS;
        float freq = 20.0 * pow(1200.0, bF);
        float sPos = saturate(freq / 24000.0);
        float specC = u_spectrum.SampleLevel(u_sampler, float2(sPos, 0.5), 0).r;
        float specL = u_spectrum.SampleLevel(u_sampler, float2(sPos, 0.166), 0).r;
        float specR = u_spectrum.SampleLevel(u_sampler, float2(sPos, 0.833), 0).r;
        float subMix = 1.0 - smoothstep(0.0, 0.08, bF);
        float val = lerp(specC, (specL + specR) * 0.5, subMix);
        val = saturate(val * 0.4);
        float qJump = a.beat * exp(-bF * 2.5) * 0.2 * a.tempoConf;
        float h = (val + qJump) * maxH;
        // 3D perspective — center bars taller, edge bars shorter
        float persp = 1.0 - abs(bF - 0.5) * 0.3;
        h *= persp;

        // Brain-driven hue
        float hue = a.hueBase + bF * a.hueRange * 0.5 + a.section * 0.03 + a.colorPulse * 0.04;
        float3 barCol = hsv(hue, 0.9 * a.satur, 1.2);
        float3 barGlow = hsv(hue + 0.05, 0.7 * a.satur, 1.5);

        // Full-width bars — spread across entire window
        {
            float cx = (i / NUM_BARS - 0.5) * 2.0 * halfArea;  // full width: -halfArea to +halfArea
            float xd = abs(p.x - cx);
            float edge = smoothstep(barW * 0.5, barW * 0.5 - barGap, xd);
            float top = floorY - h;  // bars go up = lower p.y
            float bot = floorY;
            float mask = step(top, p.y) * step(p.y, bot) * edge;
            float hf = saturate((bot - p.y) / max(0.001, bot - top));
            // Glowing top cap — bright at bar tip (hf near 0)
            float topGlow = smoothstep(0.25, 0.0, hf) * (a.beat * 0.6 * a.tempoConf + a.dynLight * 0.3 * a.dynActive);
            float3 litCol = barCol * (0.8 + topGlow);
            litCol += barGlow * topGlow * 1.2;
            col = lerp(col, litCol, mask * (1.0 - a.isSilent));

            // Quantum cloud halo — brain secondary, transient-reactive
            if (xd < barW * 3.0) {
                float cn = fbm2_4(float2(xd * 6.0, p.y * 3.0 + Time * 2.0 * a.motSpeed + i * 0.7));
                float ci = cn * a.transient * 0.5 * exp(-xd * xd * 10.0);
                col += a.brainCol2 * ci * a.bloomActive * (1.0 - a.isSilent);
            }
        }
    }

    // Floor line glow — kick reactive, bright
    float floorGlow = exp(-abs(p.y - floorY) * 20.0) * a.kick * 0.5 * a.kickConf;
    col += a.brainCol * floorGlow * (1.0 - a.isSilent);
    // Persistent floor line
    float floorLine = exp(-abs(p.y - floorY) * 60.0) * 0.15 * a.brightness;
    col += a.brainCol2 * floorLine * (1.0 - a.isSilent);

    // Beat shockwave — expanding ring from center
    float beatPhase = frac(Time * (a.bpm > 1.0 ? a.bpm / 120.0 : 0.5) * 0.5 * a.motSpeed);
    float beatR = beatPhase * 1.8;
    float beatFade = 1.0 - beatPhase;
    float beatRing = exp(-abs(r - beatR) * 25.0) * beatFade;
    col += hsv(a.hueCenter, 0.5 * a.satur, 1.5) * beatRing * a.beat * 0.5 * a.tempoConf * (1.0 - a.isSilent);

    // Kick flash — center burst
    float kickFlash = exp(-r * r * 5.0) * a.kick * 0.4 * a.kickConf;
    col += a.brainCol2 * kickFlash * a.bloomActive * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.5;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
