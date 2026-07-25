// Mode 41: Spectral Aurora Cathedral — volumetric aurora in gothic space
// You stand in a cathedral. 8 aurora curtains hang from above at different heights.
// Bass = curtain base width, mids = curtain wave/sway, highs = curtain top shimmer.
// Stereo = L/R curtain separation. Beat = light pillars through stained glass.
// Kick = stained glass illumination. Transient = aurora ripple.
// Envelope = curtain sway. Section = color palette shift. LUFS = aurora brightness.
// Crest = curtain edge sharpness. THD = atmospheric turbulence. Phase = L/R symmetry.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define N_CURTAINS 8

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

struct AuroraCurtain {
    float xCenter;
    float yBase;
    float yTop;
    float width;
    float energy;
    float gate;
    float freqFrac;
    float3 color;
};

void computeCurtains(out AuroraCurtain curtains[N_CURTAINS], float bands[8], float dspBands[8],
                     float kickSurge, float beatPulse, float stereoBal, float stereoWid,
                     float crest, float thd, float transient, float envelope, float section, AudioData a)
{
    [unroll] for (int n = 0; n < N_CURTAINS; n++)
    {
        float bt = float(n) / float(N_COMP - 1);

        float rawEnergy = bands[n] + dspBands[n] * 0.12;
        float energy = (n < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
        float gate = smoothstep(0.02, 0.08, rawEnergy);

        // Spectrum L/R — stereo spatial positioning
        float freqU = bandFreq[n];
        float lE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.166), 0).r;
        float rE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.833), 0).r;
        float stereoEnergy = max(lE, rE);
        energy = max(energy, stereoEnergy * 0.5);
        gate = max(gate, smoothstep(0.02, 0.08, stereoEnergy));
        float panMod = (lE - rE) * 0.5;

        // Curtain position — spread across X with stereo separation
        curtains[n].xCenter = lerp(-2.5, 2.5, bt) + stereoBal * 0.3 + panMod * 0.5;
        curtains[n].yBase = 0.5;
        curtains[n].yTop = lerp(2.0, 4.0, bt) + energy * 0.5;
        curtains[n].width = lerp(0.8, 0.3, bt) * (1.0 + stereoWid * 0.3);

        // Staggered beat breathing
        float h = energy * (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
        h += transient * lerp(0.05, 0.2, bt) * gate;
        h += envelope * lerp(0.08, 0.03, bt) * gate;
        h += section * 0.05 * gate;
        h += (n < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;
        h *= gate;

        curtains[n].energy = clamp(h, 0.0, 1.5);
        curtains[n].gate = gate;
        curtains[n].freqFrac = bt;

        // Color — section-driven palette
        float3 c = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        c = lerp(c, lerp(a.brainCol, a.brainCol2, bt), 0.3);
        // Section shift
        if (int(a.section) % 3 == 1) c = lerp(c, a.brainCol3, 0.3);
        curtains[n].color = c;
    }
}

// Aurora curtain density at a 3D point
float auroraDensity(float3 p, AuroraCurtain curtains[N_CURTAINS], float bands[8],
                    float envelope, float thd, float beatPulse, float silence)
{
    float density = 0.0;

    [unroll] for (int n = 0; n < N_CURTAINS; n++) {
        if (curtains[n].gate < 0.01) continue;

        // Distance from curtain center plane
        float xDist = p.x - curtains[n].xCenter;
        float yFrac = (p.y - curtains[n].yBase) / max(curtains[n].yTop - curtains[n].yBase, 0.1);

        if (yFrac < 0.0 || yFrac > 1.0) continue;

        // Curtain width modulated by height — wider at base, narrower at top
        float w = curtains[n].width * (1.0 - yFrac * 0.3);

        // Wave displacement — envelope-driven sway
        float sway = sin(p.y * 2.0 + Time * 1.5 * (0.5 + curtains[n].freqFrac)) * envelope * 0.3;
        sway += cos(p.y * 3.5 + Time * 2.0) * bands[2] * 0.2;
        xDist += sway;

        // THD turbulence
        float turb = fbm2_4(float2(p.y * 3.0 + Time * 0.5, xDist * 2.0)) * thd * 0.15;
        xDist += turb;

        // Gaussian falloff
        float xFalloff = exp(-xDist * xDist / (w * w));

        // Vertical falloff — fade at top and bottom
        float yFalloff = sin(yFrac * PI);

        // High-band shimmer at top
        float shimmer = bands[7] * pow(yFrac, 3.0) * 0.3;

        density += (xFalloff * yFalloff * curtains[n].energy + shimmer * xFalloff) * 0.3;
    }

    // Beat — global pulse
    density += beatPulse * 0.02 * exp(-p.y * 0.3) * silence;

    return density * silence;
}

float3 auroraColor(float3 p, AuroraCurtain curtains[N_CURTAINS], AudioData a)
{
    float3 col = float3(0, 0, 0);
    float totalWeight = 0.0;

    [unroll] for (int n = 0; n < N_CURTAINS; n++) {
        if (curtains[n].gate < 0.01) continue;
        float xDist = p.x - curtains[n].xCenter;
        float yFrac = (p.y - curtains[n].yBase) / max(curtains[n].yTop - curtains[n].yBase, 0.1);
        if (yFrac < 0.0 || yFrac > 1.0) continue;
        float w = curtains[n].width * (1.0 - yFrac * 0.3);
        float weight = exp(-xDist * xDist / (w * w)) * curtains[n].energy;
        col += curtains[n].color * weight;
        totalWeight += weight;
    }

    return totalWeight > 0.001 ? col / totalWeight : a.brainCol;
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
    float dspBands[8] = { DspBand0, DspBand1, DspBand2, DspBand3, DspBand4, DspBand5, DspBand6, DspBand7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;
    float phrase = phrasePulse(a);

    AuroraCurtain curtains[N_CURTAINS];
    computeCurtains(curtains, bands, dspBands, kickSurge, beatPulse, a.stereoBal, a.stereoWid,
                    crest, thd, transientAmt, envelope, a.section, a);

    // ── Camera — looking up at aurora from cathedral floor ──
    float FOV = 0.8;
    float camAng = a.section * 0.3 + a.stereoBal * 0.15 + Time * 0.02 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 1.0, 0.0, cos(camAng) * 1.0);
    float3 camTarget = float3(0, 2.5, 0);
    float3 rd = cameraRay(camPos, camTarget, float2(-p.x, -p.y), FOV);

    // ── Background — dark cathedral ──
    float3 col = float3(0.002, 0.001, 0.005) * silence;
    col += starfield(uv, a) * 0.003;

    // ── Volumetric raymarch through aurora ──
    float t = 0.1;
    float3 accum = float3(0, 0, 0);
    float transmittance = 1.0;
    float stepSize = 0.1;

    [loop] for (int i = 0; i < 24; i++) {
        float3 sp = camPos + rd * t;
        if (sp.y > 5.0 || length(sp.xz) > 4.0) break;

        float density = auroraDensity(sp, curtains, bands, envelope, thd, beatPulse, silence);
        density *= smoothstep(0.002, 0.02, density);

        if (density > 0.003) {
            float3 pointCol = auroraColor(sp, curtains, a);
            pointCol *= density * (0.5 + envelope * 0.5) * (1.0 + lufs * 0.2);

            float sigma = density * 0.2 + 0.01;
            transmittance *= exp(-sigma * stepSize);
            accum += pointCol * transmittance * stepSize * 2.0;
        }
        t += stepSize;
    }

    col += accum * silence;

    // ── Cathedral pillars — gothic arches at edges ──
    {
        float3 pillarPos = float3(3.0, 2.0, 0);
        float3 toPillar = pillarPos - camPos;
        float pillarDepth = dot(toPillar, normalize(camTarget - camPos));
        if (pillarDepth > 0.1) {
            float3 fwd2 = normalize(camTarget - camPos);
            float3 right2 = normalize(cross(fwd2, float3(0, 1, 0)));
            float3 up2 = cross(right2, fwd2);
            float2 scrPillar = float2(dot(toPillar, right2) / (pillarDepth * FOV), dot(toPillar, up2) / (pillarDepth * FOV));
            float pillarDist = length(p - scrPillar);
            // Pillar silhouette
            float pillarGlow = exp(-pillarDist * pillarDist * 10.0) * 0.02;
            col += a.brainCol3 * pillarGlow * silence;
        }
    }

    // ── Beat — light pillars through stained glass ──
    col += a.brainCol * beatPulse * exp(-a.beatPhase * 4.0) * exp(-p.x * p.x * 2.0) * 0.08 * silence;

    // ── Kick — stained glass illumination ──
    col += a.brainCol3 * kickSurge * 0.06 * exp(-r * r * 3.0) * silence;

    // ── Transient — aurora ripple ──
    col += a.brainCol2 * transientAmt * 0.03 * sin(r * 20.0 - Time * 10.0) * silence;

    // ── Beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.025 * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.02 * silence;

    // ── Energy + punch ──
    col += a.brainCol2 * a.energy * 0.015 * silence;
    col += a.brainCol * a.punch * 0.015 * silence;

    // ── Beat anticipation ──
    col += a.brainCol * a.beatAnt * 0.01 * exp(-r * 2.0) * silence;

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── HDR limiter — dark volumetric ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
