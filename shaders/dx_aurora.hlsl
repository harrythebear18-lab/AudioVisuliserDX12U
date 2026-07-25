// Mode 7: Aurora Borealis — Ionospheric Curtain
// Real raymarched volumetric depth. One to four luminous plasma curtains hang
// close to the camera and fill the frame — not a distant thin line.
// Exclusive brain-role mapping (DX12U_VISUALIZATION_RULES.md):
//   bass      -> curtain MASS: thickness + base glow (foundation)
//   mids      -> TOPOLOGY: curl-noise fold frequency/amplitude of the curtain's spine
//   highs     -> MICRO-DETAIL: fine vertical filament streaking
//   stereo    -> DIRECTIONAL FORCE: lateral curtain placement, L/R independent when multiple
//   beat      -> COHERENT WAVE: whole-curtain brightness pulse
//   kick      -> IMPULSE: bright ground-level shockfront
//   transient -> RUPTURE: a tearing rip cuts through the curtain body
//   section   -> REGIME: how many curtains are active (1-4)
#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/raymarch.hlsl"
#include "include/layers.hlsl"

#define MAX_CURTAINS 4
#define MARCH_STEPS 40

// Curtain spine X position at a given height — topology folded by curl noise (mids)
float curtainSpineX(int i, float y, float baseX, float foldFreq, float foldAmp, float t) {
    float2 n = curl2(float2(y * foldFreq + float(i) * 4.3, t));
    return baseX + n.x * foldAmp;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ---- night sky base ----
    float3 col = lerp(a.brainCol * 0.025, a.brainCol2 * 0.015, saturate(uv.y));
    col += starfield(uv, a) * 0.28 * (1.0 - a.isSilent);

    // ---- exclusive brain roles ----
    float bass = a.b0 * 0.6 + a.b1 * 0.4;          // MASS
    float mids = (a.b2 + a.b3 + a.b4) / 3.0;        // TOPOLOGY
    float highs = (a.b5 + a.b6 + a.b7) / 3.0;       // MICRO-DETAIL

    // section -> REGIME: 1 to 4 active curtains
    int curtainCount = 1 + (int)floor(saturate(frac(a.section * 0.08)) * 3.999);

    float foldFreq = 1.2 + mids * 2.4;
    float foldAmp = 0.12 + mids * 0.55;
    float thicknessBase = 0.16 + bass * 0.32;        // MASS -> thickness
    float glowBase = (0.3 + bass * 1.1) * (0.35 + a.envelope * 0.65);
    float beatWave = 1.0 + a.beat * a.tempoConf * 0.7; // COHERENT WAVE

    // ---- camera: close, low, looking up into the curtain wall — makes it fill the frame ----
    float3 camPos = float3(a.stereoBal * 0.12, 0.15, -0.55);
    float3 camTarget = float3(0.0, 0.75, 1.2);
    float3 rd = cameraRay(camPos, camTarget, p, 1.35);

    float3 accumCol = float3(0, 0, 0);
    float accumAlpha = 0.0;
    float t = 0.15;
    float maxDist = 3.2;
    float stepLen = maxDist / float(MARCH_STEPS);

    [loop] for (int s = 0; s < MARCH_STEPS && accumAlpha < 0.96; s++) {
        float3 wp = camPos + rd * t;

        // ---- ground-level kick shockfront — IMPULSE ----
        float kickGlow = exp(-(wp.y + 0.15) * (wp.y + 0.15) * 5.0) * a.kick * a.kickConf;
        if (kickGlow > 0.001) {
            accumCol += lerp(a.brainCol, a.brainCol2, 0.5) * kickGlow * stepLen * (1.0 - accumAlpha) * 3.0;
        }

        [unroll] for (int i = 0; i < MAX_CURTAINS; i++) {
            float active = step(float(i), float(curtainCount) - 0.5);
            if (active < 0.5) continue;

            // stereo -> DIRECTIONAL FORCE: independent L/R placement per curtain
            float side = (i % 2 == 0) ? -1.0 : 1.0;
            float stereoAmt = (i % 2 == 0) ? a.leftEn : a.rightEn;
            float baseX = side * (0.25 + float(i / 2) * 0.55) + a.stereoBal * 0.3 + (side * stereoAmt * 0.15);

            float spineX = curtainSpineX(i, wp.y, baseX, foldFreq, foldAmp, Time * 0.05 * a.motSpeed);
            float curtainZ = 0.6 + float(i) * 0.5;

            float dx = wp.x - spineX;
            float dz = wp.z - curtainZ;
            float shapeX = exp(-(dx * dx) / (thicknessBase * thicknessBase));
            float shapeZ = exp(-(dz * dz) / 0.09);
            float vEnv = smoothstep(-0.25, 0.1, wp.y) * smoothstep(2.4, 1.4, wp.y);

            // highs -> MICRO-DETAIL: fine vertical filament streaking
            float filament = 0.55 + 0.45 * sin(wp.x * (30.0 + highs * 40.0) + wp.y * 4.0);
            filament = lerp(1.0, filament, saturate(highs * 1.5));

            // transient -> RUPTURE: a tearing rip cuts through the curtain body
            float tearSeed = float(i) * 13.7 + floor(Time * 2.5);
            float tearX = spineX + (hash11(tearSeed) - 0.5) * thicknessBase * 3.0;
            float tearWidth = 0.045;
            float tearCut = 1.0;
            float tearEdge = 0.0;
            if (a.transient > 0.22) {
                float td = wp.x - tearX;
                tearCut = 1.0 - exp(-(td * td) / (tearWidth * tearWidth)) * a.transient;
                tearEdge = exp(-(td * td) / (tearWidth * tearWidth * 5.0)) * a.transient;
            }

            float density = shapeX * shapeZ * vEnv * glowBase * beatWave * filament * tearCut;

            if (density > 0.001 || tearEdge > 0.001) {
                float freqFrac = float(i) / float(max(MAX_CURTAINS - 1, 1));
                float hue = a.hueBase + freqFrac * a.hueRange + a.section * 0.03;
                float3 curtainCol = lerp(a.brainCol, a.brainCol2, freqFrac);
                curtainCol = lerp(curtainCol, hsv(hue, a.satur, 1.0), 0.55);

                float3 emission = curtainCol * density + hsv(hue + 0.5, 1.0, 1.0) * tearEdge * 1.2;
                float sharp = 1.0 + crestFactorNormalized() * 0.5;
                float alphaStep = saturate(density * stepLen * 3.2 * sharp);
                accumCol += emission * stepLen * (1.0 - accumAlpha) * 2.6;
                accumAlpha += alphaStep * (1.0 - accumAlpha);
            }
        }
        t += stepLen;
    }
    col += accumCol * (1.0 - a.isSilent);

    // ---- shared compositing layers only ----
    col += standardOverlays(p, r, a) * 0.02;

    // LUFS additive exposure (DSP complements, never replaces brain)
    col *= 0.85 + lufsNormalized() * 0.3;

    // soft highlight limiter — bloom-safe
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.8) col *= 1.8 / maxChannel;

    return float4(col, 1.0);
}
