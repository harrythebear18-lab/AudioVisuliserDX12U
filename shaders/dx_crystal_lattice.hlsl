// Mode 29: Synthwave Grid — 3D perspective grid floor with audio-reactive particles
// Tron/synthwave aesthetic: grid lines converge to horizon, particles pulse on intersections
// Bass moves the grid forward, spectrum creates height on grid points, kick creates shockwaves
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/postfx.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

// Project a 3D world point to screen space
// Grid is on the XZ plane at y=0, camera elevated looking forward
float2 worldToScreen(float3 world, float3 camPos, float camPitch, float2 screenP, float fov) {
    float3 rel = world - camPos;
    // Rotate by pitch around X axis
    float3 rotated = float3(
        rel.x,
        rel.y * cos(camPitch) - rel.z * sin(camPitch),
        rel.y * sin(camPitch) + rel.z * cos(camPitch)
    );
    if (rotated.z < 0.01) return float2(999.0, 999.0);
    return float2(rotated.x / rotated.z * fov, rotated.y / rotated.z * fov);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    float3 col = float3(0.005, 0.002, 0.02) * (1.0 - a.isSilent * 0.98);

    float t = Time * a.motSpeed;

    // Camera — elevated, looking down at grid
    float camPitch = 0.4 + a.stereoDiff * 0.05;
    float3 camPos = float3(a.stereoBal * 2.0, 2.0, -5.0 - t * 2.0);
    float fov = 1.0;

    // Horizon line — where grid meets sky
    float horizonY = -camPos.y * sin(camPitch) / cos(camPitch) * fov;
    float horizonScreen = horizonY;

    // Sky gradient — synthwave purple/pink
    if (p.y > horizonScreen) {
        float skyT = saturate((p.y - horizonScreen) / (1.0 - horizonScreen));
        float3 skyTop = float3(0.02, 0.005, 0.08);
        float3 skyBot = lerp(float3(0.15, 0.02, 0.12), float3(0.3, 0.05, 0.15), a.b0 * 0.3);
        col = lerp(skyBot, skyTop, skyT);

        // Sun on horizon — synthwave style
        float2 sunPos = float2(0.0, horizonScreen + 0.05);
        float sunR = length(p - sunPos);
        float sun = smoothstep(0.15, 0.12, sunR) * smoothstep(0.18, 0.13, sunR);
        // Sun bars — classic synthwave horizontal stripes
        float sunBars = smoothstep(0.15, 0.0, sunR) * (0.5 + 0.5 * sin(p.y * 60.0 + t * 2.0));
        sunBars = step(0.5, sunBars) * smoothstep(0.16, 0.0, sunR);
        float3 sunCol = lerp(float3(1.0, 0.8, 0.3), float3(1.0, 0.3, 0.6), skyT);
        col += sunCol * smoothstep(0.15, 0.0, sunR) * 0.8;
        col -= sunCol * sunBars * 0.5;

        // Stars
        float starB = pow(hash21(floor(p * 80.0) + 7.3), 50.0);
        col += float3(1.0, 0.9, 0.8) * starB * skyT * 0.5;
    }

    // Grid floor — perspective lines
    if (p.y < horizonScreen + 0.02) {
        // Inverse projection — from screen to grid plane
        // y = 0 plane, camera at (camX, camY, camZ) with pitch
        float screenY = p.y;
        float screenX = p.x;

        // Ray from camera through pixel
        float3 rd = normalize(float3(screenX, screenY, fov));
        // Rotate ray by pitch
        float3 rdRot = float3(
            rd.x,
            rd.y * cos(camPitch) - rd.z * sin(camPitch),
            rd.y * sin(camPitch) + rd.z * cos(camPitch)
        );

        // Intersect with y=0 plane
        if (rdRot.y < -0.001) {
            float hitT = -camPos.y / rdRot.y;
            float3 hitPos = camPos + rdRot * hitT;

            // Grid coordinates
            float2 gridPos = hitPos.xz;
            float2 gridFrac = frac(gridPos);
            float2 gridDist = min(gridFrac, 1.0 - gridFrac); // distance to nearest line

            // Grid line intensity — thin bright lines
            float lineWidth = 0.02;
            float lineX = smoothstep(lineWidth, 0.0, gridDist.x);
            float lineZ = smoothstep(lineWidth, 0.0, gridDist.y);
            float gridLines = max(lineX, lineZ);

            // Grid scrolling — move forward with time
            float scrollPhase = frac(hitPos.z * 0.5 + t * 2.0);
            float scrollGlow = pow(0.5 + 0.5 * sin(scrollPhase * 6.283), 4.0) * lineZ;

            // Audio: spectrum creates height bumps on grid
            float specU = saturate(hitPos.x * 0.1 + 0.5);
            float specVal = u_spectrum.SampleLevel(u_sampler, float2(specU, 0.5), 0).r;

            // Grid point height — particles at intersections
            float2 cellId = floor(gridPos);
            float cellSeed = hash21(cellId);
            float pointHeight = specVal * 0.5 * a.barScale;
            pointHeight += a.b0 * 0.3 * sin(length(hitPos.xz) * 0.5 - t * 1.5);
            pointHeight += a.kick * 0.2 * a.kickConf * sin(length(hitPos.xz) * 1.0 - t * 3.0) * exp(-length(hitPos.xz) * 0.1);

            // Glow at grid intersections
            float intersection = lineX * lineZ;
            float pointGlow = intersection * (0.5 + specVal * 2.0 + a.b0 * 0.5);

            // Color — synthwave cyan/magenta grid
            float hue = 0.5 + cellSeed * 0.1 + a.section * 0.03 + a.b4 * 0.02;
            float3 gridCol = hsv(hue, 0.7 * a.satur, gridLines * (0.3 + a.brightness * 0.2));
            gridCol += hsv(hue + 0.1, 0.8, 1.0) * pointGlow * 0.8;
            gridCol += hsv(hue + 0.05, 0.6, 1.0) * scrollGlow * 0.5;

            // Kick: shockwave on grid
            float kickDist = length(hitPos.xz);
            float shockwave = a.kick * a.kickConf * exp(-abs(kickDist - frac(t) * 10.0) * 2.0) * 0.5;
            gridCol += hsv(a.hueCenter, 0.5, 1.0) * shockwave * gridLines;

            // Distance fog — fade grid into horizon
            float fog = exp(-hitT * 0.04);
            float horizonFade = smoothstep(horizonScreen - 0.01, horizonScreen - 0.15, p.y);
            gridCol *= fog * horizonFade;

            col = blendAdd(col, gridCol * (1.0 - a.isSilent));
        }
    }

    // Bass: glow on horizon
    col += hsv(0.85, 0.6, 1.0) * a.b0 * 0.1 * smoothstep(horizonScreen - 0.05, horizonScreen + 0.05, p.y) * smoothstep(horizonScreen + 0.1, horizonScreen, p.y) * (1.0 - a.isSilent);

    col += standardOverlays(p, r, a) * 0.2;

    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);

    // Vignette
    float vignette = smoothstep(1.5, 0.4, r);
    col *= vignette;

    return float4(col, 1.0);
}

