// Mode 13: Synaptic Storm — 3D volumetric brain of firing neurons driven by spectrum
// 32 neurons in 3D brain hemisphere topology, depth-sorted with perspective projection
// Axon bundles with traveling electrical signals, spectrum-driven firing per neuron
// Dopamine waves on energy, phase coherence = synchrony, transient = seizure, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

#define N_NEURONS 32

// 3D brain hemisphere position — neurons scattered in a dome
float3 brainNeuronPos3D(int idx, float total, float stereoBal, float energy) {
    float golden = 2.39996;
    float theta = idx * golden;
    float phi = acos(1.0 - 2.0 * (idx + 0.5) / total);
    // Hemisphere — brain dome shape
    float x = sin(phi) * cos(theta) * 1.3 + stereoBal * 0.15;
    float y = cos(phi) * 0.9 + 0.05;
    float z = sin(phi) * sin(theta) * 1.1;
    // Energy swell
    float swell = 1.0 + energy * 0.12;
    return float3(x * swell, y * swell, z * swell);
}

// Project 3D to screen
float2 project3D(float3 world, float3 camPos, float3 fwd, float3 right, float3 up, float fov) {
    float3 toObj = world - camPos;
    float depth = dot(toObj, fwd);
    if (depth < 0.01) depth = 0.01;
    return float2(dot(toObj, right) / (depth * fov), dot(toObj, up) / (depth * fov));
}

float objDepth3D(float3 world, float3 camPos, float3 fwd) {
    return dot(world - camPos, fwd);
}

// Jagged electrical arc in 2D screen space
float arcGlow(float2 p, float2 a, float2 b, float jagged, float seed) {
    float2 dir = b - a;
    float len = length(dir);
    if (len < 0.001) return 0.0;
    float2 norm = dir / len;
    float2 perp = float2(-norm.y, norm.x);
    float proj = clamp(dot(p - a, norm), 0.0, len);
    float perpDist = abs(dot(p - a, perp));
    perpDist += sin(proj * 18.0 + seed * 10.0) * jagged;
    perpDist += sin(proj * 35.0 + seed * 5.0) * jagged * 0.5;
    return exp(-perpDist * perpDist * 900.0);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Background — deep brain interior ──
    float3 col = float3(0.006, 0.004, 0.01) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.15;

    // Neural tissue texture — brain-colored, flowing
    float tissue = fbm2_4(p * 3.0 + Time * 0.02 * a.motSpeed);
    col += a.brainCol * tissue * 0.04 * a.ambient * a.ambActive * (1.0 - a.isSilent);
    float tissue2 = fbm2_4(p * 6.0 - Time * 0.03 * a.motSpeed + 5.0);
    col += a.brainCol2 * tissue2 * 0.025 * a.ambient * a.ambActive * (1.0 - a.isSilent);

    // ── Camera — orbiting the brain ──
    float FOV = 1.0;
    float camAng = a.stereoBal * 0.25 + Time * 0.04 * a.motSpeed;
    float camDist = 3.5 + a.profBass * 0.15;
    float3 camPos = float3(sin(camAng) * camDist, 0.8 + a.stereoDiff * 0.15, cos(camAng) * camDist);
    float3 camTarget = float3(0, 0.1, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Generate 3D neurons ──
    float3 neuronPos[N_NEURONS];
    float neuronFire[N_NEURONS];
    float3 neuronCol[N_NEURONS];
    float neuronDepth[N_NEURONS];
    float2 neuronScr[N_NEURONS];
    int neuronOrder[N_NEURONS];

    float bandVals[8] = {a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7};

    [unroll] for (int ni = 0; ni < N_NEURONS; ni++) {
        neuronPos[ni] = brainNeuronPos3D(ni, N_NEURONS, a.stereoBal, a.energy);
        int bandIdx = ni % 8;
        neuronFire[ni] = bandVals[bandIdx];

        // Firing rate — spectrum band + beat modulation
        float firePhase = Time * (1.0 + bandVals[bandIdx] * 4.0) + ni * 0.7;
        float fireWave = sin(firePhase) * 0.5 + 0.5;
        neuronFire[ni] *= fireWave * (0.4 + a.beat * 0.6 * a.tempoConf);

        // Color by frequency band
        float hue = a.hueBase + float(bandIdx) / 8.0 * a.hueRange + a.section * 0.03;
        neuronCol[ni] = hsv(hue, 0.7 * a.satur, 0.9);

        // Project to screen
        neuronDepth[ni] = objDepth3D(neuronPos[ni], camPos, fwd);
        neuronScr[ni] = project3D(neuronPos[ni], camPos, fwd, right, up, FOV);
        neuronOrder[ni] = ni;
    }

    // Simple depth sort — bubble sort by depth (far to near)
    [loop] for (int si = 0; si < N_NEURONS - 1; si++) {
        [loop] for (int sj = 0; sj < N_NEURONS - 1 - si; sj++) {
            if (neuronDepth[neuronOrder[sj]] < neuronDepth[neuronOrder[sj + 1]]) {
                int tmp = neuronOrder[sj];
                neuronOrder[sj] = neuronOrder[sj + 1];
                neuronOrder[sj + 1] = tmp;
            }
        }
    }

    // ── Synaptic arcs between nearby firing neurons ──
    [loop] for (int ai = 0; ai < N_NEURONS; ai++) {
        if (neuronFire[ai] < 0.08) continue;
        [loop] for (int bi = ai + 1; bi < N_NEURONS; bi++) {
            if (neuronFire[bi] < 0.08) continue;
            float3 pa3 = neuronPos[ai];
            float3 pb3 = neuronPos[bi];
            float dist3D = length(pa3 - pb3);
            if (dist3D > 0.9) continue;

            float2 pa = neuronScr[ai];
            float2 pb = neuronScr[bi];
            float da = neuronDepth[ai];
            float db = neuronDepth[bi];
            if (da < 0.1 || db < 0.1) continue;

            // Arc strength from phase coherence + combined firing
            float sync = a.phaseCorr * neuronFire[ai] * neuronFire[bi];
            float arcStr = sync * 0.35 * smoothstep(0.9, 0.1, dist3D);
            float avgDepth = (da + db) * 0.5;
            float depthFade = exp(-avgDepth * 0.08);

            // Jagged electrical arc
            float jagged = 0.006 * a.transient + 0.002;
            float arc = arcGlow(p, pa, pb, jagged, float(ai) + float(bi) * 0.3);
            col += neuronCol[ai] * arc * arcStr * depthFade * (1.0 - a.isSilent);

            // Signal pulse traveling along arc
            float pulseSpeed = (a.bpm > 1.0 ? a.bpm / 120.0 : 0.5) * a.motSpeed;
            float pulsePhase = frac(Time * pulseSpeed + ai * 0.1 + bi * 0.07);
            float2 pulsePos = lerp(pa, pb, pulsePhase);
            float pulseDist = length(p - pulsePos);
            float pulseGlow = exp(-pulseDist * pulseDist * 600.0) * sync * 0.6 * depthFade;
            col += float3(0.9, 0.95, 1.0) * pulseGlow * a.dynActive * (1.0 - a.isSilent);
        }
    }

    // ── Render neurons back-to-front ──
    [loop] for (int ri = 0; ri < N_NEURONS; ri++) {
        int idx = neuronOrder[ri];
        float depth = neuronDepth[idx];
        if (depth < 0.1) continue;

        float2 nPos = neuronScr[idx];
        float nDist = length(p - nPos);
        float fire = neuronFire[idx];

        // Depth-based size — closer = bigger
        float baseSize = 0.012 + fire * 0.015;
        float screenSize = baseSize / depth * 4.0;
        float depthFade = exp(-depth * 0.06);

        // Neuron body — glows with firing
        float bodyGlow = exp(-nDist * nDist / (screenSize * screenSize * 3.0)) * (0.2 + fire * 0.7);
        col += neuronCol[idx] * bodyGlow * depthFade * (1.0 - a.isSilent);

        // Bright core when firing
        float coreGlow = exp(-nDist * nDist / (screenSize * screenSize * 0.3)) * fire * 0.9;
        float3 fireCol = lerp(neuronCol[idx], float3(1.0, 1.0, 1.0), fire);
        col += fireCol * coreGlow * depthFade * (1.0 - a.isSilent);

        // Synaptic cleft — halo around firing neuron
        float cleftGlow = exp(-nDist * nDist * 50.0) * fire * 0.08 * depthFade;
        col += a.brainCol2 * cleftGlow * (1.0 - a.isSilent);

        // Kick — neural spike expansion
        if (a.kick > 0.1) {
            float spikeGlow = exp(-nDist * nDist * 200.0) * a.kick * 0.3 * a.kickConf * depthFade;
            col += float3(0.8, 0.9, 1.0) * spikeGlow * (1.0 - a.isSilent);
        }
    }

    // ── Dopamine wave — energy surge creates expanding 3D wave ──
    float2 brainCenter = project3D(float3(0, 0.1, 0), camPos, fwd, right, up, FOV);
    float dopamineR = a.energy * 1.2;
    float dopamineDist = length(p - brainCenter);
    float dopamineWave = exp(-abs(dopamineDist - dopamineR) * 6.0) * a.energy * 0.12;
    col += a.brainCol * dopamineWave * (1.0 - a.isSilent);

    // ── Seizure activity — transient causes chaotic firing ──
    if (a.transient > 0.25) {
        float chaosN = hash21(floor(p * 15.0) + floor(Time * 8.0));
        float chaos = step(0.93, chaosN) * a.transient * 0.2;
        col += float3(0.9, 0.7, 1.0) * chaos * a.beamActive * (1.0 - a.isSilent);
    }

    // ── Kick shock — neural spike from brain center ──
    float kickDist = length(p - brainCenter);
    float kickSpike = exp(-kickDist * kickDist * 8.0) * a.kick * 0.15 * a.kickConf;
    col += a.brainCol2 * kickSpike * (1.0 - a.isSilent);

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.25;

    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
