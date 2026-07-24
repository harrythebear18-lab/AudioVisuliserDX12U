// Mode 28: Audio-Reactive Mandelbulb — 3D spherical fractal with audio-driven power
// Based on the proven mode 13 pattern. Mandelbulb DE swaps in for Mandelbox.
// Power N: bass/kick/beat → 2..8 (smooth sphere → crystalline explosion)
// Twist: low-mids + stereo phase → iteration warping (stretches 3D space)
// Highs: edge shimmer + escape threshold refinement
// Transient: dimensional glitch/tearing
// DSP: LUFS→emission, crest→specular sharpness, THD→glitch, phase→symmetry
// HDR output, no local postfx. Follows DX12U rules.
#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define MB_ITER 8

// Mandelbulb DE — audio-reactive spherical fractal
float audioMandelbulbSDF(float3 p, AudioData a, float time, out float3 trapColor) {
    float3 z = p;
    float dr = 1.0;
    float r = 0.0;
    trapColor = float3(0.0, 0.0, 0.0);

    // Power: bass compressor + beat/kick surge (N=2 smooth → N=12 crystalline)
    float bassMass = pow(a.b0, 0.5) * (1.0 + lufsNormalized() * 0.3);
    float power = 2.0 + bassMass * 6.0 + a.profBass * 4.0;
    power += a.beat * 5.0 * a.tempoConf;
    power += a.kick * 4.0 * a.kickConf;
    power = clamp(power, 2.0, 12.0);

    // Iteration warping — stereo + low-mids stretch 3D space
    float warp = a.stereoBal * 0.4 + (a.b2 + a.b3) * 0.3;
    warp += thdNormalized() * sin(time * 3.0) * 0.1;
    warp += a.transient * sin(time * 20.0) * 0.15;

    // Per-iteration audio injection — each band modulates a different iteration
    float bandVals[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    [unroll] for (int i = 0; i < 8; i++) {
        r = length(z);
        if (r > 2.0) break;

        // Orbit trap — sample spectrum at iteration depth, L/R for stereo
        float trapFreq = float(i) / 8.0;
        float trapSpecL = u_spectrum.SampleLevel(u_sampler, float2(trapFreq, 0.0), 0).r;
        float trapSpecR = u_spectrum.SampleLevel(u_sampler, float2(trapFreq, 1.0), 0).r;
        float trapSpec = (trapSpecL + trapSpecR) * 0.5;
        float3 trapCol = hsv(a.hueBase + trapFreq * a.hueRange, 0.7 * a.satur, 0.5 + trapSpec * 0.5);
        trapColor += trapCol * (1.0 / (1.0 + r * r * 0.1));

        float theta = acos(z.z / max(r, 0.001)) * power;
        float phi = atan2(z.y, z.x) * power;
        float st = sin(theta);
        z = pow(r, power) * float3(st * cos(phi), st * sin(phi), cos(theta)) + p;

        // Per-iteration audio displacement — each band warps a different depth
        float bandWarp = bandVals[i] * 0.3;
        z += float3(warp + bandWarp, warp * 0.7 - bandWarp * 0.5, -warp * 0.5 + bandWarp * 0.3) * float(i + 1);
        dr = pow(r, power - 1.0) * power * dr + 1.0;
    }

    return 0.5 * log(max(r, 0.001)) * r / max(dr, 0.001);
}

float3 calcNormal(float3 p, AudioData a, float time) {
    float eps = 0.001;
    float3 dummy;
    return normalize(float3(
        audioMandelbulbSDF(p + float3(eps,0,0), a, time, dummy) - audioMandelbulbSDF(p - float3(eps,0,0), a, time, dummy),
        audioMandelbulbSDF(p + float3(0,eps,0), a, time, dummy) - audioMandelbulbSDF(p - float3(0,eps,0), a, time, dummy),
        audioMandelbulbSDF(p + float3(0,0,eps), a, time, dummy) - audioMandelbulbSDF(p - float3(0,0,eps), a, time, dummy)
    ));
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // DSP additive
    float dspLUFS = lufsNormalized();
    float dspCrest = crestFactorNormalized();
    float dspTHD = thdNormalized();
    float dspPhaseCoh = phaseCoherence();

    // Bass mass for camera — compressor curve per rules
    float bassMass = pow(a.b0, 0.5) * (1.0 + dspLUFS * 0.3);

    // Background — same as mode 13
    float3 col = float3(0.005, 0.004, 0.012) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.3;

    // Nebula haze
    float nebula = fbm2_4(p * 2.0 + Time * 0.02 * a.motSpeed);
    col += a.brainCol * nebula * 0.03 * a.ambient * a.ambActive * (1.0 - a.isSilent);

    // Camera — audio-driven orbit with kick shake
    float camAng = a.section * 1.5 + a.stereoBal * 0.5 + Time * 0.05 * a.motSpeed;
    float beatZoom = 1.0 - a.beat * 0.15 * a.tempoConf;
    float camDist = 4.5 * beatZoom - bassMass * 0.8;
    // Kick camera shake
    float kickShake = a.kick * a.kickConf * 0.15;
    float3 camPos = float3(
        sin(camAng) * camDist + sin(Time * 37.0) * kickShake,
        0.5 + a.stereoDiff * 0.3 + cos(Time * 41.0) * kickShake,
        cos(camAng) * camDist
    );
    float3 rd = cameraRay(camPos, float3(0, 0, 0), p, 1.0);

    // Highs — link to escape threshold for edge glow/fracture on bright transients
    float highEnergy = (a.b6 + a.b7) * 0.5;
    float hitThreshold = 0.01 - highEnergy * 0.006;  // tighter on highs = more edge detail

    // Raymarch
    float t = 0.05;
    float marchGlow = 0.0;
    float steps = 0.0;
    bool hit = false;
    float3 trapColor = float3(0.0, 0.0, 0.0);

    [loop] for (int i = 0; i < 64; i++) {
        float3 sp = camPos + rd * t;
        float3 tc;
        float d = audioMandelbulbSDF(sp, a, Time, tc);
        marchGlow += 0.01 / (1.0 + d * d * 50.0);
        steps += 1.0;
        if (d < hitThreshold) { hit = true; trapColor = tc; break; }
        t += d * 0.7;
        if (t > 12.0) break;
    }
    float ao = 1.0 - steps / 64.0 * 0.5;

    if (hit) {
        float3 hp = camPos + rd * t;
        float3 n = calcNormal(hp, a, Time);

        // 3-light setup — stereo-balanced, audio-rotated
        float3 lDir1 = normalize(float3(0.5, 1.0, 0.3));
        float3 lDir2 = normalize(float3(-1.0 + a.stereoBal * 1.5, 0.7, 0.2));
        float3 lDir3 = normalize(float3(0.0, -0.3, 0.8));
        float diff1 = max(dot(n, lDir1), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
        float diff3 = max(dot(n, lDir3), 0.0) * 0.2;
        float spec = pow(max(dot(reflect(-lDir1, n), -rd), 0.0), 32.0 + dspCrest * 96.0);
        float fres = pow(1.0 - max(dot(n, -rd), 0.0), 3.0 + a.overall * 4.0);

        // Orbit trap coloring — spectrum-driven, brain palette blended
        float3 baseCol = trapColor / float(MB_ITER);
        baseCol = lerp(baseCol, a.brainCol, 0.25);
        baseCol = lerp(baseCol, a.brainCol2, a.b4 * 0.4);  // mids shift color

        // Dynamic lighting — envelope drives brightness hard
        float3 litCol = baseCol * (diff1 + diff2 + diff3) * (0.2 + a.brightness * 0.4 + a.envelope * 0.5);
        litCol += float3(1.0, 0.95, 0.8) * spec * 0.6 * (0.3 + a.dynActive * 0.7);
        litCol += a.brainCol2 * fres * (0.5 + a.b4 * 0.5) * a.bloomActive;

        // Highs — edge shimmer, bright on treble transients
        float highShimmer = (a.b6 + a.b7) * 0.5;
        litCol += hsv(a.hueBase + 0.7 * a.hueRange, 0.5, 1.0) * fres * highShimmer * 1.2 * (1.0 - a.isSilent);

        // Beat — fresnel rim flash, hue-shifted per section
        float beatEmit = a.beat * 0.6 * a.tempoConf * fres;
        litCol += hsv(a.hueCenter + a.section * 0.1, 0.5, 1.0) * beatEmit * (1.0 - a.isSilent);

        // Kick — warm radial shockfront
        float kickFlash = a.kick * 0.5 * a.kickConf * exp(-length(hp) * 0.3);
        litCol += float3(1.0, 0.5, 0.15) * kickFlash * (1.0 - a.isSilent);

        // Transient — surface spark rupture
        litCol += hsv(a.hueCenter + 0.5, 0.8, 1.0) * a.transient * fres * 0.5 * (1.0 - a.isSilent);

        // DSP additive — LUFS boosts emission
        litCol *= (1.0 + dspLUFS * 0.5);
        // DSP additive — phase coherence
        litCol *= lerp(0.6, 1.2, dspPhaseCoh);

        litCol *= ao * (0.4 + a.ambient * 0.6) * a.ambActive;
        col = blendScreen(col, litCol);
    }

    // March glow — audio-reactive halo, envelope-driven
    col += a.brainCol2 * marchGlow * 0.15 * (0.5 + a.b4 * 0.5 + a.envelope * 0.5) * (1.0 - a.isSilent);

    // Beat anticipation — pre-beat tension glow
    col += a.brainCol * a.beatAnt * 0.1 * (1.0 - a.isSilent);

    // Foreground overlays
    col += standardOverlays(p, r, a) * 0.4;

    // Brightness limiter — prevent bloom blowout
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.5) col *= 1.5 / maxChannel;

    // Silence suppression
    col *= (1.0 - a.isSilent * 0.98);

    return float4(col, 1.0);
}
