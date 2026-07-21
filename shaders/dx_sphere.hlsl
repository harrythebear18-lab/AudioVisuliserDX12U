// Mode 6: Chladni Plate — real standing-wave interference resonance
// field(x,z) = sum of 8 mode-pair standing waves, one per audio band.
// Mode number increases with frequency (bass=broad pattern, treble=fine
// pattern) — a genuine physical analogy, not a metaphor. Section drives how
// many modes are unlocked (regime), dominant band is highlighted, L/R energy
// skews mode numbers asymmetrically (independent stereo structure), beat
// realigns phases (plate strike), kick adds a traveling impulse ripple,
// transient scatters glints along nodal lines.
#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PLATE_MODES 8
#define PI 3.14159265

float chladniField(float2 pc, AudioData a, float regimeLevel, float stereoSkew,
                    float phaseNorm, float beatSync, out float domContribution, int domIdx)
{
    float field = 0.0;
    domContribution = 0.0;
    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    [unroll] for (int i = 0; i < PLATE_MODES; i++)
    {
        float unlock = saturate(regimeLevel * float(PLATE_MODES) - float(i) + 2.0);
        float amp = bands[i] * unlock;

        float m = float(i + 1);
        float skew = 1.0 + stereoSkew * 0.4 * (1.0 - phaseNorm);
        float n = m * skew;

        float phi = Time * (0.12 + a.motSpeed * 0.08) * (1.0 + float(i) * 0.05);
        phi = lerp(phi, 0.0, beatSync * 0.6);

        float contribution = amp * cos(m * PI * pc.x + phi) * cos(n * PI * pc.y + phi);
        field += contribution;
        if (i == domIdx) domContribution = contribution;
    }
    return field;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r0 = length(p);
    float silence = 1.0 - a.isSilent;
    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();

    // ── Background ──
    float3 col = float3(0.008, 0.006, 0.016) * silence;
    col += starfield(uv, a) * 0.12;

    // ── Camera — ray/plane intersection (genuine 3D perspective, not a 2D trick) ──
    float3 camPos = float3(a.stereoBal * 0.15, 1.7, 2.0);
    float3 camTarget = float3(0.0, -0.15, 0.0);
    float3 rd = cameraRay(camPos, camTarget, p, 1.0);

    float plateRadius = 1.3;

    if (rd.y < -0.0005)
    {
        float t = -camPos.y / rd.y;
        float3 hit = camPos + rd * t;
        float2 plateCoord = hit.xz;
        float r = length(plateCoord);

        if (t > 0.0 && r < plateRadius)
        {
            // ── Brain-macro regime + structure ──
            float regimeLevel = saturate(a.section);
            float stereoSkew = a.rightEn - a.leftEn;
            float phaseNorm = saturate(a.phaseCorr * 0.5 + 0.5);
            float beatSync = a.beat * a.tempoConf;
            int domIdx = clamp(int(a.domBand * 8.0), 0, 7);

            float domContribution;
            float field = chladniField(plateCoord, a, regimeLevel, stereoSkew, phaseNorm, beatSync, domContribution, domIdx);

            // Kick impulse ripple — traveling disturbance on the plate
            float kickTravel = frac(Time * 1.2) * plateRadius * 1.3;
            field += a.kick * a.kickConf * 0.35 * exp(-abs(r - kickTravel) * 6.0);

            // ── Shading: nodal lines (sand collects at zero-crossings) + antinode fill ──
            float lineSharpness = 34.0 / (1.0 + crest * 0.6);
            float nodeLine = exp(-field * field * lineSharpness);
            float antinodeMag = saturate(abs(field));

            float zoneT = saturate(r / plateRadius);
            float3 fillColor = lerp(a.brainCol, a.brainCol2, zoneT);
            float domHighlight = saturate(abs(domContribution) * 3.0);
            fillColor = lerp(fillColor, a.brainCol3, domHighlight * 0.5);

            float baseBrightness = (0.14 + a.envelope * 0.22) * (1.0 + lufs * 0.25);
            float3 plateCol = fillColor * antinodeMag * baseBrightness;
            plateCol += float3(1.0, 0.98, 0.9) * nodeLine * (0.45 + a.brightness * 0.35);

            // Transient glints along nodal lines
            float sparkleNoise = hash21(plateCoord * 220.0 + floor(Time * 10.0));
            float glint = step(0.985 - a.transient * 0.4, sparkleNoise) * nodeLine * a.transient;
            plateCol += a.brainCol3 * glint * 0.9;

            // Edge fade + distance fog (real perspective depth, from actual ray distance)
            plateCol *= smoothstep(plateRadius * 1.05, plateRadius * 0.55, r);
            plateCol *= exp(-t * 0.12);

            col += plateCol * silence;
        }

        // Rim glow at plate boundary
        float rimGlow = exp(-abs(length(float2(hit.x, hit.z)) - plateRadius) * 8.0) * (0.12 + a.beat * 0.18 * a.tempoConf);
        col += lerp(a.brainCol, a.brainCol2, 0.5) * rimGlow * step(t, 8.0) * step(0.0, t) * silence;
    }

    // ── Foreground overlays ──
    col += standardOverlays(p, r0, a) * 0.12;

    return float4(col, 1.0);
}
