// ============================================================================
// HUD 20: Spacetime Gravity Waves (dx_galaxy.hlsl)
// DX12U Layer 0 — Grid mesh heightfield: spacetime fabric rippled by
// gravitational waves from 8 audio-driven wave sources. Rendered as a
// 3D wireframe grid mesh — raycast to base plane, evaluate 4 cell corners,
// bilinear interpolate displaced surface, draw grid lines + glowing nodes.
//
// Concept: A 3D spacetime fabric grid stretched across the view. 8 gravitational
// wave sources at golden-ratio positions emit expanding ripples that distort
// the grid. Where waves constructively interfere, grid nodes glow bright.
// Bass sources emit long-wavelength rumbles, high sources emit short-wavelength
// shimmer. Beat = massive gravitational wave event. Kick = spacetime tear.
// Transient = quantum fluctuations.
//
// Silhouette: A dark wireframe grid stretching into the distance, with grid
// lines rippling up/down from wave sources. Grid nodes glow at wave crests.
// Beat sends a visible omnidirectional ripple through the grid. Kick tears it.
//
// Audio mapping (exclusive roles per DX12U_VISUALIZATION_RULES.md):
//   audioSimElement(n, 8, a) → per-source amplitude, pan, intensity, scatter
//   b0-b7 → 8 wave sources, bass=long wavelength, highs=short wavelength
//   stereoBal → camera orbit + source pan displacement
//   stereoWid → fabric spread + wave blend width
//   beat      → omnidirectional gravitational wave event
//   kick      → spacetime tear (localized fabric rupture)
//   transient → quantum fluctuations (high-freq surface jitter)
//   beatAnt   → pre-beat wave tension
//   envelope  → overall emission gain
//
// DSP additive (refinement only, never replaces brain):
//   LUFS → wave amplitude boost: amp *= (1.0 + lufs * 0.2)
//   crest → wave sharpness: sharpness *= (1.0 + crest * 0.5)
//   THD → surface roughness: phase += thd * noise * 0.05
//   phase coherence → wave coherence: lerp(0.3, 1.0, phaseCoh)
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
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define PHI 1.61803399
#define N_SOURCES 8
#define FABRIC_RADIUS 4.0
#define GRID_SPACING 0.25

// ── Wave source struct — positioned via audioSimElement ──
struct WaveSource {
    float2 pos;         // xz position on fabric (golden ratio + pan + scatter)
    float amplitude;
    float wavelength;
    float intensity;
    float pan;
    float freqFrac;
};

// ── Golden ratio distribution for wave sources ──
float2 sourceBasePos(int idx, float radius, float stereoBal, float stereoWid)
{
    float bt = float(idx) / float(N_SOURCES - 1);
    float ang = float(idx) * PHI * PI * 2.0 + stereoBal * PI;
    float r = lerp(0.3, radius * 0.85, bt);
    return float2(cos(ang) * r, sin(ang) * r) * (0.8 + stereoWid * 0.3);
}

// ── Distance attenuation — inverse square per 3D Spatial Audio Math ──
float distAtten(float d, float k)
{
    return 1.0 / (1.0 + k * d * d);
}

// ── Compute 8 wave sources using audioSimElement per DX12U rules ──
void computeSources(out WaveSource sources[N_SOURCES], AudioData a,
                    float crest, float lufs)
{
    float fabricR = FABRIC_RADIUS * (0.8 + a.stereoWid * 0.3);

    [unroll] for (int n = 0; n < N_SOURCES; n++)
    {
        AudioElement e = audioSimElement(n, N_SOURCES, a);

        // Position via golden ratio + stereo pan + transient scatter
        float2 base = sourceBasePos(n, fabricR, a.stereoBal, a.stereoWid);
        float2 panOff = e.panOffset * (1.0 + a.stereoWid);
        float2 scatter = float2(e.transientScatter, e.transientScatter * 0.7);
        sources[n].pos = base + panOff + scatter;
        sources[n].pan = e.pan;
        sources[n].freqFrac = e.freqFrac;

        // Noise gate per rules
        float gate = smoothstep(0.02, 0.08, e.amplitude);

        // Compressor curve per rules: bass pow(0.5), highs linear
        float energy = (n < 4) ? pow(max(e.intensity, 0.0), 0.5) : max(e.intensity, 0.0);

        // Amplitude — LUFS additive per rules
        sources[n].amplitude = energy * gate * (1.0 + lufs * 0.2);

        // Wavelength — golden ratio frequency compression: Cf = (Dx * PI) / PHI
        // Bass = long wavelength, highs = short wavelength
        float dx = lerp(2.0, 0.3, e.freqFrac);
        sources[n].wavelength = (dx * PI) / PHI * (1.0 + crest * 0.3);

        sources[n].intensity = energy * gate;
    }
}

// ── Spacetime fabric heightfield — wave interference from 8 sources ──
float fabricHeight(float2 xz, WaveSource sources[N_SOURCES],
                   float time, float beatPulse, float beatPhase,
                   float kickSurge, float transient, float thd, float envelope,
                   float lufs, float phaseCoh, float silence)
{
    float r = length(xz);
    if (r > FABRIC_RADIUS) return -1.0;

    // Base fabric level — LUFS additive per rules
    float surface = (0.01 + lufs * 0.015) * silence;

    // 8 wave sources — expanding circular waves with interference
    [unroll] for (int n = 0; n < N_SOURCES; n++)
    {
        if (sources[n].amplitude < 0.01) continue;
        float d = length(xz - sources[n].pos);
        float atten = distAtten(d, 0.1);

        // Wave phase — expanding ripple
        float waveSpeed = 1.5 + sources[n].freqFrac * 2.0;
        float phase = (d - time * waveSpeed * 0.3) / sources[n].wavelength * PI * 2.0;

        // Wave amplitude with distance attenuation
        float waveAmp = sources[n].amplitude * atten * 0.15;

        // Phase coherence → wave coherence per rules
        float coherence = lerp(0.3, 1.0, phaseCoh);
        float wave = sin(phase) * waveAmp * coherence;

        // Beat anticipation — pre-beat wave tension
        wave += sin(phase * 0.5) * waveAmp * 0.3 * (1.0 + beatPulse * 2.0);

        surface += wave;
    }

    // Beat — omnidirectional gravitational wave event
    float beatWave = beatPulse * 0.08 * sin(r * 4.0 - beatPhase * PI * 4.0) *
                     smoothstep(FABRIC_RADIUS, 0.0, r) * silence;
    surface += beatWave;

    // Kick — spacetime tear (localized rupture)
    surface -= kickSurge * 0.12 * exp(-r * r * 2.0) * silence;

    // Transient — quantum fluctuations (high-freq jitter) per rules: thd * noise
    if (transient > 0.02)
        surface += transient * 0.02 * sin(xz.x * 30.0 + xz.y * 28.0 + time * 40.0) *
                   smoothstep(FABRIC_RADIUS, 0.0, r) * silence * (0.5 + thd);

    // Envelope swell
    surface += envelope * 0.008 * smoothstep(FABRIC_RADIUS, 0.0, r) * silence;

    // Fabric edge — curve down into void
    surface -= smoothstep(FABRIC_RADIUS * 0.7, FABRIC_RADIUS, r) * 0.3;

    return surface;
}

// ── SDF — distance to fabric surface (kept for compatibility) ──
// Not used in grid mesh mode — replaced by ray-plane + bilinear interpolation

// ── Project 3D world point to screen space ──
float2 projectWorld(float3 worldPos, float3 camPos, float3 fwd, float3 right, float3 up, float fov)
{
    float3 toObj = worldPos - camPos;
    float depth = dot(toObj, fwd);
    if (depth < 0.01) depth = 0.01;
    return float2(dot(toObj, right) / (depth * fov), dot(toObj, up) / (depth * fov));
}

// ── Distance from point to line segment in 2D ──
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

    // ── Compute 8 wave sources using audioSimElement per DX12U rules ──
    WaveSource sources[N_SOURCES];
    computeSources(sources, a, dspCrest, dspLUFS);

    // ── Camera — above fabric, low angle looking across to horizon ──
    float FOV = 0.7;
    float camAng = a.stereoBal * 0.15 + a.section * 0.1 + Time * 0.015 * a.motSpeed;
    float camDist = 5.5;
    float camHeight = 1.8 + a.stereoDiff * 0.15;
    float3 camPos = float3(sin(camAng) * camDist, camHeight, cos(camAng) * camDist);
    float3 camTarget = float3(0.0, 0.0, 0.0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(fwd + p.x * right * FOV + p.y * up * FOV);

    // ── Background — deep spacetime void ──
    float3 col = float3(0.002, 0.001, 0.004) * silence;
    col += starfield(uv, a) * 0.015;
    float nebula = fbm2_4(p * 0.8 + Time * 0.003 * a.motSpeed);
    col += a.brainCol * nebula * 0.008 * a.ambient * a.ambActive * silence;

    // ── Raycast to base plane (y=0) ──
    float tPlane = -camPos.y / rd.y;
    float3 planeHit = camPos + rd * tPlane;
    float2 xz = planeHit.xz;
    float distFromCenter = length(xz);

    // Depth fade — grid fades into distance
    float depthFade = smoothstep(8.0, 1.0, tPlane) * smoothstep(0.0, 0.5, tPlane);
    // Radial fade — grid fades at edges
    float radialFade = smoothstep(FABRIC_RADIUS, 0.0, distFromCenter) * silence;

    if (tPlane > 0.0 && radialFade > 0.01)
    {
        // ── Grid cell lookup ──
        float2 gridCoord = xz / GRID_SPACING;
        float2 cellBase = floor(gridCoord);
        float2 cellFrac = frac(gridCoord);

        // ── Evaluate 4 corner heights ──
        float2 c0xz = (cellBase + float2(0, 0)) * GRID_SPACING;
        float2 c1xz = (cellBase + float2(1, 0)) * GRID_SPACING;
        float2 c2xz = (cellBase + float2(0, 1)) * GRID_SPACING;
        float2 c3xz = (cellBase + float2(1, 1)) * GRID_SPACING;

        float h0 = fabricHeight(c0xz, sources, Time, beatPulse, a.beatPhase,
                                kickSurge, a.transient, dspTHD, a.envelope,
                                dspLUFS, dspPhaseCoh, silence);
        float h1 = fabricHeight(c1xz, sources, Time, beatPulse, a.beatPhase,
                                kickSurge, a.transient, dspTHD, a.envelope,
                                dspLUFS, dspPhaseCoh, silence);
        float h2 = fabricHeight(c2xz, sources, Time, beatPulse, a.beatPhase,
                                kickSurge, a.transient, dspTHD, a.envelope,
                                dspLUFS, dspPhaseCoh, silence);
        float h3 = fabricHeight(c3xz, sources, Time, beatPulse, a.beatPhase,
                                kickSurge, a.transient, dspTHD, a.envelope,
                                dspLUFS, dspPhaseCoh, silence);

        // ── Bilinear interpolate surface height ──
        float surfH = lerp(lerp(h0, h1, cellFrac.x), lerp(h2, h3, cellFrac.x), cellFrac.y);

        // ── Project 4 corners to screen space ──
        float3 c0world = float3(c0xz.x, h0, c0xz.y);
        float3 c1world = float3(c1xz.x, h1, c1xz.y);
        float3 c2world = float3(c2xz.x, h2, c2xz.y);
        float3 c3world = float3(c3xz.x, h3, c3xz.y);

        float2 c0screen = projectWorld(c0world, camPos, fwd, right, up, FOV);
        float2 c1screen = projectWorld(c1world, camPos, fwd, right, up, FOV);
        float2 c2screen = projectWorld(c2world, camPos, fwd, right, up, FOV);
        float2 c3screen = projectWorld(c3world, camPos, fwd, right, up, FOV);

        // ── Grid line rendering — distance to each edge segment ──
        float2 tmpClosest;
        float dEdge01 = distToSeg2D(p, c0screen, c1screen, tmpClosest);
        float dEdge02 = distToSeg2D(p, c0screen, c2screen, tmpClosest);
        float dEdge13 = distToSeg2D(p, c1screen, c3screen, tmpClosest);
        float dEdge23 = distToSeg2D(p, c2screen, c3screen, tmpClosest);
        float minEdge = min(min(dEdge01, dEdge02), min(dEdge13, dEdge23));

        // ── Grid node glow — distance to each corner in screen space ──
        float dNode0 = length(p - c0screen);
        float dNode1 = length(p - c1screen);
        float dNode2 = length(p - c2screen);
        float dNode3 = length(p - c3screen);
        float minNode = min(min(dNode0, dNode1), min(dNode2, dNode3));

        // ── Find nearest wave source for frequency-positioned color ──
        float nearestSrcDist = 999.0;
        float nearestFreqFrac = 0.5;
        float nearestPan = 0.0;
        [unroll] for (int ns = 0; ns < N_SOURCES; ns++)
        {
            if (sources[ns].amplitude < 0.01) continue;
            float sd2 = dot(xz - sources[ns].pos, xz - sources[ns].pos);
            if (sd2 < nearestSrcDist) { nearestSrcDist = sd2; nearestFreqFrac = sources[ns].freqFrac; nearestPan = sources[ns].pan; }
        }

        // ── Color computation ──
        float3 freqCol = hsv(a.hueBase + nearestFreqFrac * a.hueRange, 0.6 * a.satur, 0.9);
        float3 brain = lerp(a.brainCol, a.brainCol2, nearestFreqFrac);
        brain = lerp(brain, freqCol, 0.3);

        // Height-based wave glow — crests glow warm, troughs stay dark
        float heightFrac = clamp(surfH * 2.0 + 0.3, 0.0, 1.0);
        float3 waveGlow = lerp(float3(0.3, 0.1, 0.03), float3(0.8, 0.4, 0.1), heightFrac);
        waveGlow = lerp(waveGlow, float3(1.0, 0.85, 0.6), pow(heightFrac, 3.0));

        // Phase coherence → field symmetry per rules
        float coherence = lerp(0.3, 1.0, dspPhaseCoh);
        float3 gridCol = lerp(brain, waveGlow, 0.4);
        gridCol = lerp(gridCol, gridCol.gbr, (1.0 - coherence) * 0.05);

        // Stereo L/R tint
        float sideTint = clamp(xz.x * 0.2 + nearestPan * 0.3, -1.0, 1.0);
        gridCol = lerp(gridCol, gridCol * float3(1.2, 0.9, 0.78), max(sideTint, 0.0) * a.stereoWid * 0.15);
        gridCol = lerp(gridCol, gridCol * float3(0.78, 0.9, 1.2), max(-sideTint, 0.0) * a.stereoWid * 0.15);

        // ── Grid lines — thin glowing wireframe ──
        float lineWidth = 0.002 / (1.0 + tPlane * 0.05);
        float lineIntensity = exp(-minEdge * minEdge / (lineWidth * lineWidth * 2.0));
        lineIntensity *= depthFade * radialFade;

        // Line color modulated by wave height at the nearest point on the line
        float lineHeightFrac = clamp(surfH * 2.0 + 0.3, 0.0, 1.0);
        float3 lineCol = gridCol * (0.3 + lineHeightFrac * 0.7);
        col += lineCol * lineIntensity * (0.4 + a.brightness * 0.3 + a.envelope * 0.3) * silence;

        // ── Grid nodes — glowing dots at intersections ──
        float nodeSize = 0.006 / (1.0 + tPlane * 0.08);
        float nodeIntensity = exp(-minNode * minNode / (nodeSize * nodeSize * 2.0));
        nodeIntensity *= depthFade * radialFade;

        // Node glow brighter at wave crests
        float nodeHeight = surfH;
        float crestGlow = smoothstep(0.02, 0.15, nodeHeight);
        float3 nodeCol = lerp(gridCol * 0.5, waveGlow, crestGlow);
        col += nodeCol * nodeIntensity * (0.5 + a.envelope * 0.5 + crestGlow * 0.5) * silence;

        // ── Wave crest glow — bright where surface is high ──
        float crestIntensity = crestGlow * depthFade * radialFade;
        col += waveGlow * crestIntensity * (0.15 + a.envelope * 0.3) * silence;

        // ── Beat — gravitational wave pulse through grid ──
        col += waveGlow * beatPulse * crestGlow * 0.06 * depthFade * radialFade * silence;

        // ── Kick — spacetime tear glow ──
        col += float3(1.0, 0.3, 0.05) * kickSurge * crestGlow * 0.3 * depthFade * radialFade * silence;

        // ── Transient — quantum fluctuation flash ──
        if (a.transient > 0.02)
            col += float3(0.8, 0.9, 1.0) * a.transient * crestGlow * 0.1 * depthFade * radialFade * silence;

        // ── ColorPulse ──
        col += a.brainCol3 * a.colorPulse * crestGlow * 0.02 * depthFade * radialFade * silence;

        // ── Dynamic + punch ──
        col += waveGlow * a.punch * crestGlow * 0.04 * depthFade * radialFade * silence;
    }

    // ── Beat ring — gravitational wave expanding outward ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.02 * silence;

    // ── Kick flash — spacetime tear ──
    col += float3(1.0, 0.4, 0.1) * kickSurge * 0.04 * exp(-r * r * 5.0) * silence;

    // ── Transient pop ──
    col += float3(0.8, 0.9, 1.0) * a.transient * 0.015 * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.015 * silence;

    // ── Energy + punch ──
    col += a.brainCol2 * a.energy * 0.01 * silence;
    col += a.brainCol * a.punch * 0.01 * silence;

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02 * silence;

    // ── HDR brightness limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.5) col *= 1.5 / maxC;

    return float4(col, 1.0);
}
