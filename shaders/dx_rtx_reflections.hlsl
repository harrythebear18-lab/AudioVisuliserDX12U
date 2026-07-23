// Mode 24: Acoustic Droplets & Mirror Pool — falling objects into reflective liquid
//
// 8 band-driven objects drop from above into a dark reflective liquid pool.
// Each band has multiple drop pulses per beat cycle (3 sub-pulses per band).
// Beat = main drop, transient = fast small droplets, kick = big bass splash.
// Objects fall fast, hit surface, create expanding ripple rings, sink.
// No central mass. Ray-traced liquid surface reflection. HDR, no postfx, no Time orbit.
// DSP: LUFS→pool level, crest→object sharpness, THD→surface roughness, phaseCoh→ripple symmetry.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_BANDS 8
#define N_PULSES 3       // 3 drop pulses per band per beat cycle
#define N_DROPS (N_BANDS * N_PULSES)  // 24 total drop slots
#define MARCH_STEPS 64
#define REFL_STEPS 32

struct Drop {
    float3 pos;
    float radius;
    float energy;
    float2 poolPos;
    float active;     // 0=inactive, 1=fully active
    float glow;       // emission intensity
};

// Compute 24 drop objects — 3 pulses per band, phase-offset across beat cycle
void computeDrops(out Drop drops[N_DROPS], float bands[8], float dspBands[8],
                  float beatPhase, float beatPulse, float kickSurge, float transient,
                  float envelope, float stereoBal, float lufs, float crest)
{
    float surfaceY = -1.0;
    float startY = 2.8;

    [unroll] for (int n = 0; n < N_DROPS; n++)
    {
        int band = n / N_PULSES;
        int pulse = n % N_PULSES;
        float bt = float(band) / float(N_BANDS - 1);
        float rawEnergy = bands[band] + dspBands[band] * 0.12;
        float energy = (band < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
        float gate = smoothstep(0.02, 0.08, rawEnergy);

        // Each pulse has a phase offset within the beat cycle
        // Pulse 0 = on beat, pulse 1 = 1/3 after, pulse 2 = 2/3 after
        float pulsePhase = frac(beatPhase + float(pulse) / float(N_PULSES) + float(band) * 0.07);

        // Fall cycle: 0-0.5 falling, 0.5-0.6 impact, 0.6-1.0 sinking/ripple
        float fallT = clamp(pulsePhase / 0.5, 0.0, 1.0);
        float impactT = clamp((pulsePhase - 0.5) / 0.1, 0.0, 1.0);
        float sinkT = clamp((pulsePhase - 0.6) / 0.4, 0.0, 1.0);

        // Quadratic fall — fast acceleration
        float y = lerp(startY, surfaceY, fallT * fallT);
        // Sink after impact
        y -= sinkT * 0.4 * gate;
        // Small bounce on impact
        if (pulsePhase > 0.48 && pulsePhase < 0.58)
            y += sin((pulsePhase - 0.48) * PI / 0.1) * 0.06;

        // Pool position — spread across surface in rings per band
        float ringR = lerp(0.4, 2.0, bt);
        float ang = float(pulse) * (PI * 2.0 / float(N_PULSES)) + bt * PI * 1.5 + stereoBal * 0.4;
        float2 poolPos = float2(cos(ang) * ringR, sin(ang) * ringR);

        // Object stays at pool xz, only y changes
        drops[n].pos = float3(poolPos.x, y, poolPos.y);
        drops[n].poolPos = poolPos;

        // Radius — bass bigger, highs smaller, scaled by energy
        float radius = lerp(0.18, 0.06, bt) * (0.5 + energy * 0.8) * gate;
        // Kick boost on bass drops
        if (band < 3 && pulse == 0)
            radius += kickSurge * 0.12 * lerp(1.0, 0.3, bt);
        // Transient boost — small fast drops on highs
        if (pulse > 0)
            radius += transient * 0.04 * bt;
        drops[n].radius = clamp(radius, 0.0, 0.3);

        // Active when falling or near surface, fades when sunk
        float active = gate;
        active *= smoothstep(1.0, 0.85, pulsePhase);  // fade out at end of cycle
        active *= smoothstep(0.0, 0.05, pulsePhase);  // fade in at start
        drops[n].active = active;

        // Glow — bright on impact, fades as sinking
        float glow = energy * gate;
        glow *= smoothstep(0.45, 0.52, pulsePhase) * smoothstep(0.65, 0.52, pulsePhase);
        glow += energy * gate * (1.0 - sinkT) * 0.3;  // residual glow while sinking
        glow += beatPulse * (pulse == 0 ? 1.0 : 0.3);  // beat flash on pulse 0
        glow += (band < 3 && pulse == 0) ? kickSurge * 0.5 : 0.0;
        drops[n].glow = glow * (0.3 + envelope * 0.7);

        drops[n].energy = energy;
    }
}

// Liquid surface height — flat + ripple rings from drop impacts
float liquidHeight(float2 xz, Drop drops[N_DROPS], float beatPhase, float beatPulse,
                   float kickSurge, float transient, float lufs, float silence)
{
    float surface = -1.0 + lufs * 0.03 * silence;
    float r = length(xz);

    // Ripple rings from each drop impact
    [unroll] for (int n = 0; n < N_DROPS; n++)
    {
        if (drops[n].active < 0.01) continue;
        // Only create ripples after impact (pulsePhase > 0.5)
        int band = n / N_PULSES;
        int pulse = n % N_PULSES;
        float pulsePhase = frac(beatPhase + float(pulse) / float(N_PULSES) + float(band) * 0.07);
        if (pulsePhase < 0.5) continue;

        float rippleAge = (pulsePhase - 0.5) / 0.5;  // 0=just hit, 1=faded
        float distToImpact = length(xz - drops[n].poolPos);
        // Expanding ring
        float ringR = rippleAge * lerp(1.5, 0.8, float(band) / float(N_BANDS - 1));
        float ringDist = abs(distToImpact - ringR);
        float ringWidth = 0.15 + rippleAge * 0.3;
        float ringStrength = exp(-ringDist * ringDist / (ringWidth * ringWidth));
        ringStrength *= (1.0 - rippleAge) * drops[n].active;
        surface += ringStrength * drops[n].radius * 0.8;
    }

    // Beat ripple from center
    surface += beatPulse * 0.04 * sin(r * 5.0 - beatPhase * PI * 4.0) * exp(-r * 0.3) * silence;

    // Kick impact — big central ring
    surface += kickSurge * 0.08 * sin(r * 4.0 - beatPhase * PI * 3.0) * exp(-r * 0.25) * silence;

    // Transient scatter ripples
    if (transient > 0.03)
        surface += transient * 0.02 * sin(xz.x * 18.0 + xz.y * 16.0) * exp(-r * 0.4) * silence;

    return surface;
}

// Liquid surface SDF
float liquidSDF(float3 p, Drop drops[N_DROPS], float beatPhase, float beatPulse,
                float kickSurge, float transient, float lufs, float silence)
{
    float h = liquidHeight(p.xz, drops, beatPhase, beatPulse, kickSurge, transient, lufs, silence);
    return p.y - h;
}

// Drop sphere SDF
float dropSDF(float3 p, Drop drops[N_DROPS])
{
    float minD = 1e10;
    [unroll] for (int n = 0; n < N_DROPS; n++)
    {
        if (drops[n].active < 0.01 || drops[n].radius < 0.005) continue;
        float d = sdSphere(p - drops[n].pos, drops[n].radius);
        if (d < minD) minD = d;
    }
    return minD;
}

// Full scene SDF — liquid surface + dropping objects
float sceneSDF(float3 p, Drop drops[N_DROPS], float beatPhase, float beatPulse,
               float kickSurge, float transient, float lufs, float silence,
               out int hitType)
{
    hitType = 0; // 0=liquid, 1=drop
    float liquidD = liquidSDF(p, drops, beatPhase, beatPulse, kickSurge, transient, lufs, silence);
    float dropD = dropSDF(p, drops);
    if (dropD < liquidD) { hitType = 1; return dropD; }
    return liquidD;
}

// Normal via finite differences
float3 calcNormal(float3 p, Drop drops[N_DROPS], float beatPhase, float beatPulse,
                  float kickSurge, float transient, float lufs, float silence)
{
    float eps = 0.005;
    int dummy;
    return normalize(float3(
        sceneSDF(p + float3(eps,0,0), drops, beatPhase, beatPulse, kickSurge, transient, lufs, silence, dummy)
          - sceneSDF(p - float3(eps,0,0), drops, beatPhase, beatPulse, kickSurge, transient, lufs, silence, dummy),
        sceneSDF(p + float3(0,eps,0), drops, beatPhase, beatPulse, kickSurge, transient, lufs, silence, dummy)
          - sceneSDF(p - float3(0,eps,0), drops, beatPhase, beatPulse, kickSurge, transient, lufs, silence, dummy),
        sceneSDF(p + float3(0,0,eps), drops, beatPhase, beatPulse, kickSurge, transient, lufs, silence, dummy)
          - sceneSDF(p - float3(0,0,eps), drops, beatPhase, beatPulse, kickSurge, transient, lufs, silence, dummy)
    ));
}

// Sky color for reflections
float3 skyColor(float3 rd, AudioData a)
{
    float t = saturate(rd.y * 0.5 + 0.5);
    float3 top = a.brainCol * 0.12 + float3(0.01, 0.01, 0.03);
    float3 bot = a.brainCol2 * 0.06 + float3(0.02, 0.01, 0.01);
    return lerp(bot, top, t);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    // ── DSP ──
    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();

    // ── Background — dark sky ──
    float3 col = skyColor(float3(p.x, p.y, -1.0), a) * silence;
    col += starfield(uv, a) * 0.15;

    // ── Camera — fixed 3/4 angle, stereo shift only ──
    float camAng = a.stereoBal * 0.2;
    float3 camPos = float3(sin(camAng) * 4.0, 2.0, cos(camAng) * 4.0);
    float3 camTarget = float3(0.0, -0.5, 0.0);
    float3 rd = cameraRay(camPos, camTarget, float2(-p.x, -p.y), 0.5);

    // ── Audio ──
    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    float dspBands[8] = { DspBand0, DspBand1, DspBand2, DspBand3, DspBand4, DspBand5, DspBand6, DspBand7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Compute drops ──
    Drop drops[N_DROPS];
    computeDrops(drops, bands, dspBands, a.beatPhase, beatPulse, kickSurge, transientAmt,
                 envelope, a.stereoBal, lufs, crest);

    // ── Primary raymarch ──
    float t = 0.05;
    float marchGlow = 0.0;
    float steps = 0.0;
    bool hit = false;
    int hitType = 0;
    float3 hitPos = float3(0,0,0);

    [loop] for (int i = 0; i < MARCH_STEPS; i++)
    {
        float3 sp = camPos + rd * t;
        int ht;
        float d = sceneSDF(sp, drops, a.beatPhase, beatPulse, kickSurge, transientAmt, lufs, silence, ht);
        marchGlow += 0.006 / (1.0 + d * d * 50.0);
        steps += 1.0;
        if (d < 0.003) { hit = true; hitType = ht; hitPos = sp; break; }
        t += d * 0.5;
        if (t > 12.0) break;
    }
    float ao = 1.0 - steps / float(MARCH_STEPS) * 0.3;

    if (hit)
    {
        float3 n = calcNormal(hitPos, drops, a.beatPhase, beatPulse, kickSurge, transientAmt, lufs, silence);
        float3 v = -rd;

        // Lighting
        float3 sunDir = normalize(float3(0.4, 0.7, 0.5));
        float3 fillDir = normalize(float3(-0.5 + a.stereoBal * 0.3, 0.4, 0.2));
        float diff = max(dot(n, sunDir), 0.0);
        float diff2 = max(dot(n, fillDir), 0.0) * 0.4;
        float spec = pow(max(dot(reflect(-sunDir, n), v), 0.0), 100.0);
        float fres = pow(1.0 - max(dot(n, v), 0.0), 4.0);

        float3 litCol;

        if (hitType == 0)
        {
            // ── Liquid surface — dark reflective ──
            float3 baseCol = float3(0.012, 0.012, 0.018);

            // Ray-traced reflection of drops above
            float3 reflDir = reflect(rd, n);
            float3 reflPos = hitPos + reflDir * 0.01;
            float rt = 0.05;
            float3 reflCol = skyColor(reflDir, a);

            [loop] for (int ri = 0; ri < REFL_STEPS; ri++)
            {
                float3 rsp = reflPos + reflDir * rt;
                int rdummy;
                float rd2 = sceneSDF(rsp, drops, a.beatPhase, beatPulse, kickSurge, transientAmt, lufs, silence, rdummy);
                if (rd2 < 0.003)
                {
                    float3 rn = calcNormal(rsp, drops, a.beatPhase, beatPulse, kickSurge, transientAmt, lufs, silence);
                    float rdiff = max(dot(rn, sunDir), 0.0);
                    float rspec = pow(max(dot(reflect(-sunDir, rn), -reflDir), 0.0), 80.0);
                    // Find which drop was hit in reflection
                    float3 rBase = a.brainCol * (0.15 + rdiff * 0.2);
                    rBase += float3(0.9, 0.85, 0.8) * rspec * 0.3;
                    // Check if reflection hit a drop — add drop glow
                    [unroll] for (int dn = 0; dn < N_DROPS; dn++)
                    {
                        if (drops[dn].active < 0.01) continue;
                        float dropDist = length(rsp - drops[dn].pos);
                        if (dropDist < drops[dn].radius * 2.0)
                        {
                            int dband = dn / N_PULSES;
                            float dbt = float(dband) / float(N_BANDS - 1);
                            float3 dropCol = lerp(a.brainCol, a.brainCol2, dbt);
                            rBase += dropCol * drops[dn].glow * 0.3;
                        }
                    }
                    reflCol = rBase;
                    break;
                }
                rt += rd2 * 0.5;
                if (rt > 6.0) break;
            }

            // Blend reflection with liquid surface
            litCol = lerp(baseCol * (diff + diff2) * 0.25, reflCol, 0.65 + fres * 0.25);
            litCol += float3(0.9, 0.85, 0.8) * spec * 0.25 * a.dynLight;
            litCol *= ao;

            // Ripple glow — highlight active ripple rings
            [unroll] for (int rn2 = 0; rn2 < N_DROPS; rn2++)
            {
                if (drops[rn2].active < 0.01) continue;
                int rband = rn2 / N_PULSES;
                int rpulse = rn2 % N_PULSES;
                float rpp = frac(a.beatPhase + float(rpulse) / float(N_PULSES) + float(rband) * 0.07);
                if (rpp < 0.5) continue;
                float rippleAge = (rpp - 0.5) / 0.5;
                float distToImpact = length(hitPos.xz - drops[rn2].poolPos);
                float ringR = rippleAge * lerp(1.5, 0.8, float(rband) / float(N_BANDS - 1));
                float ringDist = abs(distToImpact - ringR);
                float ringGlow = exp(-ringDist * ringDist * 20.0) * (1.0 - rippleAge);
                float3 ringCol = lerp(a.brainCol, a.brainCol2, float(rband) / float(N_BANDS - 1));
                litCol += ringCol * ringGlow * drops[rn2].active * 0.04 * silence;
            }
        }
        else
        {
            // ── Drop object — glowing metallic sphere ──
            // Find nearest drop
            int nearestIdx = 0;
            float nearestDist = 1e10;
            [unroll] for (int dn = 0; dn < N_DROPS; dn++)
            {
                if (drops[dn].active < 0.01) continue;
                float dd = length(hitPos - drops[dn].pos);
                if (dd < nearestDist) { nearestDist = dd; nearestIdx = dn; }
            }
            int band = nearestIdx / N_PULSES;
            float bt = float(band) / float(N_BANDS - 1);

            // Color by band
            float3 dropCol = lerp(a.brainCol, a.brainCol2, bt);
            dropCol = lerp(dropCol, a.brainCol3, phaseCoh * 0.1);

            // Metallic base
            float3 baseCol = dropCol * 0.2 + float3(0.04, 0.04, 0.05);

            // Reflection from sky
            float3 reflDir = reflect(rd, n);
            float3 reflCol = skyColor(reflDir, a);
            float metal = 0.5 + a.dynamic * 0.2;
            litCol = lerp(baseCol * (diff + diff2), reflCol * metal, fres * 0.5);
            litCol += float3(0.9, 0.85, 0.8) * spec * 0.4 * a.dynLight;

            // Glow — band energy + beat + kick
            litCol += dropCol * drops[nearestIdx].glow * 0.5 * silence;

            // Kick flash on bass drops
            if (band < 3)
                litCol += float3(1.0, 0.4, 0.1) * kickSurge * 0.1 * silence;

            // Transient sparkle
            if (transientAmt > 0.02)
                litCol += float3(1.0, 0.9, 0.7) * transientAmt * 0.04 * silence;

            // ColorPulse
            litCol += a.brainCol3 * a.colorPulse * 0.02 * silence;

            litCol *= ao * (0.5 + a.brightness * 0.3);
        }

        col = blendScreen(col, litCol);
    }

    // ── Volumetric glow around drops ──
    col += a.brainCol * marchGlow * (0.012 + a.glow * 0.015) * (0.5 + envelope * 0.5) * silence;

    // ── Kick flash ──
    col += float3(1.0, 0.5, 0.1) * kickSurge * 0.03 * exp(-r * r * 4.0) * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.012 * silence;

    // ── Energy boost ──
    col += a.brainCol2 * a.energy * 0.008 * silence;

    col += standardOverlays(p, r, a) * 0.02;

    // ── Brightness limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    return float4(col, 1.0);
}
