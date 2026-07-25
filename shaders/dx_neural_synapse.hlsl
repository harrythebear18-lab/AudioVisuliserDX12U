// Mode 38: Neural Synapse Storm — immersive 3D neural network
// You are inside a brain. 8 band clusters = brain regions with neurons and synapses.
// Stereo = left/right hemisphere split. Phase coherence = hemisphere synchronization.
// Beat = action potential cascade. Kick = neurotransmitter flood.
// Transient = synaptic firing burst. Envelope = baseline neural activity.
// DSP: LUFS→neuron brightness, crest→synapse sharpness, THD→neural noise, phase→hemisphere sync.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define N_NEURONS 24
#define N_SYNAPSES 24

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

struct Neuron {
    float3 pos;
    float energy;
    float gate;
    float freqFrac;
    int hemisphere; // 0=left, 1=right
    float3 color;
};

struct Synapse {
    int from;
    int to;
    float strength;
    float gate;
};

void computeNeurons(out Neuron neurons[N_NEURONS], out Synapse synapses[N_SYNAPSES],
                    float bands[8], float dspBands[8], float kickSurge, float beatPulse,
                    float stereoBal, float stereoWid, float crest, float thd,
                    float transient, float envelope, float section, float phaseCoh, AudioData a)
{
    // 4 neurons per band, 2 per hemisphere
    [unroll] for (int n = 0; n < N_NEURONS; n++)
    {
        int band = n / 4;
        int sub = n % 4;
        int hemi = sub / 2;  // 0=left, 1=right
        float bt = float(band) / float(N_COMP - 1);

        float rawEnergy = bands[band] + dspBands[band] * 0.12;
        float energy = (band < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
        float gate = smoothstep(0.02, 0.08, rawEnergy);

        // Spectrum L/R — stereo spatial positioning (neurons use hemisphere)
        float freqU = bandFreq[band];
        float lE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.166), 0).r;
        float rE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.833), 0).r;
        float stereoEnergy = max(lE, rE);
        energy = max(energy, stereoEnergy * 0.5);
        gate = max(gate, smoothstep(0.02, 0.08, stereoEnergy));
        // Hemisphere already splits L/R — use spectrum to modulate per-hemisphere energy
        if (hemi == 0) energy = max(energy, lE * 0.5);
        else energy = max(energy, rE * 0.5);

        // Position — hemisphere split with stereo width
        float hemiSign = (hemi == 0) ? -1.0 : 1.0;
        float xBase = hemiSign * (0.8 + a.stereoWid * 0.4);
        float ang = float(sub % 2) * PI + float(band) * 0.5 + stereoBal * 0.3;
        float radius = 0.5 + float(band) * 0.3;
        float yLevel = lerp(-1.5, 1.5, bt);

        neurons[n].pos = float3(
            xBase + cos(ang) * radius * 0.3,
            yLevel + sin(float(n) * 2.3) * 0.3,
            sin(ang) * radius
        );
        neurons[n].hemisphere = hemi;

        // Staggered beat breathing
        float h = energy * (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
        h += transient * lerp(0.05, 0.2, bt) * gate;
        h += envelope * lerp(0.08, 0.03, bt) * gate;
        h += section * 0.05 * gate;
        h += (band < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;
        h *= gate;

        neurons[n].energy = clamp(h, 0.0, 1.5);
        neurons[n].gate = gate;
        neurons[n].freqFrac = bt;

        // Color — hemisphere tint
        float3 c = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
        c = lerp(c, lerp(a.brainCol, a.brainCol2, bt), 0.3);
        // Left hemisphere slightly warmer, right cooler
        if (hemi == 0) c = lerp(c, float3(1.0, 0.7, 0.5), 0.1);
        else c = lerp(c, float3(0.5, 0.7, 1.0), 0.1);
        neurons[n].color = c;
    }

    // Synapses — connect neurons within and across hemispheres
    int synIdx = 0;
    [loop] for (int i = 0; i < N_NEURONS; i++) {
        if (synIdx >= N_SYNAPSES) break;
        [loop] for (int j = i + 1; j < N_NEURONS; j++) {
            if (synIdx >= N_SYNAPSES) break;
            float dist = length(neurons[i].pos - neurons[j].pos);
            if (dist > 1.5) continue;

            synapses[synIdx].from = i;
            synapses[synIdx].to = j;
            synapses[synIdx].strength = 1.0 / (dist + 0.1);

            // Cross-hemisphere synapses gated by phase coherence
            if (neurons[i].hemisphere != neurons[j].hemisphere) {
                synapses[synIdx].strength *= phaseCoh;
            }
            synapses[synIdx].gate = neurons[i].gate * neurons[j].gate;
            synIdx++;
        }
    }
    // Fill remaining
    for (int k = synIdx; k < N_SYNAPSES; k++) {
        synapses[k].from = 0;
        synapses[k].to = 0;
        synapses[k].strength = 0.0;
        synapses[k].gate = 0.0;
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

    Neuron neurons[N_NEURONS];
    Synapse synapses[N_SYNAPSES];
    computeNeurons(neurons, synapses, bands, dspBands, kickSurge, beatPulse,
                   a.stereoBal, a.stereoWid, crest, thd, transientAmt, envelope,
                   a.section, phaseCoh, a);

    // ── Camera — inside the brain, slowly rotating ──
    float FOV = 0.75;
    float camAng = a.section * 0.5 + a.stereoBal * 0.2 + Time * 0.02 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 1.5, 0.5 + a.stereoDiff * 0.1, cos(camAng) * 1.5);
    float3 camTarget = float3(0, 0, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Background — dark neural space ──
    float3 col = float3(0.002, 0.001, 0.006) * silence;
    col += starfield(uv, a) * 0.005;

    // ── Project neurons ──
    float2 scrPos[N_NEURONS];
    float scrDepth[N_NEURONS];

    [unroll] for (int n = 0; n < N_NEURONS; n++) {
        float3 toN = neurons[n].pos - camPos;
        scrDepth[n] = dot(toN, fwd);
        if (scrDepth[n] < 0.1) { scrPos[n] = float2(999, 999); scrDepth[n] = 0.0; continue; }
        scrPos[n] = float2(dot(toN, right) / (scrDepth[n] * FOV), dot(toN, up) / (scrDepth[n] * FOV));
    }

    // ── Synapses — axon connections with signal propagation ──
    [unroll] for (int s = 0; s < N_SYNAPSES; s++) {
        if (synapses[s].gate < 0.01) continue;
        int i = synapses[s].from;
        int j = synapses[s].to;
        if (scrDepth[i] < 0.1 || scrDepth[j] < 0.1) continue;

        // Signal propagation along axon — beat phase drives position
        float signalPos = a.beatPhase;
        float2 sigPoint = lerp(scrPos[i], scrPos[j], signalPos);

        // Axon line — dim base
        float2 ab = scrPos[j] - scrPos[i];
        float t = clamp(dot(p - scrPos[i], ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
        float2 closest = scrPos[i] + ab * t;
        float axonDist = length(p - closest);
        float axonWidth = 0.002 + synapses[s].strength * 0.003;
        float axonGlow = exp(-axonDist * axonDist / (axonWidth * axonWidth));

        float3 synCol = lerp(neurons[i].color, neurons[j].color, 0.5);
        float avgDepth = (scrDepth[i] + scrDepth[j]) * 0.5;
        float depthFade = exp(-avgDepth * 0.08);

        // Base axon — always visible when gated
        col += synCol * axonGlow * synapses[s].strength * depthFade * 0.15 * silence;

        // Signal pulse traveling along axon
        float sigDist = length(p - sigPoint);
        float sigGlow = exp(-sigDist * sigDist * 80.0);
        col += float3(0.9, 0.95, 1.0) * sigGlow * beatPulse * synapses[s].strength * depthFade * 0.5 * silence;

        // Kick — neurotransmitter flood lights up entire axon
        col += synCol * axonGlow * kickSurge * synapses[s].strength * depthFade * 0.3 * silence;
    }

    // ── Neurons — glowing cell bodies ──
    [unroll] for (int m = 0; m < N_NEURONS; m++) {
        if (neurons[m].gate < 0.01 || scrDepth[m] < 0.1) continue;

        float scrDist = length(p - scrPos[m]);
        float sz = (0.015 + neurons[m].energy * 0.04) / max(scrDepth[m] * 0.15, 0.3) * 3.0;

        float coreGlow = exp(-scrDist * scrDist / (sz * sz * 0.1));
        float midGlow = exp(-scrDist * scrDist / (sz * sz * 0.8));
        float haloGlow = exp(-scrDist * scrDist / (sz * sz * 5.0));

        float intensity = neurons[m].energy * (1.0 + lufs * 0.2);
        float depthFade = exp(-scrDepth[m] * 0.08);

        // Firing neuron — white-hot flash on beat
        float firing = beatPulse * neurons[m].gate * exp(-a.beatPhase * 4.0);
        col += float3(0.9, 0.95, 1.0) * coreGlow * (intensity + firing * 2.0) * depthFade * silence;
        col += neurons[m].color * midGlow * intensity * depthFade * 0.8 * silence;
        col += neurons[m].color * haloGlow * intensity * depthFade * 0.2 * silence;

        // Dendrite halo — THD noise
        float dendNoise = thd * hash21(scrPos[m] * 50.0 + Time * 10.0) * 0.02;
        col += neurons[m].color * dendNoise * midGlow * silence;
    }

    // ── Hemisphere divider — phase coherence indicator ──
    if (phaseCoh > 0.6) {
        float divider = exp(-p.x * p.x * 50.0) * (phaseCoh - 0.6) * 0.03;
        col += float3(0.4, 0.6, 0.5) * divider * silence;
    }

    // ── Beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.025 * silence;

    // ── Kick flash ──
    col += a.brainCol3 * kickSurge * 0.05 * exp(-r * r * 5.0) * silence;

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

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── HDR limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
