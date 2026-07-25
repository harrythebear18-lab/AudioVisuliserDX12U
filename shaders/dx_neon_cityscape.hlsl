// Mode 35: Neon Cityscape — synthwave skyline with SDF buildings
// 24 buildings (3 per band) with neon window glow, wet street reflections.
// Bass = building height/mass, mids = window illumination/neon flicker,
// highs = particle shimmer/edge highlights. Beat = sun pulse. Kick = ground flash.
// Transient = neon glitch. DSP: LUFS→emission, crest→neon edge, THD→flicker, phase→coherence.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define N_BUILDINGS 24
#define MAX_STEPS 48

struct Building {
    float3 pos;
    float3 dims;
    float energy;
    float gate;
    float freqFrac;
    float3 color;
};

void computeBuildings(out Building bld[N_BUILDINGS], float bands[8], float dspBands[8],
                      float kickSurge, float beatPulse, float stereoBal, float crest, float thd,
                      float transient, float envelope, float section, AudioData a)
{
    [unroll] for (int n = 0; n < N_BUILDINGS; n++)
    {
        int band = n / 3;
        int sub = n % 3;
        float bt = float(band) / float(N_COMP - 1);

        float rawEnergy = bands[band] + dspBands[band] * 0.12;
        float energy = (band < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
        float gate = smoothstep(0.02, 0.08, rawEnergy);

        // Building position — lined up along z-axis on both sides
        float side = (n % 2 == 0) ? 1.0 : -1.0;
        float zPos = (float(n) - float(N_BUILDINGS) * 0.5) * 1.5;
        float xPos = side * (1.5 + a.stereoWid * 0.3);

        // Height — bass drives taller buildings
        float height = 1.0 + energy * 2.5 * gate;
        float width = 0.8 + bands[1] * 0.2;
        float depth = 0.8 + bands[0] * 0.2;

        bld[n].pos = float3(xPos, height * 0.5 - 1.0, zPos);
        bld[n].dims = float3(width * 0.5, height * 0.5, depth * 0.5);

        // Staggered beat breathing
        float h = energy * (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
        h += transient * lerp(0.05, 0.2, bt) * gate;
        h += envelope * lerp(0.08, 0.03, bt) * gate;
        h += section * 0.05 * gate;
        h += (band < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;
        h *= gate;

        bld[n].energy = clamp(h, 0.0, 1.5);
        bld[n].gate = gate;
        bld[n].freqFrac = bt;

        // Color — frequency-positioned neon
        float3 c = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        c = lerp(c, lerp(a.brainCol, a.brainCol2, bt), 0.3);
        bld[n].color = c;
    }
}

float sceneSDF(float3 p, Building bld[N_BUILDINGS])
{
    float minDist = 1e10;
    [unroll] for (int i = 0; i < N_BUILDINGS; i++) {
        if (bld[i].gate < 0.01) continue;
        float3 local = p - bld[i].pos;
        float d = sdBox(local, bld[i].dims);
        minDist = smin(minDist, d, 0.1);
    }
    // Ground plane
    float ground = sdPlane(p, float3(0, 1, 0), 1.0);
    minDist = smin(minDist, ground, 0.05);
    return minDist;
}

float3 windowGlow(float3 p, Building bld[N_BUILDINGS], float bands[8], float thd, AudioData a)
{
    float3 winCol = float3(0, 0, 0);
    [unroll] for (int j = 0; j < N_BUILDINGS; j++) {
        if (bld[j].gate < 0.01) continue;

        float2 winUV = float2(p.x, p.y + 1.0) * 5.0;
        float2 winCell = floor(winUV);
        float2 winFrac = frac(winUV);

        float winHash = hash21(winCell + float(j) * 17.3);
        float winOn = step(0.5, winHash) * bld[j].gate;

        float flicker = 0.8 + 0.2 * sin(Time * 10.0 + winHash * 100.0) * thd;

        float winShape = smoothstep(0.15, 0.25, winFrac.x) * smoothstep(0.15, 0.25, winFrac.y) *
                         smoothstep(0.85, 0.75, winFrac.x) * smoothstep(0.85, 0.75, winFrac.y);

        winCol += bld[j].color * winOn * winShape * flicker * bld[j].energy * 0.3;
    }
    return winCol;
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

    Building bld[N_BUILDINGS];
    computeBuildings(bld, bands, dspBands, kickSurge, beatPulse, a.stereoBal, crest, thd,
                     transientAmt, envelope, a.section, a);

    // ── Camera — section-driven orbit ──
    float FOV = 0.7;
    float camAng = a.section * 0.8 + a.stereoBal * 0.2 + Time * 0.03 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 0.5, -0.3 + a.stereoDiff * 0.15, -4.0);
    float3 camTarget = float3(a.stereoBal * 0.2, 0.5, 0);
    float3 rd = cameraRay(camPos, camTarget, float2(-p.x, -p.y), FOV);

    // ── Background — synthwave sky ──
    float3 col = float3(0.02, 0.005, 0.04) * silence;

    // Setting sun — beat-pulsing
    float2 sunPos = float2(0, 0.3);
    float sunDist = length(p - sunPos);
    float sunPulse = 0.5 + beatPulse * 0.5;
    float3 sunCol = hsv(0.08, 0.6 * a.satur, 0.9) * exp(-sunDist * 3.0) * sunPulse * 0.5;
    col += sunCol * silence;

    // Sun bands
    float sunBands = step(0.5, frac((p.y - 0.3) * 20.0)) * exp(-sunDist * 2.0) * 0.3;
    col += float3(1.0, 0.4, 0.1) * sunBands * sunPulse * silence;

    col += starfield(uv, a) * 0.02;

    // ── SDF raymarch — buildings and ground ──
    float t = 0.05;
    float marchGlow = 0.0;
    float steps = 0.0;
    bool hit = false;
    float3 hitPos = float3(0, 0, 0);

    [loop] for (int i = 0; i < MAX_STEPS; i++) {
        float3 sp = camPos + rd * t;
        float d = sceneSDF(sp, bld);
        marchGlow += 0.01 / (1.0 + d * d * 50.0);
        steps += 1.0;
        if (d < 0.001) { hit = true; hitPos = sp; break; }
        t += d * 0.5;
        if (t > 30.0) break;
    }

    if (hit) {
        float eps = 0.001;
        float3 n = normalize(float3(
            sceneSDF(hitPos + float3(eps, 0, 0), bld) - sceneSDF(hitPos - float3(eps, 0, 0), bld),
            sceneSDF(hitPos + float3(0, eps, 0), bld) - sceneSDF(hitPos - float3(0, eps, 0), bld),
            sceneSDF(hitPos + float3(0, 0, eps), bld) - sceneSDF(hitPos - float3(0, 0, eps), bld)
        ));

        float ao = 1.0 - steps / float(MAX_STEPS) * 0.5;
        bool isGround = hitPos.y < -0.95;

        if (isGround) {
            // Wet street reflection
            float3 reflDir = reflect(rd, n);
            float2 reflUV = uv + reflDir.xy * 0.3;
            float3 reflCol = float3(0.02, 0.005, 0.04);
            reflCol += hsv(0.08, 0.6 * a.satur, 0.9) * exp(-length(p - float2(0, 0.3)) * 3.0) * sunPulse * 0.3;

            float reflStrength = 0.3 + bands[0] * 0.4 + bands[1] * 0.3;
            col = lerp(col, reflCol, reflStrength * 0.5) * ao;

            // Street neon lines
            float2 streetUV = float2(p.x / (1.0 - p.y * 0.5), p.y);
            float streetLine = smoothstep(0.48, 0.5, abs(frac(streetUV.x * 3.0) - 0.5));
            col += a.brainCol * streetLine * 0.3 * silence;

            // Kick reflection flash
            col += a.brainCol3 * kickSurge * 0.2 * silence;
        } else {
            // Building surface
            float3 baseCol = float3(0.03, 0.02, 0.05);

            // Fresnel edge glow
            float fres = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
            float3 edgeCol = lerp(a.brainCol, a.brainCol2, a.section * 0.1);
            baseCol += edgeCol * fres * (0.4 + bands[4] * 0.3) * (1.0 + crest * 0.2);

            // Window glow
            float3 winCol = windowGlow(hitPos, bld, bands, thd, a);

            float3 litCol = (baseCol + winCol) * ao * (1.0 + lufs * 0.15);

            // Neon sign flicker — transient-driven
            float neonFlicker = transientAmt * hash21(hitPos.xz * 10.0 + Time * 20.0) * 0.1;
            litCol += a.brainCol3 * neonFlicker * silence;

            col = blendScreen(col, litCol);
        }
    }

    // March glow — atmospheric haze
    col += a.brainCol * marchGlow * 0.05 * silence;

    // ── Flying particles — high-band driven ──
    [unroll] for (int k = 0; k < 12; k++) {
        float kf = float(k) / 12.0;
        float2 partPos = float2(
            sin(kf * PI * 2.0 + Time * 0.5 * a.motSpeed) * 2.0,
            cos(kf * PI * 3.0 + Time * 0.3 * a.motSpeed) * 1.5
        );
        float partDist = length(p - partPos);
        float partGlow = exp(-partDist * partDist * 50.0) * (bands[6] + bands[7]) * 0.1;
        col += a.brainCol2 * partGlow * silence;
    }

    // ── Beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.025 * silence;

    // ── Kick flash ──
    col += a.brainCol2 * kickSurge * 0.05 * exp(-r * r * 5.0) * silence;

    // ── Transient pop ──
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.025 * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.02 * silence;

    // ── Energy + punch ──
    col += a.brainCol2 * a.energy * 0.015 * silence;
    col += a.brainCol * a.punch * 0.015 * silence;

    // ── Beat anticipation ──
    col += a.brainCol * a.beatAnt * 0.01 * exp(-r * 2.0) * silence;

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays — surface mode gets more weight ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── HDR limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
