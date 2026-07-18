// Mode 9: RTX Mesh — deformable 3D mesh grid with audio-driven displacement
// Dark background, brain-colored metallic mesh grid, wireframe overlay
// Heightfield raymarch, 48 steps, 2 lights, starfield + godrays, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

float meshHeight(float2 xz, AudioData a) {
    float h = 0.0;
    float u = saturate((xz.x + 2.0) / 4.0);
    float spec1 = u_spectrum.SampleLevel(u_sampler, float2(u, 0.5), 0).r;
    float specL = u_spectrum.SampleLevel(u_sampler, float2(u, 0.0), 0).r;
    float specR = u_spectrum.SampleLevel(u_sampler, float2(u, 1.0), 0).r;
    h += spec1 * 0.3 * smoothstep(0.5, 0.0, abs(xz.x));
    h += specL * 0.2 * smoothstep(0.0, -1.0, xz.x);
    h += specR * 0.2 * smoothstep(0.0, 1.0, xz.x);
    h += sin(xz.x * 4.0 + Time * 2.0 * a.motSpeed) * a.b3 * 0.08;
    h += sin(xz.y * 5.0 + Time * 1.5 * a.motSpeed) * a.b4 * 0.06;
    float dist = length(xz);
    h += sin(dist * 6.0 - Time * 8.0 * a.motSpeed) * a.kick * 0.15 * a.kickConf;
    h += sin(dist * 10.0 - Time * 5.0 * a.motSpeed) * a.beat * 0.08 * a.tempoConf;
    h += fbm3_4(float3(xz * 1.5, Time * 0.2)) * 0.03;
    return h;
}

float sceneSDF(float3 p, AudioData a) {
    // Swap X and Z to rotate terrain 90° — frequency runs horizontally
    return p.y - meshHeight(float2(p.z, p.x), a);
}

float3 calcNormal(float3 p, AudioData a) {
    float eps = 0.001;
    return normalize(float3(
        sceneSDF(p + float3(eps,0,0), a) - sceneSDF(p - float3(eps,0,0), a),
        sceneSDF(p + float3(0,eps,0), a) - sceneSDF(p - float3(0,eps,0), a),
        sceneSDF(p + float3(0,0,eps), a) - sceneSDF(p - float3(0,0,eps), a)
    ));
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    uv = 1.0 - uv;  // 180° visual flip
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Background ──
    float3 col = float3(0.01, 0.008, 0.02) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.25;
    col += godRays(p, r, a) * 0.15;

    float camAng = a.stereoBal * 0.15;
    float3 camPos = float3(sin(camAng) * 4.0, 2.5, cos(camAng) * 4.0);
    float3 rd = cameraRay(camPos, float3(0, 0, 0), p, 1.0);

    float t = 0.05;
    float marchGlow = 0.0;
    float steps = 0.0;
    bool hit = false;

    [loop] for (int i = 0; i < 48; i++) {
        float3 sp = camPos + rd * t;
        float d = sceneSDF(sp, a);
        marchGlow += 0.01 / (1.0 + d * d * 80.0);
        steps += 1.0;
        if (d < 0.001) { hit = true; break; }
        t += d * 0.6;
        if (t > 10.0) break;
    }
    float ao = 1.0 - steps / 48.0 * 0.5;

    if (hit) {
        float3 hp = camPos + rd * t;
        float3 n = calcNormal(hp, a);

        float lightAng = 0.0;
        float3 lDir = normalize(float3(cos(lightAng), 1.0, sin(lightAng)));
        float3 lDir2 = normalize(float3(-1.0 + a.stereoBal, 0.5, 0.3));
        float diff = max(dot(n, lDir), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.5;
        float spec = pow(max(dot(reflect(-lDir, n), -rd), 0.0), 64.0);
        float fres = pow(1.0 - max(dot(n, -rd), 0.0), 4.0);

        // Brain-driven metallic surface
        float hue = a.hueBase + a.section * 0.03 + a.colorPulse * 0.04;
        float3 baseCol = hsv(hue, 0.6 * a.satur, 0.6) * (0.5 + a.brightness * 0.3);
        float3 litCol = baseCol * (diff + diff2) * (0.5 + a.brightness * 0.3);
        litCol += float3(1.0, 0.95, 0.8) * spec * 0.5 * a.dynLight * a.dynActive;
        litCol += a.brainCol2 * fres * (0.3 + a.b4 * 0.3) * a.bloomActive;
        litCol *= ao * (0.4 + a.ambient * 0.6) * a.ambActive;

        // Wireframe overlay — brain primary colored grid lines, brighter
        float2 wireUV = hp.xz * (5.0 + a.dynamic * 10.0);
        float2 wireId = abs(frac(wireUV) - 0.5);
        float wireLine = smoothstep(0.48, 0.5, max(wireId.x, wireId.y));
        litCol += a.brainCol * wireLine * 0.25 * a.brightness;

        col = blendScreen(col, litCol);
    }

    // Glow
    col += a.brainCol2 * marchGlow * 0.04 * a.bloomActive * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.5;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
