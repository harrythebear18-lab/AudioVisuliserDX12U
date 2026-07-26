// Mode 32: Gravitational Space Waves — spacetime fabric with GW strain tensor
// h+ and h× polarizations, quadrupole radiation pattern, geodesic deviation.
// 24 grid nodes (3 per band) displaced by 8 GW sources at golden-ratio positions.
// Bass = long-wavelength GW, mids = structural distortion, highs = quantum jitter.
// Beat = omnidirectional GW event. Kick = spacetime tear. Transient = quantum fluct.
// DSP: LUFS→strain amplitude, crest→wave sharpness, THD→fabric roughness, phase→coherence.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define PHI 1.618
#define N_COMP 8
#define N_SOURCES 24
#define GRID_SIZE 6.0

struct GWSource {
    float2 pos;
    float amplitude;
    float wavelength;
    float gate;
    float freqFrac;
};

void computeSources(out GWSource sources[N_SOURCES], float bands[8], float dspBands[8],
                    float kickSurge, float beatPulse, float stereoBal, float crest, float thd,
                    float transient, float envelope, float section)
{
    [unroll] for (int n = 0; n < N_SOURCES; n++)
    {
        int band = n / 3;
        int sub = n % 3;
        float bt = float(band) / float(N_COMP - 1);

        float rawEnergy = bands[band] + dspBands[band] * 0.12;
        float energy = (band < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
        float gate = smoothstep(0.02, 0.08, rawEnergy);

        // Golden ratio angular distribution
        float ang = float(n) * PHI * PI * 2.0 + stereoBal * 0.4;
        float rad = lerp(1.5, 3.0, bt);
        sources[n].pos = float2(cos(ang) * rad, sin(ang) * rad);

        // Wavelength: bass = long, highs = short
        sources[n].wavelength = lerp(4.0, 0.5, bt);

        // Staggered beat breathing
        float h = energy * (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
        h += transient * lerp(0.05, 0.2, bt) * gate;
        h += envelope * lerp(0.08, 0.03, bt) * gate;
        h += section * 0.05 * gate;
        h += (band < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;
        h *= gate;

        sources[n].amplitude = clamp(h, 0.0, 1.5);
        sources[n].gate = gate;
        sources[n].freqFrac = bt;
    }
}

// GW strain tensor — h+ and h× polarizations
float2 gwStrain(float2 pos, float dist, float wavelength, float amplitude, float phase)
{
    float k = (2.0 * PI) / wavelength;
    float omega = 2.0 * PI * 0.5;
    float phaseShift = k * dist - omega * phase;

    float hPlus = amplitude * sin(phaseShift);
    float hCross = amplitude * cos(phaseShift) * 0.7;

    float2 strain;
    strain.x = hPlus * pos.x + hCross * pos.y;
    strain.y = hCross * pos.x - hPlus * pos.y;
    return strain;
}

// Quadrupole radiation pattern — strongest perpendicular to source axis
float quadrupolePattern(float2 sourcePos, float2 fieldPos)
{
    float2 toField = normalize(fieldPos - sourcePos);
    float2 sourceAxis = normalize(sourcePos);
    float cosTheta = dot(toField, sourceAxis);
    return 1.0 - cosTheta * cosTheta;
}

// Heightfield displacement from all GW sources
float gwHeightfield(float2 xz, GWSource sources[N_SOURCES], float bands[8],
                    float beatPulse, float kickSurge, float transient, float envelope,
                    float lufs, float crest, float thd, float phaseCoh, float stereoBal, float silence)
{
    float h = 0.0;

    [unroll] for (int i = 0; i < N_SOURCES; i++) {
        if (sources[i].gate < 0.01) continue;

        float dist = length(xz - sources[i].pos);
        float amp = sources[i].amplitude * quadrupolePattern(sources[i].pos, xz);
        amp *= (1.0 + lufs * 0.2);

        float2 horizPos = xz - sources[i].pos;
        float2 strain = gwStrain(horizPos, dist, sources[i].wavelength, amp * 0.15, Time + float(i) * 0.5);

        h += (strain.x + strain.y) * 0.5;
    }

    // Beat — omnidirectional GW event
    h += beatPulse * sin(length(xz) * 3.0 - Time * 6.0) * 0.1 * exp(-length(xz) * 0.3) * silence;

    // Kick — spacetime tear
    float tearDist = length(xz - float2(stereoBal * 0.5, 0));
    h += kickSurge * exp(-tearDist * 2.0) * 0.3 * sin(tearDist * 10.0 - Time * 15.0) * silence;

    // Transient — quantum fluctuations, staggered for highs
    h += transient * fbm2_4(xz * 3.0 + Time * 2.0) * 0.04 * (1.0 + thd * 0.5) * silence;

    // Phase coherence
    h *= lerp(0.8, 1.15, phaseCoh);

    // Crest — wave sharpness
    h *= (1.0 + crest * 0.3);

    return h;
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

    GWSource sources[N_SOURCES];
    computeSources(sources, bands, dspBands, kickSurge, beatPulse, a.stereoBal, crest, thd,
                   transientAmt, envelope, a.section);

    // ── Camera — section-driven orbit ──
    float FOV = 0.55;
    float camAng = a.section * 0.8 + a.stereoBal * 0.2;
    float3 camPos = float3(sin(camAng) * 4.0, 2.5 + a.stereoDiff * 0.15, cos(camAng) * 4.0);
    float3 camTarget = float3(0, 0, 0);
    float3 rd = cameraRay(camPos, camTarget, float2(-p.x, -p.y), FOV);

    // ── Background — deep space ──
    float3 col = float3(0.001, 0.001, 0.006) * silence;
    col += starfield(uv, a) * 0.025;
    col += godRays(p, r, a) * 0.06 * silence;

    // ── Raycast to base plane and render grid ──
    float t = -camPos.y / rd.y;
    if (t > 0.0 && t < 20.0) {
        float3 hitPos = camPos + rd * t;
        float2 gridCoord = hitPos.xz;

        if (abs(gridCoord.x) < GRID_SIZE && abs(gridCoord.y) < GRID_SIZE) {
            float2 cellSize = float2(0.25, 0.25);
            float2 cellId = floor(gridCoord / cellSize);
            float2 cellUV = frac(gridCoord / cellSize);

            // Bilinear heightfield at 4 corners
            float h00 = gwHeightfield(float2(cellId.x * cellSize.x, cellId.y * cellSize.y), sources, bands, beatPulse, kickSurge, transientAmt, envelope, lufs, crest, thd, phaseCoh, a.stereoBal, silence);
            float h10 = gwHeightfield(float2((cellId.x+1) * cellSize.x, cellId.y * cellSize.y), sources, bands, beatPulse, kickSurge, transientAmt, envelope, lufs, crest, thd, phaseCoh, a.stereoBal, silence);
            float h01 = gwHeightfield(float2(cellId.x * cellSize.x, (cellId.y+1) * cellSize.y), sources, bands, beatPulse, kickSurge, transientAmt, envelope, lufs, crest, thd, phaseCoh, a.stereoBal, silence);
            float h11 = gwHeightfield(float2((cellId.x+1) * cellSize.x, (cellId.y+1) * cellSize.y), sources, bands, beatPulse, kickSurge, transientAmt, envelope, lufs, crest, thd, phaseCoh, a.stereoBal, silence);

            float heightVal = lerp(lerp(h00, h10, cellUV.x), lerp(h01, h11, cellUV.x), cellUV.y);

            // Grid line intensity
            float2 edgeDist = abs(cellUV - 0.5) * 2.0;
            float gridLine = smoothstep(0.85, 1.0, max(edgeDist.x, edgeDist.y));

            // Node glow at intersections
            float nodeDist = length(cellUV - 0.5);
            float nodeGlow = exp(-nodeDist * nodeDist * 8.0) * 0.5;

            // Color — frequency-positioned with brain palette
            float freqFrac = length(gridCoord) / GRID_SIZE;
            float3 lineCol = lerp(a.brainCol, a.brainCol2, freqFrac);
            lineCol = lerp(lineCol, hsv(a.hueBase + heightVal * 0.5 + freqFrac * a.hueRange, 0.6 * a.satur, 0.9), 0.3);

            // Emission — height-driven
            float emission = (gridLine * 0.4 + nodeGlow) * (0.3 + abs(heightVal) * 3.0);
            emission *= (0.5 + envelope * 0.5) * (1.0 + lufs * 0.15);

            float depthFog = exp(-t * 0.08);
            col += lineCol * emission * depthFog * silence;

            // Kick tear glow
            float tearDist = length(gridCoord - float2(a.stereoBal * 0.5, 0));
            col += a.brainCol3 * exp(-tearDist * 3.0) * kickSurge * 0.5 * depthFog * silence;
        }
    }

    // ── Beat GW ripple ──
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

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── HDR limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
