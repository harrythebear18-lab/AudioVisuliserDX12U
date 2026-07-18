using System.Collections.Generic;

namespace DXRenderer;

/// <summary>
/// Read-only master reference profiles for the two gold-standard shaders.
/// Loaded once at startup and provided to the AI as immutable context.
/// The AI uses these to understand how parameters map to visuals,
/// but each mode maintains its own distinct look — these are reference
/// baselines, not templates to copy.
///
/// Think of these as the "known good" parameter ranges that produce
/// the best results for each reference shader. The AI can reason about
/// why wave_tessellation looks good with brightness=0.6 and satur=0.7,
/// and apply similar reasoning to other modes without making them
/// look identical.
/// </summary>
public static class MasterShaderProfiles
{
    /// <summary>
    /// Reference profile for wave_tessellation (Mode 17).
    /// Top: wireframe tessellated mesh, stereo-driven.
    /// Bottom: colorful wave pool, sub/bass-driven.
    /// </summary>
    public static readonly Dictionary<string, float> WaveTessellation = new()
    {
        ["BRIGHTNESS"]    = 0.60f,
        ["BEAM"]          = 0.30f,
        ["BLOOM"]         = 0.40f,
        ["AMBIENT"]       = 0.50f,
        ["HUE_BASE"]      = 0.45f,
        ["HUE_CENTER"]    = 0.55f,
        ["SATUR"]         = 0.70f,
        ["ATMOS"]         = 0.35f,
        ["DYN_LIGHT"]     = 0.50f,
        ["PERSP"]         = 0.50f,
        ["MOVE_SPEED"]    = 1.00f,
        ["EFFECT_INT"]    = 0.50f,
        ["PULSE"]         = 0.50f,
        ["INTENSITY"]     = 1.00f,
        ["SPEED"]         = 1.00f,
        ["ZOOM"]          = 1.00f,
        ["FEEDBACK"]      = 0.50f,
        ["ACCENT"]        = 0.80f,
        ["COLOR_SHIFT"]   = 0.00f,
    };

    /// <summary>
    /// Reference profile for spectrum_3d (Mode 2).
    /// Stereo mirror spectrum bars, 128 per side, bass in center.
    /// </summary>
    public static readonly Dictionary<string, float> Spectrum3D = new()
    {
        ["BRIGHTNESS"]    = 0.70f,
        ["BEAM"]          = 0.15f,
        ["BLOOM"]         = 0.25f,
        ["AMBIENT"]       = 0.40f,
        ["HUE_BASE"]      = 0.50f,
        ["HUE_CENTER"]    = 0.50f,
        ["SATUR"]         = 0.85f,
        ["ATMOS"]         = 0.20f,
        ["DYN_LIGHT"]     = 0.40f,
        ["PERSP"]         = 0.50f,
        ["BAR_SCALE"]     = 1.00f,
        ["MOVE_SPEED"]    = 1.00f,
        ["EFFECT_INT"]    = 0.40f,
        ["PULSE"]         = 0.50f,
        ["INTENSITY"]     = 1.10f,
        ["SPEED"]         = 1.00f,
        ["ZOOM"]          = 1.00f,
        ["FEEDBACK"]      = 0.30f,
        ["ACCENT"]        = 1.00f,
        ["COLOR_SHIFT"]   = 0.00f,
    };

    /// <summary>
    /// Build a text description of the master profiles for the AI prompt.
    /// Emphasizes these are REFERENCES, not templates — each mode is distinct.
    /// </summary>
    public static string BuildProfileContext()
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("=== MASTER REFERENCE PROFILES (read-only, do NOT copy directly) ===");
        sb.AppendLine();
        sb.AppendLine("These are the known-good baseline parameters for the two reference shaders.");
        sb.AppendLine("Use them to understand how each parameter affects the visual output.");
        sb.AppendLine("DO NOT try to make other modes look like these — each mode is distinct.");
        sb.AppendLine("Use these as reasoning anchors: 'brightness=0.6 works well for wave_tess");
        sb.AppendLine("because it balances mesh visibility with depth, so for a darker mode I");
        sb.AppendLine("might try brightness=0.45 instead'.");
        sb.AppendLine();

        sb.AppendLine("--- wave_tessellation baseline ---");
        foreach (var kv in WaveTessellation)
            sb.AppendLine($"  {kv.Key}: {kv.Value:F2}");
        sb.AppendLine();
        sb.AppendLine("  Visual character: split-screen, wireframe mesh top + water bottom,");
        sb.AppendLine("  stereo-driven displacement, specular highlights, caustics, god rays.");
        sb.AppendLine("  Good when: you want depth, structure, and stereo separation visible.");
        sb.AppendLine();

        sb.AppendLine("--- spectrum_3d baseline ---");
        foreach (var kv in Spectrum3D)
            sb.AppendLine($"  {kv.Key}: {kv.Value:F2}");
        sb.AppendLine();
        sb.AppendLine("  Visual character: stereo mirror bars, bass-centered, frequency-spread,");
        sb.AppendLine("  beat shockwaves, kick flash, atmosphere haze, perspective vignette.");
        sb.AppendLine("  Good when: you want clear frequency representation and energy mapping.");
        sb.AppendLine();

        sb.AppendLine("=== MODE INDEPENDENCE ===");
        sb.AppendLine("Each of the 22 modes has its own shader with unique rendering logic.");
        sb.AppendLine("Your parameter adjustments modify the shared AudioUBO that ALL modes read.");
        sb.AppendLine("The same BRIGHTNESS=0.6 will look different in plasma_field vs spectrum_3d");
        sb.AppendLine("because each shader uses it differently. Always consider the current mode's");
        sb.AppendLine("character when choosing values. The reference profiles show what 'good'");
        sb.AppendLine("looks like for two specific modes — extrapolate, don't copy.");
        sb.AppendLine();

        return sb.ToString();
    }
}
