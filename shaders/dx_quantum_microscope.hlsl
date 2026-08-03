// Mode 51: Quantum Spectral Microscope — fly through spectrum as 3D terrain
// Biquad bands create mountain ranges. Spectral centroid shifts camera focus.
// Crest = terrain roughness. Phase = fog density. LUFS = terrain height.
// Beat = terrain pulse. Kick = camera dolly. Transient = terrain glitch.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define MARCH_STEPS 16

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

float terrainHeight(float3 p, float bands[8], float lufs, float crest, float thd, float beatPulse)
{
    float h = 0.0;
    h += bands[0] * 0.5 * exp(-abs(p.x + 2.0) * 0.5);
    h += bands[1] * 0.4 * exp(-abs(p.x + 1.0) * 0.6);
    h += bands[2] * 0.35 * exp(-abs(p.x) * 0.7);
    h += bands[3] * 0.3 * exp(-abs(p.x - 1.0) * 0.8);
    h += bands[4] * 0.25 * exp(-abs(p.x - 2.0) * 0.9);
    h += bands[5] * 0.2 * exp(-abs(p.x - 3.0) * 1.0);
    h += bands[6] * 0.15 * exp(-abs(p.x - 4.0) * 1.1);
    h += bands[7] * 0.1 * exp(-abs(p.x - 5.0) * 1.2);
    h *= (1.0 + lufs * 0.3);
    h += beatPulse * 0.1 * sin(p.x * 3.0 + Time * 2.0);
    h += crest * 0.08 * sin(p.x * 8.0 + p.z * 6.0 + Time);
    h += thd * 0.04 * (hash11(p.x * 20.0 + p.z * 15.0 + Time) - 0.5);
    return h;
}

float terrainSDF(float3 p, float bands[8], float lufs, float crest, float thd, float beatPulse)
{
    float h = terrainHeight(p, bands, lufs, crest, thd, beatPulse);
    return p.y - h;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    float specL[8]; float specR[8];
    [unroll] for (int sb = 0; sb < 8; sb++) {
        specL[sb] = u_spectrum.SampleLevel(u_sampler, float2(bandFreq[sb], 0.166), 0).r;
        specR[sb] = u_spectrum.SampleLevel(u_sampler, float2(bandFreq[sb], 0.833), 0).r;
        bands[sb] = max(bands[sb], max(specL[sb], specR[sb]) * 0.5);
    }
    float panMod = (specL[0] + specL[1] - specR[0] - specR[1]) * 0.25;
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;
    float phrase = phrasePulse(a);

    float FOV = 0.7 + kickSurge * 0.05;
    float camAng = a.section * 0.3 + a.stereoBal * 0.2 + panMod * 0.2 + Time * 0.02 * a.motSpeed;
    float camDist = 5.0 - a.profBass * 0.3 - kickSurge * 0.3;
    float3 camPos = float3(sin(camAng) * camDist, 2.0 + a.stereoDiff * 0.15, cos(camAng) * camDist);
    camPos += float3(
        sin(Time * 47.0) * kickSurge * 0.05,
        cos(Time * 43.0) * kickSurge * 0.03,
        sin(Time * 51.0) * kickSurge * 0.04
    );
    camPos.y += sin(a.beatPhase * PI * 2.0) * beatPulse * 0.04;
    float3 camTarget = float3(a.stereoBal * 0.5, 0.5, 0);
    float3 rd = cameraRay(camPos, camTarget, float2(-p.x, -p.y), FOV);

    float3 col = float3(0.002, 0.003, 0.01) * silence;
    col += starfield(uv, a) * 0.005;

    float t = 0.05;
    float marchGlow = 0.0;
    bool hit = false;
    int hitIter = 0;

    [loop] for (int i = 0; i < MARCH_STEPS; i++) {
        float3 sp = camPos + rd * t;
        float d = terrainSDF(sp, bands, lufs, crest, thd, beatPulse);
        marchGlow += 0.005 / (1.0 + d * d * 30.0);
        if (d < 0.003) { hit = true; hitIter = i; break; }
        t += d * 0.6;
        if (t > 10.0) break;
    }

    if (hit) {
        float3 hp = camPos + rd * t;
        float3 vDir = normalize(camPos - hp);

        float eps = 0.003;
        float3 n = normalize(float3(
            terrainSDF(hp + float3(eps, 0, 0), bands, lufs, crest, thd, beatPulse)
          - terrainSDF(hp - float3(eps, 0, 0), bands, lufs, crest, thd, beatPulse),
            2.0 * eps,
            terrainSDF(hp + float3(0, 0, eps), bands, lufs, crest, thd, beatPulse)
          - terrainSDF(hp - float3(0, 0, eps), bands, lufs, crest, thd, beatPulse)
        ));

        float fres = pow(1.0 - max(dot(n, vDir), 0.0), 5.0);
        float3 lDir = normalize(float3(0.5, 0.7, 0.3));
        float3 lDir2 = normalize(float3(-0.3 + a.stereoBal * 0.2, 0.5, 0.4));
        float diff = max(dot(n, lDir), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
        float spec = pow(max(dot(reflect(-lDir, n), vDir), 0.0), 60.0);

        float iterFrac = float(hitIter) / float(MARCH_STEPS);
        float hueShift = beatPulse * 0.1 + kickSurge * 0.15;
        float freqFrac = clamp((hp.x + 3.0) / 8.0, 0.0, 1.0);
        float3 terrainCol = hsv(a.hueBase + freqFrac * a.hueRange + hueShift, 0.6 * a.satur, 0.9);
        terrainCol = lerp(terrainCol, lerp(a.brainCol, a.brainCol2, freqFrac), 0.3);
        terrainCol = lerp(terrainCol, a.brainCol3, bands[7] * 0.2 + kickSurge * 0.15);

        float edge = pow(1.0 - max(dot(n, vDir), 0.0), 2.0) * crest;

        float3 litCol = terrainCol * (diff + diff2) * (0.3 + a.brightness * 0.3 + a.dynamic * 0.2);
        litCol += float3(0.9, 0.85, 0.8) * spec * (0.5 + a.dynLight * 0.7);
        litCol += terrainCol * fres * (0.4 + envelope * 0.4 + a.glow * 0.2);
        litCol += a.brainCol3 * edge * 0.1;
        litCol += terrainCol * beatPulse * 0.15 * silence;
        litCol += float3(1.0, 0.5, 0.1) * kickSurge * 0.25 * silence;

        if (transientAmt > 0.02)
            litCol = lerp(litCol, litCol.gbr, transientAmt * 0.5);

        litCol *= (0.6 + a.dynamic * 0.4);
        litCol += terrainCol * a.punch * 0.05 * silence;

        col = blendScreen(col, litCol);
    }

    float fogDepth = exp(-t * 0.06) * (1.0 - phaseCoh * 0.3);
    col *= fogDepth;

    col += a.brainCol * marchGlow * (0.015 + a.glow * 0.02) * (0.5 + envelope * 0.5) * silence;
    col += a.brainCol * exp(-abs(r - a.beatPhase * 0.7) * abs(r - a.beatPhase * 0.7) * 40.0) * beatPulse * 0.025 * silence;
    col += a.brainCol3 * kickSurge * 0.05 * exp(-r * r * 5.0) * silence;
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.025 * silence;
    col += a.brainCol3 * a.colorPulse * 0.02 * silence;
    col += a.brainCol2 * a.energy * 0.015 * silence;
    col += a.brainCol * a.punch * 0.015 * silence;
    col += a.brainCol * a.beatAnt * 0.01 * exp(-r * 2.0) * silence;
    col *= (0.3 + a.gated * 0.7);
    col += standardOverlays(p, r, a) * 0.02;
    col = hdrLimiter(col);
    col *= silence;

    return float4(col, 1.0);
}
