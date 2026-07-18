// Mode 20: Spectrum Reflections — reflective SDF objects on mirror floor
// 8 metallic spheres orbit at spectrum-mapped positions, radius/emission = frequency amplitude
// Mirror floor with ray-traced reflections, chrome surfaces, spectrum glow pillars
// Beat = emission pulse, kick = expansion, transients = floor ripples
// Raymarched SDF with PBR lighting, spatial spectrum sampling, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define REFLECT_SPHERES 8

// Scene SDF — orbiting spheres + floor
float sceneSDF(float3 p, AudioData a, float time, out int hitSphere) {
    hitSphere = -1;

    // Floor at y = -1.0
    float floorD = p.y + 1.0;

    // Ripple on floor from kick
    float ripDist = length(p.xz);
    floorD -= a.kick * 0.03 * a.kickConf * sin(ripDist * 8.0 - time * 6.0) * exp(-ripDist * 0.3);
    // Transient ripples
    floorD -= a.transient * 0.015 * sin(ripDist * 15.0 - time * 10.0) * exp(-ripDist * 0.4);

    float minD = floorD;

    // 8 orbiting spheres — each at a spectrum-mapped position
    [unroll] for (int i = 0; i < REFLECT_SPHERES; i++) {
        AudioElement e = audioSimElement(i, REFLECT_SPHERES, a);

        // Orbit position — spectrum band determines angle and radius
        float orbitAng = e.freqFrac * 6.28318 + time * 0.3 * a.motSpeed + i * 0.5;
        float orbitR = 0.8 + e.freqFrac * 1.5;
        float3 spherePos = float3(
            cos(orbitAng) * orbitR + e.pan * 0.2,
            -0.3 + sin(time * 0.5 + i) * 0.15 + e.amplitude * 0.2,
            sin(orbitAng) * orbitR
        );

        // Radius driven by amplitude
        float sphereR = 0.15 + e.amplitude * 0.2 * a.barScale + a.beat * 0.03 * a.tempoConf;
        sphereR += a.kick * 0.04 * a.kickConf;

        float d = sdSphere(p - spherePos, sphereR);
        if (d < minD) { minD = d; hitSphere = i; }
    }

    return minD;
}

float3 calcNormal(float3 p, AudioData a, float time) {
    float eps = 0.001;
    int dummy;
    return normalize(float3(
        sceneSDF(p + float3(eps,0,0), a, time, dummy) - sceneSDF(p - float3(eps,0,0), a, time, dummy),
        sceneSDF(p + float3(0,eps,0), a, time, dummy) - sceneSDF(p - float3(0,eps,0), a, time, dummy),
        sceneSDF(p + float3(0,0,eps), a, time, dummy) - sceneSDF(p - float3(0,0,eps), a, time, dummy)
    ));
}

// Sky color for reflections
float3 skyColor(float3 rd, AudioData a) {
    float t = saturate(rd.y * 0.5 + 0.5);
    float3 top = a.brainCol * 0.3 + float3(0.02, 0.03, 0.06);
    float3 bot = a.brainCol2 * 0.15 + float3(0.04, 0.03, 0.02);
    return lerp(bot, top, t);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Background — sky gradient ──
    float3 col = skyColor(float3(p.x, p.y, -1.0), a) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.4;
    col += godRays(p, r, a) * 0.2;

    // ── Camera — orbiting scene ──
    float camAng = a.stereoBal * 0.2 + Time * 0.03 * a.motSpeed;
    float camDist = 4.5 + a.profBass * 0.2;
    float3 camPos = float3(sin(camAng) * camDist, 1.5 + a.stereoDiff * 0.2, cos(camAng) * camDist);
    float3 camTarget = float3(0, -0.2, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(fwd + p.x * right + p.y * up);

    // ── Primary raymarch ──
    float t = 0.05;
    float marchGlow = 0.0;
    float steps = 0.0;
    bool hit = false;
    int hitSphere = -1;
    float3 hitPos = float3(0,0,0);

    [loop] for (int i = 0; i < 64; i++) {
        float3 sp = camPos + rd * t;
        int hs;
        float d = sceneSDF(sp, a, Time, hs);
        marchGlow += 0.008 / (1.0 + d * d * 50.0);
        steps += 1.0;
        if (d < 0.001) { hit = true; hitSphere = hs; hitPos = sp; break; }
        t += d * 0.5;
        if (t > 12.0) break;
    }
    float ao = 1.0 - steps / 64.0 * 0.4;

    if (hit) {
        float3 n = calcNormal(hitPos, a, Time);
        float3 v = -rd; // view direction

        // Determine if floor or sphere
        bool isFloor = (hitSphere < 0);

        // Lighting
        float3 sunDir = normalize(float3(0.5, 0.8, 0.3));
        float3 fillDir = normalize(float3(-0.6 + a.stereoBal, 0.5, 0.2));
        float diff = max(dot(n, sunDir), 0.0);
        float diff2 = max(dot(n, fillDir), 0.0) * 0.4;
        float spec = pow(max(dot(reflect(-sunDir, n), v), 0.0), 128.0);
        float fres = pow(1.0 - max(dot(n, v), 0.0), 3.0 + a.overall * 2.0);

        float3 baseCol;
        float3 litCol;

        if (isFloor) {
            // Mirror floor — reflective surface
            // Checkered pattern
            float2 checkUV = hitPos.xz * 2.0;
            float check = step(0.5, frac(checkUV.x) * frac(checkUV.y) + 0.5);
            baseCol = lerp(float3(0.02, 0.02, 0.03), float3(0.05, 0.05, 0.07), check);

            // Ray-traced reflection
            float3 reflDir = reflect(rd, n);
            float3 reflPos = hitPos + reflDir * 0.01;
            float rt = 0.05;
            float3 reflCol = skyColor(reflDir, a);
            bool reflHit = false;

            [loop] for (int ri = 0; ri < 32; ri++) {
                float3 rsp = reflPos + reflDir * rt;
                int rdummy;
                float rd2 = sceneSDF(rsp, a, Time, rdummy);
                if (rd2 < 0.001) {
                    float3 rn = calcNormal(rsp, a, Time);
                    float rdiff = max(dot(rn, sunDir), 0.0);
                    // Sample spectrum at reflected position
                    float rSpecU = saturate((rsp.x + 2.0) / 4.0);
                    float rSpecVal = u_spectrum.SampleLevel(u_sampler, float2(rSpecU, 0.5), 0).r;
                    float3 rBase = lerp(a.brainCol, a.brainCol2, rSpecU) * (0.3 + rdiff * 0.4);
                    rBase += float3(1.0, 0.95, 0.85) * pow(max(dot(reflect(-sunDir, rn), -reflDir), 0.0), 64.0) * 0.3;
                    reflCol = rBase;
                    reflHit = true;
                    break;
                }
                rt += rd2 * 0.5;
                if (rt > 8.0) break;
            }

            // Blend reflection with floor
            litCol = lerp(baseCol * (diff + diff2), reflCol, 0.6 + fres * 0.3);
            litCol += float3(1.0, 0.95, 0.85) * spec * 0.5 * a.dynLight * a.dynActive;
            litCol *= ao * (0.4 + a.ambient * 0.6) * a.ambActive;

        } else {
            // Sphere — chrome metallic surface with spectrum emission
            AudioElement e = audioSimElement(hitSphere, REFLECT_SPHERES, a);
            float hue = a.hueBase + e.freqFrac * a.hueRange;

            // Chrome base color
            baseCol = hsv(hue, 0.3 * a.satur, 0.7) * (0.5 + a.brightness * 0.3);

            // Reflection
            float3 reflDir = reflect(rd, n);
            float3 reflCol = skyColor(reflDir, a);
            // Blend reflection based on metallicity
            float metal = 0.7 + a.profBass * 0.2;
            litCol = lerp(baseCol * (diff + diff2), reflCol * metal, fres * 0.5);
            litCol += float3(1.0, 0.95, 0.85) * spec * 0.6 * a.dynLight * a.dynActive;

            // Spectrum emission — sphere glows with its frequency
            float emit = e.amplitude * 0.3 * a.envelope;
            litCol += hsv(hue, 0.6 * a.satur, emit) * (1.0 - a.isSilent);

            // Beat emission
            float beatEmit = a.beat * 0.15 * a.tempoConf * fres;
            litCol += hsv(a.hueCenter, 0.4, beatEmit) * (1.0 - a.isSilent);

            // Kick flash
            float kickFlash = a.kick * 0.1 * a.kickConf * exp(-length(hitPos) * 0.5);
            litCol += a.brainCol2 * kickFlash * (1.0 - a.isSilent);

            litCol *= ao * (0.4 + a.ambient * 0.6) * a.ambActive;
        }

        col = blendScreen(col, litCol);
    }

    // Volumetric glow
    col += a.brainCol2 * marchGlow * 0.04 * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.3;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
