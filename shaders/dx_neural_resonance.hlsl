// Mode 50: Neural Resonance Lattice — 3D lattice of glowing nodes connected by phase coherence
// A 3D grid of nodes pulses with frequency bands. Phase coherence lights up connections.
// LUFS = node brightness. Crest = node sharpness. THD = jitter. Phase = link glow.
// Beat = lattice compression. Kick = node spike. Transient = link rupture.

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
#define LATTICE_NX 4
#define LATTICE_NY 3
#define LATTICE_NZ 4

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

float3 nodePos(int ix, int iy, int iz, AudioData a, float beatPulse, float kickSurge)
{
    float fx = (float(ix) - float(LATTICE_NX - 1) * 0.5) / float(LATTICE_NX);
    float fy = (float(iy) - float(LATTICE_NY - 1) * 0.5) / float(LATTICE_NY);
    float fz = (float(iz) - float(LATTICE_NZ - 1) * 0.5) / float(LATTICE_NZ);
    float3 pos = float3(fx, fy, fz) * 3.0;
    pos.y += sin(Time * 0.3 + float(ix) * 0.7) * 0.05 * a.motSpeed;
    pos.x += cos(Time * 0.2 + float(iz) * 0.5) * 0.05 * a.motSpeed;
    pos += float3(a.stereoBal * 0.1, 0, 0);
    float beatScale = 1.0 - beatPulse * 0.08;
    pos *= beatScale;
    pos += normalize(pos + 0.001) * kickSurge * 0.1;
    return pos;
}

float latticeSDF(float3 p, AudioData a, float bands[8], float beatPulse, float kickSurge,
                 float thd, float crest, float lufs)
{
    float minDist = 1e10;
    float minNodeDist = 1e10;

    [loop] for (int iz = 0; iz < LATTICE_NZ; iz++)
    {
        [loop] for (int iy = 0; iy < LATTICE_NY; iy++)
        {
            [loop] for (int ix = 0; ix < LATTICE_NX; ix++)
            {
                int bandIdx = iz * 2 + (ix % 2);
                bandIdx = clamp(bandIdx, 0, 7);
                float bandLevel = bands[bandIdx];

                float3 np = nodePos(ix, iy, iz, a, beatPulse, kickSurge);
                float nodeR = 0.06 + bandLevel * 0.10 + lufs * 0.02;
                nodeR *= (0.8 + crest * 0.4);

                float3 jitter = float3(
                    thd * (hash11(np.x * 50.0 + Time) - 0.5) * 0.02,
                    thd * (hash11(np.y * 50.0 + Time) - 0.5) * 0.02,
                    thd * (hash11(np.z * 50.0 + Time) - 0.5) * 0.02
                );

                float d = sdSphere(p - (np + jitter), nodeR);
                if (d < minDist) minDist = d;
                if (d < minNodeDist) minNodeDist = d;
            }
        }
    }

    float phaseCoh = phaseCoherence();
    float linkRadius = 0.012 + phaseCoh * 0.015;

    [loop] for (int lz = 0; lz < LATTICE_NZ; lz++)
    {
        [loop] for (int ly = 0; ly < LATTICE_NY; ly++)
        {
            [loop] for (int lx = 0; lx < LATTICE_NX; lx++)
            {
                float3 a0 = nodePos(lx, ly, lz, a, beatPulse, kickSurge);

                if (lx < LATTICE_NX - 1)
                {
                    float3 a1 = nodePos(lx + 1, ly, lz, a, beatPulse, kickSurge);
                    float d = sdCapsule(p, a0, a1, linkRadius);
                    minDist = min(minDist, d * 2.0);
                }
                if (lz < LATTICE_NZ - 1)
                {
                    float3 a1 = nodePos(lx, ly, lz + 1, a, beatPulse, kickSurge);
                    float d = sdCapsule(p, a0, a1, linkRadius);
                    minDist = min(minDist, d * 2.0);
                }
            }
        }
    }

    return minDist;
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
    float camAng = a.section * 0.5 + a.stereoBal * 0.3 + panMod * 0.2 + Time * 0.03 * a.motSpeed;
    float camDist = 4.0 - a.profBass * 0.3 - kickSurge * 0.3;
    float3 camPos = float3(sin(camAng) * camDist, 1.5 + a.stereoDiff * 0.1, cos(camAng) * camDist);
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
        float d = latticeSDF(sp, a, bands, beatPulse, kickSurge, thd, crest, lufs);
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
            latticeSDF(hp + float3(eps, 0, 0), a, bands, beatPulse, kickSurge, thd, crest, lufs)
          - latticeSDF(hp - float3(eps, 0, 0), a, bands, beatPulse, kickSurge, thd, crest, lufs),
            2.0 * eps,
            latticeSDF(hp + float3(0, 0, eps), a, bands, beatPulse, kickSurge, thd, crest, lufs)
          - latticeSDF(hp - float3(0, 0, eps), a, bands, beatPulse, kickSurge, thd, crest, lufs)
        ));

        float fres = pow(1.0 - max(dot(n, vDir), 0.0), 5.0);
        float3 lDir = normalize(float3(0.5, 0.7, 0.3));
        float3 lDir2 = normalize(float3(-0.3 + a.stereoBal * 0.2, 0.5, 0.4));
        float diff = max(dot(n, lDir), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
        float spec = pow(max(dot(reflect(-lDir, n), vDir), 0.0), 60.0);

        float iterFrac = float(hitIter) / float(MARCH_STEPS);
        float hueShift = beatPulse * 0.1 + kickSurge * 0.15;
        float3 nodeCol = hsv(a.hueBase + iterFrac * a.hueRange + hueShift, 0.6 * a.satur, 0.9);
        nodeCol = lerp(nodeCol, lerp(a.brainCol, a.brainCol2, iterFrac), 0.3);
        nodeCol = lerp(nodeCol, a.brainCol3, phaseCoh * 0.2 + kickSurge * 0.15);

        float edge = pow(1.0 - max(dot(n, vDir), 0.0), 2.0) * crest;

        float3 litCol = nodeCol * (diff + diff2) * (0.3 + a.brightness * 0.3 + a.dynamic * 0.2);
        litCol += float3(0.9, 0.85, 0.8) * spec * (0.5 + a.dynLight * 0.7);
        litCol += nodeCol * fres * (0.4 + envelope * 0.4 + a.glow * 0.2);
        litCol += a.brainCol3 * edge * 0.1;
        litCol += nodeCol * beatPulse * 0.15 * silence;
        litCol += float3(1.0, 0.5, 0.1) * kickSurge * 0.25 * silence;

        if (transientAmt > 0.02)
            litCol = lerp(litCol, litCol.gbr, transientAmt * 0.5);

        litCol *= (0.6 + a.dynamic * 0.4);
        litCol += nodeCol * a.punch * 0.05 * silence;

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
