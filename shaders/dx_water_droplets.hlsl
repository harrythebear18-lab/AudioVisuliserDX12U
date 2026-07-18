// Mode 26: Water Droplet Pool — 3D water surface with droplet impact ripples
// Uses damped sinusoid ripple propagation (like 4rknova's raindrops on puddle)
// Droplets fall from above on kick/transient, create expanding rings
// Fresnel reflections, specular, caustic-like glow on wave crests
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/postfx.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

// Water surface heightfield — damped wave propagation from droplet impacts
float waterHeight(float2 xz, AudioData a) {
    float t = Time;
    float h = 0.0;

    // Ambient water motion
    h += sin(xz.x * 0.3 + t * 0.2) * cos(xz.y * 0.3 + t * 0.15) * 0.015;
    h += fbm2_4(xz * 0.2 + t * 0.03) * 0.02;

    // Droplet impacts — expanding damped sinusoid rings
    [unroll] for (int i = 0; i < 12; i++) {
        float dropTime = floor(t * 3.0) - i * 0.33;
        float age = t - dropTime;
        if (age < 0.0 || age > 4.0) continue;

        float2 dropPos = float2(
            (hash11(dropTime * 1.3 + i * 0.7) - 0.5) * 8.0 + a.stereoBal * 1.5,
            (hash11(dropTime * 2.7 + i * 1.1) - 0.5) * 8.0
        );

        float intensity = (i == 0) ? a.kick * a.kickConf * 1.5 :
                          (i < 3) ? a.transient * 0.8 :
                          hash11(dropTime * 3.1 + i * 2.3) * (a.b0 * 0.6 + a.b1 * 0.3);
        if (intensity < 0.02) continue;

        float dist = length(xz - dropPos);
        float waveSpeed = 2.0;
        float waveFront = age * waveSpeed;

        // Damped traveling sinusoid — the key ripple equation
        float phase = dist - waveFront;
        float ripple = sin(phase * 6.0) * exp(-phase * phase * 1.5);
        ripple *= exp(-age * 0.5);           // temporal damping
        ripple *= exp(-abs(dist - waveFront) * 2.0); // localize to wave front
        ripple *= intensity * 0.25;

        h += ripple;
    }

    // Sub-bass: large swell
    h += a.b0 * 0.08 * sin(length(xz) * 0.6 - t * 0.4);
    h += a.b1 * 0.05 * sin(xz.x * 1.0 + t * 0.6) * cos(xz.y * 0.8 + t * 0.4);

    // Highs: capillary ripples
    h += a.b6 * 0.015 * sin(xz.x * 6.0 + t * 2.5);
    h += a.b7 * 0.012 * sin(xz.y * 8.0 + t * 3.0);

    return h;
}

float sceneSDF(float3 p, AudioData a) {
    return p.y - waterHeight(p.xz, a);
}

float3 calcNormal(float3 p, AudioData a) {
    float eps = 0.005;
    return normalize(float3(
        sceneSDF(p + float3(eps,0,0), a) - sceneSDF(p - float3(eps,0,0), a),
        2.0 * eps,
        sceneSDF(p + float3(0,0,eps), a) - sceneSDF(p - float3(0,0,eps), a)
    ));
}

// Environment for reflections — dark sky with audio glow
float3 envColor(float3 rd, AudioData a) {
    float3 col = lerp(float3(0.008, 0.012, 0.03), float3(0.04, 0.06, 0.12), rd.y * 0.5 + 0.5);
    // Stars
    float2 skyUV = rd.xz / (rd.y + 0.3) * 0.5;
    float starB = pow(hash21(floor(skyUV * 40.0) + 7.3), 50.0);
    col += float3(1.0, 0.9, 0.8) * starB * 0.4;
    // Audio glow on horizon
    col += a.brainCol * smoothstep(-0.1, 0.4, rd.y) * (a.b0 * 0.15 + a.b1 * 0.08);
    // Moon-like glow
    float3 moonDir = normalize(float3(0.3, 0.7, 0.4));
    float moon = pow(max(dot(rd, moonDir), 0.0), 80.0);
    col += float3(0.9, 0.85, 0.7) * moon * 0.5;
    return col;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    float3 col = float3(0.005, 0.008, 0.02) * (1.0 - a.isSilent * 0.98);

    // Camera looking down at water at an angle
    float camAng = a.stereoBal * 0.1 + Time * 0.015 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 4.0, 2.5, cos(camAng) * 4.0);
    float3 rd = cameraRay(camPos, float3(0, 0, 0), p, 1.0);

    // Raymarch water surface
    float t = 0.05;
    float steps = 0.0;
    bool hit = false;

    [loop] for (int i = 0; i < 64; i++) {
        float3 sp = camPos + rd * t;
        float d = sceneSDF(sp, a);
        steps += 1.0;
        if (d < 0.001) { hit = true; break; }
        t += d * 0.6;
        if (t > 25.0) break;
    }

    if (hit) {
        float3 hp = camPos + rd * t;
        float3 n = calcNormal(hp, a);

        // Fresnel
        float fres = pow(1.0 - max(dot(n, -rd), 0.0), 5.0);
        fres = lerp(0.03, 1.0, fres);

        // Reflection
        float3 reflDir = reflect(rd, n);
        float3 reflCol = envColor(reflDir, a);

        // Water body color — depth-dependent
        float3 waterCol = lerp(float3(0.01, 0.04, 0.08), float3(0.03, 0.1, 0.18), a.brightness);

        // Specular — moon glint
        float3 lDir = normalize(float3(0.3, 0.7, 0.4));
        float spec = pow(max(dot(reflect(-lDir, n), -rd), 0.0), 200.0);

        col = lerp(waterCol, reflCol, fres);
        col += float3(1.0, 0.95, 0.85) * spec * 1.2;

        // Caustic-like glow on wave crests
        float heightVal = waterHeight(hp.xz, a);
        float crestGlow = smoothstep(0.01, 0.06, abs(heightVal));
        col += a.brainCol * crestGlow * (0.4 + a.b0 * 0.4) * a.bloomActive;

        // Secondary specular from audio-reactive light
        float3 lDir2 = normalize(float3(-0.5 + a.stereoBal, 0.5, -0.3));
        float spec2 = pow(max(dot(reflect(-lDir2, n), -rd), 0.0), 100.0);
        col += a.brainCol2 * spec2 * 0.3 * a.dynLight;

        // Distance fog
        float fog = exp(-t * 0.06);
        col = lerp(float3(0.005, 0.008, 0.02), col, fog);
    } else {
        col = envColor(rd, a);
    }

    // Falling droplet streaks — visible above the water before impact
    float t2 = Time;
    [unroll] for (int j = 0; j < 6; j++) {
        float dropTime = floor(t2 * 3.0) - j * 0.33;
        float age = t2 - dropTime;
        if (age < 0.0 || age > 0.33) continue;

        float2 dropPos = float2(
            (hash11(dropTime * 1.3 + j * 0.7) - 0.5) * 8.0 + a.stereoBal * 1.5,
            (hash11(dropTime * 2.7 + j * 1.1) - 0.5) * 8.0
        );
        float intensity = (j == 0) ? a.kick * a.kickConf : hash11(dropTime * 3.1 + j * 2.3) * a.b0 * 0.5;
        if (intensity < 0.02) continue;

        // Droplet falls from y=3 to y=0 over its lifetime
        float dropY = 3.0 * (1.0 - age * 3.0);
        float3 dropWorld = float3(dropPos.x, dropY, dropPos.y);

        // Project to screen — simple distance check
        float3 toDrop = dropWorld - camPos;
        float dropProj = dot(toDrop, rd);
        float3 closestPoint = camPos + rd * dropProj;
        float dropDist = length(closestPoint - dropWorld);

        // Streak — elongated along fall direction
        float streak = exp(-dropDist * dropDist * 50.0) * intensity * 0.8;
        col += float3(0.7, 0.9, 1.0) * streak * (1.0 - a.isSilent);
    }

    col += standardOverlays(p, r, a) * 0.25;

    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);

    float centerDim = 0.65 + 0.35 * smoothstep(0.0, 0.6, r);
    col *= centerDim;

    return float4(col, 1.0);
}
