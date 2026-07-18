using System.Collections.Generic;
using System.Text;

namespace DXRenderer;

/// <summary>
/// Static manifest of all shader-level controls the AI text model can adjust.
/// This is the constraint boundary — the text model can only output values
/// for fields listed here, with the specified ranges and semantics.
///
/// Mirrors smc-autosort's approach of constraining the LLM to known actions,
/// but adapted for shader uniforms instead of game primitives.
/// </summary>
public static class ShaderConstraintManifest
{
    /// <summary>
    /// Build the constraint prompt section that tells the text model what it can control.
    /// </summary>
    public static string BuildConstraintPrompt()
    {
        var sb = new StringBuilder();
        sb.AppendLine("You are an AI visual director for a real-time music visualizer.");
        sb.AppendLine("A vision model has observed the current frame and given you its assessment.");
        sb.AppendLine("Your job is to translate that into concrete shader parameter adjustments.");
        sb.AppendLine();
        sb.AppendLine("You can ONLY adjust these parameters. Do NOT invent new ones.");
        sb.AppendLine("Output each adjustment on its own line as KEY: VALUE");
        sb.AppendLine("Omit any parameter you don't want to change.");
        sb.AppendLine();
        sb.AppendLine("=== SHADER UNIFORM CONTROLS ===");
        sb.AppendLine();

        sb.AppendLine("--- VisualModifiers (float4) ---");
        sb.AppendLine("BRIGHTNESS: 0.0-1.0   (overall scene brightness, higher = brighter)");
        sb.AppendLine("BEAM: 0.0-1.0         (additive light beam intensity, higher = more beams)");
        sb.AppendLine("BLOOM: 0.0-1.0        (bloom/glow halo intensity, higher = more glow)");
        sb.AppendLine("AMBIENT: 0.0-1.0      (ambient atmospheric haze, higher = more fog/haze)");
        sb.AppendLine();

        sb.AppendLine("--- ColorPrimary (float4: RGB + Hue) ---");
        sb.AppendLine("HUE_BASE: 0.0-1.0     (base hue rotation, wraps around color wheel)");
        sb.AppendLine("COLOR_R: 0.0-1.0      (primary color red channel)");
        sb.AppendLine("COLOR_G: 0.0-1.0      (primary color green channel)");
        sb.AppendLine("COLOR_B: 0.0-1.0      (primary color blue channel)");
        sb.AppendLine();

        sb.AppendLine("--- ColorSecondary (float4: RGB + HueCenter) ---");
        sb.AppendLine("HUE_CENTER: 0.0-1.0   (secondary hue center for palette spread)");
        sb.AppendLine("COLOR2_R: 0.0-1.0     (secondary color red channel)");
        sb.AppendLine("COLOR2_G: 0.0-1.0     (secondary color green channel)");
        sb.AppendLine("COLOR2_B: 0.0-1.0     (secondary color blue channel)");
        sb.AppendLine();

        sb.AppendLine("--- PerformanceRhythm ---");
        sb.AppendLine("MOVE_SPEED: 0.1-3.0   (noise/particle evolution speed, higher = faster motion)");
        sb.AppendLine();

        sb.AppendLine("--- SystemState (float4) ---");
        sb.AppendLine("EFFECT_INT: 0.0-1.0   (effect intensity multiplier for distortion/displacement)");
        sb.AppendLine("PULSE: 0.0-1.0        (visual pulse strength synced to beat)");
        sb.AppendLine();

        sb.AppendLine("--- RenderGraph Performance Params ---");
        sb.AppendLine("INTENSITY: 0.3-2.0    (master intensity multiplier for all visuals)");
        sb.AppendLine("ACCENT: 0.0-2.0       (transient accent strength, sharpens beat reactions)");
        sb.AppendLine("COLOR_SHIFT: 0.0-1.0  (hue offset added on top of brain hue)");
        sb.AppendLine("SPEED: 0.1-3.0        (global speed multiplier for motion)");
        sb.AppendLine("ZOOM: 0.8-1.6         (camera zoom level, higher = zoomed in)");
        sb.AppendLine("FEEDBACK: 0.0-1.0     (frame feedback/echo amount, higher = more trails)");
        sb.AppendLine();

        sb.AppendLine("--- Derived Shader Fields ---");
        sb.AppendLine("SATUR: 0.0-1.0        (color saturation, 0=grayscale, 1=full color)");
        sb.AppendLine("ATMOS: 0.0-1.0        (atmospheric density for volumetric effects)");
        sb.AppendLine("DYN_LIGHT: 0.0-1.0    (dynamic light intensity reactive to beat)");
        sb.AppendLine("PERSP: 0.0-1.0        (perspective depth, higher = more 3D depth)");
        sb.AppendLine("BAR_SCALE: 0.5-2.0    (scale of bar/spectrum elements)");
        sb.AppendLine();

        sb.AppendLine("--- Visualization Modes (use MODE: to switch) ---");
        sb.AppendLine("MODE: <one of: spectrum_bars spectrum_3d plasma_field neon_pulse particle_flow");
        sb.AppendLine("      waveform sphere aurora dna_helix heartbeat rtx_mesh ray_marched");
        sb.AppendLine("      volumetric_clouds fractal_dimensions neural_network quantum_field");
        sb.AppendLine("      holographic particle_storm wave_tessellation compute_shaders");
        sb.AppendLine("      rtx_reflections quantum_bars>");
        sb.AppendLine();

        sb.AppendLine("--- Mood Presets (use MOOD: to set) ---");
        sb.AppendLine("MOOD: <one of: Chill Energetic SciFi Organic>");
        sb.AppendLine();

        // Insert master reference profiles (read-only baselines)
        sb.Append(MasterShaderProfiles.BuildProfileContext());

        sb.AppendLine("=== REFERENCE SHADERS (gold standards) ===");
        sb.AppendLine();
        sb.AppendLine("These two shaders are the reference implementations. Use them as");
        sb.AppendLine("examples of how parameters should be tuned for good results.");
        sb.AppendLine();
        sb.AppendLine("--- wave_tessellation (Mode 17) ---");
        sb.AppendLine("Top half: wireframe tessellated mesh, stereo-driven displacement.");
        sb.AppendLine("  Uses: specL/specR for L/R displacement, stereoBal shifts center ridge,");
        sb.AppendLine("        stereoWid widens gap, b4-b7 for fine detail, transient for spike.");
        sb.AppendLine("  Lighting: diff + spec(64) + fres(4) with brainCol/brainCol2.");
        sb.AppendLine("  Color: hueBase + heightFrac * hueRange + section*0.03 + colorPulse*0.04.");
        sb.AppendLine("  Key: brightness affects base color (0.4 + brightness*0.3),");
        sb.AppendLine("       bloom affects fresnel glow, ambient affects AO (0.4 + ambient*0.6),");
        sb.AppendLine("       satur controls wireframe/mesh color saturation (0.7 * satur).");
        sb.AppendLine("  Post: centerDim 0.55-1.0 radial, godRays, standardOverlays, applyPostFX.");
        sb.AppendLine();
        sb.AppendLine("--- spectrum_3d (Mode 2) ---");
        sb.AppendLine("Stereo mirror spectrum bars, 128 bars per side, bass in center.");
        sb.AppendLine("  Uses: specL/specR from spectrum texture, sub-bass summed L+R center.");
        sb.AppendLine("  Height: gatedOverall + punch + barScale, phaseCorr tightens mirror.");
        sb.AppendLine("  Color: barHue = hueBase + barFrac*hueRange*0.4 + colorPulse*0.05 + section*0.02.");
        sb.AppendLine("  Key: brightness affects bar value (0.7 + brightness*0.3),");
        sb.AppendLine("       bloom adds glow (glow*0.2*bloomActive), beam adds (beam*0.15*beamActive),");
        sb.AppendLine("       satur scales bar saturation (0.85*satur),");
        sb.AppendLine("       dynLight adds topGlow on tall bars (beat*0.3 + dynLight*0.2),");
        sb.AppendLine("       atmos adds haze, persp controls vignette, motionPers adds brightness.");
        sb.AppendLine("  Post: tone map col/(1+col), perspective vignette.");
        sb.AppendLine();
        sb.AppendLine("=== PIPELINE CONTEXT ===");
        sb.AppendLine();
        sb.AppendLine("The visualizer runs a render pipeline: AudioBrain -> VisualDirectorBot ->");
        sb.AppendLine("VisualSmoother -> AudioUBO -> GPU Shaders. The director sets performance");
        sb.AppendLine("targets (Intensity, Speed, Zoom, etc.) which are smoothed and applied to");
        sb.AppendLine("the AudioUBO constant buffer. All 22 shader modes read from the same UBO.");
        sb.AppendLine("The AudioData struct in shaders has ~60 fields derived from the UBO.");
        sb.AppendLine("Your adjustments modify the UBO values that ALL shaders consume.");
        sb.AppendLine();
        sb.AppendLine("Also include:");
        sb.AppendLine("SUGGESTION: <one sentence explaining why you made these changes>");
        sb.AppendLine();
        sb.AppendLine("Example output (reducing brightness because scene is too bright):");
        sb.AppendLine("BRIGHTNESS: 0.45");
        sb.AppendLine("BLOOM: 0.20");
        sb.AppendLine("SATUR: 0.80");
        sb.AppendLine("SUGGESTION: reduce brightness and bloom to reveal mid-frequency detail");
        sb.AppendLine();
        sb.AppendLine("Example output (increasing energy because scene is too flat):");
        sb.AppendLine("BRIGHTNESS: 0.65");
        sb.AppendLine("EFFECT_INT: 0.60");
        sb.AppendLine("PULSE: 0.70");
        sb.AppendLine("SUGGESTION: increase effect intensity and pulse for stronger beat reaction");
        return sb.ToString();
    }

    /// <summary>
    /// All valid parameter keys the text model can output.
    /// Used for validation before applying.
    /// </summary>
    public static readonly HashSet<string> ValidKeys = new()
    {
        "BRIGHTNESS", "BEAM", "BLOOM", "AMBIENT",
        "HUE_BASE", "COLOR_R", "COLOR_G", "COLOR_B",
        "HUE_CENTER", "COLOR2_R", "COLOR2_G", "COLOR2_B",
        "MOVE_SPEED",
        "EFFECT_INT", "PULSE",
        "INTENSITY", "ACCENT", "COLOR_SHIFT", "SPEED", "ZOOM", "FEEDBACK",
        "SATUR", "ATMOS", "DYN_LIGHT", "PERSP", "BAR_SCALE",
        "MODE", "MOOD",
        "SUGGESTION"
    };

    /// <summary>
    /// Valid visualization mode names.
    /// </summary>
    public static readonly HashSet<string> ValidModes = new()
    {
        "spectrum_bars", "spectrum_3d", "plasma_field", "neon_pulse",
        "particle_flow", "waveform", "sphere", "aurora",
        "dna_helix", "heartbeat", "rtx_mesh", "ray_marched",
        "volumetric_clouds", "fractal_dimensions", "neural_network",
        "quantum_field", "holographic", "particle_storm",
        "wave_tessellation", "compute_shaders", "rtx_reflections",
        "quantum_bars"
    };

    public static readonly HashSet<string> ValidMoods = new()
    {
        "Chill", "Energetic", "SciFi", "Organic"
    };
}
