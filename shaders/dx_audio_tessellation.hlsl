// Mode 18: Audio Tessellation — Voronoi tessellation with audio-driven displacement and fault lines
// Dark orange-black background, amber Voronoi terrain, fault line glow on beat
// Heightfield raymarch with Voronoi pattern, wireframe overlay, 48 steps, targets 16ms
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

float tessHeight(float2 xz, AudioData a) {
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
    // Spectrum along X (left-right on screen) — swap X/Z to rotate terrain 90°
    float u = saturate((xz.x + 2.0) / 4.0);
    float specVal = u_spectrum.SampleLevel(u_sampler, float2(u, 0.5), 0).r;
    float h = cellHash * 0.2 + specVal * 0.25 * a.barScale;
    h += a.profBass * 0.15 * smoothstep(0.5, 0.0, length(xz));
    h += a.b3 * 0.08 * sin(xz.x * 3.0 + t * 2.0);
    h += a.b4 * 0.06 * sin(xz.y * 4.0 + t * 1.5);

    // Fault line on beat
    float faultAngle = t * 0.5;
    float2 faultDir = float2(cos(faultAngle), sin(faultAngle));
    float faultDist = abs(dot(xz, faultDir));
    h += a.kick * 0.2 * a.kickConf * exp(-faultDist * faultDist * 5.0);

    // Voronoi edge enhancement
    float edgeDist = sqrt(minDist);
    h += smoothstep(0.15, 0.05, edgeDist) * 0.1;
    h += fbm3_4(float3(xz * 1.5, t)) * 0.03;
    return h;
}

float sceneSDF(float3 p, AudioData a) {
    // Swap X and Z to rotate terrain 90° in the XZ plane
    return p.y - tessHeight(float2(p.z, p.x), a);
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
    AudioData a = extractAudio();
    uv.y = 1.0 - uv.y;  // 180° vertical flip
    float2 p = screenToAspect(uv);
    float r = length(p);

    // Dark orange-black
    float3 col = float3(0.02, 0.008, 0.0);

    // Camera in original orientation
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

        float3 lDir = normalize(float3(0.5, 1.0, 0.3));
        float3 lDir2 = normalize(float3(-1.0 + a.stereoBal, 0.5, 0.3));
        float diff = max(dot(n, lDir), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.5;
        float spec = pow(max(dot(reflect(-lDir, n), -rd), 0.0), 64.0);
        float fres = pow(1.0 - max(dot(n, -rd), 0.0), 4.0);

        // Amber/orange terrain
        float heightFrac = clamp(hp.y * 2.0 + 0.3, 0.0, 1.0);
        float3 baseCol = lerp(float3(0.3, 0.1, 0.0), float3(0.8, 0.4, 0.05), heightFrac);
        float3 litCol = baseCol * (diff + diff2) * (0.4 + a.brightness * 0.3);
        litCol += float3(1.0, 0.9, 0.7) * spec * 0.4 * a.dynLight;
        litCol += float3(0.6, 0.2, 0.0) * fres * (0.2 + a.b4 * 0.3);
        litCol *= ao * (0.4 + a.ambient * 0.6);

        // Voronoi cell edge wireframe — bright orange
        float2 cellSize = float2(0.4, 0.4);
        float2 cellUV = hp.xz / cellSize;
        float2 cellId = abs(frac(cellUV) - 0.5);
        float voronoiEdge = smoothstep(0.45, 0.5, max(cellId.x, cellId.y));
        litCol += float3(1.0, 0.6, 0.1) * voronoiEdge * 0.1 * a.brightness;

        // Fault line glow — bright orange/red
        float faultAngle = Time * 0.1 * a.motSpeed * 0.5;
        float2 faultDir = float2(cos(faultAngle), sin(faultAngle));
        float faultDist = abs(dot(hp.xz, faultDir));
        float faultGlow = exp(-faultDist * faultDist * 10.0) * a.kick * 0.2 * a.kickConf;
        litCol += float3(1.0, 0.3, 0.0) * faultGlow * (1.0 - a.isSilent);

        col = blendScreen(col, litCol);
    }

    col += float3(0.1, 0.04, 0.0) * marchGlow * 0.04 * (1.0 - a.isSilent);

    col = col / (1.0 + col);
    col *= 1.0 - dot(uv - 0.5, uv - 0.5) * 0.12;
    col *= (0.5 + a.gated * 0.5);
    return float4(col, 1.0);
}
