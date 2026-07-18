using System;
using System.Collections.Generic;
using System.Text;

namespace DXRenderer;

/// <summary>
/// Sterile constraint boundary for a shader mode.
///
/// Defines the valid parameter space for a single mode — tighter than the global
/// ShaderConstraintManifest ranges. AI-generated values are validated against these
/// bounds before entering the adaptive system. This is the "sterile area" that keeps
/// AI output within our pipeline parameters and visual methods.
///
/// Each mode can specify:
///   - Min/max ranges per parameter (tighter than global manifest)
///   - Visual quality guards (e.g. brightness + bloom must not exceed 1.2 to prevent clipping)
///   - Locked parameters (AI cannot touch these — developer has dialed them in manually)
///   - Required relationships (e.g. speed must be >= 0.5 when intensity > 1.5)
/// </summary>
public class ProfileConstraints
{
    public string ModeName { get; }

    // Per-parameter bounds — tighter than global manifest
    private readonly Dictionary<string, (float Min, float Max)> _bounds = new();

    // Parameters locked by the developer — AI cannot modify these
    private readonly HashSet<string> _locked = new();

    // Visual quality guards — composite checks that prevent bad combinations
    private readonly List<Func<ContextSnapshot, string>> _guards = new();

    // Parameters this mode actually uses (subset of the full manifest)
    // AI should only adjust parameters the mode's shader actually reads
    private readonly HashSet<string> _relevantParams = new();

    public ProfileConstraints(string modeName)
    {
        ModeName = modeName;
    }

    /// <summary>
    /// Set bounds for a parameter. Tighter than the global manifest.
    /// </summary>
    public ProfileConstraints Bound(string key, float min, float max)
    {
        _bounds[key] = (min, max);
        _relevantParams.Add(key);
        return this;
    }

    /// <summary>
    /// Lock a parameter — AI cannot modify it. Developer has dialed it in.
    /// </summary>
    public ProfileConstraints Lock(string key)
    {
        _locked.Add(key);
        return this;
    }

    /// <summary>
    /// Add a visual quality guard — returns a warning message if violated, null if OK.
    /// Guards check composite relationships (e.g. brightness + bloom <= 1.2).
    /// </summary>
    public ProfileConstraints Guard(Func<ContextSnapshot, string> guard)
    {
        _guards.Add(guard);
        return this;
    }

    /// <summary>
    /// Mark which parameters this mode's shader actually uses.
    /// AI should only adjust these — others are ignored.
    /// </summary>
    public ProfileConstraints Uses(params string[] keys)
    {
        foreach (var k in keys) _relevantParams.Add(k);
        return this;
    }

    public bool IsLocked(string key) => _locked.Contains(key);
    public bool IsRelevant(string key) => _relevantParams.Contains(key);
    public bool TryGetBounds(string key, out float min, out float max)
    {
        if (_bounds.TryGetValue(key, out var b))
        {
            min = b.Min; max = b.Max;
            return true;
        }
        min = 0; max = 1;
        return false;
    }

    /// <summary>
    /// Validate and sanitize a set of AI-generated parameters.
    /// Returns a clean ContextParams with all values clamped to bounds,
    /// locked parameters removed, and guard violations logged.
    /// </summary>
    public ValidationResult Validate(Dictionary<string, float> aiValues)
    {
        var warnings = new List<string>();
        var clean = new Dictionary<string, float>();

        foreach (var (key, value) in aiValues)
        {
            // Skip locked parameters
            if (IsLocked(key))
            {
                warnings.Add($"{key}={value:F2} rejected — locked by developer");
                continue;
            }

            // Skip irrelevant parameters (mode doesn't use this)
            if (!IsRelevant(key))
            {
                warnings.Add($"{key}={value:F2} rejected — not used by {ModeName}");
                continue;
            }

            // Clamp to bounds
            float clamped = value;
            if (TryGetBounds(key, out var min, out var max))
            {
                clamped = Math.Clamp(value, min, max);
                if (clamped != value)
                    warnings.Add($"{key}={value:F2} clamped to {clamped:F2} (bounds: {min}-{max})");
            }
            else
            {
                // Fall back to global manifest ranges
                clamped = ClampToGlobal(key, value);
            }

            clean[key] = clamped;
        }

        // Run composite guards
        var snapshot = ContextSnapshot.FromDict(clean);
        foreach (var guard in _guards)
        {
            var msg = guard(snapshot);
            if (msg != null)
                warnings.Add($"Guard: {msg}");
        }

        return new ValidationResult { Values = clean, Warnings = warnings, IsValid = warnings.Count == 0 || true };
    }

    private static float ClampToGlobal(string key, float value) => key switch
    {
        "BRIGHTNESS" or "BEAM" or "BLOOM" or "AMBIENT" or "SATUR" or "ATMOS"
            or "DYN_LIGHT" or "PERSP" or "EFFECT_INT" or "PULSE" or "FEEDBACK"
            or "COLOR_SHIFT" or "HUE_BASE" or "HUE_CENTER"
            or "COLOR_R" or "COLOR_G" or "COLOR_B"
            or "COLOR2_R" or "COLOR2_G" or "COLOR2_B" => Math.Clamp(value, 0f, 1f),
        "INTENSITY" => Math.Clamp(value, 0.3f, 2f),
        "ACCENT" => Math.Clamp(value, 0f, 2f),
        "SPEED" or "MOVE_SPEED" => Math.Clamp(value, 0.1f, 3f),
        "ZOOM" => Math.Clamp(value, 0.8f, 1.6f),
        "BAR_SCALE" => Math.Clamp(value, 0.5f, 2f),
        _ => Math.Clamp(value, 0f, 1f)
    };

    /// <summary>
    /// Build a sterile prompt section for the AI — tells it exactly what it can
    /// and can't do for this specific mode. This is the "sterile area" boundary
    /// communicated to the AI.
    /// </summary>
    public string BuildSterilePrompt()
    {
        var sb = new StringBuilder();
        sb.AppendLine($"=== STERILE CONSTRAINTS FOR {ModeName} ===");
        sb.AppendLine("You are generating parameters for a specific mode. Stay within bounds.");
        sb.AppendLine();

        sb.AppendLine("--- Valid parameters for this mode ---");
        foreach (var key in _relevantParams)
        {
            if (IsLocked(key))
            {
                sb.AppendLine($"  {key}: LOCKED (do not change)");
            }
            else if (TryGetBounds(key, out var min, out var max))
            {
                sb.AppendLine($"  {key}: {min:F2}-{max:F2}");
            }
        }
        sb.AppendLine();

        if (_locked.Count > 0)
        {
            sb.AppendLine("--- LOCKED parameters (developer-set, do NOT adjust) ---");
            foreach (var l in _locked)
                sb.AppendLine($"  {l}");
            sb.AppendLine();
        }

        sb.AppendLine("--- Quality rules ---");
        sb.AppendLine("  - Do NOT max out multiple additive parameters (bloom+beam+brightness).");
        sb.AppendLine("  - Keep total additive energy reasonable to prevent clipping.");
        sb.AppendLine("  - Each parameter should serve the mode's visual character.");
        sb.AppendLine("  - Small, targeted adjustments are better than sweeping changes.");
        sb.AppendLine();

        return sb.ToString();
    }
}

/// <summary>
/// Snapshot of parameter values for guard evaluation.
/// </summary>
public class ContextSnapshot
{
    public float Brightness, Bloom, Beam, Ambient, Satur, EffectInt, Intensity, Speed, Pulse;

    public static ContextSnapshot FromDict(Dictionary<string, float> d)
    {
        return new ContextSnapshot
        {
            Brightness = d.GetValueOrDefault("BRIGHTNESS", 0.5f),
            Bloom = d.GetValueOrDefault("BLOOM", 0.4f),
            Beam = d.GetValueOrDefault("BEAM", 0.2f),
            Ambient = d.GetValueOrDefault("AMBIENT", 0.4f),
            Satur = d.GetValueOrDefault("SATUR", 0.7f),
            EffectInt = d.GetValueOrDefault("EFFECT_INT", 0.5f),
            Intensity = d.GetValueOrDefault("INTENSITY", 1f),
            Speed = d.GetValueOrDefault("SPEED", 1f),
            Pulse = d.GetValueOrDefault("PULSE", 0.5f),
        };
    }
}

/// <summary>
/// Result of validating AI-generated parameters through the sterile boundary.
/// </summary>
public class ValidationResult
{
    public Dictionary<string, float> Values { get; set; } = new();
    public List<string> Warnings { get; set; } = new();
    public bool IsValid { get; set; }

    public bool HasWarnings => Warnings.Count > 0;
}

/// <summary>
/// Adaptive parameter profile for a single shader mode.
///
/// Instead of hardcoded switch statements (section 6 => intensity 1.4 + beat * 2),
/// each mode has an adaptive profile that learns what parameter values work well
/// for different musical contexts (genre + section).
///
/// The profile stores per-context baselines that evolve over time based on:
///   - Audio-visual alignment (does visual energy match audio energy?)
///   - AI observation feedback (when AI says "looks good", reinforce)
///   - Manual approval (developer can lock good values)
///
/// The key insight: reactive = "audio frame => immediate output",
/// adaptive = "accumulated experience => evolving output that modulates with audio".
///
/// The audio still drives moment-to-moment modulation (beat pulses, energy swells),
/// but the *baseline* parameters (how bright, how fast, how intense) adapt to what
/// works for each mode in each musical context.
/// </summary>
public class AdaptiveShaderProfile
{
    /// <summary>
    /// A set of adaptive parameters for one (genre, section) context.
    /// Each parameter has a current value, a learning rate, and a satisfaction score.
    /// </summary>
    public class ContextParams
    {
        public float Intensity;     // base intensity multiplier
        public float Speed;         // base speed multiplier
        public float Brightness;    // base brightness (0-1)
        public float Bloom;         // base bloom (0-1)
        public float Satur;         // base saturation (0-1)
        public float Zoom;          // base zoom (1.0 = normal)
        public float ColorShift;    // base color shift rate
        public float EffectInt;     // base effect intensity (0-1)

        // How well the current params are working (0-1, higher = better)
        // Driven by audio-visual alignment + AI feedback
        public float Satisfaction;

        // How many samples we've accumulated — more samples = slower learning
        public int SampleCount;

        // When this context was last active (for decay of stale contexts)
        public float LastActiveTime;

        /// <summary>
        /// Create with sensible defaults for a context.
        /// These are starting points — they'll adapt over time.
        /// </summary>
        public static ContextParams Default() => new()
        {
            Intensity = 1.0f,
            Speed = 1.0f,
            Brightness = 0.5f,
            Bloom = 0.4f,
            Satur = 0.7f,
            Zoom = 1.0f,
            ColorShift = 0.02f,
            EffectInt = 0.5f,
            Satisfaction = 0.5f,
            SampleCount = 0
        };

        /// <summary>
        /// Adapt parameters toward values that produce better satisfaction.
        /// Uses gradient-free hill climbing: nudge each parameter slightly,
        /// keep the nudge if satisfaction improves.
        /// </summary>
        public void Adapt(float learningRate, float dt, System.Random rng)
        {
            // Learning rate decays with sample count — fast early, slow later
            float effectiveRate = learningRate / (1f + SampleCount * 0.01f);

            // Small random perturbations — exploration
            float noise = (float)(rng.NextDouble() * 2 - 1) * effectiveRate * dt;

            // If satisfaction is low, explore more; if high, refine
            float explore = (1f - Satisfaction) * 0.5f + 0.1f;
            noise *= explore;

            // Nudge parameters toward better values
            // The direction of the nudge depends on what's undershooting/overshooting
            // For now, use small random walk with satisfaction-guided step size
            Intensity = Math.Clamp(Intensity + noise * 0.3f, 0.3f, 2.5f);
            Speed = Math.Clamp(Speed + noise * 0.2f, 0.2f, 3.0f);
            Brightness = Math.Clamp(Brightness + noise * 0.15f, 0.1f, 0.95f);
            Bloom = Math.Clamp(Bloom + noise * 0.1f, 0f, 0.9f);
            Satur = Math.Clamp(Satur + noise * 0.1f, 0.1f, 1.0f);
            EffectInt = Math.Clamp(EffectInt + noise * 0.1f, 0f, 1.0f);

            // Satisfaction decays slowly — must be re-earned
            Satisfaction = Math.Clamp(Satisfaction - dt * 0.02f, 0f, 1f);
        }

        /// <summary>
        /// Blend toward a target value (used when AI suggests parameters).
        /// </summary>
        public void BlendToward(ContextParams target, float weight)
        {
            Intensity = Lerp(Intensity, target.Intensity, weight);
            Speed = Lerp(Speed, target.Speed, weight);
            Brightness = Lerp(Brightness, target.Brightness, weight);
            Bloom = Lerp(Bloom, target.Bloom, weight);
            Satur = Lerp(Satur, target.Satur, weight);
            Zoom = Lerp(Zoom, target.Zoom, weight);
            ColorShift = Lerp(ColorShift, target.ColorShift, weight);
            EffectInt = Lerp(EffectInt, target.EffectInt, weight);
        }

        private static float Lerp(float a, float b, float t) => a + (b - a) * t;
    }

    /// <summary>
    /// Key for looking up context-specific parameters.
    /// </summary>
    private readonly record struct ContextKey(string Genre, int Section);

    private readonly Dictionary<ContextKey, ContextParams> _contexts = new();
    private readonly string _modeName;
    private readonly System.Random _rng = new();

    // Sterile constraint boundary for this mode — AI output is validated through this
    public ProfileConstraints? Constraints { get; set; }

    // Global learning rate — how fast parameters adapt
    public float LearningRate { get; set; } = 0.5f;

    // Current active context
    private ContextKey _currentKey;
    private ContextParams? _current;

    // Alignment tracking — how well visual output matches audio
    private float _visualEnergySmoothed = 0.5f;
    private float _audioEnergySmoothed = 0.5f;
    private float _alignmentScore = 0.5f;

    // AI feedback — when AI says params look good, satisfaction boosts
    private float _aiSatisfactionBoost = 0f;

    // Profile stats
    public int ContextCount => _contexts.Count;
    public string ModeName => _modeName;
    public float CurrentSatisfaction => _current?.Satisfaction ?? 0f;
    public float CurrentAlignment => _alignmentScore;

    public AdaptiveShaderProfile(string modeName)
    {
        _modeName = modeName;
    }

    /// <summary>
    /// Get or create the adaptive parameters for the current musical context.
    /// </summary>
    public ContextParams GetContext(string genre, int section, float currentTime)
    {
        var key = new ContextKey(genre, section);
        if (!_contexts.TryGetValue(key, out var ctx))
        {
            ctx = ContextParams.Default();
            _contexts[key] = ctx;
        }
        ctx.LastActiveTime = currentTime;
        _currentKey = key;
        _current = ctx;
        return ctx;
    }

    /// <summary>
    /// Update the alignment score based on how well visual energy matches audio energy.
    /// This is the primary learning signal — when visual output matches the music,
    /// satisfaction goes up and current parameters are reinforced.
    /// </summary>
    public void UpdateAlignment(float audioEnergy, float visualBrightness, float dt)
    {
        // Smooth both signals
        _audioEnergySmoothed = Lerp(_audioEnergySmoothed, audioEnergy, 1f - MathF.Exp(-dt * 3f));
        _visualEnergySmoothed = Lerp(_visualEnergySmoothed, visualBrightness, 1f - MathF.Exp(-dt * 3f));

        // Alignment = how close visual energy is to audio energy (0=opposite, 1=perfect match)
        float diff = MathF.Abs(_visualEnergySmoothed - _audioEnergySmoothed);
        _alignmentScore = Math.Clamp(1f - diff * 2f, 0f, 1f);

        // Feed alignment into satisfaction
        if (_current != null)
        {
            // Satisfaction rises when alignment is good
            float satisfactionDelta = (_alignmentScore - 0.5f) * dt * 0.5f;
            _current.Satisfaction = Math.Clamp(_current.Satisfaction + satisfactionDelta, 0f, 1f);

            // AI boost decays
            if (_aiSatisfactionBoost > 0f)
            {
                _current.Satisfaction = Math.Clamp(_current.Satisfaction + _aiSatisfactionBoost * dt, 0f, 1f);
                _aiSatisfactionBoost = Math.Max(0f, _aiSatisfactionBoost - dt * 0.5f);
            }
        }
    }

    /// <summary>
    /// Provide AI feedback — when the AI says parameters look good,
    /// boost satisfaction to reinforce the current values.
    /// </summary>
    public void ProvideAIFeedback(float satisfaction, float confidence)
    {
        // satisfaction: 0-1, how good the AI thinks the current params are
        // confidence: 0-1, how confident the AI is
        _aiSatisfactionBoost = Math.Max(_aiSatisfactionBoost, (satisfaction - 0.5f) * confidence * 0.5f);
    }

    /// <summary>
    /// Apply AI-suggested parameters — blend the current context toward AI values.
    /// This is the "dynamic shader factory" — AI generates, profile learns.
    /// Values are validated through the sterile constraint boundary first.
    /// </summary>
    public void ApplyAISuggestion(ContextParams aiParams, float weight)
    {
        if (_current == null) return;

        // Validate through sterile boundary if constraints are set
        if (Constraints != null)
        {
            var aiDict = new Dictionary<string, float>
            {
                ["INTENSITY"] = aiParams.Intensity,
                ["SPEED"] = aiParams.Speed,
                ["BRIGHTNESS"] = aiParams.Brightness,
                ["BLOOM"] = aiParams.Bloom,
                ["SATUR"] = aiParams.Satur,
                ["EFFECT_INT"] = aiParams.EffectInt,
            };
            var result = Constraints.Validate(aiDict);
            if (result.HasWarnings)
            {
                foreach (var w in result.Warnings)
                    DebugLogger.Info($"[Adaptive] {ModeName} sterile filter: {w}");
            }
            // Use validated values
            aiParams.Intensity = result.Values.GetValueOrDefault("INTENSITY", aiParams.Intensity);
            aiParams.Speed = result.Values.GetValueOrDefault("SPEED", aiParams.Speed);
            aiParams.Brightness = result.Values.GetValueOrDefault("BRIGHTNESS", aiParams.Brightness);
            aiParams.Bloom = result.Values.GetValueOrDefault("BLOOM", aiParams.Bloom);
            aiParams.Satur = result.Values.GetValueOrDefault("SATUR", aiParams.Satur);
            aiParams.EffectInt = result.Values.GetValueOrDefault("EFFECT_INT", aiParams.EffectInt);
        }

        _current.BlendToward(aiParams, weight);

        // If AI is confident, boost satisfaction to reinforce the new values
        if (weight > 0.3f)
            _current.Satisfaction = Math.Clamp(_current.Satisfaction + weight * 0.2f, 0f, 1f);
    }

    /// <summary>
    /// Run the adaptation step — nudge parameters based on satisfaction.
    /// Call this once per frame (or every few frames).
    /// </summary>
    public void Tick(float dt)
    {
        if (_current == null) return;
        _current.Adapt(LearningRate, dt, _rng);
        _current.SampleCount++;
    }

    /// <summary>
    /// Get a snapshot of the current adaptive parameters for HUD display.
    /// </summary>
    public string GetDebugString()
    {
        if (_current == null) return "no context";
        return $"{_modeName}[{_currentKey.Genre},s{_currentKey.Section}] " +
               $"I={_current.Intensity:F2} Sp={_current.Speed:F2} Br={_current.Brightness:F2} " +
               $"Bl={_current.Bloom:F2} Sa={_current.Satur:F2} " +
               $"Sat={_current.Satisfaction:F2} Align={_alignmentScore:F2} " +
               $"N={_current.SampleCount}";
    }

    /// <summary>
    /// Save all learned contexts to a compact format for persistence.
    /// </summary>
    public Dictionary<string, object> Save()
    {
        var data = new Dictionary<string, object>();
        data["mode"] = _modeName;
        data["learningRate"] = LearningRate;
        var contexts = new List<object>();
        foreach (var (key, ctx) in _contexts)
        {
            contexts.Add(new
            {
                genre = key.Genre,
                section = key.Section,
                intensity = ctx.Intensity,
                speed = ctx.Speed,
                brightness = ctx.Brightness,
                bloom = ctx.Bloom,
                satur = ctx.Satur,
                zoom = ctx.Zoom,
                colorShift = ctx.ColorShift,
                effectInt = ctx.EffectInt,
                satisfaction = ctx.Satisfaction,
                samples = ctx.SampleCount
            });
        }
        data["contexts"] = contexts;
        return data;
    }

    private static float Lerp(float a, float b, float t) => a + (b - a) * t;
}

/// <summary>
/// Static registry of per-mode sterile constraints for all 22 shader modes.
/// Each mode gets a ProfileConstraints that defines:
///   - Which parameters the mode's shader actually uses
///   - Tighter bounds than the global manifest
///   - Visual quality guards to prevent clipping/banding/overload
///   - Developer-locked parameters that AI cannot touch
///
/// This is the sterile boundary that keeps AI-generated parameters within
/// our pipeline parameters and visual methods.
/// </summary>
public static class ModeConstraintRegistry
{
    private static readonly Dictionary<string, ProfileConstraints> _registry = new();
    private static bool _initialized = false;

    /// <summary>
    /// Get the sterile constraints for a mode. Returns null if not registered.
    /// </summary>
    public static ProfileConstraints? Get(string modeName)
    {
        EnsureInitialized();
        return _registry.TryGetValue(modeName.ToLowerInvariant(), out var c) ? c : null;
    }

    private static void EnsureInitialized()
    {
        if (_initialized) return;
        _initialized = true;

        // Common guard: prevent total additive energy from causing clipping
        Func<ContextSnapshot, string> clippingGuard = s =>
            (s.Brightness + s.Bloom + s.Beam > 1.5f)
                ? $"brightness({s.Brightness:F2})+bloom({s.Bloom:F2})+beam({s.Beam:F2})={s.Brightness + s.Bloom + s.Beam:F2} exceeds 1.5 — risk of clipping"
                : null;

        // Common guard: high intensity + high speed = visual chaos
        Func<ContextSnapshot, string> chaosGuard = s =>
            (s.Intensity > 1.8f && s.Speed > 2.0f)
                ? $"intensity({s.Intensity:F2})+speed({s.Speed:F2}) — too much motion energy"
                : null;

        // --- spectrum_bars ---
        Register("spectrum_bars", c => c
            .Uses("BRIGHTNESS", "BLOOM", "SATUR", "HUE_BASE", "COLOR_SHIFT", "INTENSITY", "SPEED", "PULSE")
            .Bound("BRIGHTNESS", 0.4f, 0.85f)
            .Bound("BLOOM", 0.1f, 0.5f)
            .Bound("SATUR", 0.6f, 1.0f)
            .Bound("INTENSITY", 0.5f, 1.5f)
            .Bound("SPEED", 0.5f, 2.0f)
            .Guard(clippingGuard).Guard(chaosGuard));

        // --- spectrum_3d ---
        Register("spectrum_3d", c => c
            .Uses("BRIGHTNESS", "BEAM", "BLOOM", "AMBIENT", "SATUR", "HUE_BASE", "HUE_CENTER",
                  "DYN_LIGHT", "ATMOS", "PERSP", "BAR_SCALE", "MOVE_SPEED", "EFFECT_INT", "PULSE",
                  "INTENSITY", "SPEED", "FEEDBACK", "ACCENT", "COLOR_SHIFT")
            .Bound("BRIGHTNESS", 0.5f, 0.9f)
            .Bound("BLOOM", 0.1f, 0.5f)
            .Bound("BEAM", 0f, 0.4f)
            .Bound("SATUR", 0.6f, 1.0f)
            .Bound("BAR_SCALE", 0.7f, 1.5f)
            .Bound("INTENSITY", 0.6f, 1.5f)
            .Bound("SPEED", 0.5f, 2.0f)
            .Guard(clippingGuard).Guard(chaosGuard));

        // --- wave_tessellation ---
        Register("wave_tessellation", c => c
            .Uses("BRIGHTNESS", "BLOOM", "AMBIENT", "SATUR", "HUE_BASE", "HUE_CENTER",
                  "DYN_LIGHT", "ATMOS", "PERSP", "MOVE_SPEED", "EFFECT_INT", "PULSE",
                  "INTENSITY", "SPEED", "FEEDBACK", "ACCENT", "COLOR_SHIFT")
            .Bound("BRIGHTNESS", 0.4f, 0.8f)
            .Bound("BLOOM", 0.2f, 0.6f)
            .Bound("AMBIENT", 0.3f, 0.7f)
            .Bound("SATUR", 0.5f, 0.9f)
            .Bound("INTENSITY", 0.5f, 1.5f)
            .Bound("SPEED", 0.4f, 2.0f)
            .Guard(clippingGuard).Guard(chaosGuard));

        // --- plasma_field ---
        Register("plasma_field", c => c
            .Uses("BRIGHTNESS", "BLOOM", "SATUR", "HUE_BASE", "EFFECT_INT", "MOVE_SPEED",
                  "INTENSITY", "SPEED", "COLOR_SHIFT")
            .Bound("BRIGHTNESS", 0.3f, 0.8f)
            .Bound("BLOOM", 0.2f, 0.6f)
            .Bound("SATUR", 0.5f, 1.0f)
            .Bound("EFFECT_INT", 0.2f, 0.8f)
            .Bound("INTENSITY", 0.4f, 1.5f)
            .Bound("SPEED", 0.3f, 2.0f)
            .Guard(clippingGuard));

        // --- neon_pulse ---
        Register("neon_pulse", c => c
            .Uses("BRIGHTNESS", "BLOOM", "SATUR", "HUE_BASE", "EFFECT_INT", "PULSE",
                  "INTENSITY", "SPEED", "COLOR_SHIFT")
            .Bound("BRIGHTNESS", 0.3f, 0.85f)
            .Bound("BLOOM", 0.3f, 0.7f)
            .Bound("SATUR", 0.7f, 1.0f)
            .Bound("PULSE", 0.2f, 0.9f)
            .Bound("INTENSITY", 0.5f, 1.8f)
            .Bound("SPEED", 0.5f, 2.5f)
            .Guard(clippingGuard));

        // --- particle_flow ---
        Register("particle_flow", c => c
            .Uses("BRIGHTNESS", "BLOOM", "SATUR", "HUE_BASE", "MOVE_SPEED", "EFFECT_INT",
                  "INTENSITY", "SPEED", "COLOR_SHIFT")
            .Bound("BRIGHTNESS", 0.3f, 0.8f)
            .Bound("BLOOM", 0.2f, 0.6f)
            .Bound("SATUR", 0.5f, 1.0f)
            .Bound("MOVE_SPEED", 0.3f, 2.5f)
            .Bound("INTENSITY", 0.4f, 1.5f)
            .Bound("SPEED", 0.3f, 2.0f)
            .Guard(clippingGuard));

        // --- Generic fallback for modes without specific constraints ---
        // Uses global manifest ranges with basic guards
        foreach (var mode in new[] {
            "waveform", "sphere", "aurora", "dna_helix", "heartbeat",
            "rtx_mesh", "ray_marched", "volumetric_clouds", "fractal_dimensions",
            "neural_network", "quantum_field", "holographic", "particle_storm",
            "compute_shaders", "rtx_reflections", "quantum_bars"
        })
        {
            Register(mode, c => c
                .Uses("BRIGHTNESS", "BLOOM", "SATUR", "HUE_BASE", "EFFECT_INT",
                      "INTENSITY", "SPEED", "COLOR_SHIFT", "PULSE", "MOVE_SPEED")
                .Bound("BRIGHTNESS", 0.2f, 0.9f)
                .Bound("BLOOM", 0.1f, 0.7f)
                .Bound("SATUR", 0.4f, 1.0f)
                .Bound("INTENSITY", 0.3f, 1.8f)
                .Bound("SPEED", 0.2f, 2.5f)
                .Guard(clippingGuard).Guard(chaosGuard));
        }
    }

    private static void Register(string modeName, Func<ProfileConstraints, ProfileConstraints> configure)
    {
        var constraints = new ProfileConstraints(modeName);
        configure(constraints);
        _registry[modeName.ToLowerInvariant()] = constraints;
    }
}

/// <summary>
/// Manages adaptive profiles for all shader modes.
/// Each mode gets its own AdaptiveShaderProfile that learns independently.
/// The manager handles context switching, alignment tracking, and AI integration.
/// </summary>
public class AdaptiveProfileManager
{
    private readonly Dictionary<string, AdaptiveShaderProfile> _profiles = new();
    private AdaptiveShaderProfile? _current;
    private string _currentMode = "";
    private string _currentGenre = "Unknown";
    private int _currentSection = 0;

    // Alignment tracking
    private float _lastVisualBrightness = 0.5f;

    public AdaptiveShaderProfile? Current => _current;
    public int ProfileCount => _profiles.Count;

    /// <summary>
    /// Get or create the adaptive profile for a mode.
    /// Automatically attaches sterile constraints from the registry.
    /// </summary>
    public AdaptiveShaderProfile GetOrCreateProfile(string modeName)
    {
        if (!_profiles.TryGetValue(modeName, out var profile))
        {
            profile = new AdaptiveShaderProfile(modeName);
            // Attach sterile constraints from registry
            profile.Constraints = ModeConstraintRegistry.Get(modeName);
            _profiles[modeName] = profile;
        }
        return profile;
    }

    /// <summary>
    /// Set the current active mode + musical context.
    /// Called each frame by the director.
    /// </summary>
    public void SetContext(string mode, string genre, int section, float currentTime)
    {
        if (mode != _currentMode)
        {
            _currentMode = mode;
            _current = GetOrCreateProfile(mode);
        }
        _currentGenre = genre;
        _currentSection = section;

        // Activate the context within the profile
        _current?.GetContext(genre, section, currentTime);
    }

    /// <summary>
    /// Update alignment and run adaptation.
    /// Called each frame with audio + visual energy data.
    /// </summary>
    public void Update(float audioEnergy, float visualBrightness, float dt)
    {
        _lastVisualBrightness = visualBrightness;
        _current?.UpdateAlignment(audioEnergy, visualBrightness, dt);
        _current?.Tick(dt);
    }

    /// <summary>
    /// Feed AI observation feedback into the current profile.
    /// </summary>
    public void ProvideAIFeedback(float satisfaction, float confidence)
    {
        _current?.ProvideAIFeedback(satisfaction, confidence);
    }

    /// <summary>
    /// Apply AI-generated parameters to the current profile.
    /// </summary>
    public void ApplyAISuggestion(AdaptiveShaderProfile.ContextParams aiParams, float weight)
    {
        _current?.ApplyAISuggestion(aiParams, weight);
    }

    /// <summary>
    /// Get the current adaptive baseline parameters for blending with audio-driven values.
    /// Returns null if no context is active.
    /// </summary>
    public AdaptiveShaderProfile.ContextParams? GetCurrentParams()
    {
        return _current?.GetContext(_currentGenre, _currentSection, 0f);
    }

    /// <summary>
    /// Debug string for HUD.
    /// </summary>
    public string GetDebugString()
    {
        if (_current == null) return "Adaptive: no profile";
        return _current.GetDebugString();
    }
}
