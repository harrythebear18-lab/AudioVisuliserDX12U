// Mode 13: Spectrum Mandelbox — 3D box-fold fractal with audio-driven parameters
// Mandelbox folding scale = bass, iteration count = envelope, color = spectrum bands
// Beat = zoom pulse, kick = fold morph, transients = dimensional glitch
// Raymarched with PBR lighting, orbit trap coloring from spectrum, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define MB_ITER 8

// Mandelbox SDF with audio-driven scale
float mandelboxSDF(float3 p, AudioData a, float time, out float3 trapColor) {
    float3 z = p;
    float dr = 1.0;
    trapColor = float3(0.0, 0.0, 0.0);

    // Scale driven by bass — morphs fractal shape
    float scale = 2.0 + a.profBass * 1.5 + a.b0 * 0.5;
    // Kick morphs scale momentarily
    scale += a.kick * 0.8 * a.kickConf;

    // Fixed radius for box fold
    float foldR = 1.0 + a.envelope * 0.2;

    [unroll] for (int i = 0; i < MB_ITER; i++) {
        // Box fold — clamp to [-foldR, foldR] then reflect
        z = clamp(z, -foldR, foldR) * 2.0 - z;

        // Sphere fold
        float r2 = dot(z, z);
        if (r2 < 0.25) { z *= 4.0; dr *= 4.0; }
        else if (r2 < 1.0) { z /= r2; dr /= r2; }

        // Scale and offset
        z = z * scale + p;
        dr = dr * abs(scale) + 1.0;

        // Orbit trap — sample spectrum at iteration depth
        float trapFreq = float(i) / float(MB_ITER);
        float trapSpec = u_spectrum.SampleLevel(u_sampler, float2(trapFreq, 0.5), 0).r;
        float3 trapCol = hsv(a.hueBase + trapFreq * a.hueRange, 0.7 * a.satur, 0.5 + trapSpec * 0.5);
        trapColor += trapCol * (1.0 / (1.0 + dot(z, z) * 0.1));
    }

    // Transient glitch — dimensional tearing
    if (a.transient > 0.3) {
        z.x += sin(z.y * 20.0 + time * 15.0) * a.transient * 0.05;
        z.z += cos(z.x * 20.0 + time * 12.0) * a.transient * 0.05;
    }

    float r = length(z);
    return r / abs(dr);
}

float3 calcNormal(float3 p, AudioData a, float time) {
    float eps = 0.001;
    float3 dummy;
    return normalize(float3(
        mandelboxSDF(p + float3(eps,0,0), a, time, dummy) - mandelboxSDF(p - float3(eps,0,0), a, time, dummy),
        mandelboxSDF(p + float3(0,eps,0), a, time, dummy) - mandelboxSDF(p - float3(0,eps,0), a, time, dummy),
        mandelboxSDF(p + float3(0,0,eps), a, time, dummy) - mandelboxSDF(p - float3(0,0,eps), a, time, dummy)
    ));
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Background ──
    float3 col = float3(0.005, 0.004, 0.012) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.3;

    // Nebula haze
    float nebula = fbm2_4(p * 2.0 + Time * 0.02 * a.motSpeed);
    col += a.brainCol * nebula * 0.03 * a.ambient * a.ambActive * (1.0 - a.isSilent);

    // Camera — slow orbit, beat zoom
    float camAng = a.stereoBal * 0.2 + Time * 0.08 * a.motSpeed;
    float beatZoom = 1.0 - a.beat * 0.08 * a.tempoConf;
    float camDist = 4.0 * beatZoom - a.profBass * 0.3;
    float3 camPos = float3(sin(camAng) * camDist, 0.5 + a.stereoDiff * 0.2, cos(camAng) * camDist);
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
        float d = mandelboxSDF(sp, a, Time, tc);
        marchGlow += 0.01 / (1.0 + d * d * 50.0);
        steps += 1.0;
        if (d < 0.001) { hit = true; trapColor = tc; break; }
        t += d * 0.5;
        if (t > 12.0) break;
    }
    float ao = 1.0 - steps / 64.0 * 0.5;

    if (hit) {
        float3 hp = camPos + rd * t;
        float3 n = calcNormal(hp, a, Time);

        // 3-light setup
        float3 lDir1 = normalize(float3(0.5, 1.0, 0.3));
        float3 lDir2 = normalize(float3(-1.0 + a.stereoBal, 0.7, 0.2));
        float3 lDir3 = normalize(float3(0.0, -0.3, 0.8));
        float diff1 = max(dot(n, lDir1), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
        float diff3 = max(dot(n, lDir3), 0.0) * 0.2;
        float spec = pow(max(dot(reflect(-lDir1, n), -rd), 0.0), 96.0);
        float fres = pow(1.0 - max(dot(n, -rd), 0.0), 4.0 + a.overall * 3.0);

        // Orbit trap coloring — normalized
        float3 baseCol = trapColor / float(MB_ITER);
        baseCol = lerp(baseCol, a.brainCol, 0.3);

        float3 litCol = baseCol * (diff1 + diff2 + diff3) * (0.5 + a.brightness * 0.4);
        litCol += float3(1.0, 0.95, 0.8) * spec * 0.5 * a.dynLight * a.dynActive;
        litCol += a.brainCol2 * fres * (0.4 + a.b4 * 0.3) * a.bloomActive;

        // Beat emission
        float beatEmit = a.beat * 0.2 * a.tempoConf * fres;
        litCol += hsv(a.hueCenter, 0.4, beatEmit) * (1.0 - a.isSilent);

        // Kick morph flash
        float kickFlash = a.kick * 0.15 * a.kickConf * exp(-length(hp) * 0.5);
        litCol += a.brainCol2 * kickFlash * (1.0 - a.isSilent);

        litCol *= ao * (0.4 + a.ambient * 0.6) * a.ambActive;
        col = blendScreen(col, litCol);
    }

    // March glow
    col += a.brainCol2 * marchGlow * 0.05 * a.bloomActive * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.4;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
