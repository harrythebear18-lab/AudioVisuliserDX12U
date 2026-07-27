// Mode 40: Quantum Field Interferometer — wave-particle duality in 3D
// You are inside an interference chamber. Each band creates a coherent wave source.
// Phase correlation = coherence visibility (high phase = sharp fringes, low = blur).
// Stereo = dual-slit geometry (L/R sources). Beat = wave packet emission.
// Kick = quantum jump. Transient = measurement collapse. LUFS = field intensity.
// Crest = fringe sharpness. THD = quantum noise/decoherence.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define N_SOURCES 8

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

struct WaveSource {
    float3 pos;
    float frequency;
    float amplitude;
    float phase;
    float gate;
    float3 color;
};

void computeSources(out WaveSource sources[N_SOURCES], float bands[8], float dspBands[8],
                    float kickSurge, float beatPulse, float stereoBal, float stereoWid,
                    float crest, float thd, float transient, float envelope, float section,
                    float phaseCoh, float leftEn, float rightEn, AudioData a)
{
    [unroll] for (int n = 0; n < N_SOURCES; n++)
    {
        int band = n / 2;
        int slit = n % 2;  // 0=left slit, 1=right slit
        float bt = float(band) / float(N_COMP - 1);

        float rawEnergy = bands[band] + dspBands[band] * 0.12;
        float energy = (band < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
        float gate = smoothstep(0.02, 0.08, rawEnergy);

        // Spectrum L/R — stereo spatial positioning (slit = L/R channel)
        float freqU = bandFreq[band];
        float lE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.166), 0).r;
        float rE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.833), 0).r;
        float stereoEnergy = max(lE, rE);
        energy = max(energy, stereoEnergy * 0.5);
        gate = max(gate, smoothstep(0.02, 0.08, stereoEnergy));
        // Slit 0 = left channel, slit 1 = right channel
        if (slit == 0) energy = max(energy, lE * 0.5);
        else energy = max(energy, rE * 0.5);

        // Dual-slit positions — stereo width controls slit separation
        float slitSep = 0.5 + stereoWid * 0.5;
        float slitSign = (slit == 0) ? -1.0 : 1.0;
        float xPos = slitSign * slitSep * 0.5 + stereoBal * 0.3;

        // Y position by band — bass at bottom, treble at top
        float yPos = lerp(-1.5, 1.5, bt);
        // Z position — sources at back of chamber
        float zPos = -2.0 + sin(float(n) * 1.7) * 0.3;

        sources[n].pos = float3(xPos, yPos, zPos);
        sources[n].frequency = lerp(2.0, 12.0, bt) * (1.0 + a.tempo * 0.3);
        sources[n].amplitude = energy * gate;
        sources[n].phase = float(n) * 0.7 + Time * sources[n].frequency;
        sources[n].gate = gate;

        // Color — slit 0 = brain color, slit 1 = secondary
        float3 c = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        if (slit == 0) c = lerp(c, a.brainCol, 0.4);
        else c = lerp(c, a.brainCol2, 0.4);
        sources[n].color = c;
    }
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

    WaveSource sources[N_SOURCES];
    computeSources(sources, bands, dspBands, kickSurge, beatPulse, a.stereoBal, a.stereoWid,
                   crest, thd, transientAmt, envelope, a.section, phaseCoh, a.leftEn, a.rightEn, a);

    // ── Camera — inside the chamber looking at sources ──
    float FOV = 0.7;
    float camAng = a.section * 0.5 + a.stereoBal * 0.2 + Time * 0.02 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 1.0, 0.5 + a.stereoDiff * 0.1, 2.5);
    float3 camTarget = float3(0, 0, -1.0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Background — quantum vacuum ──
    float3 col = float3(0.001, 0.001, 0.004) * silence;
    col += starfield(uv, a) * 0.005;

    // Quantum vacuum fluctuation noise
    float vacuum = fbm2_4(p * 5.0 + Time * 0.5) * 0.003 * (1.0 + lufs * 0.1);
    col += float3(0.1, 0.15, 0.2) * vacuum * silence;

    // ── Interference field — sample at screen-space grid ──
    // Project a virtual screen at z=0 in world space
    float3 screenCenter = float3(0, 0, 0);
    float3 toScreen = screenCenter - camPos;
    float screenDepth = dot(toScreen, fwd);
    if (screenDepth > 0.1) {
        float2 scrCenter = float2(dot(toScreen, right) / (screenDepth * FOV), dot(toScreen, up) / (screenDepth * FOV));

        // Convert screen point to world position on virtual screen plane
        float3 worldP = camPos + fwd * screenDepth + right * p.x * screenDepth * FOV + up * p.y * screenDepth * FOV;

        // Compute wave amplitude from each source
        float totalAmp = 0.0;
        float3 totalCol = float3(0, 0, 0);

        [unroll] for (int s = 0; s < N_SOURCES; s++) {
            if (sources[s].gate < 0.01) continue;

            float dist = length(worldP - sources[s].pos);
            float wavelength = 2.0 * PI / sources[s].frequency;
            float wave = sin(dist / wavelength * 2.0 * PI - sources[s].phase);
            wave *= sources[s].amplitude / max(dist * 0.3, 0.5);

            // Phase coherence — high coherence = sharp interference, low = decoherence blur
            wave *= lerp(0.3, 1.0, phaseCoh);

            // THD — quantum noise
            wave += thd * hash21(p * 200.0 + float(s) * 13.7) * 0.02;

            totalAmp += wave;
            totalCol += sources[s].color * abs(wave) * sources[s].gate;
        }

        // Interference intensity — |amplitude|^2 (quantum probability)
        float intensity = totalAmp * totalAmp * (1.0 + lufs * 0.2);
        intensity *= (1.0 + crest * 0.3);

        // Color from interference
        float3 fieldCol = totalCol / max(length(totalCol), 0.001);
        fieldCol = lerp(fieldCol, a.brainCol, 0.2);

        // Fringe visibility — phase coherence
        float fringeVis = lerp(0.2, 1.0, phaseCoh);

        col += fieldCol * intensity * fringeVis * 0.3 * silence;

        // Beat — wave packet pulse
        col += a.brainCol * beatPulse * exp(-a.beatPhase * 4.0) * 0.04 * silence;

        // Kick — quantum jump flash
        col += float3(0.9, 0.8, 1.0) * kickSurge * 0.06 * exp(-r * r * 3.0) * silence;

        // Transient — measurement collapse (sharp flash)
        if (transientAmt > 0.02) {
            col += float3(1.0, 1.0, 0.9) * transientAmt * 0.04 * exp(-r * r * 8.0) * silence;
        }
    }

    // ── Source glows — visible emitters at back of chamber ──
    [unroll] for (int s2 = 0; s2 < N_SOURCES; s2++) {
        if (sources[s2].gate < 0.01) continue;
        float3 toSrc = sources[s2].pos - camPos;
        float srcDepth = dot(toSrc, fwd);
        if (srcDepth < 0.1) continue;
        float2 scrSrc = float2(dot(toSrc, right) / (srcDepth * FOV), dot(toSrc, up) / (srcDepth * FOV));
        float scrDist = length(p - scrSrc);
        float srcSize = 0.01 / max(srcDepth * 0.15, 0.3) * 3.0;
        float srcGlow = exp(-scrDist * scrDist / (srcSize * srcSize));
        col += sources[s2].color * srcGlow * sources[s2].amplitude * 0.5 * silence;
    }

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

    // ── Soft tone mapping (Reinhard) — no hard clamp, preserves color ──
    col = softReinhard(col);

    col *= silence;

    return float4(col, 1.0);
}
