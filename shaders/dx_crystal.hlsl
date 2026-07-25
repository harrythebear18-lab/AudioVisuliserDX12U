// ============================================================================
// HUD 18: Ferrofluid Gravitational Wavefield (dx_crystal.hlsl)
// DX12U Layer 0 — SDF heightfield: distributed ferrofluid spike field with
// wave interference surface modulation. 24 spikes using audioSimElement for
// per-spike spatial accuracy. Distance-aided march with early-out.
//
// Concept: 24 Rosensweig instability spikes rise from a ferrofluid surface.
// Each spike samples its own frequency bin via audioSimElement — per-spike
// L/R amplitude, pan, transient scatter, intensity. Spike positions follow
// golden-ratio distribution across the field, displaced by stereo pan and
// transient scatter. Wave interference between 8 band-emitters modulates
// the surface between spikes. Beat = expanding ripple rings. Kick = bass
// spike eruption. Transient = surface jitter + spike scatter.
//
// Silhouette: A dark reflective ferrofluid plain with glowing spike columns
// scattered across it at distinct depths. Bass spikes tall and hot, high
// spikes short and sharp. Beat sends visible ripple rings outward. Stereo
// pan shifts spike positions left/right. No central mass.
//
// Audio mapping (exclusive roles per DX12U_VISUALIZATION_RULES.md):
//   audioSimElement(n, 24, a) → per-spike amplitude, pan, intensity, scatter
//   b0-b7     → spike height per band (3 spikes per band, 24 total)
//   stereoBal → camera orbit + spike pan displacement
//   stereoWid → field spread + surface blend width
//   beat      → expanding ripple rings across surface
//   kick      → bass spike eruption (height boost on band 0-2)
//   transient → surface jitter + spike position scatter
//   beatAnt   → pre-beat spike tension
//   envelope  → overall emission gain
//   section   → wave complexity tier
//
// DSP additive (refinement only, never replaces brain):
//   LUFS → emission/surface boost: val *= (1.0 + lufs * 0.2)
//   crest → spike sharpness: sharpness *= (1.0 + crest * 0.5)
//   THD → surface roughness: phase += thd * noise * 0.05
//   phase coherence → field symmetry: lerp(0.3, 1.0, phaseCoh)
//
// 3D Spatial Audio Math (per DX12U_VISUALIZATION_RULES.md):
//   A(d) = 1.0 / (1.0 + k * d^2)
//   Cf = (Dx * PI) / PHI  (golden ratio frequency compression)
//
// HDR output to shared pipeline. No local postfx, tonemapping, or bloom.
// ============================================================================

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define PHI 1.61803399
#define N_EMITTERS 8
#define N_SPIKES 24
#define MARCH_STEPS 64
#define FIELD_RADIUS 3.5

// ── Spike struct — 2D position + properties, driven by audioSimElement ──
struct Spike {
    float2 pos;         // xz position on field (emitter + pan + scatter)
    float height;
    float sharpness;
    float energy;
    float pan;
    float freqFrac;
};

// ── Golden ratio distribution for spike positions across the field ──
float2 spikeBasePos(int idx, float radius, float stereoBal, float stereoWid)
{
    float bt = float(idx) / float(N_SPIKES - 1);
    float ang = float(idx) * PHI * PI * 2.0 + stereoBal * PI;
    float r = lerp(0.3, radius, bt);
    return float2(cos(ang) * r, sin(ang) * r) * (0.8 + stereoWid * 0.3);
}

// ── Distance attenuation — inverse square per 3D Spatial Audio Math ──
float distAtten(float d, float k)
{
    return 1.0 / (1.0 + k * d * d);
}

// ── Compute 24 spikes using audioSimElement per DX12U rules ──
void computeSpikes(out Spike spikes[N_SPIKES], AudioData a,
                   float kickSurge, float beatPulse, float crest, float thd, float lufs)
{
    float fieldR = FIELD_RADIUS * (0.8 + a.stereoWid * 0.3);

    [unroll] for (int n = 0; n < N_SPIKES; n++)
    {
        int band = n / 3;
        int sub = n % 3;
        float bt = float(band) / float(N_EMITTERS - 1);

        // Per-element audio data — spatially accurate per DX12U rules
        AudioElement e = audioSimElement(n, N_SPIKES, a);

        // Base position via golden ratio, offset by stereo pan + transient scatter
        float2 base = spikeBasePos(n, fieldR, a.stereoBal, a.stereoWid);
        float2 panOff = e.panOffset * (1.0 + a.stereoWid);
        float2 scatter = float2(e.transientScatter, e.transientScatter * 0.7);
        spikes[n].pos = base + panOff + scatter;
        spikes[n].pan = e.pan;
        spikes[n].freqFrac = e.freqFrac;

        // Noise gate per rules
        float gate = smoothstep(0.02, 0.08, e.amplitude);

        // Compressor curve per rules: bass pow(0.5), highs linear
        float energy = (band < 4) ? pow(max(e.intensity, 0.0), 0.5) : max(e.intensity, 0.0);

        // Height — intensity-driven + kick on bass + beat anticipation
        float h = energy * lerp(1.2, 0.4, bt) * gate;
        if (band < 3 && sub == 0)
            h += kickSurge * kickSurge * lerp(0.5, 0.15, bt);
        h *= (0.3 + beatPulse * 0.7);
        h += a.beatAnt * lerp(0.08, 0.2, bt) * gate;
        h += a.transient * lerp(0.03, 0.1, bt) * gate;
        h += a.envelope * lerp(0.04, 0.01, bt) * gate;
        h += a.section * 0.03 * gate;
        h *= (1.0 + lufs * 0.2);
        spikes[n].height = clamp(h, 0.0, 1.8);

        // Sharpness — crest sharpens, THD roughens per rules
        float sharp = lerp(12.0, 30.0, bt) * (1.0 + crest * 0.5) - thd * 2.0;
        spikes[n].sharpness = max(sharp, 8.0);
        spikes[n].energy = energy * gate;
    }
}

// ── Precompute wave modulation per emitter (constant per frame) ──
void precomputeWaveMods(out float waveMods[N_EMITTERS], float2 emitterPos2D[N_EMITTERS],
                        float bands[N_EMITTERS], float time, float beatPulse, float beatPhase)
{
    [unroll] for (int i = 0; i < N_EMITTERS; i++)
    {
        float mod = 0.0;
        [unroll] for (int w = 0; w < N_EMITTERS; w++)
        {
            float dist = length(emitterPos2D[i] - emitterPos2D[w]);
            float atten = distAtten(dist, 0.2);
            float wavelength = (0.5 + float(w) * 0.08) * PI / PHI;
            float phase = (dist - time * (0.8 + float(w) * 0.12)) / wavelength * PI * 2.0;
            mod += sin(phase) * bands[w] * atten * 0.25;
        }
        if (beatPulse > 0.01)
        {
            float wf = length(emitterPos2D[i]) - beatPhase * 2.0;
            mod += beatPulse * (-wf) * exp(-wf * wf * 4.0) * 0.12;
        }
        waveMods[i] = mod;
    }
}

// ── Heightfield — spikes + wave interference + beat ripples + kick ──
float fieldHeight(float2 xz, Spike spikes[N_SPIKES], float2 emitterPos2D[N_EMITTERS],
                  float waveMods[N_EMITTERS], float beatPulse, float beatPhase,
                  float kickSurge, float transient, float thd, float envelope,
                  float lufs, float silence)
{
    float r = length(xz);
    if (r > FIELD_RADIUS) return -1.0;

    // Base surface — flat with LUFS additive per rules
    float surface = (0.02 + lufs * 0.02) * silence;

    // Envelope breathing
    surface += envelope * 0.015 * sin(beatPhase * PI * 2.0) * silence;

    // 24 spikes — Gaussian cone exp falloff (cheap, no 3D sphere math)
    [unroll] for (int n = 0; n < N_SPIKES; n++)
    {
        if (spikes[n].height < 0.01) continue;
        float d = length(xz - spikes[n].pos);
        surface += spikes[n].height * exp(-d * d * spikes[n].sharpness);
    }

    // Wave interference between 8 emitters — surface modulation
    [unroll] for (int i = 0; i < N_EMITTERS; i++)
    {
        float d = length(xz - emitterPos2D[i]);
        float atten = distAtten(d, 0.15);
        surface += waveMods[i] * atten * 0.03;
    }

    // Beat ripple rings — expanding wavefront per rules
    float ringPhase = beatPhase * PI * 2.0;
    surface += beatPulse * 0.04 * sin(r * 6.0 - ringPhase * 3.0) *
               smoothstep(FIELD_RADIUS, 0.0, r) * silence;

    // Kick — central bulge
    surface += kickSurge * 0.06 * exp(-r * r * 3.0) * silence;

    // Transient — surface jitter per rules: thd * noise
    if (transient > 0.02)
        surface += transient * 0.025 * sin(xz.x * 25.0 + xz.y * 22.0 + beatPhase * 30.0) *
                   smoothstep(FIELD_RADIUS, 0.0, r) * silence * (0.5 + thd);

    // Envelope swell
    surface += envelope * 0.012 * smoothstep(FIELD_RADIUS, 0.0, r) * silence;

    // Field edge — curve down into basin
    surface -= smoothstep(FIELD_RADIUS * 0.6, FIELD_RADIUS, r) * 0.2;

    return surface;
}

// ── SDF — distance to heightfield surface ──
float fieldSDF(float3 p, Spike spikes[N_SPIKES], float2 emitterPos2D[N_EMITTERS],
               float waveMods[N_EMITTERS], float beatPulse, float beatPhase,
               float kickSurge, float transient, float thd, float envelope,
               float lufs, float silence)
{
    float h = fieldHeight(p.xz, spikes, emitterPos2D, waveMods, beatPulse, beatPhase,
                          kickSurge, transient, thd, envelope, lufs, silence);
    return p.y - h;
}

// ── Normal via finite differences on heightfield (cheap: 4 evals) ──
float3 fieldNormal(float3 p, Spike spikes[N_SPIKES], float2 emitterPos2D[N_EMITTERS],
                   float waveMods[N_EMITTERS], float beatPulse, float beatPhase,
                   float kickSurge, float transient, float thd, float envelope,
                   float lufs, float silence)
{
    float eps = 0.008;
    float hL = fieldHeight(p.xz - float2(eps, 0), spikes, emitterPos2D, waveMods, beatPulse, beatPhase, kickSurge, transient, thd, envelope, lufs, silence);
    float hR = fieldHeight(p.xz + float2(eps, 0), spikes, emitterPos2D, waveMods, beatPulse, beatPhase, kickSurge, transient, thd, envelope, lufs, silence);
    float hD = fieldHeight(p.xz - float2(0, eps), spikes, emitterPos2D, waveMods, beatPulse, beatPhase, kickSurge, transient, thd, envelope, lufs, silence);
    float hU = fieldHeight(p.xz + float2(0, eps), spikes, emitterPos2D, waveMods, beatPulse, beatPhase, kickSurge, transient, thd, envelope, lufs, silence);
    return normalize(float3(hL - hR, 2.0 * eps, hD - hU));
}

// ── Project 3D point to screen space ──
float2 project3D(float3 worldPos, float3 camPos, float3 fwd, float3 right, float3 up, float fov)
{
    float3 toP = worldPos - camPos;
    float depth = dot(toP, fwd);
    if (depth < 0.1) return float2(999.0, 999.0);
    return float2(dot(toP, right), dot(toP, up)) / (depth * fov);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    // ── DSP additive ──
    float dspLUFS = lufsNormalized();
    float dspCrest = crestFactorNormalized();
    float dspTHD = thdNormalized();
    float dspPhaseCoh = phaseCoherence();

    // ── Band extraction for wave modulation ──
    float rawBands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    float bands[N_EMITTERS];
    [unroll] for (int g = 0; g < N_EMITTERS; g++)
        bands[g] = pow(max(rawBands[g], 0.0), 0.35);

    // ── Audio dynamics ──
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);

    // ── Emitter 2D positions for wave interference (projected from 3D) ──
    float fieldR = FIELD_RADIUS * (0.8 + a.stereoWid * 0.3);
    float2 emitterPos2D[N_EMITTERS];
    [unroll] for (int e = 0; e < N_EMITTERS; e++)
    {
        float bt = float(e) / float(N_EMITTERS - 1);
        float ang = float(e) * PHI * PI * 2.0 + a.stereoBal * PI;
        float rad = lerp(0.4, fieldR * 0.9, bt);
        emitterPos2D[e] = float2(cos(ang) * rad, sin(ang) * rad);
    }

    // ── Compute 24 spikes using audioSimElement per DX12U rules ──
    Spike spikes[N_SPIKES];
    computeSpikes(spikes, a, kickSurge, beatPulse, dspCrest, dspTHD, dspLUFS);

    // ── Precompute wave modulation per emitter (constant per frame) ──
    float waveMods[N_EMITTERS];
    precomputeWaveMods(waveMods, emitterPos2D, bands, Time, beatPulse, a.beatPhase);

    // ── Camera — 3/4 orbital angle looking at field ──
    float camAng = a.stereoBal * 0.2 + a.section * 0.15 + Time * 0.03 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 4.0, 2.5 + a.stereoDiff * 0.15, cos(camAng) * 4.0);
    float3 camTarget = float3(0.0, 0.15, 0.0);
    float3 rd = cameraRay(camPos, camTarget, float2(-p.x, -p.y), 0.45);

    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Background ──
    float3 col = float3(0.001, 0.001, 0.003) * silence;
    col += starfield(uv, a) * 0.008;
    float nebula = fbm2_4(p * 0.7 + Time * 0.004 * a.motSpeed);
    col += a.brainCol * nebula * 0.006 * a.ambient * a.ambActive * silence;

    // ── SDF raymarch — distance-aided, early-out ──
    float t = 0.05;
    float marchGlow = 0.0;
    bool hit = false;

    [loop] for (int i = 0; i < MARCH_STEPS; i++)
    {
        float3 sp = camPos + rd * t;
        float d = fieldSDF(sp, spikes, emitterPos2D, waveMods, beatPulse, a.beatPhase,
                          kickSurge, a.transient, dspTHD, a.envelope, dspLUFS, silence);
        marchGlow += 0.01 / (1.0 + d * d * 50.0);
        if (d < 0.003) { hit = true; break; }
        t += d * 0.5;
        if (t > 6.0) break;
    }

    if (hit)
    {
        float3 hp = camPos + rd * t;
        float3 n = fieldNormal(hp, spikes, emitterPos2D, waveMods, beatPulse, a.beatPhase,
                               kickSurge, a.transient, dspTHD, a.envelope, dspLUFS, silence);
        float3 vDir = normalize(camPos - hp);

        // ── Find nearest spike for frequency-positioned color per rules ──
        float nearestSpikeDist = 999.0;
        float nearestFreqFrac = 0.5;
        float nearestPan = 0.0;
        [unroll] for (int ns = 0; ns < N_SPIKES; ns++)
        {
            if (spikes[ns].height < 0.01) continue;
            float sd2 = dot(hp.xz - spikes[ns].pos, hp.xz - spikes[ns].pos);
            if (sd2 < nearestSpikeDist) { nearestSpikeDist = sd2; nearestFreqFrac = spikes[ns].freqFrac; nearestPan = spikes[ns].pan; }
        }

        // ── Metallic ferrofluid shading ──
        float fres = pow(1.0 - max(dot(n, vDir), 0.0), 5.0);

        // Key lights
        float3 lDir = normalize(float3(0.4, 0.8, 0.5));
        float3 lDir2 = normalize(float3(-0.5 + a.stereoBal * 0.3, 0.6, 0.3));
        float diff = max(dot(n, lDir), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
        float spec = pow(max(dot(reflect(-lDir, n), vDir), 0.0), 80.0);
        float spec2 = pow(max(dot(reflect(-lDir2, n), vDir), 0.0), 60.0) * 0.5;

        // Height determines temperature — spikes glow, surface stays dark
        float heightFrac = clamp(hp.y * 1.5, 0.0, 1.0);
        float3 darkFluid = float3(0.008, 0.008, 0.012);
        float3 hotTip = lerp(float3(0.6, 0.1, 0.03), float3(1.0, 0.5, 0.1), heightFrac);
        hotTip = lerp(hotTip, float3(1.0, 0.9, 0.7), pow(heightFrac, 3.0));

        // Brain color blend — frequency-positioned per rules
        float3 freqCol = hsv(a.hueBase + nearestFreqFrac * a.hueRange, 0.6 * a.satur, 0.9);
        float3 brain = lerp(a.brainCol, a.brainCol2, nearestFreqFrac);
        brain = lerp(brain, freqCol, 0.3);
        float3 baseCol = lerp(darkFluid, hotTip, smoothstep(0.02, 0.25, hp.y));
        baseCol = lerp(baseCol, brain, 0.2);

        // Phase coherence → field symmetry per rules
        float coherence = lerp(0.3, 1.0, dspPhaseCoh);
        baseCol = lerp(baseCol, baseCol.gbr, (1.0 - coherence) * 0.05);
        // Stereo L/R tint based on nearest spike pan + spatial position
        float sideTint = clamp(hp.x * 0.2 + nearestPan * 0.3, -1.0, 1.0);
        baseCol = lerp(baseCol, baseCol * float3(1.2, 0.9, 0.78), max(sideTint, 0.0) * a.stereoWid * 0.15);
        baseCol = lerp(baseCol, baseCol * float3(0.78, 0.9, 1.2), max(-sideTint, 0.0) * a.stereoWid * 0.15);

        // Lighting
        float3 litCol = baseCol * (diff + diff2) * (0.3 + a.brightness * 0.3 + a.dynamic * 0.2);
        litCol += float3(0.9, 0.85, 0.8) * (spec + spec2) * (0.5 + a.dynLight * 0.7);
        litCol += lerp(baseCol, hotTip, 0.5) * fres * (0.4 + a.envelope * 0.4 + a.glow * 0.2);

        // Spike tip glow
        float tipGlow = smoothstep(0.08, 0.5, hp.y);
        litCol += hotTip * tipGlow * (0.2 + a.envelope * 0.5) * silence;
        // Kick eruption
        litCol += float3(1.0, 0.4, 0.08) * kickSurge * tipGlow * 0.4 * silence;
        // Transient speckle
        if (a.transient > 0.02)
            litCol += float3(1.0, 0.85, 0.6) * a.transient * tipGlow * 0.2 * silence;
        // Beat pulse
        litCol += hotTip * beatPulse * tipGlow * 0.08 * silence;
        // ColorPulse
        litCol += a.brainCol3 * a.colorPulse * tipGlow * 0.025 * silence;
        // Dynamic + punch
        litCol *= (0.6 + a.dynamic * 0.4);
        litCol += hotTip * a.punch * tipGlow * 0.05 * silence;

        col = blendScreen(col, litCol);
    }

    // ── March glow — atmospheric halo ──
    col += a.brainCol * marchGlow * (0.02 + a.glow * 0.025) * (0.5 + a.envelope * 0.5) * silence;

    // ── Beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.025 * silence;

    // ── Kick flash ──
    col += float3(1.0, 0.5, 0.1) * kickSurge * 0.05 * exp(-r * r * 5.0) * silence;

    // ── Transient pop ──
    col += float3(1.0, 0.8, 0.5) * a.transient * 0.025 * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.02 * silence;

    // ── Energy + punch ──
    col += a.brainCol2 * a.energy * 0.015 * silence;
    col += a.brainCol * a.punch * 0.015 * silence;

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02 * silence;

    // ── HDR brightness limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    return float4(col, 1.0);
}
