// Mode 8: Spectrum Double Helix — professional 3D frequency-driven double helix
// 48 segments, each assigned a frequency bin, radius/twist/brightness = amplitude
// L/R stereo splits strands, beat = base pair flashes, kick = expansion
// Proper 3D perspective with depth fog, energy pulses, nucleotide markers, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define HELIX_SEGS 48

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Background — deep space with nebula ──
    float3 col = float3(0.006, 0.004, 0.012) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.25;
    float nebula = fbm2_4(p * 1.5 + Time * 0.02 * a.motSpeed);
    col += a.brainCol * nebula * 0.02 * a.ambient * a.ambActive * (1.0 - a.isSilent);

    // Camera — slight orbit for 3D feel
    float camAng = a.stereoBal * 0.15 + Time * 0.03 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 5.0, 0.0, cos(camAng) * 5.0);
    float3 camTarget = float3(0, 0, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(fwd + p.x * right + p.y * up);

    float helixH = 2.8;

    // ── 48 helix segments, each driven by a frequency bin ──
    [loop] for (int si = 0; si < HELIX_SEGS; si++) {
        AudioElement e = audioSimElement(si, HELIX_SEGS, a);

        float t = float(si) / float(HELIX_SEGS - 1);
        float y = (t - 0.5) * helixH;

        // Twist frequency driven by treble — more treble = tighter twist
        float twistFreq = 2.5 + a.profTreb * 2.5;

        // Rotation — slow base rotation + transient unwinding
        float rot = Time * 0.4 * a.motSpeed + a.transient * sin(t * 8.0) * 0.25;
        float ang = t * twistFreq * 3.14159 + rot;

        // Helix radius driven by amplitude — louder = wider
        float helixR = 0.5 + e.amplitude * 0.35 * a.barScale;
        helixR += a.kick * 0.12 * a.kickConf;
        helixR -= a.beat * 0.04 * a.tempoConf;

        // Strand A — left channel
        float3 posA = float3(cos(ang) * helixR, y, sin(ang) * helixR);
        // Strand B — right channel (opposite phase)
        float3 posB = float3(cos(ang + 3.14159) * helixR, y, sin(ang + 3.14159) * helixR);

        // Project to screen with proper perspective
        float depthA = dot(posA - camPos, fwd);
        float depthB = dot(posB - camPos, fwd);
        if (depthA < 0.1 && depthB < 0.1) continue;

        float2 scrA = posA.xy - camPos.xy;
        scrA = scrA / max(depthA, 0.1) * 2.5;
        float2 scrB = posB.xy - camPos.xy;
        scrB = scrB / max(depthB, 0.1) * 2.5;

        // Depth fog
        float fogA = exp(-depthA * 0.08);
        float fogB = exp(-depthB * 0.08);

        // Depth-based glow size — closer = larger
        float glowSizeA = 40.0 / max(depthA * depthA, 0.5);
        float glowSizeB = 40.0 / max(depthB * depthB, 0.5);

        // Strand glow — amplitude-driven brightness
        float strandBright = 0.15 + e.intensity * 0.4;

        float distA = length(p - scrA);
        float distB = length(p - scrB);

        float glowA = exp(-distA * distA * glowSizeA) * strandBright * fogA;
        float glowB = exp(-distB * distB * glowSizeB) * strandBright * fogB;

        // L/R stereo coloring
        float3 colA = lerp(a.brainCol, hsv(a.hueBase + e.freqFrac * a.hueRange, 0.6 * a.satur, 0.9), 0.35);
        float3 colB = lerp(a.brainCol2, hsv(a.hueBase + e.freqFrac * a.hueRange + 0.1, 0.6 * a.satur, 0.9), 0.35);

        col += colA * glowA * e.ampL * 1.2 * (1.0 - a.isSilent);
        col += colB * glowB * e.ampR * 1.2 * (1.0 - a.isSilent);

        // Strand cores — bright white centers with depth sizing
        float coreSizeA = 200.0 / max(depthA * depthA, 0.5);
        float coreSizeB = 200.0 / max(depthB * depthB, 0.5);
        float coreA = exp(-distA * distA * coreSizeA) * 0.12 * fogA * e.amplitude;
        float coreB = exp(-distB * distB * coreSizeB) * 0.12 * fogB * e.amplitude;
        col += float3(0.85, 0.92, 1.0) * (coreA + coreB) * a.bloomActive * (1.0 - a.isSilent);

        // Nucleotide markers — every 4th segment, larger glowing nodes
        if (si % 4 == 0) {
            float nucSizeA = 80.0 / max(depthA * depthA, 0.5);
            float nucSizeB = 80.0 / max(depthB * depthA, 0.5);
            float nucA = exp(-distA * distA * nucSizeA) * e.ampL * 0.3 * fogA;
            float nucB = exp(-distB * distB * nucSizeB) * e.ampR * 0.3 * fogB;
            float3 nucCol = hsv(a.hueCenter + e.freqFrac * 0.15, 0.5 * a.satur, 0.9);
            col += nucCol * (nucA + nucB) * a.bloomActive * (1.0 - a.isSilent);
        }

        // Base pair connectors — every 3rd segment, flash on beat
        if (si % 3 == 0) {
            float2 bpDir = scrB - scrA;
            float bpLen = length(bpDir);
            if (bpLen > 0.001) {
                float2 bpNorm = bpDir / bpLen;
                float bpProj = clamp(dot(p - scrA, bpNorm), 0.0, bpLen);
                float2 bpClosest = scrA + bpNorm * bpProj;
                float bpDist = length(p - bpClosest);
                float bpGlow = exp(-bpDist * bpDist * 100.0) * 0.15 * e.intensity * fogA;
                float bpFlash = a.beat * 0.25 * a.tempoConf * exp(-bpDist * bpDist * 180.0);
                float3 bpCol = hsv(a.hueCenter + e.freqFrac * 0.1, 0.6 * a.satur, 0.9);
                col += bpCol * (bpGlow + bpFlash) * (1.0 - a.isSilent);
            }
        }

        // Energy pulse traveling along strands — driven by beat phase
        float pulsePhase = a.beatPhase + t * 2.5;
        if (pulsePhase < 0.08 && e.amplitude > 0.08) {
            float pulseA = exp(-distA * distA * 180.0) * 0.25 * a.beat * fogA;
            float pulseB = exp(-distB * distB * 180.0) * 0.25 * a.beat * fogB;
            col += float3(0.7, 0.85, 1.0) * pulseA * a.dynActive * (1.0 - a.isSilent);
            col += float3(0.85, 1.0, 0.7) * pulseB * a.dynActive * (1.0 - a.isSilent);
        }
    }

    // ── Kick flash — center burst ──
    float kickGlow = exp(-r * r * 6.0) * a.kick * 0.12 * a.kickConf;
    col += a.brainCol2 * kickGlow * a.bloomActive * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.25;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
