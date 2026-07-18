using System;
using System.Numerics;
using StageSimWASAPI;

namespace DXRenderer;

/// <summary>
/// Visual-side smoothing / decay filter.
/// Takes raw VisualFrame data from the audio brain and applies a sine-decay
/// envelope so visuals feel smooth and punchy without altering the audio path.
/// </summary>
public class VisualSmoother
{
    private bool _firstFrame = true;

    private float _smBeat, _smKick, _smTransient, _smEnvelope, _smOverall;
    private float _smB0, _smB1, _smB2, _smB3, _smB4, _smB5, _smB6, _smB7;
    private float _smBrightness, _smBloom, _smBeam, _smDynLight, _smAmbient;
    private float _smEffect, _smMovement;
    private float _smStereoBal, _smStereoWid;
    private float _smHue;
    private float _smPhaseCorr, _smBeatAnt, _smClarity;

    // Performance parameters produced by VisualDirectorBot and decayed here as the last CPU stage.
    private float _smIntensity = 1.0f, _smPulse, _smAccent, _smColorShift, _smSpeed = 1.0f, _smZoom = 1.0f, _smFeedback;
    private bool _firstPerf = true;

    /// <summary>
    /// Sine-curved decay: instant attack, smooth release.
    /// </summary>
    public static float SineDecay(float current, float target, float release)
    {
        if (target >= current)
            return target;
        float t = 1f - MathF.Cos(release * MathF.PI * 0.5f);
        return current + (target - current) * t;
    }

    private static float LerpHue(float a, float b, float t)
    {
        float diff = b - a;
        if (diff > 0.5f) diff -= 1f;
        else if (diff < -0.5f) diff += 1f;
        return (a + diff * t + 1f) % 1f;
    }

    /// <summary>
    /// Final CPU stage: decay the raw brain frame and the director's raw performance targets,
    /// then build the AudioUBO that is uploaded to the GPU. The director writes the targets;
    /// this method is the only place those targets are smoothed.
    /// </summary>
    public AudioUBO Smooth(RenderGraph graph, QuadBufferedVisuals.VisualFrame f)
    {
        var ubo = SmoothFrame(f);
        ApplyPerformanceParams(ref ubo, graph);
        return ubo;
    }

    /// <summary>
    /// Smooth the raw brain frame values only.
    /// </summary>
    private AudioUBO SmoothFrame(QuadBufferedVisuals.VisualFrame f)
    {
        float fast = 0.20f;
        float med = 0.12f;
        float slow = 0.08f;

        if (_firstFrame)
        {
            _smBeat = f.BeatIntensity; _smKick = f.KickLevel;
            _smTransient = f.Transient; _smEnvelope = f.Envelope; _smOverall = f.Overall;
            _smB0 = f.Band0; _smB1 = f.Band1; _smB2 = f.Band2; _smB3 = f.Band3;
            _smB4 = f.Band4; _smB5 = f.Band5; _smB6 = f.Band6; _smB7 = f.Band7;
            _smBrightness = f.Brightness; _smBloom = f.BloomIntensity;
            _smBeam = f.BeamIntensity; _smDynLight = f.DynamicLightIntensity;
            _smAmbient = f.AmbientLightIntensity; _smEffect = f.EffectIntensity;
            _smMovement = f.MovementIntensity; _smStereoBal = f.StereoBalance;
            _smStereoWid = f.StereoWidth; _smHue = f.BaseHue;
            _smPhaseCorr = f.PhaseCorrelation; _smBeatAnt = f.BeatAnticipation;
            _smClarity = f.SpectralClarity;
            _firstFrame = false;
        }
        else
        {
            _smBeat = SineDecay(_smBeat, f.BeatIntensity, fast);
            _smKick = SineDecay(_smKick, f.KickLevel, fast);
            _smTransient = SineDecay(_smTransient, f.Transient, fast);
            _smEnvelope = SineDecay(_smEnvelope, f.Envelope, med);
            _smOverall = SineDecay(_smOverall, f.Overall, med);
            _smB0 = SineDecay(_smB0, f.Band0, med);
            _smB1 = SineDecay(_smB1, f.Band1, med);
            _smB2 = SineDecay(_smB2, f.Band2, med);
            _smB3 = SineDecay(_smB3, f.Band3, med);
            _smB4 = SineDecay(_smB4, f.Band4, med);
            _smB5 = SineDecay(_smB5, f.Band5, med);
            _smB6 = SineDecay(_smB6, f.Band6, med);
            _smB7 = SineDecay(_smB7, f.Band7, med);
            _smBrightness = SineDecay(_smBrightness, f.Brightness, slow);
            _smBloom = SineDecay(_smBloom, f.BloomIntensity, slow);
            _smBeam = SineDecay(_smBeam, f.BeamIntensity, slow);
            _smDynLight = SineDecay(_smDynLight, f.DynamicLightIntensity, slow);
            _smAmbient = SineDecay(_smAmbient, f.AmbientLightIntensity, slow);
            _smEffect = SineDecay(_smEffect, f.EffectIntensity, slow);
            _smMovement = SineDecay(_smMovement, f.MovementIntensity, slow);
            _smStereoBal = SineDecay(_smStereoBal, f.StereoBalance, slow);
            _smStereoWid = SineDecay(_smStereoWid, f.StereoWidth, slow);
            _smHue = LerpHue(_smHue, f.BaseHue, slow);
            _smPhaseCorr = SineDecay(_smPhaseCorr, f.PhaseCorrelation, med);
            _smBeatAnt = SineDecay(_smBeatAnt, f.BeatAnticipation, fast);
            _smClarity = SineDecay(_smClarity, f.SpectralClarity, med);
        }

        return new AudioUBO
        {
            // BrainDynamics
            Beat = _smBeat,
            Trans = _smTransient,
            Env = _smEnvelope,
            Overall = _smOverall,
            // FrequencySpectrum
            Sub = _smB0,
            Bass = _smB1,
            LMid = _smB2,
            Mid = _smB3,
            HMid = _smB4,
            Pres = _smB5,
            Bril = _smB6,
            Air = _smB7,
            // SpatialTelemetry
            StereoLR = new Vector2(f.LeftEnergy, f.RightEnergy),
            Balance = _smStereoBal,
            Width = _smStereoWid,
            Phase = _smPhaseCorr,
            Anticip = _smBeatAnt,
            _pad0 = 0f,
            _pad1 = 0f,
            // PerformanceRhythm
            BPM = f.BPM,
            Conf = f.TempoConfidence,
            KickWeight = _smKick,
            MoveSpeed = _smMovement,
            // Shader Control Multipliers
            ColorPrimary = new Vector4(f.ColorR, f.ColorG, f.ColorB, _smHue),
            ColorSecondary = new Vector4(f.Color2R, f.Color2G, f.Color2B, f.SectionHueCenter),
            VisualModifiers = new Vector4(_smBrightness, _smBeam, _smBloom, _smAmbient),
            SystemState = new Vector4(f.PhraseBeat, _smEffect, f.ColorPulse, f.Section)
        };
    }

    private void ApplyPerformanceParams(ref AudioUBO ubo, RenderGraph graph)
    {
        float fast = 0.18f;
        float med = 0.12f;
        float slow = 0.06f;

        if (_firstPerf)
        {
            _smIntensity = graph.Intensity;
            _smPulse = graph.Pulse;
            _smAccent = graph.Accent;
            _smColorShift = graph.ColorShift;
            _smSpeed = graph.Speed;
            _smZoom = graph.Zoom;
            _smFeedback = graph.Feedback;
            _firstPerf = false;
        }
        else
        {
            _smIntensity = SineDecay(_smIntensity, graph.Intensity, slow);
            _smPulse = SineDecay(_smPulse, graph.Pulse, fast);
            _smAccent = SineDecay(_smAccent, graph.Accent, med);
            _smColorShift = LerpHue(_smColorShift, graph.ColorShift, slow);
            _smSpeed = SineDecay(_smSpeed, graph.Speed, slow);
            _smZoom = SineDecay(_smZoom, graph.Zoom, slow);
            _smFeedback = SineDecay(_smFeedback, graph.Feedback, slow);
        }

        // Remap brain brightness to a wider dark-to-bright range, then scale by director intensity.
        float brainBrightness = ubo.VisualModifiers.X;
        float scaledBrightness = 0.05f + brainBrightness * 0.65f;

        ubo.VisualModifiers = new Vector4(
            scaledBrightness * _smIntensity,
            ubo.VisualModifiers.Y + _smAccent * 0.5f,
            ubo.VisualModifiers.Z + _smPulse * 0.6f,
            ubo.VisualModifiers.W);

        // Apply color shift on top of brain hue.
        ubo.ColorPrimary = new Vector4(
            ubo.ColorPrimary.X,
            ubo.ColorPrimary.Y,
            ubo.ColorPrimary.Z,
            (ubo.ColorPrimary.W + _smColorShift) % 1.0f);

        // Speed modulates MoveSpeed
        ubo.MoveSpeed *= _smSpeed;

        // Zoom and feedback feed into SystemState
        ubo.SystemState = new Vector4(
            ubo.SystemState.X,
            ubo.SystemState.Y,
            ubo.SystemState.Z,
            Math.Clamp(_smFeedback * 0.5f + ubo.SystemState.W * 0.5f, 0f, 1f));
    }
}
