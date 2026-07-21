// Mode 5: Audio Lichtenberg — branching electrical discharge tree
// A single trunk grows upward from a stereo-biased source and forks into
// four branch generations. Each generation is driven by an exclusive audio
// role: bass = trunk mass, low-mid/mid = branch topology (independent L/R),
// high-mid = propagation detail, highs = filament/spark micro-turbulence.
// Beat fires a traveling discharge flash trunk→tips, kick triggers a local
// branch-strike flare, transient scatters sparks at active tips.
#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"

#include "include/layers.hlsl"

#define SEG_COUNT 63
// Index ranges: [0]=trunk (L0), [1-2]=L1, [3-6]=L2, [7-14]=L3, [15-30]=L4, [31-62]=L5

float2 rotateVec(float2 v, float ang)
{
    float c = cos(ang), s = sin(ang);
    return float2(v.x * c - v.y * s, v.x * s + v.y * c);
}

float segDist(float2 p, float2 a, float2 b, out float along)
{
    float2 ab = b - a;
    float lenSq = max(dot(ab, ab), 0.00001);
    along = saturate(dot(p - a, ab) / lenSq);
    return length(p - (a + ab * along));
}

// Ambient charge motes — fills negative space, gated by air band + overall energy
float3 chargeMotes(float2 p, AudioData a)
{
    float3 col = float3(0.0, 0.0, 0.0);
    float energyGate = smoothstep(0.02, 0.3, a.overall) * (0.35 + a.b7 * 0.85);
    [loop] for (int i = 0; i < 40; i++)
    {
        float2 cellUV = p * 3.2 + float2(hash11(float(i) * 7.1 + 2.0), hash11(float(i) * 11.3 + 5.0)) * 12.0;
        float2 cellId = floor(cellUV);
        float2 cellF = frac(cellUV) - 0.5;
        float h = hash21(cellId + float(i) * 3.7);
        float2 jitter = (hash22(cellId + float(i) * 1.7) - 0.5) * 0.7;
        float dist = length(cellF - jitter);
        float size = 0.05 + h * 0.09;
        float glow = exp(-dist * dist / max(size * size, 0.0001));
        float twinkle = 0.5 + 0.5 * sin(Time * (1.0 + h * 2.0) + h * 10.0);
        col += lerp(a.brainCol, a.brainCol2, h) * glow * twinkle * energyGate * 0.06;
    }
    return col;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float silence = 1.0 - a.isSilent;
    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float phase = phaseCoherence();
    float thd = thdNormalized();

    float3 col = float3(0.0015, 0.003, 0.009) * silence;
    float atmosphere = fbm2_4(p * 1.2 + float2(Time * 0.02, -Time * 0.015));
    col += lerp(a.brainCol, a.brainCol2, atmosphere) * atmosphere * 0.02 * (0.25 + a.envelope) * silence;
    col += starfield(uv, a) * 0.06;
    col += chargeMotes(p, a) * silence;

    // ── Independent L/R energy per generation (spatial spectrum rule) ──
    float ampL1 = u_spectrum.SampleLevel(u_sampler, float2(0.05, 0.166), 0).r;
    float ampR1 = u_spectrum.SampleLevel(u_sampler, float2(0.05, 0.833), 0).r;
    float ampL2 = u_spectrum.SampleLevel(u_sampler, float2(0.22, 0.166), 0).r;
    float ampR2 = u_spectrum.SampleLevel(u_sampler, float2(0.22, 0.833), 0).r;
    float ampL3 = u_spectrum.SampleLevel(u_sampler, float2(0.42, 0.166), 0).r;
    float ampR3 = u_spectrum.SampleLevel(u_sampler, float2(0.42, 0.833), 0).r;
    float ampL4 = u_spectrum.SampleLevel(u_sampler, float2(0.68, 0.166), 0).r;
    float ampR4 = u_spectrum.SampleLevel(u_sampler, float2(0.68, 0.833), 0).r;
    float ampL5 = u_spectrum.SampleLevel(u_sampler, float2(0.86, 0.166), 0).r;
    float ampR5 = u_spectrum.SampleLevel(u_sampler, float2(0.86, 0.833), 0).r;

    float bassMass = a.b0 * 0.55 + a.b1 * 0.45;
    float kickImpulse = a.kick * a.kickConf;

    float2 segStart[SEG_COUNT];
    float2 segEnd[SEG_COUNT];

    // ── Level 0: trunk — bass mass + kick impulse ──
    float2 source = float2(a.stereoBal * 0.05, 0.72);
    float2 trunkDir = normalize(float2(sin(Time * 0.25) * 0.03 * a.b2, -1.0));
    float trunkLen = 0.10 + bassMass * 0.24 + kickImpulse * 0.06;
    segStart[0] = source;
    segEnd[0] = source + trunkDir * trunkLen;

    // ── Level 1: 2 branches — low-mid topology, independent L/R bias ──
    [unroll] for (int c1 = 0; c1 < 2; c1++)
    {
        float side = c1 == 0 ? -1.0 : 1.0;
        float branchAmp = c1 == 0 ? ampL1 : ampR1;
        float jitter = (hash11(float(c1) * 3.7 + 1.3) - 0.5) * 0.22;
        float angle = side * (0.34 + a.b2 * 0.5 + jitter);
        float2 dir = rotateVec(trunkDir, angle);
        float len = trunkLen * (0.5 + branchAmp * 0.85) * 0.58;
        int idx = 1 + c1;
        segStart[idx] = segEnd[0];
        segEnd[idx] = segEnd[0] + dir * len;
    }

    // ── Level 2: 4 branches — mid structure, independent L/R bias ──
    [unroll] for (int p2 = 0; p2 < 2; p2++)
    {
        int parentIdx = 1 + p2;
        float2 parentDir = normalize(segEnd[parentIdx] - segStart[parentIdx]);
        float parentLen = length(segEnd[parentIdx] - segStart[parentIdx]);
        [unroll] for (int c2 = 0; c2 < 2; c2++)
        {
            float side = c2 == 0 ? -1.0 : 1.0;
            float branchAmp = (p2 == 0) ? ampL2 : ampR2;
            float jitter = (hash11(float(p2 * 2 + c2) * 5.1 + 2.7) - 0.5) * 0.3;
            float angle = side * (0.3 + a.b3 * 0.55 + jitter);
            float2 dir = rotateVec(parentDir, angle);
            float len = parentLen * (0.45 + branchAmp * 0.9) * 0.62;
            int idx = 3 + p2 * 2 + c2;
            segStart[idx] = segEnd[parentIdx];
            segEnd[idx] = segEnd[parentIdx] + dir * len;
        }
    }

    // ── Level 3: 8 branches — high-mid propagation detail ──
    [unroll] for (int p3 = 0; p3 < 4; p3++)
    {
        int parentIdx = 3 + p3;
        float2 parentDir = normalize(segEnd[parentIdx] - segStart[parentIdx]);
        float parentLen = length(segEnd[parentIdx] - segStart[parentIdx]);
        float parentChannel = (p3 < 2) ? ampL3 : ampR3;
        [unroll] for (int c3 = 0; c3 < 2; c3++)
        {
            float side = c3 == 0 ? -1.0 : 1.0;
            float jitter = (hash11(float(p3 * 2 + c3) * 7.3 + 4.1) - 0.5) * 0.36;
            float angle = side * (0.26 + a.b4 * 0.5 + jitter);
            float2 dir = rotateVec(parentDir, angle);
            float len = parentLen * (0.4 + parentChannel * 0.85) * 0.64;
            int idx = 7 + p3 * 2 + c3;
            segStart[idx] = segEnd[parentIdx];
            segEnd[idx] = segEnd[parentIdx] + dir * len;
        }
    }

    // ── Level 4: 16 tips — highs filament micro-turbulence + THD roughness ──
    [unroll] for (int p4 = 0; p4 < 8; p4++)
    {
        int parentIdx = 7 + p4;
        float2 parentDir = normalize(segEnd[parentIdx] - segStart[parentIdx]);
        float parentLen = length(segEnd[parentIdx] - segStart[parentIdx]);
        float parentChannel = (p4 < 4) ? ampL4 : ampR4;
        [unroll] for (int c4 = 0; c4 < 2; c4++)
        {
            float side = c4 == 0 ? -1.0 : 1.0;
            float jitter = (hash11(float(p4 * 2 + c4) * 9.7 + 6.3) - 0.5) * (0.4 + thd * 0.3);
            float angle = side * (0.24 + a.b6 * 0.55 + jitter);
            float2 dir = rotateVec(parentDir, angle);
            float len = parentLen * (0.32 + parentChannel * 0.95) * 0.62;
            int idx = 15 + p4 * 2 + c4;
            segStart[idx] = segEnd[parentIdx];
            segEnd[idx] = segEnd[parentIdx] + dir * len;
        }
    }

    // ── Level 5: 32 micro-filaments — air band + THD roughness ──
    [unroll] for (int p5 = 0; p5 < 16; p5++)
    {
        int parentIdx = 15 + p5;
        float2 parentDir = normalize(segEnd[parentIdx] - segStart[parentIdx]);
        float parentLen = length(segEnd[parentIdx] - segStart[parentIdx]);
        float parentChannel = (p5 < 8) ? ampL5 : ampR5;
        [unroll] for (int c5 = 0; c5 < 2; c5++)
        {
            float side = c5 == 0 ? -1.0 : 1.0;
            float jitter = (hash11(float(p5 * 2 + c5) * 12.9 + 8.7) - 0.5) * (0.5 + thd * 0.4);
            float angle = side * (0.22 + a.b7 * 0.6 + jitter);
            float2 dir = rotateVec(parentDir, angle);
            float len = parentLen * (0.28 + parentChannel * 1.0) * 0.55;
            int idx = 31 + p5 * 2 + c5;
            segStart[idx] = segEnd[parentIdx];
            segEnd[idx] = segEnd[parentIdx] + dir * len;
        }
    }

    // ── Phase coherence symmetry: blend right-side tips toward mirrored left ──
    [unroll] for (int m = 0; m < 15; m += 2)
    {
        float2 mirrorEnd = segEnd[m + 1];
        mirrorEnd.x = -mirrorEnd.x;
        segEnd[m + 2] = lerp(segEnd[m + 2], mirrorEnd, phase * 0.35);
    }

    // ── Beat traveling discharge flash: trunk → tips over generations ──
    float beatWave = a.beat * a.tempoConf;

    [loop] for (int seg = 0; seg < SEG_COUNT; seg++)
    {
        int level = seg == 0 ? 0 : (seg <= 2 ? 1 : (seg <= 6 ? 2 : (seg <= 14 ? 3 : (seg <= 30 ? 4 : 5))));
        float levelFrac = float(level) / 5.0;

        float baseWidth = lerp(0.024, 0.0035, levelFrac);
        float width = baseWidth / (1.0 + crest * 0.6);
        float glowWidth = width * 4.2;

        float hue = a.hueBase + levelFrac * a.hueRange * 0.6 + a.section * 0.03;
        float3 branchColor = lerp(hsv(hue, 0.7 * a.satur, 1.0), lerp(a.brainCol, a.brainCol2, levelFrac), 0.3);

        float flash = exp(-abs(a.beatPhase * 4.0 - levelFrac * 5.0) * 3.0) * beatWave;
        float brightness = (0.45 + a.envelope * 0.75) * (1.0 + lufs * 0.3) * (1.0 + flash * 1.5);

        float along;
        float dist = segDist(p, segStart[seg], segEnd[seg], along);

        float body = exp(-dist * dist / max(width * width, 0.000001));
        float aura = exp(-dist * dist / max(glowWidth * glowWidth, 0.000001));

        col += branchColor * aura * brightness * 0.12 * silence;
        col += branchColor * body * brightness * 0.95 * silence;

        // ── Kick branch-strike flare on high generations ──
        if (level >= 3)
        {
            float strike = step(0.7 - kickImpulse * 0.5, hash11(float(seg) * 13.7));
            float flare = exp(-dist * dist / max(width * width * 6.0, 0.000001)) * strike * kickImpulse;
            col += float3(1.0, 0.95, 0.85) * flare * 0.7 * silence;
        }

        // ── Transient spark burst at tips ──
        if (level >= 4)
        {
            float sparkChance = hash11(float(seg) * 21.3 + floor(Time * 6.0));
            float spark = step(0.88 - a.transient * 0.45, sparkChance) * a.transient;
            float sparkGlow = exp(-length(p - segEnd[seg]) * 90.0) * spark;
            col += float3(0.85, 0.92, 1.0) * sparkGlow * 0.75 * silence;
        }
    }

    col += standardOverlays(p, length(p - source), a) * 0.05;
    return float4(col, 1.0);
}
