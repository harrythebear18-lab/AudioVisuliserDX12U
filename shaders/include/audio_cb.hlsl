// Shared AudioCB + TimeCB cbuffer definitions
// Finalized Hardware Telemetry Mirror — structured for brain data access
#ifndef AUDIO_CB_INCLUDED
#define AUDIO_CB_INCLUDED

// Grouping 1: Primary Transient Tracking and Phase Envelopes
struct BrainDynamics {
    float Beat;             // Tracked rhythm peak intensity
    float Trans;            // Instantaneous transient delta spike
    float Env;              // Smoothed envelope follower contour
    float Overall;          // Global RMS power across all channels
};

// Grouping 2: Multi-band Cross-over Matrix
struct FrequencySpectrum {
    float Sub;              // Sub-bass energy (0-60Hz)
    float Bass;             // Punchy bass region (60Hz-250Hz)
    float LMid;             // Low-mid instrumentation (250Hz-500Hz)
    float Mid;              // Centered mid frequencies (500Hz-2kHz)
    float HMid;             // High-mids / vocals (2kHz-4kHz)
    float Pres;             // Presence range (4kHz-6kHz)
    float Bril;             // Brilliance range (6kHz-12kHz)
    float Air;              // Air band high-end airiness (12kHz-20kHz)
};

// Grouping 3: Real-Time Spatial Field Mechanics
struct SpatialTelemetry {
    float2 StereoLR;        // x: Left channel RMS, y: Right channel RMS
    float Balance;          // Stereo balance vector (-1.0 to 1.0)
    float Width;            // Stereo image width factor (0.0 to 1.0)
    float Phase;            // Phase correlation coefficient (-1.0 to 1.0)
    float Anticip;          // Predictive Lookahead Transient metric
};

// Grouping 4: Macro Section Telemetry and Visual Constants
struct PerformanceRhythm {
    float BPM;              // Extracted Track BPM
    float Conf;             // Frequency tracker tracking confidence
    float KickWeight;       // Isolated kick drum trigger probability scalar
    float MoveSpeed;        // Audio velocity constant to drive noise evolution
};

cbuffer AudioBrainCB : register(b0)
{
    BrainDynamics      Dynamics;
    FrequencySpectrum  Spectrum;
    SpatialTelemetry   Spatial;
    PerformanceRhythm  Rhythm;
    
    float4 ColorPrimary;    // RGB values from Color() tracking array
    float4 ColorSecondary;  // RGB values from C2() tracking array
    
    float4 VisualModifiers; // x: Bright, y: Beam, z: Bloom, w: Ambient
    float4 SystemState;     // x: Phrase Progress, y: Eff, z: Pulse, w: SectionID
};

cbuffer TimeCB : register(b1)
{
    float GlobalTime;
    float DeltaTime;
    float2 RenderResolution;
};

Texture2D<float4> u_spectrum : register(t0);
SamplerState u_sampler : register(s0);

// Feedback texture — previous frame output for simulation memory
Texture2D<float4> u_feedback : register(t5);
SamplerState u_feedbackSampler : register(s1);

// Convenience struct — adapter so all 21 mode shaders work unchanged
struct AudioData {
    float beat, transient, envelope, overall;
    float bpm, tempoConf, kick, kickConf;
    float stereoBal, stereoWid, effectInt, motionSpd;
    float hueBase, hueCenter, hueRange, beatDet;
    float brightness, beam, bloom, dynLight;
    float ambient, atmos, phaseCorr, clarity;
    float burstTrig, burstType, burstInt, colorPulse;
    float dynActive, beamActive, ambActive, bloomActive;
    float groupMode, effectMode, beatCount, phraseBeat;
    float section, shouldChg, beatAnt, motionPers;
    float energy, profBass, profTreb, tempo;
    float punch, profStereo, dynamic, glow;
    float barScale, motSpeed, satur, persp;
    float leftEn, rightEn, sectionConf, silent;
    float specCent, specSpread, domFreq, domBand;
    float3 brainCol, brainCol2;
    float gated, isSilent;
    float b0, b1, b2, b3, b4, b5, b6, b7;
    float specL, specR, stereoDiff;
    float beatPeriod, beatPhase, tempoPulse;
    float speechMode, calmMode, voiceActivity, ambientLevel;
};

// Adapter: maps new structured cbuffer to flat AudioData used by all shaders
AudioData extractAudio() {
    AudioData a;
    
    // Dynamics
    a.beat = Dynamics.Beat;
    a.transient = Dynamics.Trans;
    a.envelope = Dynamics.Env;
    a.overall = Dynamics.Overall;
    
    // Rhythm
    a.bpm = Rhythm.BPM;
    a.tempoConf = Rhythm.Conf;
    a.kick = Rhythm.KickWeight;
    a.kickConf = Rhythm.Conf;
    a.motSpeed = Rhythm.MoveSpeed;
    
    // Spectrum bands
    a.b0 = Spectrum.Sub;
    a.b1 = Spectrum.Bass;
    a.b2 = Spectrum.LMid;
    a.b3 = Spectrum.Mid;
    a.b4 = Spectrum.HMid;
    a.b5 = Spectrum.Pres;
    a.b6 = Spectrum.Bril;
    a.b7 = Spectrum.Air;
    
    // Spatial
    a.stereoBal = Spatial.Balance;
    a.stereoWid = Spatial.Width;
    a.phaseCorr = Spatial.Phase;
    a.beatAnt = Spatial.Anticip;
    a.leftEn = Spatial.StereoLR.x;
    a.rightEn = Spatial.StereoLR.y;
    
    // Color
    a.brainCol = float3(ColorPrimary.x, ColorPrimary.y, ColorPrimary.z);
    a.brainCol2 = float3(ColorSecondary.x, ColorSecondary.y, ColorSecondary.z);
    a.hueBase = ColorPrimary.w;
    a.hueCenter = ColorSecondary.w;
    
    // Visual modifiers
    a.brightness = VisualModifiers.x;
    a.beam = VisualModifiers.y;
    a.bloom = VisualModifiers.z;
    a.ambient = VisualModifiers.w;
    a.dynLight = VisualModifiers.y * 0.5 + a.beat * 0.3;
    a.atmos = VisualModifiers.w * 0.5;
    
    // System state
    a.phraseBeat = SystemState.x;
    a.effectInt = SystemState.y;
    a.colorPulse = SystemState.z;
    a.section = SystemState.w;
    
    // Derive fields not directly in new cbuffer
    a.beatDet = a.beat;
    a.clarity = a.tempoConf;
    // hueRange widens with spectral clarity — more frequency variation = wider color spread
    a.hueRange = 0.15 + a.clarity * 0.35 + a.stereoWid * 0.1;
    
    // Triggers — derived from beat/transient
    a.burstTrig = step(0.7, a.transient);
    a.burstType = 0.0;
    a.burstInt = a.transient;
    
    // Active flags — derived from visual modifiers
    a.dynActive = step(0.01, a.dynLight);
    a.beamActive = step(0.01, a.beam);
    a.ambActive = step(0.01, a.ambient);
    a.bloomActive = step(0.01, a.bloom);
    
    // Group/section info
    a.groupMode = 0.0;
    a.effectMode = 0.0;
    a.beatCount = 0.0;
    a.shouldChg = 0.0;
    a.motionPers = 0.5;
    
    // Profile data — derived from spectrum
    a.energy = a.overall;
    a.profBass = (a.b0 + a.b1) * 0.5;
    a.profTreb = (a.b6 + a.b7) * 0.5;
    a.tempo = a.bpm / 120.0;
    a.punch = a.kick;
    a.profStereo = a.stereoWid;
    a.dynamic = a.transient;
    a.glow = a.bloom;
    a.barScale = 1.0;
    // Saturation is audio-reactive: rises with energy + kick, drops in silence
    a.satur = clamp(0.45 + a.overall * 0.4 + a.kick * 0.15, 0.3, 1.0);
    a.persp = 0.5;
    
    a.sectionConf = a.tempoConf;
    a.silent = step(a.overall, 0.005);
    a.specCent = 0.5;
    a.specSpread = 0.3;
    a.domFreq = 0.0;
    a.domBand = 0.0;
    
    // Gate
    float gate = 0.015;
    a.gated = max(a.overall - gate, 0.0) / (1.0 - gate);
    a.isSilent = step(a.overall, 0.005);
    
    // Speech detection
    float bassEnergy = (a.b0 + a.b1) * 0.5;
    float midEnergy = (a.b2 + a.b3 + a.b4) / 3.0;
    float bassRatio = bassEnergy / max(a.overall, 0.01);
    a.speechMode = smoothstep(0.35, 0.15, bassRatio) * smoothstep(0.3, 0.6, midEnergy) * (1.0 - a.tempoConf * 0.5);
    a.speechMode = clamp(a.speechMode, 0.0, 1.0);
    a.voiceActivity = a.transient * (0.5 + a.speechMode * 0.5);
    a.calmMode = 1.0 - smoothstep(0.0, 0.3, a.overall);
    a.ambientLevel = 0.15 + a.calmMode * 0.25 + a.speechMode * 0.1;
    
    // Spectrum texture sampling for stereo + fine-grained bands
    a.b0 = u_spectrum.SampleLevel(u_sampler, float2(0.02, 0.5), 0).r;
    a.b1 = u_spectrum.SampleLevel(u_sampler, float2(0.06, 0.5), 0).r;
    a.b2 = u_spectrum.SampleLevel(u_sampler, float2(0.12, 0.5), 0).r;
    a.b3 = u_spectrum.SampleLevel(u_sampler, float2(0.20, 0.5), 0).r;
    a.b4 = u_spectrum.SampleLevel(u_sampler, float2(0.30, 0.5), 0).r;
    a.b5 = u_spectrum.SampleLevel(u_sampler, float2(0.42, 0.5), 0).r;
    a.b6 = u_spectrum.SampleLevel(u_sampler, float2(0.55, 0.5), 0).r;
    a.b7 = u_spectrum.SampleLevel(u_sampler, float2(0.70, 0.5), 0).r;
    a.specL = u_spectrum.SampleLevel(u_sampler, float2(0.5, 0.166), 0).r;
    a.specR = u_spectrum.SampleLevel(u_sampler, float2(0.5, 0.833), 0).r;
    a.stereoDiff = a.specL - a.specR;
    
    // Beat timing
    a.beatPeriod = a.bpm > 1.0 ? 60.0 / a.bpm : 0.5;
    a.beatPhase = a.bpm > 1.0 ? frac(GlobalTime / a.beatPeriod) : 0.0;
    float beatPulse = a.bpm > 1.0 ? exp(-a.beatPhase * 6.0) * a.tempoConf : 0.0;
    float speechPulse = a.speechMode * sin(GlobalTime * 1.5) * 0.5 + 0.5;
    a.tempoPulse = lerp(beatPulse, speechPulse * a.voiceActivity, a.speechMode);
    return a;
}

float2 screenToAspect(float2 uv) {
    float2 p = (uv - 0.5) * 2.0;
    p.x *= RenderResolution.x / RenderResolution.y;
    return p;
}

// Backward-compat aliases — all 21 mode shaders use these names
#define Time GlobalTime
#define Width RenderResolution.x
#define Height RenderResolution.y
#define Aspect (RenderResolution.x / RenderResolution.y)

#endif // AUDIO_CB_INCLUDED
