using System;
using System.Collections.Generic;
using StageSimWASAPI;

namespace DXRenderer;

/// <summary>
/// Node in a visual behavior graph.
/// Like smc-autosort's behavior graph, but for music visualization decisions.
/// </summary>
public class VisualGraphNode
{
    public string Name { get; set; } = "";

    // Conditions -> next node name
    public Dictionary<string, string> Checks { get; set; } = new();

    // Action: which visual render passes to add
    public List<RenderPassNode> Actions { get; set; } = new();

    // Optional: ask LLM for this node
    public bool UseLlm { get; set; }
}

/// <summary>
/// Condition evaluator for the visual behavior graph.
/// Checks against AudioUBO-like state values.
/// </summary>
public static class VisualConditionEvaluator
{
    public static bool Eval(string condition, VisualEvalState state)
    {
        // Format: "energy > 0.5", "section == 6", "beat > 0.3"
        var parts = condition.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 3) return false;

        string key = parts[0];
        string op = parts[1];
        string valStr = parts[2];

        float a = GetValue(key, state);
        if (!float.TryParse(valStr, out float b)) return false;

        return op switch
        {
            ">" => a > b,
            ">=" => a >= b,
            "<" => a < b,
            "<=" => a <= b,
            "==" => Math.Abs(a - b) < 0.001f,
            "!=" => Math.Abs(a - b) >= 0.001f,
            _ => false
        };
    }

    private static float GetValue(string key, VisualEvalState s)
    {
        return key.ToLowerInvariant() switch
        {
            "energy" => s.Overall,
            "beat" => s.BeatIntensity,
            "kick" => s.KickLevel,
            "bpm" => s.BPM,
            "section" => s.Section,
            "confidence" => s.SectionConfidence,
            "anticipation" => s.BeatAnticipation,
            "transient" => s.Transient,
            "spectralclarity" => s.SpectralClarity,
            "motionpersistence" => s.MotionPersistence,
            "beams" => s.BeamsActive ? 1 : 0,
            "lasers" => s.LasersActive ? 1 : 0,
            "phrasebeat" => s.PhraseBeat,
            _ => 0f
        };
    }
}

public class VisualEvalState
{
    public float Overall;
    public float BeatIntensity;
    public float KickLevel;
    public float BPM;
    public int Section;
    public float SectionConfidence;
    public float BeatAnticipation;
    public float Transient;
    public float SpectralClarity;
    public float MotionPersistence;
    public bool BeamsActive;
    public bool LasersActive;
    public int PhraseBeat;

    public static VisualEvalState FromFrame(QuadBufferedVisuals.VisualFrame f)
    {
        return new VisualEvalState
        {
            Overall = f.Overall,
            BeatIntensity = f.BeatIntensity,
            KickLevel = f.KickLevel,
            BPM = f.BPM,
            Section = f.Section,
            SectionConfidence = f.SectionConfidence,
            BeatAnticipation = f.BeatAnticipation,
            Transient = f.Transient,
            SpectralClarity = f.SpectralClarity,
            MotionPersistence = f.MotionPersistence,
            BeamsActive = f.BeamsActive != 0,
            LasersActive = f.DynamicLightsActive != 0,
            PhraseBeat = f.PhraseBeat
        };
    }
}

/// <summary>
/// Behavior graph for visualization: walks nodes based on musical state and
/// emits render-pass actions. Inspired by smc-autosort's BehaviorGraph.
/// </summary>
public class VisualBehaviorGraph
{
    private readonly Dictionary<string, VisualGraphNode> _nodes;
    private string _currentNode = "start";
    private float _lastNodeTime = 0;
    private const float NodeDwell = 2.0f;

    public string CurrentNodeName => _currentNode;
    public VisualDirectorBot.MoodPreset Mood { get; set; } = VisualDirectorBot.MoodPreset.Energetic;

    public VisualBehaviorGraph(Dictionary<string, VisualGraphNode> nodes)
    {
        _nodes = nodes;
    }

    /// <summary>
    /// Default visualization graph tuned for music reactivity.
    /// </summary>
    public static VisualBehaviorGraph CreateDefault()
    {
        return new VisualBehaviorGraph(new Dictionary<string, VisualGraphNode>
        {
            ["start"] = new()
            {
                Name = "start",
                Checks = new()
                {
                    ["section == 6"] = "drop",
                    ["section == 5"] = "buildup",
                    ["section == 4"] = "chorus",
                    ["section == 7"] = "breakdown",
                    ["energy > 0.45"] = "high_energy",
                    ["energy < 0.08"] = "ambient",
                    ["default"] = "groove"
                }
            },
            ["drop"] = new()
            {
                Name = "drop",
                Checks = new()
                {
                    ["section != 6"] = "start",
                    ["default"] = "drop"
                },
                Actions = new()
                {
                    new FullscreenPassNode { Name = "base", ShaderName = "spectrum_bars" },
                    new ParticlePassNode { Name = "particles", Blend = BlendMode.Add, BlendWeight = 1.0f, ParticleCount = 65536, VortexStrength = 3.0f },
                    new BeamPassNode { Name = "beams", Blend = BlendMode.Add, BlendWeight = 0.8f, BeamCount = 48 }
                }
            },
            ["buildup"] = new()
            {
                Name = "buildup",
                Checks = new()
                {
                    ["section != 5"] = "start",
                    ["default"] = "buildup"
                },
                Actions = new()
                {
                    new FullscreenPassNode { Name = "base", ShaderName = "spectrum_bars" },
                    new BeamPassNode { Name = "beams", Blend = BlendMode.Add, BlendWeight = 0.5f, BeamCount = 24 }
                }
            },
            ["chorus"] = new()
            {
                Name = "chorus",
                Checks = new()
                {
                    ["section != 4"] = "start",
                    ["default"] = "chorus"
                },
                Actions = new()
                {
                    new FullscreenPassNode { Name = "base", ShaderName = "spectrum_bars" },
                    new ParticlePassNode { Name = "particles", Blend = BlendMode.Add, BlendWeight = 0.7f, ParticleCount = 32768, VortexStrength = 1.5f }
                }
            },
            ["breakdown"] = new()
            {
                Name = "breakdown",
                Checks = new()
                {
                    ["section != 7"] = "start",
                    ["default"] = "breakdown"
                },
                Actions = new()
                {
                    new FullscreenPassNode { Name = "base", ShaderName = "spectrum_bars" },
                    new BeamPassNode { Name = "beams", Blend = BlendMode.Add, BlendWeight = 0.3f, BeamCount = 8, BeamThickness = 0.01f }
                }
            },
            ["high_energy"] = new()
            {
                Name = "high_energy",
                Checks = new()
                {
                    ["energy < 0.25"] = "start",
                    ["default"] = "high_energy"
                },
                Actions = new()
                {
                    new FullscreenPassNode { Name = "base", ShaderName = "spectrum_bars" },
                    new BeamPassNode { Name = "beams", Blend = BlendMode.Add, BlendWeight = 0.6f, BeamCount = 32 }
                }
            },
            ["ambient"] = new()
            {
                Name = "ambient",
                Checks = new()
                {
                    ["energy > 0.15"] = "start",
                    ["default"] = "ambient"
                },
                Actions = new()
                {
                    new FullscreenPassNode { Name = "base", ShaderName = "spectrum_bars" }
                }
            },
            ["groove"] = new()
            {
                Name = "groove",
                Checks = new()
                {
                    ["energy > 0.45"] = "high_energy",
                    ["energy < 0.08"] = "ambient",
                    ["default"] = "groove"
                },
                Actions = new()
                {
                    new FullscreenPassNode { Name = "base", ShaderName = "spectrum_bars" },
                    new BeamPassNode { Name = "beams", Blend = BlendMode.Add, BlendWeight = 0.25f, BeamCount = 12 }
                }
            }
        });
    }

    /// <summary>
    /// Tick the graph and return the selected render passes.
    /// </summary>
    public List<RenderPassNode> Tick(VisualEvalState state, VisualDirectorBot.MoodPreset mood)
    {
        Mood = mood;
        float now = (float)Environment.TickCount / 1000.0f;

        if (!_nodes.TryGetValue(_currentNode, out var node))
        {
            _currentNode = "start";
            node = _nodes["start"];
        }

        // Evaluate checks
        string nextNode = "default";
        foreach (var check in node.Checks)
        {
            if (check.Key == "default")
            {
                nextNode = check.Value;
                continue;
            }
            if (VisualConditionEvaluator.Eval(check.Key, state))
            {
                nextNode = check.Value;
                break;
            }
        }

        // Transition with dwell
        if (nextNode != _currentNode && _nodes.ContainsKey(nextNode))
        {
            if (now - _lastNodeTime >= NodeDwell)
            {
                DebugLogger.Info($"[VisualBehaviorGraph] {_currentNode} -> {nextNode}");
                _currentNode = nextNode;
                _lastNodeTime = now;
                node = _nodes[_currentNode];
            }
        }

        return node.Actions;
    }
}
