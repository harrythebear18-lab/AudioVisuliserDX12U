// Mode 20: Dual Tessellation — dual inverted mesh, sub-bass floor + highs ceiling
// Bottom: sub-bass tessellation mesh (bottom 15% of spectrum), wireframe + fault lines
// Top: inverted highs tessellation mesh (upper 40% of spectrum), hanging ceiling
// Single shared camera, thin blend zone at horizon, both same visual style

#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/postfx.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

// Sub-bass tessellation — Voronoi terrain, sub-bass frequencies (bottom 15% of spectrum)
float tessBassHeight(float2 xz, AudioData a) {
    float t = Time * 0.1 * a.motSpeed;
    float2 cellSize = float2(0.4, 0.4);
    float2 cell = floor(xz / cellSize);
    float2 cellPos = frac(xz / cellSize);

    float minDist = 10.0;
    float2 nearestCell = cell;
    [unroll] for (int dx = -1; dx <= 1; dx++) {
        [unroll] for (int dy = -1; dy <= 1; dy++) {
            float2 neighbor = float2(dx, dy);
            float2 cellOffset = hash22(cell + neighbor) * 0.8 + 0.1;
            float2 diff = neighbor + cellOffset - cellPos;
            float d = dot(diff, diff);
            if (d < minDist) { minDist = d; nearestCell = cell + neighbor; }
        }
    }

    float cellHash = hash21(nearestCell);
    float u = saturate((xz.x + 2.0) / 4.0) * 0.15; // sub-bass only
    float specVal = u_spectrum.SampleLevel(u_sampler, float2(u, 0.5), 0).r;
    float h = cellHash * 0.2 + specVal * 0.40 * a.barScale;
    h += a.b0 * 0.25 * smoothstep(0.5, 0.0, length(xz));
    h += a.b1 * 0.16 * sin(xz.x * 3.0 + t * 2.0);
    h += a.b2 * 0.12 * sin(xz.y * 4.0 + t * 1.5);

    float faultAngle = t * 0.5;
    float2 faultDir = float2(cos(faultAngle), sin(faultAngle));
    float faultDist = abs(dot(xz, faultDir));
    h += a.kick * 0.2 * a.kickConf * exp(-faultDist * faultDist * 5.0);

    float edgeDist = sqrt(minDist);
    h += smoothstep(0.15, 0.05, edgeDist) * 0.1;
    h += fbm3_4(float3(xz * 1.5, t)) * 0.03;
    return h;
}

// Highs tessellation — Voronoi terrain, highs frequencies (upper 40% of spectrum)
float tessHighsHeight(float2 xz, AudioData a) {
    float t = Time * 0.1 * a.motSpeed;
    float2 cellSize = float2(0.4, 0.4);
    float2 cell = floor(xz / cellSize);
    float2 cellPos = frac(xz / cellSize);

    float minDist = 10.0;
    float2 nearestCell = cell;
    [unroll] for (int dx = -1; dx <= 1; dx++) {
        [unroll] for (int dy = -1; dy <= 1; dy++) {
            float2 neighbor = float2(dx, dy);
            float2 cellOffset = hash22(cell + neighbor) * 0.8 + 0.1;
            float2 diff = neighbor + cellOffset - cellPos;
            float d = dot(diff, diff);
            if (d < minDist) { minDist = d; nearestCell = cell + neighbor; }
        }
    }

    float cellHash = hash21(nearestCell);
    float u = saturate((xz.x + 2.0) / 4.0);
    float specUHigh = saturate(u * 0.4 + 0.6); // highs only
    float specVal = u_spectrum.SampleLevel(u_sampler, float2(specUHigh, 0.5), 0).r;
    float h = cellHash * 0.2 + specVal * 0.25 * a.barScale;
    h += a.b4 * 0.08 * sin(xz.x * 3.0 + t * 2.0);
    h += a.b5 * 0.06 * sin(xz.y * 4.0 + t * 1.5);
    h += a.b6 * 0.05 * sin(length(xz) * 5.0 + t);
    h += a.b7 * 0.04 * sin(length(xz) * 7.0 + t * 1.5);

    float faultAngle = t * 0.5;
    float2 faultDir = float2(cos(faultAngle), sin(faultAngle));
    float faultDist = abs(dot(xz, faultDir));
    h += a.kick * 0.15 * a.kickConf * exp(-faultDist * faultDist * 5.0);

    float edgeDist = sqrt(minDist);
    h += smoothstep(0.15, 0.05, edgeDist) * 0.1;
    h += fbm3_4(float3(xz * 1.5, t)) * 0.03;
    return h;
}

float sceneBassSDF(float3 p, AudioData a) {
    return p.y - tessBassHeight(float2(p.z, p.x), a);
}

float sceneHighsSDF(float3 p, AudioData a) {
    return p.y - tessHighsHeight(float2(p.z, p.x), a);
}

float3 calcNormalBass(float3 p, AudioData a) {
    float eps = 0.001;
    return normalize(float3(
        sceneBassSDF(p + float3(eps,0,0), a) - sceneBassSDF(p - float3(eps,0,0), a),
        sceneBassSDF(p + float3(0,eps,0), a) - sceneBassSDF(p - float3(0,eps,0), a),
        sceneBassSDF(p + float3(0,0,eps), a) - sceneBassSDF(p - float3(0,0,eps), a)
    ));
}

float3 calcNormalHighs(float3 p, AudioData a) {
    float eps = 0.001;
    return normalize(float3(
        sceneHighsSDF(p + float3(eps,0,0), a) - sceneHighsSDF(p - float3(eps,0,0), a),
        sceneHighsSDF(p + float3(0,eps,0), a) - sceneHighsSDF(p - float3(0,eps,0), a),
        sceneHighsSDF(p + float3(0,0,eps), a) - sceneHighsSDF(p - float3(0,0,eps), a)
    ));
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();

    // Sharp split with thin blend zone
    float blendZone = 0.04;
    float topWeight = smoothstep(0.5 - blendZone, 0.5 + blendZone, uv.y);
    float botWeight = 1.0 - topWeight;

    float3 colTop = float3(0,0,0);
    float3 colBot = float3(0,0,0);

    // ── BOTTOM: Sub-bass audio tessellation — mass at bottom edge, converges up to center ──
    if (botWeight > 0.01) {
        float2 pBot = screenToAspect(uv);

        float3 col = float3(0.02, 0.008, 0.0);

        float camAng = a.stereoBal * 0.15;
        float3 camPos = float3(sin(camAng) * 4.0, 2.5, cos(camAng) * 4.0);
        float3 rd = cameraRay(camPos, float3(0, 0, 0), pBot, 1.0);

        float t = 0.05;
        float marchGlow = 0.0;
        float steps = 0.0;
        bool hit = false;

        [loop] for (int i = 0; i < 48; i++) {
            float3 sp = camPos + rd * t;
            float d = sceneBassSDF(sp, a);
            marchGlow += 0.01 / (1.0 + d * d * 80.0);
            steps += 1.0;
            if (d < 0.001) { hit = true; break; }
            t += d * 0.6;
            if (t > 10.0) break;
        }
        float ao = 1.0 - steps / 48.0 * 0.5;

        if (hit) {
            float3 hp = camPos + rd * t;
            float3 n = calcNormalBass(hp, a);

            float3 lDir = normalize(float3(0.5, 1.0, 0.3));
            float3 lDir2 = normalize(float3(-1.0 + a.stereoBal, 0.5, 0.3));
            float diff = max(dot(n, lDir), 0.0);
            float diff2 = max(dot(n, lDir2), 0.0) * 0.5;
            float spec = pow(max(dot(reflect(-lDir, n), -rd), 0.0), 64.0);
            float fres = pow(1.0 - max(dot(n, -rd), 0.0), 4.0);

            float heightFrac = clamp(hp.y * 2.0 + 0.3, 0.0, 1.0);
            float3 baseCol = lerp(float3(0.3, 0.1, 0.0), float3(0.8, 0.4, 0.05), heightFrac);
            float3 litCol = baseCol * (diff + diff2) * (0.4 + a.brightness * 0.3);
            litCol += float3(1.0, 0.9, 0.7) * spec * 0.4 * a.dynLight;
            litCol += float3(0.6, 0.2, 0.0) * fres * (0.2 + a.b0 * 0.3);
            litCol *= ao * (0.4 + a.ambient * 0.6);

            float2 cellSize = float2(0.4, 0.4);
            float2 cellUV = hp.xz / cellSize;
            float2 cellId = abs(frac(cellUV) - 0.5);
            float voronoiEdge = smoothstep(0.45, 0.5, max(cellId.x, cellId.y));
            litCol += float3(1.0, 0.6, 0.1) * voronoiEdge * 0.1 * a.brightness;

            float faultAngle = Time * 0.1 * a.motSpeed * 0.5;
            float2 faultDir = float2(cos(faultAngle), sin(faultAngle));
            float faultDist = abs(dot(hp.xz, faultDir));
            float faultGlow = exp(-faultDist * faultDist * 10.0) * a.kick * 0.2 * a.kickConf;
            litCol += float3(1.0, 0.3, 0.0) * faultGlow * (1.0 - a.isSilent);

            col = blendScreen(col, litCol);
        }

        col += float3(0.1, 0.04, 0.0) * marchGlow * 0.04 * (1.0 - a.isSilent);
        col = col / (1.0 + col);
        colBot = col;
    }

    // ── TOP: Highs audio tessellation — mass at top edge, converges down to center ──
    if (topWeight > 0.01) {
        float2 pTop = screenToAspect(uv);
        float2 pFlip = float2(pTop.x, -pTop.y);

        float3 col = float3(0.02, 0.008, 0.0);

        float camAng = a.stereoBal * 0.15;
        float3 camPos = float3(sin(camAng) * 4.0, 2.5, cos(camAng) * 4.0);
        float3 rd = cameraRay(camPos, float3(0, 0, 0), pFlip, 1.0);

        float t = 0.05;
        float marchGlow = 0.0;
        float steps = 0.0;
        bool hit = false;

        [loop] for (int i = 0; i < 48; i++) {
            float3 sp = camPos + rd * t;
            float d = sceneHighsSDF(sp, a);
            marchGlow += 0.01 / (1.0 + d * d * 80.0);
            steps += 1.0;
            if (d < 0.001) { hit = true; break; }
            t += d * 0.6;
            if (t > 10.0) break;
        }
        float ao = 1.0 - steps / 48.0 * 0.5;

        if (hit) {
            float3 hp = camPos + rd * t;
            float3 n = calcNormalHighs(hp, a);

            float3 lDir = normalize(float3(0.5, 1.0, 0.3));
            float3 lDir2 = normalize(float3(-1.0 + a.stereoBal, 0.5, 0.3));
            float diff = max(dot(n, lDir), 0.0);
            float diff2 = max(dot(n, lDir2), 0.0) * 0.5;
            float spec = pow(max(dot(reflect(-lDir, n), -rd), 0.0), 64.0);
            float fres = pow(1.0 - max(dot(n, -rd), 0.0), 4.0);

            float heightFrac = clamp(hp.y * 2.0 + 0.3, 0.0, 1.0);
            float3 baseCol = lerp(float3(0.3, 0.1, 0.0), float3(0.8, 0.4, 0.05), heightFrac);
            float3 litCol = baseCol * (diff + diff2) * (0.4 + a.brightness * 0.3);
            litCol += float3(1.0, 0.9, 0.7) * spec * 0.4 * a.dynLight;
            litCol += float3(0.6, 0.2, 0.0) * fres * (0.2 + a.b4 * 0.3);
            litCol *= ao * (0.4 + a.ambient * 0.6);

            float2 cellSize = float2(0.4, 0.4);
            float2 cellUV = hp.xz / cellSize;
            float2 cellId = abs(frac(cellUV) - 0.5);
            float voronoiEdge = smoothstep(0.45, 0.5, max(cellId.x, cellId.y));
            litCol += float3(1.0, 0.6, 0.1) * voronoiEdge * 0.1 * a.brightness;

            float faultAngle = Time * 0.1 * a.motSpeed * 0.5;
            float2 faultDir = float2(cos(faultAngle), sin(faultAngle));
            float faultDist = abs(dot(hp.xz, faultDir));
            float faultGlow = exp(-faultDist * faultDist * 10.0) * a.kick * 0.15 * a.kickConf;
            litCol += float3(1.0, 0.3, 0.0) * faultGlow * (1.0 - a.isSilent);

            col = blendScreen(col, litCol);
        }

        col += float3(0.1, 0.04, 0.0) * marchGlow * 0.04 * (1.0 - a.isSilent);
        col = col / (1.0 + col);
        colTop = col;
    }

    // Blend top and bottom
    float3 col = lerp(colBot, colTop, topWeight);

    col += standardOverlays(screenToAspect(uv), length(screenToAspect(uv)), a) * 0.5;
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    float r = length(screenToAspect(uv));
    float centerDim = 0.55 + 0.45 * smoothstep(0.0, 0.6, r);
    col *= centerDim;

    return float4(col, 1.0);
}
