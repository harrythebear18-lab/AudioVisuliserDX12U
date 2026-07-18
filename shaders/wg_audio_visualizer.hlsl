// WORK GRAPH AUDIO VISUALIZER — GPU-driven audio reactive rendering.
// Entry node reads all brain data from AudioCB and dispatches work to
// child nodes that process different aspects of the audio spectrum.
// Output: writes to a UAV texture (R16G16B16A16_Float) for compositing.

cbuffer AudioCB : register(b0)
{
    float4 Bands;             // sub, bass, low_mid, mid
    float4 Bands2;            // high_mid, presence, brilliance, air
    float4 Dynamics;          // beat_intensity, transient, envelope, overall
    float4 Rhythm;            // bpm, tempo_conf, kick_level, kick_conf
    float4 Stereo;            // balance, width, effect_int, movement_int
    float4 ColorHue;          // base_hue, section_hue_ctr, section_hue_rng, beat_detected
    float4 VisualIntensities; // brightness, beam, bloom, dynamic_light
    float4 VisualIntensities2;// ambient, atmosphere_density, phase_corr, spectral_clarity
    float4 VisualTriggers;    // effect_burst, burst_type, burst_intensity, color_pulse
    float4 VisualActive;      // dynamic_lights, beams, ambient, bloom
    float4 Group;             // behavior_mode, effect_mode, beat_count, phrase_beat
    float4 SectionInfo;       // section, beat_anticipation, should_change, motion_persistence
};

cbuffer TimeCB : register(b1)
{
    float Time;
    float Width;
    float Height;
    float Aspect;
};

// UAV output texture — work graph writes here
RWTexture2D<float4> OutputTex : register(u0);

// Brain data macros — ALL fields used
#define BAND_SUB        Bands.x
#define BAND_BASS       Bands.y
#define BAND_LOW_MID    Bands.z
#define BAND_MID        Bands.w
#define BAND_HIGH_MID   Bands2.x
#define BAND_PRESENCE   Bands2.y
#define BAND_BRILLIANCE Bands2.z
#define BAND_AIR        Bands2.w
#define BEAT_INTENSITY  Dynamics.x
#define TRANSIENT       Dynamics.y
#define ENVELOPE        Dynamics.z
#define OVERALL         Dynamics.w
#define BPM             Rhythm.x
#define TEMPO_CONF      Rhythm.y
#define KICK_LEVEL      Rhythm.z
#define KICK_CONF       Rhythm.w
#define STEREO_BALANCE  Stereo.x
#define STEREO_WIDTH    Stereo.y
#define EFFECT_INT      Stereo.z
#define MOVEMENT_INT    Stereo.w
#define BASE_HUE        ColorHue.x
#define SECTION_HUE_CTR ColorHue.y
#define SECTION_HUE_RNG ColorHue.z
#define BEAT_DETECTED   ColorHue.w
#define BRIGHTNESS      VisualIntensities.x
#define BEAM_INTENSITY  VisualIntensities.y
#define BLOOM_INTENSITY VisualIntensities.z
#define DYNAMIC_LIGHT   VisualIntensities.w
#define AMBIENT_LIGHT   VisualIntensities2.x
#define ATMOSPHERE      VisualIntensities2.y
#define PHASE_CORR      VisualIntensities2.z
#define SPECTRAL_CLARITY VisualIntensities2.w
#define EFFECT_BURST    VisualTriggers.x
#define BURST_TYPE      VisualTriggers.y
#define BURST_INTENSITY VisualTriggers.z
#define COLOR_PULSE     VisualTriggers.w
#define DYN_LIGHTS_ACT  VisualActive.x
#define BEAMS_ACTIVE    VisualActive.y
#define AMBIENT_ACTIVE  VisualActive.z
#define BLOOM_ACTIVE    VisualActive.w
#define BEHAVIOR_MODE   Group.x
#define EFFECT_MODE     Group.y
#define BEAT_COUNT      Group.z
#define PHRASE_BEAT     Group.w
#define SECTION         SectionInfo.x
#define BEAT_ANTICIP    SectionInfo.y
#define SHOULD_CHANGE   SectionInfo.z
#define MOTION_PERSIST  SectionInfo.w

#define PI 3.14159265359

float3 hsv(float h, float s, float v) {
    float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    float3 p = abs(frac(float3(h, h, h) + K.xyz) * 6.0 - K.www);
    return v * lerp(K.xxx, saturate(p - K.xxx), s);
}

float hash21(float2 p) { return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

float noise(float2 p) {
    float2 i = floor(p), f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(hash21(i), hash21(i + float2(1, 0)), f.x),
               lerp(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), f.x), f.y);
}

float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    [loop] for (int i = 0; i < 5; i++) { v += a * noise(p); p *= 2.1; a *= 0.5; }
    return v;
}

// Record types for work graph node communication
struct EntryRecord {
    uint2 dispatchDims;     // output texture dimensions
    uint2 padding;
};

struct TileRecord {
    uint2 tileOrigin;       // pixel offset of this tile
    uint2 tileSize;         // tile dimensions
    float bandLevels[8];    // per-tile band levels
    float beatIntensity;
    float kickLevel;
    float brightness;
    float baseHue;
    float phaseCorr;
    float spectralClarity;
    float beatAnticip;
    float motionPersist;
    float stereoWidth;
    float stereoBalance;
    float atmosphere;
    float bloomIntensity;
    float colorPulse;
    float effectBurst;
    float burstIntensity;
    float time;
    float aspect;
    uint effectMode;
    uint section;
    float phraseBeat;
    float bpm;
    float tempoConf;
    float transient;
    float envelope;
    float overall;
    float ambientLight;
    float dynamicLight;
    float beamIntensity;
    float padding2;
};

// Entry node — reads brain data, divides screen into tiles, dispatches tile nodes
[Node("entry", 1, false)]
void EntryNode(
    [MaxRecords(8)] NodeOutput<TileRecord> tileOutput,
    uint2 dispatchDims : SV_DispatchGrid)
{
    // dispatchDims comes from DispatchGraph — set to (tilesX, tilesY, 1)
    uint tilesX = dispatchDims.x;
    uint tilesY = dispatchDims.y;

    uint tileW = (uint)(Width + tilesX - 1) / tilesX;
    uint tileH = (uint)(Height + tilesY - 1) / tilesY;

    // Collect all brain data into a record for each tile
    float bands[8] = {
        BAND_SUB, BAND_BASS, BAND_LOW_MID, BAND_MID,
        BAND_HIGH_MID, BAND_PRESENCE, BAND_BRILLIANCE, BAND_AIR
    };

    // Dispatch one tile record per grid cell
    GroupNodeOutputRecords<TileRecord> records =
        tileOutput.GroupNodeOutputRecords(tilesX * tilesY);

    for (uint ty = 0; ty < tilesY; ty++)
    {
        for (uint tx = 0; tx < tilesX; tx++)
        {
            uint idx = ty * tilesX + tx;
            TileRecord rec = (TileRecord)0;
            rec.tileOrigin = uint2(tx * tileW, ty * tileH);
            rec.tileSize = uint2(tileW, tileH);

            // Per-tile band modulation — each tile emphasizes different bands
            // based on its position (left=bass, right=treble)
            float xFrac = (float)tx / max(1, tilesX - 1);
            for (int b = 0; b < 8; b++)
            {
                float weight = 1.0 - abs(xFrac - (float)b / 7.0) * 2.0;
                weight = saturate(weight);
                rec.bandLevels[b] = bands[b] * (0.5 + weight * 1.5);
            }

            rec.beatIntensity = BEAT_INTENSITY;
            rec.kickLevel = KICK_LEVEL;
            rec.brightness = BRIGHTNESS;
            rec.baseHue = BASE_HUE;
            rec.phaseCorr = PHASE_CORR;
            rec.spectralClarity = SPECTRAL_CLARITY;
            rec.beatAnticip = BEAT_ANTICIP;
            rec.motionPersist = MOTION_PERSIST;
            rec.stereoWidth = STEREO_WIDTH;
            rec.stereoBalance = STEREO_BALANCE;
            rec.atmosphere = ATMOSPHERE;
            rec.bloomIntensity = BLOOM_INTENSITY;
            rec.colorPulse = COLOR_PULSE;
            rec.effectBurst = EFFECT_BURST;
            rec.burstIntensity = BURST_INTENSITY;
            rec.time = Time;
            rec.aspect = Aspect;
            rec.effectMode = (uint)EFFECT_MODE;
            rec.section = (uint)SECTION;
            rec.phraseBeat = PHRASE_BEAT;
            rec.bpm = BPM;
            rec.tempoConf = TEMPO_CONF;
            rec.transient = TRANSIENT;
            rec.envelope = ENVELOPE;
            rec.overall = OVERALL;
            rec.ambientLight = AMBIENT_LIGHT;
            rec.dynamicLight = DYNAMIC_LIGHT;
            rec.beamIntensity = BEAM_INTENSITY;

            records.GetRecord(idx) = rec;
        }
    }
}

// Tile render node — processes one tile of the output texture
[Node("renderTile")]
[NodeDispatchGrid(8, 8, 1)]
void RenderTileNode(
    DispatchNodeInputRecord<TileRecord> input,
    uint2 globalIdx : SV_DispatchThreadId,
    uint2 groupIdx : SV_GroupThreadId,
    uint2 groupID : SV_GroupId)
{
    TileRecord rec = input.Get();

    // Map group thread ID to pixel coordinates
    uint2 pixelCoord = rec.tileOrigin + groupIdx;
    if (pixelCoord.x >= (uint)Width || pixelCoord.y >= (uint)Height)
        return;

    // Normalized coordinates
    float2 uv = (float2(pixelCoord) + 0.5) / float2(Width, Height);
    float2 p = (uv - 0.5) * 2.0;
    p.x *= rec.aspect;

    float t = rec.time;
    float brightness = 0.1 + rec.brightness * 0.9;

    // Background — deep gradient with brain-driven atmosphere
    float3 col = float3(0.008, 0.006, 0.02) * brightness;
    col += float3(0.003, 0.001, 0.008) * (1.0 - uv.y);

    // Bass-driven background glow
    float bgGlow = exp(-length(p) * 1.2) * rec.bandLevels[1] * 0.15;
    col += hsv(rec.baseHue, 0.7, 1.0) * bgGlow * brightness;

    // Audio-reactive ring patterns driven by all bands
    float r = length(p);
    float a = atan2(p.y, p.x);

    // Spectral clarity — sharper ring patterns
    float ringCount = 3.0 + rec.spectralClarity * 4.0;
    float rings = sin(r * ringCount * PI * 2.0 - t * 2.0);
    rings = smoothstep(0.3, 0.7, rings);

    // Each band contributes to a different ring layer
    float ringMask = 0.0;
    for (int b = 0; b < 8; b++)
    {
        float ringR = 0.3 + b * 0.1;
        float ring = exp(-abs(r - ringR) * 8.0) * rec.bandLevels[b];
        ringMask += ring;
    }
    col += hsv(rec.baseHue + r * 0.1, 0.8, 1.0) * ringMask * brightness * 0.5;

    // Beat shockwave — expanding ring
    float shockDecay = lerp(20.0, 10.0, rec.motionPersist);
    float shockR = frac(t * 0.3) * 1.5;
    float shock = exp(-abs(r - shockR) * shockDecay) * rec.beatIntensity;
    col += hsv(rec.baseHue + 0.5, 0.8, 1.0) * shock * 2.0;

    // Kick eruption — center burst
    col += hsv(rec.baseHue, 0.4, 1.0) * exp(-r * 3.0) * rec.kickLevel * 0.3;

    // Beat anticipation — pre-compression glow
    col += hsv(rec.baseHue + 0.1, 0.3, 1.0) * rec.beatAnticip * 0.1 * brightness;

    // Phase correlation — asymmetric L/R flow
    float phaseFlow = (1.0 - rec.phaseCorr) * p.x * 0.15;
    col += hsv(rec.baseHue + phaseFlow, 0.6, 0.8) * 0.05;

    // Stereo width — widen/narrow visual field
    float stereoExpand = 1.0 + rec.stereoWidth * 0.3;
    float2 stereoP = p * stereoExpand;
    float stereoGlow = exp(-length(stereoP) * 1.5) * rec.stereoBalance * 0.1;
    col += hsv(rec.baseHue + 0.3, 0.5, 1.0) * stereoGlow;

    // Effect burst — explosion of color
    if (rec.effectBurst > 0.5)
    {
        float burst = exp(-length(p) * 2.0) * rec.burstIntensity;
        col += hsv(rec.baseHue + 0.3, 0.5, 1.0) * burst * 2.0;
        float rays = pow(abs(sin(a * 16.0)), 25.0) * burst;
        col += hsv(rec.baseHue + 0.5, 0.8, 1.0) * rays * 1.0;
    }

    // Color pulse — beat-driven hue swell
    if (rec.colorPulse > 0.01)
    {
        col *= 1.0 + rec.colorPulse * 0.2;
        col += hsv(rec.baseHue, 0.3, 1.0) * rec.colorPulse * 0.05 * brightness;
    }

    // Atmosphere haze
    col += hsv(rec.baseHue, 0.15, 1.0) * rec.atmosphere * 0.03;

    // Dynamic light — directional glow
    float lightAngle = t * 0.5 + rec.section * 0.3;
    float2 lightDir = float2(cos(lightAngle), sin(lightAngle));
    float lightGlow = max(0, dot(normalize(p + 0.001), lightDir)) * rec.dynamicLight * 0.15;
    col += hsv(rec.baseHue + 0.2, 0.6, 1.0) * lightGlow;

    // Ambient light — base illumination
    col += hsv(rec.baseHue, 0.2, 0.5) * rec.ambientLight * 0.05;

    // Beam intensity — focused light shafts
    float beam = pow(max(0, sin(a + t * 0.3)), 20.0) * rec.beamIntensity * 0.2;
    col += hsv(rec.baseHue + 0.1, 0.7, 1.0) * beam;

    // Bloom — glow on bright areas
    if (rec.bloomIntensity > 0.01)
    {
        float glow = max(0, max(col.r, max(col.g, col.b)) - 0.6);
        col += col * glow * rec.bloomIntensity * 0.8;
    }

    // Phrase beat — slow rotation modulation
    float phraseRot = rec.phraseBeat * PI / 16.0;
    float2 rotP = mul(float2x2(cos(phraseRot), -sin(phraseRot), sin(phraseRot), cos(phraseRot)), p);
    col += hsv(rec.baseHue + 0.4, 0.5, 1.0) * exp(-length(rotP) * 4.0) * 0.02;

    // Tone map
    col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
    col = pow(col, float3(0.85, 0.88, 0.95));

    // Vignette
    float vig = 1.0 - dot(uv - 0.5, uv - 0.5) * 0.4;
    col *= vig;

    // Film grain
    float grain = hash21(uv * float2(Width, Height) + t) * 0.015 - 0.0075;
    col += grain;

    // Write to output texture
    OutputTex[pixelCoord] = float4(col, 1.0);
}
