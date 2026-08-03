// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 32: Acoustic Pressure Chamber — volumetric pressure field in a wireframe room
// VR Layer mode. Uses spatial_encoder.hlsl with SE_PROFILE_PSYCHOACOUSTIC.
//
// Concept: Sound fills a room as a 3D pressure field. Each emitter is a pressure
// source whose intensity, frequency, and position are driven by the full audio brain.
// The interference between sources creates the acoustic landscape. The room wireframe
// responds to frequency-localized energy: bass shakes the floor, highs light the ceiling,
// mids illuminate the walls. Between beats, envelope and band energy sustain the field.
//
// Audio-to-visual mapping:
//   b0 (sub)    → floor pressure ripples + floor edge glow
//   b1 (bass)   → floor wireframe pulse + low shockfronts
//   b2-b5 (mids)→ wall edge glow + side pressure blobs
//   b6-b7 (highs)→ ceiling edge glow + high pressure shimmer
//   beat/kick   → expanding shockfronts from listener
//   transient   → surface disruption sparks
//   envelope    → sustained pressure field density
//   stereoBal   → L/R asymmetric pressure distribution
//   stereoWid   → wider field spread
//   phaseCoh    → coherent (tight) vs diffuse (wide) field
//   section     → room size / camera repositioning
//   phraseBeat  → slow evolution of pressure pattern
//   speechMode  → vocal band (b3-b5) emphasis
//   calmMode    → reduced intensity floor
//   brightness  → global visual scaling
//   glow        → sustained ambient brightness
//   colorPulse  → hue cycling
//   beatAnt     → anticipatory swell before beats
//
// DSP additive:
//   LUFS→field density, crest→pressure sharpness, THD→surface roughness,
//   phase→L/R coherence. HDR output to Layer 0. No local postfx.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265

// ── Room dimensions ──
#define ROOM_HALF_W 3.0
#define ROOM_CEIL   2.5
#define ROOM_FLOOR -1.5
#define ROOM_BACK  -5.0

// ── Room wireframe — 12 edges, each driven by frequency-localized energy ──
float3 roomWireframe(float2 p, SeCamera cam, AudioData a,
                     float envelope, float lufs, float kickSurge,
                     float beatPulse, float silence)
{
    float3 col = float3(0, 0, 0);

    float3 c000 = float3(-ROOM_HALF_W, ROOM_FLOOR, 0.0);
    float3 c100 = float3( ROOM_HALF_W, ROOM_FLOOR, 0.0);
    float3 c010 = float3(-ROOM_HALF_W, ROOM_CEIL,  0.0);
    float3 c110 = float3( ROOM_HALF_W, ROOM_CEIL,  0.0);
    float3 c001 = float3(-ROOM_HALF_W, ROOM_FLOOR, ROOM_BACK);
    float3 c101 = float3( ROOM_HALF_W, ROOM_FLOOR, ROOM_BACK);
    float3 c011 = float3(-ROOM_HALF_W, ROOM_CEIL,  ROOM_BACK);
    float3 c111 = float3( ROOM_HALF_W, ROOM_CEIL,  ROOM_BACK);

    float3 edges[12][2] = {
        {c000, c100}, {c010, c110}, {c001, c101}, {c011, c111},
        {c000, c010}, {c100, c110}, {c001, c011}, {c101, c111},
        {c000, c001}, {c100, c101}, {c010, c011}, {c110, c111}
    };

    // Frequency-localized energy for each surface
    float floorE = (a.b0 + a.b1) * 0.5 * (1.0 + lufs * 0.3);
    float ceilE  = (a.b6 + a.b7) * 0.5 * (1.0 + lufs * 0.2);
    float wallE  = (a.b2 + a.b3 + a.b4 + a.b5) * 0.25;
    // Speech mode boosts vocal bands on walls
    wallE *= (1.0 + a.speechMode * 0.4);
    // Glow modifier sustains edge brightness
    float glowMod = a.glow * 0.3 + a.brightness * 0.2;
    // Phrase evolution slowly shifts which surfaces are emphasized
    float phraseShift = sin(a.phraseBeat * PI * 2.0) * 0.15;

    [unroll] for (int i = 0; i < 12; i++) {
        float2 a0 = seProject(edges[i][0], cam);
        float2 a1 = seProject(edges[i][1], cam);

        float2 ab = a1 - a0;
        float len2 = dot(ab, ab);
        if (len2 < 0.0001) continue;
        float t = saturate(dot(p - a0, ab) / len2);
        float2 closest = a0 + ab * t;
        float dist = length(p - closest);

        // Thin bright line with slight bloom
        float lineIntensity = exp(-dist * dist * 600.0);

        // Depth fade
        float3 midPoint = lerp(edges[i][0], edges[i][1], 0.5);
        float depth = seDepth(midPoint, cam);
        float depthFade = exp(-depth * 0.06);

        // Energy by surface type
        float energy;
        float3 edgeCol;
        if (i < 4) {
            // Floor/ceiling X edges — split by Y
            if (edges[i][0].y < 0.0) {
                energy = floorE + kickSurge * 0.5;
                edgeCol = a.brainCol; // warm = floor/bass
            } else {
                energy = ceilE + a.b7 * 0.3;
                edgeCol = a.brainCol3; // cool = ceiling/highs
            }
        } else if (i < 8) {
            // Vertical edges — wall energy
            energy = wallE + phraseShift * wallE;
            edgeCol = a.brainCol2; // mid = walls
        } else {
            // Depth edges — mixed
            energy = wallE * 0.6 + floorE * 0.2 + ceilE * 0.2;
            edgeCol = lerp(a.brainCol, a.brainCol3, 0.5);
        }

        // Beat pulse brightens all edges
        energy += beatPulse * 0.3 * envelope;
        // Sustained glow
        energy += glowMod;
        // Calm mode reduces floor
        energy *= (1.0 - a.calmMode * 0.3);

        col += edgeCol * lineIntensity * energy * depthFade * 0.2 * silence;
    }

    return col;
}

// ── Pressure field — 16-source culled emitters as volumetric blobs ──
// Each emitter contributes a soft pressure region. Interference = additive overlap.
// This is distinct from mode 31's ILD beams — here we render the field itself.
float3 pressureField(float2 p, SeEmitter emit[SE_NUM_OBJ], SeWorld world,
                     float lufs, float crest, float beatPulse, float beatPhase,
                     float kickSurge, float transientAmt, float silence)
{
    float3 col = float3(0, 0, 0);

    [loop] for (int bi = 0; bi < SE_N_BANDS; bi++) {
        int li = bi * SE_N_SUB * 2 + 2;  // si=1, left (16-source culling)
        int ri = bi * SE_N_SUB * 2 + 3;  // si=1, right

        // Left pressure blob
        if (emit[li].active > 0.01 && emit[li].depth > 0.1) {
            float2 diff = p - emit[li].screenPos;
            float d2 = dot(diff, diff);
            float s = emit[li].screenSize;
            float s2 = s * s;
            if (d2 < s2 * 40.0) {
                // Soft pressure blob — two layers
                float halo = exp(-d2 / (s2 * 10.0));
                float core = exp(-d2 / (s2 * 1.5));

                // Intensity from emitter (already enriched with beatAnt, punch, glow, phrase, speech)
                float intensity = emit[li].intensity * emit[li].depthFog * emit[li].nearFade;
                // Crest sharpens the core (dynamic range = sharper sources)
                float coreSharp = core * (0.5 + crest * 0.5);
                // LUFS boosts overall field density
                intensity *= (1.0 + lufs * 0.2);

                col += emit[li].color * halo * intensity * 0.08 * silence;
                col += emit[li].color * coreSharp * intensity * 0.15 * silence;

                // Kick flash on bass bands
                if (bi <= 1) {
                    col += float3(1.0, 0.5, 0.15) * core * kickSurge * intensity * 0.1 * silence;
                }
                // Transient scatter on mid/high bands
                if (bi >= 4 && transientAmt > 0.1) {
                    col += emit[li].color * core * transientAmt * intensity * 0.08 * silence;
                }
                // Beat pulse ring from each source
                float beatR = beatPhase * s * 5.0;
                float beatRing = exp(-abs(sqrt(d2) - beatR) * 40.0 / emit[li].depth);
                col += emit[li].color * beatRing * beatPulse * intensity * 0.04 * silence;
            }
        }

        // Right pressure blob (same logic)
        if (emit[ri].active > 0.01 && emit[ri].depth > 0.1) {
            float2 diff = p - emit[ri].screenPos;
            float d2 = dot(diff, diff);
            float s = emit[ri].screenSize;
            float s2 = s * s;
            if (d2 < s2 * 40.0) {
                float halo = exp(-d2 / (s2 * 10.0));
                float core = exp(-d2 / (s2 * 1.5));

                float intensity = emit[ri].intensity * emit[ri].depthFog * emit[ri].nearFade;
                float coreSharp = core * (0.5 + crest * 0.5);
                intensity *= (1.0 + lufs * 0.2);

                col += emit[ri].color * halo * intensity * 0.08 * silence;
                col += emit[ri].color * coreSharp * intensity * 0.15 * silence;

                if (bi <= 1) {
                    col += float3(1.0, 0.5, 0.15) * core * kickSurge * intensity * 0.1 * silence;
                }
                if (bi >= 4 && transientAmt > 0.1) {
                    col += emit[ri].color * core * transientAmt * intensity * 0.08 * silence;
                }
                float beatR = beatPhase * s * 5.0;
                float beatRing = exp(-abs(sqrt(d2) - beatR) * 40.0 / emit[ri].depth);
                col += emit[ri].color * beatRing * beatPulse * intensity * 0.04 * silence;
            }
        }
    }

    return col;
}

// ── Floor pressure ripples — bass-driven standing waves on floor grid ──
float3 floorRipples(float2 p, SeCamera cam, AudioData a, float kickSurge,
                    float beatPulse, float beatPhase, float silence)
{
    float3 col = float3(0, 0, 0);
    float3 rd = normalize(cam.fwd + p.x * cam.right * cam.fov + p.y * cam.up * cam.fov);
    float tFloor = (ROOM_FLOOR - cam.pos.y) / (rd.y + 1e-5);
    if (tFloor <= 0.0 || tFloor > 30.0) return col;

    float3 hitPos = cam.pos + rd * tFloor;
    float2 fc = hitPos.xz;
    if (abs(fc.x) > ROOM_HALF_W || fc.y > 0.0 || fc.y < ROOM_BACK) return col;

    float r = length(fc);
    float bassE = (a.b0 + a.b1) * 0.5;

    // Standing wave pattern — bass modes
    float mode1 = cos(fc.x * PI * 0.5) * cos(fc.y * PI * 0.3);
    float mode2 = cos(fc.x * PI * 1.0) * cos(fc.y * PI * 0.6);
    float modalPressure = (mode1 * 0.6 + mode2 * 0.4) * bassE;

    // Beat ripple — expanding ring from center
    float beatR = beatPhase * 3.0;
    float beatRing = exp(-abs(r - beatR) * 8.0) * beatPulse * 0.5;

    // Kick — central eruption
    float kickRipple = exp(-r * r * 2.0) * kickSurge * 0.8;

    // Grid lines
    float2 gridUV = float2(fc.x * 2.5, -fc.y * 2.0);
    float2 gridId = abs(frac(gridUV) - 0.5);
    float gridLine = smoothstep(0.4, 0.5, max(gridId.x, gridId.y));
    float gridFade = smoothstep(0.0, 5.0, tFloor) * smoothstep(25.0, 8.0, tFloor);

    // Pressure modulates grid brightness
    float pressureGlow = abs(modalPressure) * 0.15 + beatRing + kickRipple;
    col += a.brainCol * gridLine * 0.04 * gridFade * silence;
    col += a.brainCol * pressureGlow * gridLine * 0.15 * gridFade * silence;
    col += a.brainCol2 * pressureGlow * 0.03 * gridFade * silence; // fill between lines

    // Kick warm flash
    col += float3(1.0, 0.5, 0.15) * kickRipple * gridLine * 0.1 * gridFade * silence;

    return col;
}

// ── Reverb field — diffuse ambient from envelope + band energy ──
float3 reverbField(float2 p, float r, AudioData a, float envelope, float lufs,
                   float phaseCoh, float silence)
{
    // Dense reverb from envelope + LUFS
    float reverbDensity = envelope * (0.4 + lufs * 0.4);
    // Diffuse field is wider when phase is decorrelated
    float diffuseWidth = lerp(0.8, 1.5, 1.0 - phaseCoh);

    float3 col = a.brainCol2 * reverbDensity * 0.012 * exp(-r * r * 0.3 * diffuseWidth) * silence;
    // High-freq reverb shimmer — decays faster
    float trebleE = (a.b6 + a.b7) * 0.5;
    col += a.brainCol3 * trebleE * reverbDensity * 0.006 * exp(-r * r * 0.8) * silence;
    // Glow sustents ambient
    col += a.brainCol * a.glow * 0.004 * exp(-r * r * 0.2) * silence;
    // Calm mode adds quiet ambient
    col += a.brainCol3 * a.calmMode * a.ambientLevel * 0.003 * silence;

    return col;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    // ── DSP additive ──
    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();

    // ── Audio dynamics — full brain data ──
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;

    // ── Camera — VR head pose or desktop orbit ──
    SeCamera cam;
    if (VR_ACTIVE) {
        cam = seCameraVR();
    } else {
        float FOV = 0.75;
        // Section drives camera repositioning, stereoBal for L/R lean
        float camAng = a.section * 0.15 + a.stereoBal * 0.08 + Time * 0.003 * a.motSpeed;
        float3 camPos = float3(sin(camAng) * 2.5, 0.5 + a.stereoDiff * 0.15, 2.0 + cos(camAng) * 0.8);
        cam = seCamera(camPos, float3(0, 0, -2.5), FOV);
    }

    // ── Spatial encoder: PSYCHOACOUSTIC profile ──
    SeParams params = seParams(SE_PROFILE_PSYCHOACOUSTIC);
    params.widthScale = 2.5 + a.stereoWid * 0.5;  // stereo width widens room
    params.heightScale = 2.0;
    params.depthScale = 4.0 - a.calmMode * 0.5;   // calm mode compresses depth
    params.jitterAmt = 0.1 + thd * 0.15;
    params.stereoWid = a.stereoWid;
    params.stereoBal = a.stereoBal;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    SeEmitter emit[SE_NUM_OBJ];
    seComputeEmitters(emit, bands, a, cam, params,
                      lufs, crest, thd, phaseCoh,
                      beatPulse, kickSurge, transientAmt, envelope);

    // ── World environment ──
    SeWorld world = seWorld(0.06, float3(0.003, 0.002, 0.008), ROOM_FLOOR, ROOM_CEIL, ROOM_BACK);
    world.gridScale = 2.5;
    world.gridIntensity = 0.025;
    world.ambientLevel = 0.003 + a.calmMode * 0.002;
    world.ambientColor = float3(0.008, 0.006, 0.015);
    world.flags = 7;  // floor + ceiling + back wall
    seApplyWorldFog(emit, world);

    // ── Background: room environment + starfield ──
    float3 col = seWorldEnvironment(p, cam, world, a, kickSurge, silence);
    col += starfield(uv, a) * 0.003;

    // ── PRIMARY: Pressure field — 16-source volumetric blobs with interference ──
    col += pressureField(p, emit, world, lufs, crest, beatPulse, a.beatPhase,
                         kickSurge, transientAmt, silence) * 3.0;

    // ── PRIMARY: Room wireframe — frequency-localized edge glow ──
    col += roomWireframe(p, cam, a, envelope, lufs, kickSurge, beatPulse, silence) * 2.5;

    // ── SECONDARY: Floor pressure ripples — bass standing waves ──
    col += floorRipples(p, cam, a, kickSurge, beatPulse, a.beatPhase, silence) * 2.0;

    // ── SECONDARY: Reverb field — diffuse ambient from envelope + bands ──
    col += reverbField(p, r, a, envelope, lufs, phaseCoh, silence);

    // ── Listener focal point — spatial anchor ──
    col += seListener(p, cam, a, beatPulse, kickSurge, silence);

    // ── Dynamic range — quiet passages dark, gated ──
    col *= (0.25 + a.gated * 0.75);

    // ── Standard overlays (sparing) ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── Active-emitter normalization ──
    col *= sqrt(16.0 / seActiveCount(emit));

    // ── HDR limiter per pipeline rules ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.2) col *= 1.2 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
