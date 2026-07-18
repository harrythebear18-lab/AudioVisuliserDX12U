// Mode 11: Spectrum Kaleidoscope — 3D raymarched kaleidoscopic fractal
// 6-fold kaleidoscopic symmetry with audio-driven fold angles and displacement
// Each frequency band maps to a symmetry layer — bass = fold power, treble = detail
// Beat = zoom pulse, kick = fold explosion, transients = glitch displacement
// Orbit trap coloring, PBR lighting, volumetric glow, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define KALEIDO_FOLDS 6
#define KALEIDO_ITER 8

// Kaleidoscopic fold SDF — creates symmetric fractal structures
float kaleidoSDF(float3 p, AudioData a, float time, out float3 trapCol) {
    float3 z = p;
    float dr = 1.0;
    trapCol = float3(0.0, 0.0, 0.0);

    // Fold power driven by bass — controls fractal complexity
    float foldScale = 1.5 + a.profBass * 0.8 + a.b0 * 0.3;
    foldScale += a.kick * 0.4 * a.kickConf;

    // Rotation driven by treble
    float rotAng = a.profTreb * 0.4 + time * 0.08 * a.motSpeed;
    float2 rotC = float2(cos(rotAng), sin(rotAng));

    [unroll] for (int i = 0; i < KALEIDO_ITER; i++) {
        // Kaleidoscopic fold — radial symmetry in XZ plane
        float ang = atan2(z.z, z.x);
        float r = length(z.xz);
        float foldAng = 6.28318 / float(KALEIDO_FOLDS);
        ang = abs(fmod(ang, foldAng)) - foldAng * 0.5;
        z.xz = float2(cos(ang), sin(ang)) * r;

        // Box fold
        z = abs(z);
        z -= 1.0;

        // Rotation
        z.xz = float2(z.x * rotC.x - z.z * rotC.y, z.x * rotC.y + z.z * rotC.x);

        // Scale and offset
        z = z * foldScale + p;
        dr = dr * abs(foldScale) + 1.0;

        // Orbit trap — spectrum at iteration depth
        float trapFreq = float(i) / float(KALEIDO_ITER);
        float trapSpec = u_spectrum.SampleLevel(u_sampler, float2(trapFreq, 0.5), 0).r;
        float3 tc = hsv(a.hueBase + trapFreq * a.hueRange, 0.8 * a.satur, 0.3 + trapSpec * 0.5);
        trapCol += tc * (1.0 / (1.0 + dot(z, z) * 0.1));

        // Transient glitch — random displacement
        if (a.transient > 0.2) {
            z += float3(
                sin(z.y * 20.0 + time * 15.0) * a.transient * 0.02,
                cos(z.z * 20.0 + time * 12.0) * a.transient * 0.02,
                sin(z.x * 20.0 + time * 10.0) * a.transient * 0.02
            );
        }
    }

    return length(z) / abs(dr);
}

float3 calcNormal(float3 p, AudioData a, float time) {
    float eps = 0.001;
    float3 dummy;
    return normalize(float3(
        kaleidoSDF(p + float3(eps,0,0), a, time, dummy) - kaleidoSDF(p - float3(eps,0,0), a, time, dummy),
        kaleidoSDF(p + float3(0,eps,0), a, time, dummy) - kaleidoSDF(p - float3(0,eps,0), a, time, dummy),
        kaleidoSDF(p + float3(0,0,eps), a, time, dummy) - kaleidoSDF(p - float3(0,0,eps), a, time, dummy)
    ));
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Background — deep void ──
    float3 col = float3(0.004, 0.003, 0.01) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.3;

    // Nebula haze
    float nebula = fbm2_4(p * 1.5 + Time * 0.02 * a.motSpeed);
    col += a.brainCol * nebula * 0.02 * a.ambient * a.ambActive * (1.0 - a.isSilent);

    // ── Camera — slow orbit, beat zoom ──
    float camAng = a.stereoBal * 0.2 + Time * 0.05 * a.motSpeed;
    float beatZoom = 1.0 - a.beat * 0.05 * a.tempoConf;
    float camDist = 3.0 * beatZoom - a.profBass * 0.15;
    float3 camPos = float3(sin(camAng) * camDist, 0.2 + a.stereoDiff * 0.1, cos(camAng) * camDist);
    float3 rd = cameraRay(camPos, float3(0, 0, 0), p, 1.0);

    // Raymarch
    float t = 0.05;
    float marchGlow = 0.0;
    float steps = 0.0;
    bool hit = false;
    float3 trapColor = float3(0.0, 0.0, 0.0);

    [loop] for (int i = 0; i < 64; i++) {
        float3 sp = camPos + rd * t;
        float3 tc;
        float d = kaleidoSDF(sp, a, Time, tc);
        marchGlow += 0.01 / (1.0 + d * d * 50.0);
        steps += 1.0;
        if (d < 0.001) { hit = true; trapColor = tc; break; }
        t += d * 0.5;
        if (t > 10.0) break;
    }
    float ao = 1.0 - steps / 64.0 * 0.5;

    if (hit) {
        float3 hp = camPos + rd * t;
        float3 n = calcNormal(hp, a, Time);

        // 3-light setup
        float3 lDir1 = normalize(float3(0.5, 1.0, 0.3));
        float3 lDir2 = normalize(float3(-1.0 + a.stereoBal, 0.6, 0.2));
        float3 lDir3 = normalize(float3(0.0, -0.3, 0.8));
        float diff1 = max(dot(n, lDir1), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
        float diff3 = max(dot(n, lDir3), 0.0) * 0.2;
        float spec = pow(max(dot(reflect(-lDir1, n), -rd), 0.0), 96.0);
        float fres = pow(1.0 - max(dot(n, -rd), 0.0), 3.0 + a.overall * 4.0);

        // Orbit trap coloring
        float3 baseCol = trapColor / float(KALEIDO_ITER);
        baseCol = lerp(baseCol, a.brainCol, 0.2);

        float3 litCol = baseCol * (diff1 + diff2 + diff3) * (0.4 + a.brightness * 0.4);
        litCol += float3(1.0, 0.95, 0.85) * spec * 0.4 * a.dynLight * a.dynActive;
        litCol += a.brainCol2 * fres * (0.3 + a.b4 * 0.2);

        // Beat emission
        float beatEmit = a.beat * 0.15 * a.tempoConf * fres;
        litCol += hsv(a.hueCenter, 0.4, beatEmit) * (1.0 - a.isSilent);

        // Kick flash
        float kickFlash = a.kick * 0.1 * a.kickConf * exp(-length(hp) * 0.5);
        litCol += a.brainCol2 * kickFlash * (1.0 - a.isSilent);

        // Spectrum emission
        float emit = dot(trapColor, trapColor) * 0.015 * a.envelope;
        litCol += baseCol * emit * (1.0 - a.isSilent);

        litCol *= ao * (0.4 + a.ambient * 0.6) * a.ambActive;
        col = blendScreen(col, litCol);
    }

    // Volumetric glow
    col += a.brainCol2 * marchGlow * 0.05 * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.35;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
