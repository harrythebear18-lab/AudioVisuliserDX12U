// Mode 53: Spectral Crystal Genesis — audio-grown 3D crystal SDF
// Octahedral folds create crystal facets. Bands control growth along each axis.
// Crest = facet sharpness. THD = surface roughness. LUFS = crystal size.
// Phase = symmetry. Beat = growth pulse. Kick = facet spike. Transient = fracture.

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

float3 crystalFold(float3 p, int iterations)
{
    [unroll(4)] for (int i = 0; i < 4; i++)
    {
        if (i >= iterations) break;
        p = abs(p);
        float ang = PI / 4.0;
        float c = cos(ang), s = sin(ang);
        p.xz = float2(p.x * c - p.z * s, p.x * s + p.z * c);
        if (p.x < p.z) p.xz = p.zx;
        if (p.y < p.z) p.yz = p.zy;
        if (p.x < p.y) p.xy = p.yx;
    }
    return p;
}

float crystalSDF(float3 p, AudioData a, float bands[8], float beatPulse, float kickSurge,
                 float thd, float crest, float lufs)
{
    float phaseCoh = phaseCoherence();
    int foldIter = 2 + int(phaseCoh * 2.0 + bands[2] * 1.0);
    foldIter = clamp(foldIter, 1, 4);

    float3 folded = crystalFold(p, foldIter);

    float3 growth = float3(
        0.5 + bands[0] * 0.3 + bands[1] * 0.2,
        0.4 + bands[2] * 0.3 + bands[3] * 0.2,
        0.5 + bands[4] * 0.3 + bands[5] * 0.2
    );
    growth *= (1.0 + lufs * 0.2);
    growth *= (1.0 - beatPulse * 0.05);

    float d = sdEllipsoid(folded, growth);

    float facetAng = PI / 6.0 + crest * 0.3;
    float3 facetN = normalize(float3(cos(facetAng), sin(facetAng), 0.3));
    float facetD = dot(p, facetN) - 0.3 - bands[6] * 0.1;
    d = max(d, -facetD);

    d += thd * 0.03 * sin(p.x * 15.0 + p.y * 12.0 + p.z * 10.0 + Time * 5.0);
    d -= kickSurge * 0.05;

    return d;
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

    float FOV = 0.6 + kickSurge * 0.06;
    float camAng = a.section * 0.6 + a.stereoBal * 0.2 + panMod * 0.2 + Time * 0.03 * a.motSpeed;
    float camDist = 3.5 - a.profBass * 0.3 - kickSurge * 0.3;
    float3 camPos = float3(sin(camAng) * camDist, 1.0 + a.stereoDiff * 0.1, cos(camAng) * camDist);
    camPos += float3(
        sin(Time * 47.0) * kickSurge * 0.06,
        cos(Time * 43.0) * kickSurge * 0.04,
        sin(Time * 51.0) * kickSurge * 0.05
    );
    camPos.y += sin(a.beatPhase * PI * 2.0) * beatPulse * 0.04;
    float3 camTarget = float3(0, 0, 0);
    float3 rd = cameraRay(camPos, camTarget, float2(-p.x, -p.y), FOV);

    float3 col = float3(0.002, 0.002, 0.008) * silence;
    col += starfield(uv, a) * 0.005;

    float t = 0.05;
    float marchGlow = 0.0;
    bool hit = false;
    int hitIter = 0;

    [loop] for (int i = 0; i < MARCH_STEPS; i++) {
        float3 sp = camPos + rd * t;
        float d = crystalSDF(sp, a, bands, beatPulse, kickSurge, thd, crest, lufs);
        marchGlow += 0.005 / (1.0 + d * d * 30.0);
        if (d < 0.003) { hit = true; hitIter = i; break; }
        t += d * 0.6;
        if (t > 8.0) break;
    }

    if (hit) {
        float3 hp = camPos + rd * t;
        float3 vDir = normalize(camPos - hp);

        float eps = 0.003;
        float3 n = normalize(float3(
            crystalSDF(hp + float3(eps, 0, 0), a, bands, beatPulse, kickSurge, thd, crest, lufs)
          - crystalSDF(hp - float3(eps, 0, 0), a, bands, beatPulse, kickSurge, thd, crest, lufs),
            2.0 * eps,
            crystalSDF(hp + float3(0, 0, eps), a, bands, beatPulse, kickSurge, thd, crest, lufs)
          - crystalSDF(hp - float3(0, 0, eps), a, bands, beatPulse, kickSurge, thd, crest, lufs)
        ));

        float fres = pow(1.0 - max(dot(n, vDir), 0.0), 5.0);
        float3 lDir = normalize(float3(0.5, 0.7, 0.3));
        float3 lDir2 = normalize(float3(-0.3 + a.stereoBal * 0.2, 0.5, 0.4));
        float diff = max(dot(n, lDir), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
        float spec = pow(max(dot(reflect(-lDir, n), vDir), 0.0), 80.0);

        float iterFrac = float(hitIter) / float(MARCH_STEPS);
        float hueShift = beatPulse * 0.1 + kickSurge * 0.15;
        float3 crystalCol = hsv(a.hueBase + iterFrac * a.hueRange + hueShift, 0.7 * a.satur, 0.9);
        crystalCol = lerp(crystalCol, lerp(a.brainCol, a.brainCol2, iterFrac), 0.3);
        crystalCol = lerp(crystalCol, a.brainCol3, phaseCoh * 0.2 + kickSurge * 0.15);

        float edge = pow(1.0 - max(dot(n, vDir), 0.0), 2.0) * crest;

        float3 litCol = crystalCol * (diff + diff2) * (0.3 + a.brightness * 0.3 + a.dynamic * 0.2);
        litCol += float3(0.9, 0.85, 0.8) * spec * (0.6 + a.dynLight * 0.7);
        litCol += crystalCol * fres * (0.4 + envelope * 0.4 + a.glow * 0.2);
        litCol += a.brainCol3 * edge * 0.15;
        litCol += crystalCol * beatPulse * 0.15 * silence;
        litCol += float3(1.0, 0.5, 0.1) * kickSurge * 0.25 * silence;

        if (transientAmt > 0.02)
            litCol = lerp(litCol, litCol.gbr, transientAmt * 0.5);

        litCol *= (0.6 + a.dynamic * 0.4);
        litCol += crystalCol * a.punch * 0.05 * silence;

        col = blendScreen(col, litCol);
    }

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
