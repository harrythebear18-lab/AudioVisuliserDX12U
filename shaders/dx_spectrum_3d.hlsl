// SPECTRUM 3D — Mode 2: Stereo mirror spectrum, fully brain-driven.
// Bass in center, frequencies spread outward L/R. Left half = L channel, right half = R channel.
// Every AudioUBO field influences the rendering.
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"

struct PSInput { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

#define HALF_BARS 128.0

float4 main(PSInput input) : SV_TARGET {
    float2 uv = input.uv;
    float2 p = (uv - 0.5) * 2.0;
    p.x *= Aspect;

    // ═══ FULL BRAIN DATA ═══
    AudioData a = extractAudio();
    float beat = a.beat;       float transient = a.transient;
    float envelope = a.envelope;   float overall = a.overall;
    float bpm = a.bpm;          float tempoConf = a.tempoConf;
    float kick = a.kick;         float kickConf = a.kickConf;
    float stereoBal = a.stereoBal;    float stereoWid = a.stereoWid;
    float effectInt = a.effectInt;    float motionSpd = a.motionSpd;
    float hueBase = a.hueBase;    float hueCenter = a.hueCenter;
    float hueRange = a.hueRange;   float beatDet = a.beatDet;
    float brightness = a.brightness; float beam = a.beam;
    float bloom = a.bloom;      float dynLight = a.dynLight;
    float ambient = a.ambient;   float atmos = a.atmos;
    float phaseCorr = a.phaseCorr;  float clarity = a.clarity;
    float burstTrig = a.burstTrig;     float burstType = a.burstType;
    float burstInt = a.burstInt;      float colorPulse = a.colorPulse;
    float dynActive = a.dynActive;       float beamActive = a.beamActive;
    float ambActive = a.ambActive;       float bloomActive = a.bloomActive;
    float groupMode = a.groupMode;              float effectMode = a.effectMode;
    float beatCount = a.beatCount;              float phraseBeat = a.phraseBeat;
    float section = a.section;          float shouldChg = a.shouldChg;
    float beatAnt = a.beatAnt;          float motionPers = a.motionPers;
    float energy = a.energy;              float profBass = a.profBass;
    float profTreb = a.profTreb;            float tempo = a.tempo;
    float punch = a.punch;               float profStereo = a.profStereo;
    float dynamic = a.dynamic;             float glow = a.glow;
    float barScale = a.barScale;            float motSpeed = a.motSpeed;
    float satur = a.satur;               float persp = a.persp;

    // Noise gate
    float gateThreshold = 0.025;
    float gatedOverall = max(overall - gateThreshold, 0.0) / (1.0 - gateThreshold);
    float silent = step(overall, gateThreshold);

    float bpmNorm = saturate((bpm - 60.0) / 140.0);
    float r = length(p);

    float3 col = float3(0.01, 0.008, 0.02) * (1.0 - silent * 0.98);

    float halfArea = Aspect * 0.98;
    float barW = halfArea / HALF_BARS;
    float barGap = barW * 0.12;
    float maxBarHeight = 1.8 * (0.8 + punch * 0.4) * barScale;

    // Audio-reactive camera tilt — kick tilts perspective, stereo shifts horizontally
    float tiltY = kick * 0.15 * kickConf + profBass * 0.08;
    float tiltX = stereoBal * 0.1;
    float2 tiltP = p;
    tiltP.y -= tiltY * (1.0 - p.y * 0.5);  // perspective tilt
    tiltP.x -= tiltX * (1.0 - p.y * 0.5);

    // Beat-reactive bar width pulse — bars get thicker on beat
    float beatWidthPulse = 1.0 + beat * 0.15 * tempoConf;
    float barWPulse = barW * beatWidthPulse;
    float barGapPulse = barGap / beatWidthPulse;

    // Stereo width expands/contracts the spread
    float widthMul = 1.0 + stereoWid * 0.3;
    // Phase correlation — low = diffuse, high = tight mirror
    float phaseTight = lerp(0.7, 1.0, phaseCorr);

    [loop] for (float i = 0; i < HALF_BARS; i += 1) {
        float barFrac = i / HALF_BARS;

        float freq = 20.0 * pow(1200.0, barFrac);
        float samplePos = saturate(freq / 24000.0);

        // L/R channels from spectrum texture rows (3-row texture: 0=left, 1=center, 2=right)
        float specL = u_spectrum.SampleLevel(u_sampler, float2(samplePos, 0.166), 0).r;
        float specR = u_spectrum.SampleLevel(u_sampler, float2(samplePos, 0.833), 0).r;
        float specC = u_spectrum.SampleLevel(u_sampler, float2(samplePos, 0.5), 0).r;

        // Sub-bass: sum L+R for centered bass
        float subMix = 1.0 - smoothstep(0.0, 0.08, barFrac);
        float subSum = (specL + specR) * 0.5;

        // Beat anticipation lift
        float antBoost = beatAnt * 0.06 * (1.0 - barFrac * 0.5);

        // Hue — base + range + color pulse + section
        float barHue = hueBase + barFrac * hueRange * 0.4 + colorPulse * 0.05 + section * 0.02;
        float barSat = 0.85 * satur;
        float barVal = 0.9 * (0.7 + brightness * 0.3 + beam * 0.15 * beamActive);

        // RIGHT side
        {
            float barCenter = (i * barW + barW * 0.5) * widthMul;
            float xDist = abs(tiltP.x - barCenter);
            float barEdge = smoothstep(barWPulse * 0.5, barWPulse * 0.5 - barGapPulse, xDist);
            float valR = lerp(specR, subSum, subMix);
            valR = saturate(valR * 0.25) * 0.9;
            // Transient adds sharp spike, envelope adds sustained body
            float h = (valR + antBoost) * maxBarHeight * phaseTight;
            h += transient * 0.08 * (1.0 - barFrac * 0.5);  // transient spike on low freqs
            float barTop = 0.85 - h;
            float barBottom = 0.85;
            float barMask = step(barTop, tiltP.y) * step(tiltP.y, barBottom) * barEdge;
            float heightFrac = saturate((barBottom - tiltP.y) / max(0.001, barBottom - barTop));
            float3 barCol = hsv(barHue + heightFrac * 0.05, barSat, barVal);
            col = lerp(col, barCol, barMask * (1.0 - silent * 0.98));
        }

        // LEFT side (mirrored)
        {
            float barCenter = -(i * barW + barW * 0.5) * widthMul;
            float xDist = abs(tiltP.x - barCenter);
            float barEdge = smoothstep(barWPulse * 0.5, barWPulse * 0.5 - barGapPulse, xDist);
            float valL = lerp(specL, subSum, subMix);
            valL = saturate(valL * 0.25) * 0.9;
            float h = (valL + antBoost) * maxBarHeight * phaseTight;
            h += transient * 0.08 * (1.0 - barFrac * 0.5);
            float barTop = 0.85 - h;
            float barBottom = 0.85;
            float barMask = step(barTop, tiltP.y) * step(tiltP.y, barBottom) * barEdge;
            float heightFrac = saturate((barBottom - tiltP.y) / max(0.001, barBottom - barTop));
            float3 barCol = hsv(barHue + heightFrac * 0.05, barSat, barVal);
            col = lerp(col, barCol, barMask * (1.0 - silent * 0.98));
        }
    }

    // Global modulator
    col *= (0.3 + gatedOverall * 0.7);
    col *= (1.0 - silent * 0.98);

    // Perspective vignette
    {
        float vig = smoothstep(1.3, 0.3, length(uv - 0.5));
        col *= lerp(1.0, 0.5 + vig * 0.5, persp);
    }

    // HDR brightness limiter
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.5) col *= 1.5 / maxC;
    return float4(col, 1);
}
