// Mode 4: Spectrum Vortex — frequency-assigned particles in audio-driven vortex
// 48 particles per layer, each assigned a frequency bin
// Amplitude drives radial position, stereo pan drives X, transient scatters
// Kick = radial impulse, beat = contraction, phase links between adjacent bins
// Starfield, standard overlays, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#include "include/dsp_cb.hlsl"

#define SPECTRAL_RAYS 96

float rayDistance(float2 p, float2 a, float2 b, out float h) {
    float2 ab = b - a;
    h = saturate(dot(p - a, ab) / max(dot(ab, ab), 0.0001));
    return length(p - (a + ab * h));
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float virtualCameraZoom = 0.86 + a.envelope * 0.025 + a.kick * a.kickConf * 0.035;
    float2 p = screenToAspect(uv) / virtualCameraZoom;
    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float coherence = phaseCoherence();
    float thd = thdNormalized();
    float silence = 1.0 - a.isSilent;
    float time = Time * (0.08 + a.motSpeed * 0.06);
    float depthPulse = a.kick * a.kickConf * 0.14 - a.beat * a.tempoConf * 0.05;
    float2 aperture = float2(a.stereoBal * 0.045, -0.015);
    float3 col = float3(0.002, 0.003, 0.010) * silence;
    col += starfield(uv, a) * 0.07;

    [loop] for (int i = 0; i < SPECTRAL_RAYS; i++) {
        float rayT = float(i) / float(SPECTRAL_RAYS - 1);
        float frequencyU = saturate(20.0 * pow(1200.0, rayT) / 24000.0);
        float ampL = u_spectrum.SampleLevel(u_sampler, float2(frequencyU, 0.166), 0).r;
        float ampR = u_spectrum.SampleLevel(u_sampler, float2(frequencyU, 0.833), 0).r;
        float monoBass = u_spectrum.SampleLevel(u_sampler, float2(frequencyU, 0.5), 0).r;
        float sharedBass = 1.0 - smoothstep(0.0, 0.05, rayT);
        ampL = lerp(ampL, monoBass, sharedBass);
        ampR = lerp(ampR, monoBass, sharedBass);

        float fanAngle = lerp(-1.78, 1.78, rayT);
        float2 directions[2] = {
            float2(-cos(fanAngle), sin(fanAngle)),
            float2(cos(fanAngle), sin(fanAngle))
        };
        float amplitudes[2] = { ampL, ampR };

        [unroll] for (int side = 0; side < 2; side++) {
            float amplitude = amplitudes[side];
            float lowWeight = 1.0 - smoothstep(0.0, 0.32, rayT);
            float innerRadius = 0.115 + lowWeight * 0.055 - a.beat * 0.018;
            float rayLength = 0.36 + amplitude * (1.02 + lufs * 0.28) + depthPulse;
            rayLength += 0.07 * sin(time * (1.0 + rayT) + rayT * 23.0 + side * 1.7) * (0.15 + amplitude);
            float2 rayStart = aperture + directions[side] * innerRadius;
            float2 rayEnd = aperture + directions[side] * (innerRadius + rayLength);
            float alongRay;
            float distanceToRay = rayDistance(p, rayStart, rayEnd, alongRay);
            float width = lerp(0.0022, 0.0048, amplitude) * lerp(1.15, 0.72, crest);
            float body = exp(-distanceToRay * distanceToRay / max(width * width, 0.000001));
            float tipWidth = width * (1.8 + a.transient * 1.3);
            float tip = exp(-distanceToRay * distanceToRay / max(tipWidth * tipWidth, 0.000001));
            tip *= smoothstep(0.78, 0.98, alongRay);
            float segment = pow(saturate(sin((alongRay * 10.0 - time * 5.0) * 3.14159)), 14.0);
            float hue = frac(0.98 - rayT * 0.86 + a.hueBase * 0.08 + thd * 0.025);
            float3 rayColor = hsv(hue, 0.82, 1.0);
            rayColor = lerp(rayColor, lerp(a.brainCol, a.brainCol2, rayT), 0.14);
            float rayEnergy = 0.08 + amplitude * (0.82 + a.brightness * 0.18);
            col += rayColor * body * rayEnergy * silence;
            col += rayColor * tip * (0.10 + amplitude * 0.72 + a.transient * 0.25) * silence;
            col += rayColor * segment * tip * a.transient * 0.32 * silence;
        }
    }

    float2 apertureShape = (p - aperture) / float2(0.245 + a.b0 * 0.045, 0.112 + a.b1 * 0.025);
    float apertureMask = 1.0 - smoothstep(0.88, 1.08, length(apertureShape));
    float rim = smoothstep(1.14, 0.94, length(apertureShape)) * (1.0 - apertureMask);
    col += hsv(a.hueCenter + 0.1, 0.38, 1.0) * rim * (0.02 + a.beat * 0.08) * silence;
    col *= 1.0 - apertureMask;

    float2 toAperture = p - aperture;
    float apertureRadius = length(toAperture);
    float shock = exp(-abs(apertureRadius - (0.30 + a.kick * 0.20)) * 30.0);
    col += a.brainCol * shock * a.kick * a.kickConf * 0.06 * silence;
    col += standardOverlays(p, length(p), a) * 0.08;
    return float4(col, 1.0);
}
