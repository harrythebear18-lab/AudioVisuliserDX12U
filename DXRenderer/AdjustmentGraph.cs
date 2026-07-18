using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Numerics;
using System.Text.Json;

namespace DXRenderer;

/// <summary>
/// A single keyframe in an adjustment curve.
/// Time is in seconds relative to when the adjustment was made.
/// </summary>
public struct AdjustmentKeyframe
{
    public float Time;
    public float Value;
    public float Weight;
}

/// <summary>
/// A parameter curve: keyframes interpolated over time.
/// Instead of storing raw AI output dumps, we store lightweight curves
/// that smoothly interpolate toward the AI's recommended values.
/// This is more efficient and produces smoother visual transitions.
/// </summary>
public class AdjustmentCurve
{
    public string Key { get; }
    public float Min { get; }
    public float Max { get; }
    private readonly List<AdjustmentKeyframe> _keyframes = new();

    public AdjustmentCurve(string key, float min, float max)
    {
        Key = key;
        Min = min;
        Max = max;
    }

    /// <summary>
    /// Add a keyframe at the given time. Clamps value to valid range.
    /// </summary>
    public void AddKeyframe(float time, float value, float weight = 1.0f)
    {
        value = Math.Clamp(value, Min, Max);
        _keyframes.Add(new AdjustmentKeyframe { Time = time, Value = value, Weight = weight });
        // Keep sorted by time
        _keyframes.Sort((a, b) => a.Time.CompareTo(b.Time));
        // Cap at 32 keyframes — older ones get pruned
        if (_keyframes.Count > 32)
            _keyframes.RemoveAt(0);
    }

    /// <summary>
    /// Sample the curve at the given time. Uses linear interpolation
    /// with weight blending between keyframes. Returns null if empty.
    /// </summary>
    public float? Sample(float time)
    {
        if (_keyframes.Count == 0) return null;
        if (_keyframes.Count == 1) return _keyframes[0].Value;

        // Before first keyframe — hold
        if (time <= _keyframes[0].Time) return _keyframes[0].Value;
        // After last keyframe — hold final value
        if (time >= _keyframes[^1].Time) return _keyframes[^1].Value;

        // Find surrounding keyframes
        for (int i = 0; i < _keyframes.Count - 1; i++)
        {
            if (time >= _keyframes[i].Time && time <= _keyframes[i + 1].Time)
            {
                float span = _keyframes[i + 1].Time - _keyframes[i].Time;
                if (span <= 0.0001f) return _keyframes[i].Value;
                float t = (time - _keyframes[i].Time) / span;
                // Smoothstep for ease in/out
                t = t * t * (3f - 2f * t);
                float v = _keyframes[i].Value + (_keyframes[i + 1].Value - _keyframes[i].Value) * t;
                return Math.Clamp(v, Min, Max);
            }
        }
        return _keyframes[^1].Value;
    }

    public bool IsEmpty => _keyframes.Count == 0;
    public int KeyframeCount => _keyframes.Count;
    public IEnumerable<AdjustmentKeyframe> Keyframes => _keyframes;

    public void ClearKeyframes() => _keyframes.Clear();
}

/// <summary>
/// Collection of adjustment curves — one per shader parameter.
/// The AI's recommendations are stored as curves, and each frame
/// the graph is sampled to produce concrete values that get
/// translated back into the AudioUBO / RenderGraph.
/// </summary>
public class AdjustmentGraph
{
    private readonly Dictionary<string, AdjustmentCurve> _curves = new();
    private float _originTime;
    private string? _lastMode;
    private string? _lastMood;
    private string _lastSuggestion = "";

    public string? PendingMode => _lastMode;
    public string? PendingMood => _lastMood;
    public string LastSuggestion => _lastSuggestion;

    public AdjustmentGraph()
    {
        // Initialize curves for all valid shader parameters with their ranges
        _curves["BRIGHTNESS"]    = new AdjustmentCurve("BRIGHTNESS", 0f, 1f);
        _curves["BEAM"]          = new AdjustmentCurve("BEAM", 0f, 1f);
        _curves["BLOOM"]         = new AdjustmentCurve("BLOOM", 0f, 1f);
        _curves["AMBIENT"]       = new AdjustmentCurve("AMBIENT", 0f, 1f);
        _curves["HUE_BASE"]      = new AdjustmentCurve("HUE_BASE", 0f, 1f);
        _curves["COLOR_R"]       = new AdjustmentCurve("COLOR_R", 0f, 1f);
        _curves["COLOR_G"]       = new AdjustmentCurve("COLOR_G", 0f, 1f);
        _curves["COLOR_B"]       = new AdjustmentCurve("COLOR_B", 0f, 1f);
        _curves["HUE_CENTER"]    = new AdjustmentCurve("HUE_CENTER", 0f, 1f);
        _curves["COLOR2_R"]      = new AdjustmentCurve("COLOR2_R", 0f, 1f);
        _curves["COLOR2_G"]      = new AdjustmentCurve("COLOR2_G", 0f, 1f);
        _curves["COLOR2_B"]      = new AdjustmentCurve("COLOR2_B", 0f, 1f);
        _curves["MOVE_SPEED"]    = new AdjustmentCurve("MOVE_SPEED", 0.1f, 3f);
        _curves["EFFECT_INT"]    = new AdjustmentCurve("EFFECT_INT", 0f, 1f);
        _curves["PULSE"]         = new AdjustmentCurve("PULSE", 0f, 1f);
        _curves["INTENSITY"]     = new AdjustmentCurve("INTENSITY", 0.3f, 2f);
        _curves["ACCENT"]        = new AdjustmentCurve("ACCENT", 0f, 2f);
        _curves["COLOR_SHIFT"]   = new AdjustmentCurve("COLOR_SHIFT", 0f, 1f);
        _curves["SPEED"]         = new AdjustmentCurve("SPEED", 0.1f, 3f);
        _curves["ZOOM"]          = new AdjustmentCurve("ZOOM", 0.8f, 1.6f);
        _curves["FEEDBACK"]      = new AdjustmentCurve("FEEDBACK", 0f, 1f);
        _curves["SATUR"]         = new AdjustmentCurve("SATUR", 0f, 1f);
        _curves["ATMOS"]         = new AdjustmentCurve("ATMOS", 0f, 1f);
        _curves["DYN_LIGHT"]     = new AdjustmentCurve("DYN_LIGHT", 0f, 1f);
        _curves["PERSP"]         = new AdjustmentCurve("PERSP", 0f, 1f);
        _curves["BAR_SCALE"]     = new AdjustmentCurve("BAR_SCALE", 0.5f, 2f);
    }

    /// <summary>
    /// Record a new set of adjustments from the text model.
    /// Each non-null value becomes a keyframe at the current time.
    /// </summary>
    public void RecordAdjustments(ShaderAdjustments adj, float currentTime)
    {
        if (_originTime == 0f) _originTime = currentTime;
        float relTime = currentTime - _originTime;

        if (adj.Brightness.HasValue)  _curves["BRIGHTNESS"].AddKeyframe(relTime, adj.Brightness.Value);
        if (adj.Beam.HasValue)        _curves["BEAM"].AddKeyframe(relTime, adj.Beam.Value);
        if (adj.Bloom.HasValue)       _curves["BLOOM"].AddKeyframe(relTime, adj.Bloom.Value);
        if (adj.Ambient.HasValue)     _curves["AMBIENT"].AddKeyframe(relTime, adj.Ambient.Value);
        if (adj.HueBase.HasValue)     _curves["HUE_BASE"].AddKeyframe(relTime, adj.HueBase.Value);
        if (adj.ColorR.HasValue)      _curves["COLOR_R"].AddKeyframe(relTime, adj.ColorR.Value);
        if (adj.ColorG.HasValue)      _curves["COLOR_G"].AddKeyframe(relTime, adj.ColorG.Value);
        if (adj.ColorB.HasValue)      _curves["COLOR_B"].AddKeyframe(relTime, adj.ColorB.Value);
        if (adj.HueCenter.HasValue)   _curves["HUE_CENTER"].AddKeyframe(relTime, adj.HueCenter.Value);
        if (adj.Color2R.HasValue)     _curves["COLOR2_R"].AddKeyframe(relTime, adj.Color2R.Value);
        if (adj.Color2G.HasValue)     _curves["COLOR2_G"].AddKeyframe(relTime, adj.Color2G.Value);
        if (adj.Color2B.HasValue)     _curves["COLOR2_B"].AddKeyframe(relTime, adj.Color2B.Value);
        if (adj.MoveSpeed.HasValue)   _curves["MOVE_SPEED"].AddKeyframe(relTime, adj.MoveSpeed.Value);
        if (adj.EffectInt.HasValue)   _curves["EFFECT_INT"].AddKeyframe(relTime, adj.EffectInt.Value);
        if (adj.Pulse.HasValue)       _curves["PULSE"].AddKeyframe(relTime, adj.Pulse.Value);
        if (adj.Intensity.HasValue)   _curves["INTENSITY"].AddKeyframe(relTime, adj.Intensity.Value);
        if (adj.Accent.HasValue)      _curves["ACCENT"].AddKeyframe(relTime, adj.Accent.Value);
        if (adj.ColorShift.HasValue)  _curves["COLOR_SHIFT"].AddKeyframe(relTime, adj.ColorShift.Value);
        if (adj.Speed.HasValue)       _curves["SPEED"].AddKeyframe(relTime, adj.Speed.Value);
        if (adj.Zoom.HasValue)        _curves["ZOOM"].AddKeyframe(relTime, adj.Zoom.Value);
        if (adj.Feedback.HasValue)    _curves["FEEDBACK"].AddKeyframe(relTime, adj.Feedback.Value);
        if (adj.Satur.HasValue)       _curves["SATUR"].AddKeyframe(relTime, adj.Satur.Value);
        if (adj.Atmos.HasValue)       _curves["ATMOS"].AddKeyframe(relTime, adj.Atmos.Value);
        if (adj.DynLight.HasValue)    _curves["DYN_LIGHT"].AddKeyframe(relTime, adj.DynLight.Value);
        if (adj.Persp.HasValue)       _curves["PERSP"].AddKeyframe(relTime, adj.Persp.Value);
        if (adj.BarScale.HasValue)    _curves["BAR_SCALE"].AddKeyframe(relTime, adj.BarScale.Value);

        if (!string.IsNullOrEmpty(adj.Mode)) _lastMode = adj.Mode;
        if (!string.IsNullOrEmpty(adj.Mood)) _lastMood = adj.Mood;
        if (!string.IsNullOrEmpty(adj.Suggestion)) _lastSuggestion = adj.Suggestion;
    }

    /// <summary>
    /// Sample all curves at the current time and produce resolved values.
    /// These are the concrete numbers that get translated into the UBO/RenderGraph.
    /// Null means "no curve data yet for this parameter — don't override".
    /// </summary>
    public ResolvedAdjustments Resolve(float currentTime)
    {
        float relTime = currentTime - _originTime;
        var result = new ResolvedAdjustments();

        result.Brightness  = _curves["BRIGHTNESS"].Sample(relTime);
        result.Beam        = _curves["BEAM"].Sample(relTime);
        result.Bloom       = _curves["BLOOM"].Sample(relTime);
        result.Ambient     = _curves["AMBIENT"].Sample(relTime);
        result.HueBase     = _curves["HUE_BASE"].Sample(relTime);
        result.ColorR      = _curves["COLOR_R"].Sample(relTime);
        result.ColorG      = _curves["COLOR_G"].Sample(relTime);
        result.ColorB      = _curves["COLOR_B"].Sample(relTime);
        result.HueCenter   = _curves["HUE_CENTER"].Sample(relTime);
        result.Color2R     = _curves["COLOR2_R"].Sample(relTime);
        result.Color2G     = _curves["COLOR2_G"].Sample(relTime);
        result.Color2B     = _curves["COLOR2_B"].Sample(relTime);
        result.MoveSpeed   = _curves["MOVE_SPEED"].Sample(relTime);
        result.EffectInt   = _curves["EFFECT_INT"].Sample(relTime);
        result.Pulse       = _curves["PULSE"].Sample(relTime);
        result.Intensity   = _curves["INTENSITY"].Sample(relTime);
        result.Accent      = _curves["ACCENT"].Sample(relTime);
        result.ColorShift  = _curves["COLOR_SHIFT"].Sample(relTime);
        result.Speed       = _curves["SPEED"].Sample(relTime);
        result.Zoom        = _curves["ZOOM"].Sample(relTime);
        result.Feedback    = _curves["FEEDBACK"].Sample(relTime);
        result.Satur       = _curves["SATUR"].Sample(relTime);
        result.Atmos       = _curves["ATMOS"].Sample(relTime);
        result.DynLight    = _curves["DYN_LIGHT"].Sample(relTime);
        result.Persp       = _curves["PERSP"].Sample(relTime);
        result.BarScale    = _curves["BAR_SCALE"].Sample(relTime);
        result.Mode        = _lastMode;
        result.Mood        = _lastMood;
        result.Suggestion  = _lastSuggestion;

        return result;
    }

    /// <summary>
    /// Translate resolved adjustments into RenderGraph performance params.
    /// This is the bridge from AI curve data → director bot consumption.
    /// Only sets values that have curve data; others are left untouched.
    /// </summary>
    /// <summary>
    /// Blend weight for motion parameters — how much the AI influences
    /// vs the audio-driven value. 0 = pure audio, 1 = pure AI.
    /// Decays over time since the last keyframe so audio reasserts control.
    /// </summary>
    private const float MotionBlendBase = 0.35f;
    private const float MotionDecaySeconds = 12f;

    /// <summary>
    /// Compute a decaying blend weight. Right after a keyframe, the AI has
    /// full influence. After MotionDecaySeconds with no new keyframes,
    /// influence drops to near zero.
    /// </summary>
    private float MotionBlendWeight(string key, float relTime)
    {
        if (!_curves.TryGetValue(key, out var curve) || curve.IsEmpty) return 0f;
        var kfs = curve.Keyframes.ToList();
        if (kfs.Count == 0) return 0f;
        float lastT = kfs[^1].Time;
        float age = relTime - lastT;
        if (age <= 0f) return MotionBlendBase;
        // Exponential decay: after MotionDecaySeconds, weight ~ 0.01 * base
        return MotionBlendBase * MathF.Exp(-age * 3f / MotionDecaySeconds);
    }

    private static float Lerp(float a, float b, float t) => a + (b - a) * t;

    public void ApplyToRenderGraph(RenderGraph graph, float currentTime)
    {
        float relTime = currentTime - _originTime;
        var r = Resolve(currentTime);

        // Aesthetic parameters — direct override (these don't kill motion)
        if (r.ColorShift.HasValue) graph.ColorShift = r.ColorShift.Value;
        if (r.Zoom.HasValue)       graph.Zoom       = r.Zoom.Value;
        if (r.Feedback.HasValue)   graph.Feedback   = r.Feedback.Value;

        // Motion parameters — blend with audio-driven values using decaying weight
        if (r.Intensity.HasValue)
        {
            float w = MotionBlendWeight("INTENSITY", relTime);
            graph.Intensity = Lerp(graph.Intensity, r.Intensity.Value, w);
        }
        if (r.Pulse.HasValue)
        {
            float w = MotionBlendWeight("PULSE", relTime);
            graph.Pulse = Lerp(graph.Pulse, r.Pulse.Value, w);
        }
        if (r.Accent.HasValue)
        {
            float w = MotionBlendWeight("ACCENT", relTime);
            graph.Accent = Lerp(graph.Accent, r.Accent.Value, w);
        }
        if (r.Speed.HasValue)
        {
            float w = MotionBlendWeight("SPEED", relTime);
            graph.Speed = Lerp(graph.Speed, r.Speed.Value, w);
        }
    }

    /// <summary>
    /// Translate resolved adjustments into AudioUBO shader uniforms.
    /// This is the bridge from AI curve data → GPU constant buffer.
    /// Modifies the UBO in-place, only touching fields with curve data.
    /// </summary>
    public void ApplyToUBO(ref AudioUBO ubo, float currentTime)
    {
        float relTime = currentTime - _originTime;
        var r = Resolve(currentTime);

        // VisualModifiers: x=brightness, y=beam, z=bloom, w=ambient
        if (r.Brightness.HasValue || r.Beam.HasValue || r.Bloom.HasValue || r.Ambient.HasValue)
        {
            ubo.VisualModifiers = new Vector4(
                r.Brightness ?? ubo.VisualModifiers.X,
                r.Beam ?? ubo.VisualModifiers.Y,
                r.Bloom ?? ubo.VisualModifiers.Z,
                r.Ambient ?? ubo.VisualModifiers.W);
        }

        // ColorPrimary: xyz=RGB, w=hueBase
        if (r.ColorR.HasValue || r.ColorG.HasValue || r.ColorB.HasValue || r.HueBase.HasValue)
        {
            ubo.ColorPrimary = new Vector4(
                r.ColorR ?? ubo.ColorPrimary.X,
                r.ColorG ?? ubo.ColorPrimary.Y,
                r.ColorB ?? ubo.ColorPrimary.Z,
                r.HueBase ?? ubo.ColorPrimary.W);
        }

        // ColorSecondary: xyz=RGB2, w=hueCenter
        if (r.Color2R.HasValue || r.Color2G.HasValue || r.Color2B.HasValue || r.HueCenter.HasValue)
        {
            ubo.ColorSecondary = new Vector4(
                r.Color2R ?? ubo.ColorSecondary.X,
                r.Color2G ?? ubo.ColorSecondary.Y,
                r.Color2B ?? ubo.ColorSecondary.Z,
                r.HueCenter ?? ubo.ColorSecondary.W);
        }

        // MoveSpeed — blend with decaying weight (motion-critical)
        if (r.MoveSpeed.HasValue)
        {
            float w = MotionBlendWeight("MOVE_SPEED", relTime);
            ubo.MoveSpeed = Lerp(ubo.MoveSpeed, r.MoveSpeed.Value, w);
        }

        // SystemState: x=phraseBeat, y=effectInt, z=pulse, w=section
        // effectInt and pulse are motion-critical — blend them
        if (r.EffectInt.HasValue || r.Pulse.HasValue)
        {
            float effectIntW = r.EffectInt.HasValue ? MotionBlendWeight("EFFECT_INT", relTime) : 0f;
            float pulseW = r.Pulse.HasValue ? MotionBlendWeight("PULSE", relTime) : 0f;
            ubo.SystemState = new Vector4(
                ubo.SystemState.X,
                r.EffectInt.HasValue ? Lerp(ubo.SystemState.Y, r.EffectInt.Value, effectIntW) : ubo.SystemState.Y,
                r.Pulse.HasValue ? Lerp(ubo.SystemState.Z, r.Pulse.Value, pulseW) : ubo.SystemState.Z,
                ubo.SystemState.W);
        }
    }

    /// <summary>
    /// Save the graph to a compact JSON file for later analysis.
    /// Only stores keyframes, not full raw AI dumps.
    /// </summary>
    public void Save(string path)
    {
        var data = new Dictionary<string, object>();
        foreach (var (key, curve) in _curves)
        {
            if (curve.IsEmpty) continue;
            var kfs = curve.Keyframes.Select(k => new { t = k.Time, v = k.Value, w = k.Weight });
            data[key] = kfs;
        }
        if (!string.IsNullOrEmpty(_lastMode)) data["_mode"] = _lastMode;
        if (!string.IsNullOrEmpty(_lastMood)) data["_mood"] = _lastMood;
        if (!string.IsNullOrEmpty(_lastSuggestion)) data["_suggestion"] = _lastSuggestion;

        var json = JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json);
    }

    /// <summary>
    /// Clear all curves (e.g. when switching modes or resetting).
    /// </summary>
    public void Clear()
    {
        foreach (var curve in _curves.Values)
            curve.ClearKeyframes();
        _originTime = 0f;
        _lastMode = null;
        _lastMood = null;
        _lastSuggestion = "";
    }

    public int ActiveCurveCount => _curves.Values.Count(c => !c.IsEmpty);
    public int TotalKeyframeCount => _curves.Values.Sum(c => c.KeyframeCount);
}

/// <summary>
/// Resolved (sampled) adjustment values at a point in time.
/// All nullable — null means no curve data for that parameter.
/// </summary>
public class ResolvedAdjustments
{
    public float? Brightness, Beam, Bloom, Ambient;
    public float? HueBase, ColorR, ColorG, ColorB;
    public float? HueCenter, Color2R, Color2G, Color2B;
    public float? MoveSpeed;
    public float? EffectInt, Pulse;
    public float? Intensity, Accent, ColorShift, Speed, Zoom, Feedback;
    public float? Satur, Atmos, DynLight, Persp, BarScale;
    public string? Mode, Mood;
    public string Suggestion = "";

    public bool HasAny => Brightness.HasValue || Beam.HasValue || Bloom.HasValue ||
        Ambient.HasValue || HueBase.HasValue || Intensity.HasValue ||
        Speed.HasValue || Zoom.HasValue || Satur.HasValue ||
        !string.IsNullOrEmpty(Mode) || !string.IsNullOrEmpty(Mood);
}
