// ============================================================================
// HUD 27: Seismic Tectonic Plate (dx_water_droplets.hlsl)
// DX12U Layer 0 — Grid mesh heightfield: tectonic plate with expanding seismic
// waves from 8 audio-driven epicenter sources. P-waves (fast compressional)
// and S-waves (slow shear) distort the plate. Visible fault lines where stress
// builds. Magma glow at rupture points. Rendered as 3D wireframe grid mesh.
//
// Concept: A dark tectonic plate viewed at a shallow angle. 8 audio band
// epicenters emit expanding seismic waves — P-waves (fast, low freq) and
// S-waves (slow, high freq). Where waves constructively interfere, the plate
// buckles and fault lines glow with magma. Beat = earthquake event.
// Kick = tectonic split (fault crack opens, magma erupts). Transient = aftershock.
//
// Audio mapping (exclusive roles per DX12U_VISUALIZATION_RULES.md):
//   audioSimElement(n, 8, a) → per-epicenter amplitude, pan, intensity, scatter
//   b0-b3 → P-waves: fast, long wavelength, high amplitude (deep earth rumbles)
//   b4-b7 → S-waves: slower, shorter wavelength (surface tremors)
//   stereoBal → camera drift + epicenter pan
//   stereoWid → plate spread
//   beat → omnidirectional earthquake event
//   kick → tectonic split (fault crack + magma eruption)
//   transient → aftershock tremors
//   envelope → overall emission gain
//
// DSP additive (refinement only, never replaces brain):
//   LUFS → seismic amplitude boost
//   crest → wave sharpness (rupture intensity)
//   THD → surface roughness (micro-fractures)
//   phase coherence → wave coherence (fault alignment)
//
// HDR output to shared pipeline. No local postfx, tonemapping, or bloom.
// ============================================================================

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define PHI 1.61803399
#define N_SOURCES 16  // 8 bands × L/R
#define N_BANDS 8
#define PLATE_RADIUS 4.0
#define GRID_SPACING 0.2

// Band frequency centers in spectrum texture U coordinate
static const float bandFreq[N_BANDS] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

// ── Epicenter struct ──
struct Epicenter {
    float2 pos;
    float amplitude;
    float wavelength;
    float intensity;
    float pan;
    float freqFrac;
    int bandIdx;     // 0-7
    int channel;     // 0=L, 1=R
};

// ── Position for 16 epicenters: 8 bands × L/R, golden ratio angular distribution ──
float2 epicenterPos(int idx, float radius, float stereoBal, float stereoWid)
{
    int band = idx / 2;
    int ch = idx % 2;
    float ang = float(idx) * PHI * PI * 2.0 + stereoBal * PI;
    float bandR = lerp(0.5, radius * 0.9, float(band) / float(N_BANDS - 1));
    float sideOffset = (ch == 0 ? -1.0 : 1.0) * stereoWid * 0.6;
    return float2(cos(ang) * bandR + sideOffset, sin(ang) * bandR) * (0.8 + stereoWid * 0.3);
}

float distAtten(float d, float k) { return 1.0 / (1.0 + k * d * d); }

// ── Compute 16 epicenters: 8 bands × L/R, each sampling its own spectrum channel ──
void computeEpicenters(out Epicenter sources[N_SOURCES], AudioData a,
                       float crest, float lufs)
{
    float plateR = PLATE_RADIUS * (0.8 + a.stereoWid * 0.3);
    float bands[N_BANDS];
    bands[0] = a.b0; bands[1] = a.b1; bands[2] = a.b2; bands[3] = a.b3;
    bands[4] = a.b4; bands[5] = a.b5; bands[6] = a.b6; bands[7] = a.b7;

    [unroll] for (int bi = 0; bi < N_BANDS; bi++)
    {
        float freqU = bandFreq[bi];
        float bandVal = bands[bi];
        float bandGate = smoothstep(0.02, 0.08, bandVal);
        float freqFrac = float(bi) / float(N_BANDS - 1);

        // Bass compressor curve
        float energyScale = (bi < 4) ? 0.5 : 1.0;

        [unroll] for (int ch = 0; ch < 2; ch++)
        {
            int idx = bi * 2 + ch;
            float2 base = epicenterPos(idx, plateR, a.stereoBal, a.stereoWid);

            // Per-channel spectrum sample
            float specVal = u_spectrum.SampleLevel(u_sampler,
                float2(freqU, ch == 0 ? 0.166 : 0.833), 0).r;
            float chanEnergy = max(specVal, bandVal * 0.5) * bandGate;

            // THD jitter
            float jt = floor(Time * 4.0);
            float jitterX = (hash11(float(idx) * 17.3 + jt) - 0.5) * thdNormalized() * 0.08;
            float jitterY = (hash11(float(idx) * 19.7 + jt) - 0.5) * thdNormalized() * 0.06;

            sources[idx].pos = base + float2(jitterX, jitterY);
            sources[idx].pan = (ch == 0 ? -1.0 : 1.0);
            sources[idx].freqFrac = freqFrac;
            sources[idx].bandIdx = bi;
            sources[idx].channel = ch;
            sources[idx].amplitude = pow(max(chanEnergy, 0.0), energyScale) * bandGate * (1.0 + lufs * 0.2);

            // Wavelength — golden ratio compression: Cf = (Dx * PI) / PHI
            // Bass = long wavelength (P-waves), highs = short (S-waves)
            float dx = lerp(3.0, 0.3, freqFrac);
            sources[idx].wavelength = (dx * PI) / PHI * (1.0 + crest * 0.3);
            sources[idx].intensity = pow(max(chanEnergy, 0.0), energyScale) * bandGate;
        }
    }
}

// ── Fault line pattern — stress accumulation along golden-ratio lines ──
float faultPattern(float2 xz, float time, float stress)
{
    float2 q = float2(fbm2_4(xz * 0.3 + time * 0.02), fbm2_4(xz * 0.3 + time * 0.02 + 5.0));
    float crack = abs(fbm2_4(xz * 0.5 + q * 2.0) - 0.5);
    return smoothstep(0.03, 0.0, crack) * stress;
}

// ── Tectonic plate heightfield — seismic waves from 8 epicenters ──
float plateHeight(float2 xz, Epicenter sources[N_SOURCES],
                  float time, float beatPulse, float beatPhase,
                  float kickSurge, float transient, float thd, float envelope,
                  float lufs, float phaseCoh, float silence)
{
    float r = length(xz);
    if (r > PLATE_RADIUS) return -1.0;

    // Base plate level — slight tectonic drift
    float surface = fbm2_4(xz * 0.15 + time * 0.01) * 0.008 * silence;

    // 16 epicenters — band-specific seismic behavior
    [unroll] for (int n = 0; n < N_SOURCES; n++)
    {
        if (sources[n].amplitude < 0.01) continue;
        float d = length(xz - sources[n].pos);
        float atten = distAtten(d, 0.03);
        int bi = sources[n].bandIdx;
        float freqFrac = sources[n].freqFrac;
        float coherence = lerp(0.3, 1.0, phaseCoh);

        // Band-specific wave behavior
        float waveSpeed, waveAmp, packetWidth;
        float seismic = 0.0;

        if (bi <= 1) {
            // Sub-bass / bass: large P-waves, kick-lunge amplification
            waveSpeed = 3.0;
            waveAmp = sources[n].amplitude * atten * 0.28 * (1.0 + kickSurge * 1.5);
            float wavefront = time * waveSpeed * 0.4;
            float phase = (d - wavefront) / sources[n].wavelength * PI * 2.0;
            float frontDist = d - wavefront;
            packetWidth = sources[n].wavelength * 3.0;
            float packet = exp(-frontDist * frontDist / (packetWidth * packetWidth));
            seismic = sin(phase) * packet * waveAmp * coherence;
            seismic += sin(phase * 0.5) * waveAmp * 0.3 * (1.0 + beatPulse * 2.0);
            // Magma hotspot at epicenter
            seismic += waveAmp * exp(-d * d * 3.0) * 0.5;
        } else if (bi <= 4) {
            // Low-mid / mid: standard P/S waves
            waveSpeed = lerp(2.5, 1.8, (float(bi) - 2.0) / 2.0);
            waveAmp = sources[n].amplitude * atten * 0.22;
            float wavefront = time * waveSpeed * 0.4;
            float phase = (d - wavefront) / sources[n].wavelength * PI * 2.0;
            float frontDist = d - wavefront;
            packetWidth = sources[n].wavelength * 2.5;
            float packet = exp(-frontDist * frontDist / (packetWidth * packetWidth));
            seismic = sin(phase) * packet * waveAmp * coherence;
            seismic += sin(phase * 0.7) * exp(-abs(phase) * 0.12) * waveAmp * coherence * 0.5;
            seismic += sin(phase * 0.5) * waveAmp * 0.3 * (1.0 + beatPulse * 2.0);
        } else {
            // High-mid / presence / brilliance / air: capillary micro-fractures
            waveSpeed = 1.5 + freqFrac * 1.0;
            waveAmp = sources[n].amplitude * atten * 0.12;
            float wavefront = time * waveSpeed * 0.5;
            float phase = (d - wavefront) / sources[n].wavelength * PI * 2.0;
            // Tight packet — high-freq ripples don't travel as far
            packetWidth = sources[n].wavelength * 1.5;
            float frontDist = d - wavefront;
            float packet = exp(-frontDist * frontDist / (packetWidth * packetWidth));
            seismic = sin(phase) * packet * waveAmp * coherence;
            // Surface crackle — THD-driven micro-fractures
            seismic += sin(phase * 3.0 + time * 10.0) * waveAmp * 0.3 * (0.5 + thd);
        }
        surface += seismic;
    }

    // Beat — omnidirectional earthquake event
    surface += beatPulse * 0.07 * sin(r * 3.5 - beatPhase * PI * 3.5) *
               smoothstep(PLATE_RADIUS, 0.0, r) * silence;

    // Kick — tectonic split (central uplift + surrounding depression)
    surface += kickSurge * 0.15 * exp(-r * r * 2.0) * silence;
    surface -= kickSurge * 0.1 * exp(-pow(r - 1.0, 2.0) * 3.0) * silence;

    // Transient — aftershock tremors (high-freq micro-fractures)
    if (transient > 0.02)
        surface += transient * 0.018 * sin(xz.x * 28.0 + xz.y * 25.0 + time * 38.0) *
                   smoothstep(PLATE_RADIUS, 0.0, r) * silence * (0.5 + thd);

    // Envelope — tectonic pressure
    surface += envelope * 0.007 * smoothstep(PLATE_RADIUS, 0.0, r) * silence;

    // Plate edge — curve down into mantle
    surface -= smoothstep(PLATE_RADIUS * 0.7, PLATE_RADIUS, r) * 0.3;

    return surface;
}

// ── Project 3D world point to screen space ──
float2 projectWorld(float3 worldPos, float3 camPos, float3 fwd, float3 right, float3 up, float fov)
{
    float3 toObj = worldPos - camPos;
    float depth = dot(toObj, fwd);
    if (depth < 0.01) depth = 0.01;
    return float2(dot(toObj, right) / (depth * fov), dot(toObj, up) / (depth * fov));
}

float distToSeg2D(float2 p, float2 a, float2 b, out float2 closest)
{
    float2 ab = b - a;
    float lenSq = dot(ab, ab);
    if (lenSq < 0.0001) { closest = a; return length(p - a); }
    float t = clamp(dot(p - a, ab) / lenSq, 0.0, 1.0);
    closest = a + ab * t;
    return length(p - closest);
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

    // ── Audio dynamics ──
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);

    // ── Compute 8 epicenters ──
    Epicenter sources[N_SOURCES];
    computeEpicenters(sources, a, dspCrest, dspLUFS);

    // ── Camera — fixed low angle above plate, no spinning ──
    float FOV = 0.7;
    float camDrift = a.stereoBal * 0.3;
    float3 camPos = float3(0.0 + camDrift, 1.8 + a.stereoDiff * 0.1, 5.0);
    float3 camTarget = float3(0.0, 0.0, 0.0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(fwd + p.x * right * FOV + p.y * up * FOV);

    // ── Background — deep earth void ──
    float3 col = float3(0.02, 0.008, 0.003) * silence;
    col += starfield(uv, a) * 0.008;
    float nebula = fbm2_4(p * 0.8 + Time * 0.003 * a.motSpeed);
    col += a.brainCol * nebula * 0.005 * a.ambient * a.ambActive * silence;

    // ── Raycast to plate plane (y=0) ──
    float tPlane = -camPos.y / rd.y;
    float3 planeHit = camPos + rd * tPlane;
    float2 xz = planeHit.xz;
    float distFromCenter = length(xz);

    float depthFade = smoothstep(10.0, 1.0, tPlane) * smoothstep(0.0, 0.5, tPlane);
    float radialFade = smoothstep(PLATE_RADIUS, 0.0, distFromCenter) * silence;

    if (tPlane > 0.0 && radialFade > 0.01)
    {
        // ── Grid cell lookup ──
        float2 gridCoord = xz / GRID_SPACING;
        float2 cellBase = floor(gridCoord);
        float2 cellFrac = frac(gridCoord);

        float2 c0xz = (cellBase + float2(0, 0)) * GRID_SPACING;
        float2 c1xz = (cellBase + float2(1, 0)) * GRID_SPACING;
        float2 c2xz = (cellBase + float2(0, 1)) * GRID_SPACING;
        float2 c3xz = (cellBase + float2(1, 1)) * GRID_SPACING;

        float h0 = plateHeight(c0xz, sources, Time, beatPulse, a.beatPhase,
                               kickSurge, a.transient, dspTHD, a.envelope,
                               dspLUFS, dspPhaseCoh, silence);
        float h1 = plateHeight(c1xz, sources, Time, beatPulse, a.beatPhase,
                               kickSurge, a.transient, dspTHD, a.envelope,
                               dspLUFS, dspPhaseCoh, silence);
        float h2 = plateHeight(c2xz, sources, Time, beatPulse, a.beatPhase,
                               kickSurge, a.transient, dspTHD, a.envelope,
                               dspLUFS, dspPhaseCoh, silence);
        float h3 = plateHeight(c3xz, sources, Time, beatPulse, a.beatPhase,
                               kickSurge, a.transient, dspTHD, a.envelope,
                               dspLUFS, dspPhaseCoh, silence);

        float surfH = lerp(lerp(h0, h1, cellFrac.x), lerp(h2, h3, cellFrac.x), cellFrac.y);

        // ── Project 4 corners to screen space ──
        float2 c0screen = projectWorld(float3(c0xz.x, h0, c0xz.y), camPos, fwd, right, up, FOV);
        float2 c1screen = projectWorld(float3(c1xz.x, h1, c1xz.y), camPos, fwd, right, up, FOV);
        float2 c2screen = projectWorld(float3(c2xz.x, h2, c2xz.y), camPos, fwd, right, up, FOV);
        float2 c3screen = projectWorld(float3(c3xz.x, h3, c3xz.y), camPos, fwd, right, up, FOV);

        // ── Grid line rendering ──
        float2 tmpClosest;
        float dEdge01 = distToSeg2D(p, c0screen, c1screen, tmpClosest);
        float dEdge02 = distToSeg2D(p, c0screen, c2screen, tmpClosest);
        float dEdge13 = distToSeg2D(p, c1screen, c3screen, tmpClosest);
        float dEdge23 = distToSeg2D(p, c2screen, c3screen, tmpClosest);
        float minEdge = min(min(dEdge01, dEdge02), min(dEdge13, dEdge23));

        // ── Grid node glow ──
        float dNode0 = length(p - c0screen);
        float dNode1 = length(p - c1screen);
        float dNode2 = length(p - c2screen);
        float dNode3 = length(p - c3screen);
        float minNode = min(min(dNode0, dNode1), min(dNode2, dNode3));

        // ── Nearest epicenter for color ──
        float nearestSrcDist = 999.0;
        float nearestFreqFrac = 0.5;
        float nearestPan = 0.0;
        int nearestBand = 4;
        int nearestCh = 0;
        [unroll] for (int ns = 0; ns < N_SOURCES; ns++)
        {
            if (sources[ns].amplitude < 0.01) continue;
            float sd2 = dot(xz - sources[ns].pos, xz - sources[ns].pos);
            if (sd2 < nearestSrcDist) {
                nearestSrcDist = sd2;
                nearestFreqFrac = sources[ns].freqFrac;
                nearestPan = sources[ns].pan;
                nearestBand = sources[ns].bandIdx;
                nearestCh = sources[ns].channel;
            }
        }

        // ── Color — earth tones with band-specific magma glow ──
        float3 freqCol = hsv(a.hueBase + nearestFreqFrac * a.hueRange, 0.5 * a.satur, 0.9);
        float3 brain = lerp(a.brainCol, a.brainCol2, nearestFreqFrac);
        brain = lerp(brain, freqCol, 0.3);

        // Band-specific magma palette
        float3 rockDark = float3(0.04, 0.02, 0.008);
        float3 magmaHot, magmaCool;
        if (nearestBand <= 1) {
            // Bass: deep red-orange magma
            magmaHot = float3(1.0, 0.3, 0.05);
            magmaCool = float3(0.5, 0.1, 0.02);
        } else if (nearestBand <= 3) {
            // Low-mid: orange-amber
            magmaHot = float3(1.0, 0.5, 0.1);
            magmaCool = float3(0.4, 0.15, 0.03);
        } else if (nearestBand <= 5) {
            // Mid-high: yellow-white hot
            magmaHot = float3(1.0, 0.8, 0.3);
            magmaCool = float3(0.3, 0.2, 0.05);
        } else {
            // Highs: white-blue friction sparks
            magmaHot = float3(0.9, 0.85, 1.0);
            magmaCool = float3(0.1, 0.08, 0.15);
        }
        float3 magmaGlow = lerp(magmaCool, magmaHot, clamp(surfH * 3.0 + 0.2, 0.0, 1.0));
        float3 gridCol = lerp(rockDark, magmaGlow, 0.4);
        gridCol = lerp(gridCol, brain, 0.2);

        // Phase coherence → fault alignment
        float coherence = lerp(0.3, 1.0, dspPhaseCoh);
        gridCol = lerp(gridCol, gridCol.gbr, (1.0 - coherence) * 0.05);

        // Stereo L/R tint
        float sideTint = clamp(xz.x * 0.2 + nearestPan * 0.3, -1.0, 1.0);
        gridCol = lerp(gridCol, gridCol * float3(1.2, 0.9, 0.78), max(sideTint, 0.0) * a.stereoWid * 0.15);
        gridCol = lerp(gridCol, gridCol * float3(0.78, 0.9, 1.2), max(-sideTint, 0.0) * a.stereoWid * 0.15);

        // ── Fault lines — stress cracks visible on plate surface ──
        float stress = clamp(abs(surfH) * 5.0 + kickSurge * 2.0, 0.0, 1.0);
        float fault = faultPattern(xz, Time * 0.1, stress);
        float3 faultCol = lerp(float3(0.8, 0.2, 0.03), float3(1.0, 0.5, 0.08), stress);
        gridCol += faultCol * fault * 0.3 * depthFade * radialFade;

        // ── Grid lines ──
        float lineWidth = 0.002 / (1.0 + tPlane * 0.05);
        float lineIntensity = exp(-minEdge * minEdge / (lineWidth * lineWidth * 2.0));
        lineIntensity *= depthFade * radialFade;
        float crestGlow = smoothstep(0.01, 0.08, abs(surfH));
        float3 lineCol = gridCol * (0.3 + crestGlow * 0.7);
        col += lineCol * lineIntensity * (0.4 + a.brightness * 0.3 + a.envelope * 0.3) * silence;

        // ── Grid nodes ──
        float nodeSize = 0.005 / (1.0 + tPlane * 0.08);
        float nodeIntensity = exp(-minNode * minNode / (nodeSize * nodeSize * 2.0));
        nodeIntensity *= depthFade * radialFade;
        float3 nodeCol = lerp(gridCol * 0.5, magmaGlow, crestGlow);
        col += nodeCol * nodeIntensity * (0.5 + a.envelope * 0.5 + crestGlow * 0.5) * silence;

        // ── Magma crest glow ──
        col += magmaGlow * crestGlow * (0.12 + a.envelope * 0.3) * depthFade * radialFade * silence;

        // ── Beat — earthquake pulse ──
        col += magmaGlow * beatPulse * crestGlow * 0.06 * depthFade * radialFade * silence;

        // ── Kick — tectonic split magma eruption ──
        col += float3(1.0, 0.3, 0.05) * kickSurge * crestGlow * 0.35 * depthFade * radialFade * silence;
        col += float3(1.0, 0.5, 0.1) * kickSurge * fault * 0.2 * depthFade * radialFade * silence;

        // ── Transient — aftershock flash ──
        if (a.transient > 0.02)
            col += float3(0.9, 0.5, 0.15) * a.transient * crestGlow * 0.1 * depthFade * radialFade * silence;

        // ── ColorPulse ──
        col += a.brainCol3 * a.colorPulse * crestGlow * 0.02 * depthFade * radialFade * silence;

        // ── Punch ──
        col += magmaGlow * a.punch * crestGlow * 0.04 * depthFade * radialFade * silence;
    }

    // ── Beat ring — seismic wave expanding outward ──
    float ringDist = abs(r - a.beatPhase * 0.6);
    col += float3(0.6, 0.15, 0.03) * exp(-ringDist * ringDist * 50.0) * beatPulse * 0.015 * silence;

    // ── Kick flash — magma eruption ──
    col += float3(1.0, 0.3, 0.05) * kickSurge * 0.04 * exp(-r * r * 5.0) * silence;

    // ── Transient pop ──
    col += float3(0.8, 0.4, 0.1) * a.transient * 0.012 * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.01 * silence;

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02 * silence;

    // ── HDR brightness limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.5) col *= 1.5 / maxC;

    return float4(col, 1.0);
}
