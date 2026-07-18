using System;
using System.Collections.Generic;

namespace DXRenderer;

/// <summary>
/// Parsed shader adjustments from the text model.
/// Only contains keys from ShaderConstraintManifest.ValidKeys.
/// Null values mean "no change requested."
/// </summary>
public class ShaderAdjustments
{
    // VisualModifiers
    public float? Brightness;
    public float? Beam;
    public float? Bloom;
    public float? Ambient;

    // ColorPrimary
    public float? HueBase;
    public float? ColorR, ColorG, ColorB;

    // ColorSecondary
    public float? HueCenter;
    public float? Color2R, Color2G, Color2B;

    // PerformanceRhythm
    public float? MoveSpeed;

    // SystemState
    public float? EffectInt;
    public float? Pulse;

    // RenderGraph params
    public float? Intensity;
    public float? Accent;
    public float? ColorShift;
    public float? Speed;
    public float? Zoom;
    public float? Feedback;

    // Derived
    public float? Satur;
    public float? Atmos;
    public float? DynLight;
    public float? Persp;
    public float? BarScale;

    // Mode / Mood
    public string? Mode;
    public string? Mood;

    // Explanation
    public string Suggestion = "";

    public bool HasAny => Brightness.HasValue || Beam.HasValue || Bloom.HasValue ||
        Ambient.HasValue || HueBase.HasValue || ColorR.HasValue || ColorG.HasValue ||
        ColorB.HasValue || HueCenter.HasValue || Color2R.HasValue || Color2G.HasValue ||
        Color2B.HasValue || MoveSpeed.HasValue || EffectInt.HasValue || Pulse.HasValue ||
        Intensity.HasValue || Accent.HasValue || ColorShift.HasValue || Speed.HasValue ||
        Zoom.HasValue || Feedback.HasValue || Satur.HasValue || Atmos.HasValue ||
        DynLight.HasValue || Persp.HasValue || BarScale.HasValue ||
        !string.IsNullOrEmpty(Mode) || !string.IsNullOrEmpty(Mood);

    /// <summary>
    /// Parse key-value lines from the text model output.
    /// Only accepts keys in ShaderConstraintManifest.ValidKeys.
    /// </summary>
    public static ShaderAdjustments Parse(string text)
    {
        var result = new ShaderAdjustments();
        foreach (var line in text.Split('\n', '\r'))
        {
            var trimmed = line.Trim();
            if (string.IsNullOrEmpty(trimmed)) continue;

            int sep = trimmed.IndexOf(':');
            if (sep <= 0) continue;

            string key = trimmed.Substring(0, sep).Trim().ToUpperInvariant();
            string val = trimmed.Substring(sep + 1).Trim();

            if (!ShaderConstraintManifest.ValidKeys.Contains(key)) continue;

            switch (key)
            {
                case "BRIGHTNESS": result.Brightness = ParseFloat(val, 0f, 1f); break;
                case "BEAM": result.Beam = ParseFloat(val, 0f, 1f); break;
                case "BLOOM": result.Bloom = ParseFloat(val, 0f, 1f); break;
                case "AMBIENT": result.Ambient = ParseFloat(val, 0f, 1f); break;
                case "HUE_BASE": result.HueBase = ParseFloat(val, 0f, 1f); break;
                case "COLOR_R": result.ColorR = ParseFloat(val, 0f, 1f); break;
                case "COLOR_G": result.ColorG = ParseFloat(val, 0f, 1f); break;
                case "COLOR_B": result.ColorB = ParseFloat(val, 0f, 1f); break;
                case "HUE_CENTER": result.HueCenter = ParseFloat(val, 0f, 1f); break;
                case "COLOR2_R": result.Color2R = ParseFloat(val, 0f, 1f); break;
                case "COLOR2_G": result.Color2G = ParseFloat(val, 0f, 1f); break;
                case "COLOR2_B": result.Color2B = ParseFloat(val, 0f, 1f); break;
                case "MOVE_SPEED": result.MoveSpeed = ParseFloat(val, 0.1f, 3f); break;
                case "EFFECT_INT": result.EffectInt = ParseFloat(val, 0f, 1f); break;
                case "PULSE": result.Pulse = ParseFloat(val, 0f, 1f); break;
                case "INTENSITY": result.Intensity = ParseFloat(val, 0.3f, 2f); break;
                case "ACCENT": result.Accent = ParseFloat(val, 0f, 2f); break;
                case "COLOR_SHIFT": result.ColorShift = ParseFloat(val, 0f, 1f); break;
                case "SPEED": result.Speed = ParseFloat(val, 0.1f, 3f); break;
                case "ZOOM": result.Zoom = ParseFloat(val, 0.8f, 1.6f); break;
                case "FEEDBACK": result.Feedback = ParseFloat(val, 0f, 1f); break;
                case "SATUR": result.Satur = ParseFloat(val, 0f, 1f); break;
                case "ATMOS": result.Atmos = ParseFloat(val, 0f, 1f); break;
                case "DYN_LIGHT": result.DynLight = ParseFloat(val, 0f, 1f); break;
                case "PERSP": result.Persp = ParseFloat(val, 0f, 1f); break;
                case "BAR_SCALE": result.BarScale = ParseFloat(val, 0.5f, 2f); break;
                case "MODE":
                    if (ShaderConstraintManifest.ValidModes.Contains(val.ToLowerInvariant()))
                        result.Mode = val.ToLowerInvariant();
                    break;
                case "MOOD":
                    foreach (var m in ShaderConstraintManifest.ValidMoods)
                        if (m.Equals(val, StringComparison.OrdinalIgnoreCase))
                            result.Mood = m;
                    break;
                case "SUGGESTION": result.Suggestion = val; break;
            }
        }
        return result;
    }

    private static float? ParseFloat(string val, float min, float max)
    {
        if (float.TryParse(val.TrimEnd('%'), System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out float f))
            return Math.Clamp(f, min, max);
        return null;
    }
}
