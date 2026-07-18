using System;
using StageSimWASAPI;

namespace DXRenderer;

/// <summary>
/// Visual performance director — reads the audio brain and produces raw visual targets.
/// All smoothing/decay is intentionally left to VisualSmoother so the GPU upload is always
/// the final, decayed state.
/// </summary>
public class VisualDirectorBot
{
    public enum MoodPreset { Chill, Energetic, SciFi, Organic }
    public enum DirectorMode { Off, Observe, Auto }

    private readonly VisualBehaviorGraph _graph;
    private DirectorMode _mode = DirectorMode.Auto;

    // Adaptive profile manager — per-mode, per-context learning baselines
    public AdaptiveProfileManager AdaptiveProfiles { get; } = new();

    // Current mode name (set externally by Program.cs from renderer.CurrentMode)
    public string CurrentModeName { get; set; } = "spectrum_bars";

    // Current genre from brain (set externally)
    public string CurrentGenre { get; set; } = "Unknown";

    public DirectorMode Mode
    {
        get => _mode;
        set => _mode = value;
    }

    public bool Enabled => _mode == DirectorMode.Auto;
    public bool Observing => _mode == DirectorMode.Observe;
    public OllamaVisionFeedback? VisionFeedback { get; set; }
    public MoodPreset Mood { get; set; } = MoodPreset.Energetic;
    public string CurrentGraphNode => _graph.CurrentNodeName;
    public string ModeLabel => _mode switch
    {
        DirectorMode.Auto => "AUTO",
        DirectorMode.Observe => "OBSERVE",
        DirectorMode.Off => "OFF",
        _ => "?"
    };

    public VisualDirectorBot()
    {
        _graph = VisualBehaviorGraph.CreateDefault();
    }

    public RenderGraph Compose(QuadBufferedVisuals.VisualFrame frame)
    {
        // OFF or OBSERVE: return a neutral pass-through graph.
        // OBSERVE still logs analysis but doesn't modify visuals.
        if (_mode == DirectorMode.Off || _mode == DirectorMode.Observe)
        {
            if (_mode == DirectorMode.Observe)
            {
                // Log observation data for debugging/HUD
                ObserveFrame(frame);
            }
            return new RenderGraph();
        }

        var graph = new RenderGraph();
        int section = Math.Clamp(frame.Section, 0, 10);

        float beat = frame.BeatIntensity;
        float transient = frame.Transient;
        float kick = frame.KickLevel;
        float overall = frame.Overall;
        float bpmFactor = Math.Clamp((frame.BPM - 60f) / 140f, 0f, 1f);

        // === Reactive layer (audio-driven, moment-to-moment) ===
        // These are the instantaneous audio-reactive values that pulse and swell with the music.
        float reactiveIntensity = section switch
        {
            1 or 9 => 0.5f + overall * 0.8f,
            2 => 0.7f + overall * 1.2f,
            3 or 5 => 0.9f + overall * 1.5f + frame.BeatAnticipation,
            6 => 1.4f + beat * 2f,
            4 => 1.1f + beat * 0.8f,
            7 or 10 => 0.7f + frame.SpectralClarity * 0.4f,
            _ => 1.0f + overall
        };

        float reactivePulse = beat * (1f + transient * 2f) + kick * 0.5f;
        float reactiveAccent = transient * 2f;
        float reactiveColorShift = 0.01f + bpmFactor * 0.03f + frame.SpectralClarity * 0.005f;

        float reactiveSpeed = section switch
        {
            1 or 9 => 0.4f,
            2 => 0.7f,
            3 or 5 => 0.9f + overall,
            6 => 1.6f + beat * 1.2f,
            _ => 1.0f
        };

        float reactiveZoom = section switch
        {
            1 or 9 => 1.0f,
            3 or 5 => 1.0f + overall * 0.3f,
            6 => 1.3f + beat * 0.4f,
            _ => 1.0f
        };

        // Frequency layer: high centroid → brighter/faster, low centroid → warmer/slower.
        float centroidNorm = Math.Clamp(frame.SpectralCentroid / 12000f, 0f, 1f);
        reactiveColorShift += centroidNorm * 0.05f;
        reactiveSpeed += centroidNorm * 0.1f;

        // Apply user mood/theme bias as direct nudges to the raw targets.
        ApplyMoodBias(ref reactiveIntensity, ref reactiveSpeed, ref reactiveColorShift);

        // === Adaptive layer (learned baselines per mode+genre+section) ===
        // The adaptive profile provides baseline multipliers that evolve over time.
        // These modulate the reactive values — the audio still drives moment-to-moment
        // motion, but the *character* (how bright, how fast, how intense) adapts.
        float now = (float)System.DateTime.UtcNow.TimeOfDay.TotalSeconds;
        AdaptiveProfiles.SetContext(CurrentModeName, CurrentGenre, section, now);

        // Update alignment: compare audio energy to visual energy (from fast vision)
        float visualBrightness = VisionFeedback?.FastBrightness ?? overall;
        float dt = 1f / 60f;
        AdaptiveProfiles.Update(overall, visualBrightness, dt);

        var adaptive = AdaptiveProfiles.GetCurrentParams();
        if (adaptive != null)
        {
            // Blend: reactive * adaptive baseline
            // The adaptive baseline acts as a multiplier on the reactive value,
            // so audio still drives the moment-to-moment changes but the overall
            // character adapts to what works for this mode in this context.
            graph.Intensity = reactiveIntensity * adaptive.Intensity;
            graph.Pulse = reactivePulse * (0.5f + adaptive.EffectInt * 0.5f);
            graph.Accent = reactiveAccent * adaptive.EffectInt;
            graph.ColorShift = (reactiveColorShift + adaptive.ColorShift) % 1f;
            graph.Speed = reactiveSpeed * adaptive.Speed;
            graph.Zoom = reactiveZoom * adaptive.Zoom;
            graph.Feedback = frame.MotionPersistence * (0.5f + adaptive.Bloom * 0.5f);
        }
        else
        {
            // Fallback: pure reactive (no adaptive profile yet)
            graph.Intensity = reactiveIntensity;
            graph.Pulse = reactivePulse;
            graph.Accent = reactiveAccent;
            graph.ColorShift = reactiveColorShift % 1f;
            graph.Speed = reactiveSpeed;
            graph.Zoom = reactiveZoom;
            graph.Feedback = frame.MotionPersistence;
        }

        // AI adjustments are routed through AdaptiveProfiles.ApplyAISuggestion()
        // which blends into the adaptive baseline. The director reads that baseline
        // via GetCurrentParams() above. No separate AI override pass needed —
        // the AI shapes the character over time, audio drives moment-to-moment.

        // Fast behavior graph chooses render passes.
        var state = VisualEvalState.FromFrame(frame);
        var passes = _graph.Tick(state, Mood);
        graph.Passes.AddRange(passes);

        // Effect burst as a one-shot full-screen overlay.
        if (frame.TriggerEffectBurst != 0)
        {
            string[] burstMap = { "radial_burst", "shockwave", "colorwave", "sparkle" };
            string burst = burstMap[Math.Clamp(frame.EffectBurstType, 0, 3)];
            graph.Passes.Add(new FullscreenPassNode
            {
                Name = "burst",
                ShaderName = burst,
                Blend = BlendMode.Add,
                BlendWeight = frame.EffectBurstIntensity * graph.Intensity
            });
        }

        return graph;
    }

    private void ObserveFrame(QuadBufferedVisuals.VisualFrame frame)
    {
        // Lightweight observation logging — no visual modifications
        // The director watches the brain and logs what it sees.
        // This data is available to the HUD for display.
        ObservedSection = Math.Clamp(frame.Section, 0, 10);
        ObservedBPM = frame.BPM;
        ObservedOverall = frame.Overall;
        ObservedBeat = frame.BeatIntensity;
        ObservedKick = frame.KickLevel;
        ObservedEnergy = frame.ProfileEnergy;
        ObservedClarity = frame.SpectralClarity;
    }

    // Observed state — read by HUD when in Observe mode
    public int ObservedSection { get; private set; }
    public float ObservedBPM { get; private set; }
    public float ObservedOverall { get; private set; }
    public float ObservedBeat { get; private set; }
    public float ObservedKick { get; private set; }
    public float ObservedEnergy { get; private set; }
    public float ObservedClarity { get; private set; }

    private void ApplyMoodBias(ref float intensity, ref float speed, ref float colorShift)
    {
        switch (Mood)
        {
            case MoodPreset.Chill:
                intensity *= 0.7f;
                speed *= 0.55f;
                colorShift += 0.02f;
                break;
            case MoodPreset.Energetic:
                intensity *= 1.2f;
                speed *= 1.3f;
                colorShift += 0.06f;
                break;
            case MoodPreset.SciFi:
                intensity *= 1.05f;
                speed *= 0.9f;
                colorShift += 0.25f;
                break;
            case MoodPreset.Organic:
                intensity *= 0.9f;
                speed *= 0.75f;
                colorShift -= 0.08f;
                break;
        }
    }
}
