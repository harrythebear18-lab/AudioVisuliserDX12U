using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace StageSimWASAPI
{
    /// <summary>
    /// AI music director — gives the LightingBrain Ollama-based intelligence.
    ///
    /// Like smc-autosort's GoalPlanner, this:
    ///   1. Takes a high-level musical goal + brain context
    ///   2. Asks a text model to produce a step-by-step plan
    ///   3. Periodically evaluates the brain's decisions and suggests corrections
    ///
    /// Unlike the visual pipeline (OllamaVisionFeedback), this is text-only —
    /// no screenshots. It reasons about genre, section, energy curves, BPM,
    /// and mode selection using the brain's telemetry data.
    /// </summary>
    public class MusicBrainAI : IDisposable
    {
        private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(30) };
        private readonly string _textModel;
        private readonly string _ollamaUrl;
        private readonly CancellationTokenSource _cts = new();
        private Task? _worker;

        private readonly object _lock = new();

        // Current plan from the LLM
        private List<MusicPlanStep> _plan = new();
        private int _planIndex = 0;
        private string _currentGoal = "";

        // Latest AI suggestion for the brain
        private string _lastSuggestion = "";
        private bool _isConnected = false;
        private int _consecutiveFailures = 0;

        // Conversation history
        private readonly List<ChatMsg> _history = new();
        private const int MaxHistory = 6;

        // Brain state snapshot (updated each frame)
        private string _genre = "Unknown";
        private float _genreConfidence = 0f;
        private string _section = "Unknown";
        private float _bpm = 0f;
        private float _energy = 0f;
        private float _energyTrend = 0f;
        private float _spectralClarity = 0f;
        private float _stereoWidth = 0f;
        private string _recommendedMode = "";
        private int _beatCount = 0;
        private int _phraseBeat = 0;

        public bool Enabled { get; set; } = false;
        public bool IsConnected { get { lock (_lock) return _isConnected; } }
        public string CurrentGoal { get { lock (_lock) return _currentGoal; } }
        public string LastSuggestion { get { lock (_lock) return _lastSuggestion; } }
        public List<MusicPlanStep> Plan { get { lock (_lock) return _plan; } }
        public int PlanIndex { get { lock (_lock) return _planIndex; } }
        public int PlanCount => _plan.Count;

        public MusicBrainAI(string? ollamaUrl = null, string? textModel = null)
        {
            _ollamaUrl = ollamaUrl?.TrimEnd('/') ?? "http://localhost:11434";
            _textModel = textModel ?? "qwen2.5-coder:7b";
        }

        /// <summary>
        /// Update the brain state snapshot. Called each frame from Program.cs.
        /// </summary>
        public void UpdateBrainState(LightingBrain brain)
        {
            lock (_lock)
            {
                _genre = brain.GetGenreName();
                _genreConfidence = brain.GenreConfidence;
                _section = brain.GetSectionName();
                _bpm = brain.BPM;
                _energy = brain.OverallNormalized;
                _spectralClarity = brain.SpectralClarity;
                _stereoWidth = brain.StereoWidth;
                _recommendedMode = brain.RecommendedMode.ToString();
                _beatCount = brain.BeatCount;
                _phraseBeat = brain.PhraseBeat;
            }
        }

        /// <summary>
        /// Set a high-level musical goal and ask the LLM to plan it.
        /// Like smc-autosort's GoalPlanner.set_goal().
        /// </summary>
        public async Task SetGoalAsync(string goal)
        {
            lock (_lock) _currentGoal = goal;

            string genre, section;
            float bpm, energy, clarity, stereoWid, genreConf;
            lock (_lock)
            {
                genre = _genre; section = _section;
                bpm = _bpm; energy = _energy; clarity = _spectralClarity;
                stereoWid = _stereoWidth; genreConf = _genreConfidence;
            }

            var prompt =
                $"You are an AI music director for a real-time audio visualizer.\n" +
                $"The user wants: {goal}\n\n" +
                $"Current brain state:\n" +
                $"  Genre: {genre} (confidence: {genreConf:F2})\n" +
                $"  Section: {section}\n" +
                $"  BPM: {bpm:F1}\n" +
                $"  Energy: {energy:F2}\n" +
                $"  Spectral clarity: {clarity:F2}\n" +
                $"  Stereo width: {stereoWid:F2}\n\n" +
                $"Available actions (use ONLY these):\n" +
                $"  CHANGE_MODE: <mode name> — switch visualization mode\n" +
                $"  SHIFT_HUE: <0-1> — rotate color palette\n" +
                $"  BOOST_ENERGY: <0-1> — increase visual intensity\n" +
                $"  CALM_DOWN: <0-1> — reduce intensity, slow motion\n" +
                $"  BUILD_TENSION: <seconds> — gradually increase energy\n" +
                $"  RELEASE_DROP: <intensity 0-1> — trigger a big visual moment\n" +
                $"  CHANGE_MOOD: <Chill|Energetic|SciFi|Organic> — set mood preset\n" +
                $"  WAIT: <seconds> — hold current state\n" +
                $"  ADJUST_BRIGHTNESS: <0-1> — change scene brightness\n" +
                $"  ADJUST_BLOOM: <0-1> — change bloom/glow\n" +
                $"  ADJUST_SPEED: <0.1-3.0> — change motion speed\n\n" +
                $"Available modes: spectrum_3d, plasma_field, neon_pulse, particle_flow,\n" +
                $"  waveform, sphere, aurora, dna_helix, heartbeat, rtx_mesh, ray_marched,\n" +
                $"  volumetric_clouds, fractal_dimensions, neural_network, quantum_field,\n" +
                $"  holographic, particle_storm, wave_tessellation, compute_shaders,\n" +
                $"  rtx_reflections, quantum_bars, spectrum_bars\n\n" +
                $"Create a step-by-step plan. Reply as JSON array, each element:\n" +
                $"  {{\"step\": <number>, \"action\": \"<action name>\", \"value\": \"<value>\",\n" +
                $"   \"done_when\": \"<how to know this step is done>\"}}\n" +
                $"Reply with ONLY the JSON array.";

            var result = await SendChatAsync(prompt, 0.3f, 500);
            if (result != null)
            {
                var plan = ParsePlan(result);
                lock (_lock)
                {
                    _plan = plan;
                    _planIndex = 0;
                }
            }
        }

        /// <summary>
        /// Periodically evaluate the brain's decisions and suggest corrections.
        /// Like smc-autosort's GoalPlanner.get_next_action() but text-only.
        /// </summary>
        public async Task EvaluateAsync()
        {
            string goal, genre, section, recMode;
            float bpm, energy, clarity, stereoWid, genreConf;
            int beatCount, phraseBeat;
            int planIdx;
            List<MusicPlanStep> plan;

            lock (_lock)
            {
                goal = _currentGoal;
                genre = _genre; section = _section; recMode = _recommendedMode;
                bpm = _bpm; energy = _energy; clarity = _spectralClarity;
                stereoWid = _stereoWidth; genreConf = _genreConfidence;
                beatCount = _beatCount; phraseBeat = _phraseBeat;
                planIdx = _planIndex;
                plan = _plan;
            }

            if (string.IsNullOrEmpty(goal)) return;

            var currentStep = planIdx < plan.Count ? plan[planIdx] : null;
            var stepInfo = currentStep != null
                ? $"Current step: {currentStep.Action} = {currentStep.Value} (done when: {currentStep.DoneWhen})"
                : "No specific step";

            var prompt =
                $"You are an AI music director evaluating the current state.\n" +
                $"Goal: {goal}\n" +
                $"{stepInfo}\n\n" +
                $"Current brain state:\n" +
                $"  Genre: {genre} (conf: {genreConf:F2})\n" +
                $"  Section: {section}\n" +
                $"  BPM: {bpm:F1}, Energy: {energy:F2}\n" +
                $"  Clarity: {clarity:F2}, Stereo width: {stereoWid:F2}\n" +
                $"  Beat count: {beatCount}, Phrase beat: {phraseBeat}/16\n" +
                $"  Recommended mode: {recMode}\n\n" +
                $"Evaluate the brain's decisions. Is the genre correct? Is the section right?\n" +
                $"Should the mode change? Is the energy trending well for the goal?\n\n" +
                $"Reply in this format:\n" +
                $"GENRE_CORRECTION: <genre name or NONE>\n" +
                $"SECTION_CORRECTION: <section name or NONE>\n" +
                $"MODE_SUGGESTION: <mode name or NONE>\n" +
                $"ENERGY_ASSESSMENT: <one sentence>\n" +
                $"STEP_DONE: <YES/NO>\n" +
                $"GOAL_DONE: <YES/NO>\n" +
                $"SUGGESTION: <one sentence overall recommendation>";

            var result = await SendChatAsync(prompt, 0.3f, 200);
            if (result != null)
            {
                var eval = ParseEvaluation(result);
                lock (_lock)
                {
                    _lastSuggestion = eval.Suggestion;
                    if (eval.StepDone && _planIndex < _plan.Count)
                        _planIndex++;
                }
            }
        }

        /// <summary>
        /// Get the latest evaluation result for the brain to consume.
        /// </summary>
        public BrainEvaluation? GetLatestEvaluation()
        {
            lock (_lock)
            {
                if (string.IsNullOrEmpty(_lastSuggestion)) return null;
                return new BrainEvaluation
                {
                    Suggestion = _lastSuggestion,
                    Goal = _currentGoal,
                    PlanIndex = _planIndex,
                    PlanCount = _plan.Count
                };
            }
        }

        public void Start()
        {
            if (_worker != null) return;
            _worker = Task.Run(async () => await Loop(), _cts.Token);
        }

        public void Stop()
        {
            _cts.Cancel();
        }

        private async Task Loop()
        {
            while (!_cts.Token.IsCancellationRequested)
            {
                try
                {
                    if (Enabled)
                    {
                        await EvaluateAsync();
                    }
                    await Task.Delay(TimeSpan.FromSeconds(8), _cts.Token);
                }
                catch (OperationCanceledException) { break; }
                catch (Exception ex)
                {
                    System.Diagnostics.Debug.WriteLine($"[MusicBrainAI] Loop error: {ex.Message}");
                    await Task.Delay(TimeSpan.FromSeconds(5), _cts.Token);
                }
            }
        }

        private async Task<string?> SendChatAsync(string prompt, float temperature, int maxTokens)
        {
            var messages = new List<object>();
            lock (_lock)
            {
                foreach (var msg in _history)
                    messages.Add(new { role = msg.Role, content = msg.Content });
            }
            messages.Add(new { role = "user", content = prompt });

            var requestBody = new
            {
                model = _textModel,
                messages = messages,
                stream = false,
                options = new { temperature = temperature, num_predict = maxTokens }
            };

            var json = JsonSerializer.Serialize(requestBody);
            var content = new StringContent(json, Encoding.UTF8, "application/json");

            try
            {
                var response = await _http.PostAsync($"{_ollamaUrl}/api/chat", content, _cts.Token);
                response.EnsureSuccessStatusCode();
                var responseJson = await response.Content.ReadAsStringAsync(_cts.Token);

                using var doc = JsonDocument.Parse(responseJson);
                var text = doc.RootElement.TryGetProperty("message", out var msg) &&
                           msg.TryGetProperty("content", out var contentEl)
                    ? contentEl.GetString() ?? ""
                    : "";

                lock (_lock)
                {
                    _history.Add(new ChatMsg { Role = "user", Content = prompt });
                    _history.Add(new ChatMsg { Role = "assistant", Content = text });
                    while (_history.Count > MaxHistory)
                        _history.RemoveAt(0);
                    _isConnected = true;
                    _consecutiveFailures = 0;
                }
                return text;
            }
            catch (Exception ex)
            {
                lock (_lock)
                {
                    _consecutiveFailures++;
                    _isConnected = false;
                }
                System.Diagnostics.Debug.WriteLine($"[MusicBrainAI] Chat failed ({_consecutiveFailures}x): {ex.Message}");
                return null;
            }
        }

        private static List<MusicPlanStep> ParsePlan(string raw)
        {
            var plan = new List<MusicPlanStep>();
            // Extract JSON from code blocks if present
            if (raw.Contains("```"))
            {
                var idx = raw.IndexOf("```");
                raw = raw.Substring(idx + 3);
                if (raw.StartsWith("json")) raw = raw.Substring(4);
                var endIdx = raw.IndexOf("```");
                if (endIdx >= 0) raw = raw.Substring(0, endIdx);
            }

            try
            {
                using var doc = JsonDocument.Parse(raw.Trim());
                foreach (var el in doc.RootElement.EnumerateArray())
                {
                    plan.Add(new MusicPlanStep
                    {
                        Step = el.TryGetProperty("step", out var s) ? s.GetInt32() : plan.Count + 1,
                        Action = el.TryGetProperty("action", out var a) ? a.GetString() ?? "" : "",
                        Value = el.TryGetProperty("value", out var v) ? v.GetString() ?? "" : "",
                        DoneWhen = el.TryGetProperty("done_when", out var d) ? d.GetString() ?? "" : ""
                    });
                }
            }
            catch
            {
                // Fallback: single step with raw text
                plan.Add(new MusicPlanStep { Step = 1, Action = raw.Trim(), Value = "", DoneWhen = "complete" });
            }
            return plan;
        }

        private static BrainEvaluation ParseEvaluation(string text)
        {
            var eval = new BrainEvaluation();
            foreach (var line in text.Split('\n', '\r'))
            {
                var trimmed = line.Trim();
                if (string.IsNullOrEmpty(trimmed)) continue;
                int sep = trimmed.IndexOf(':');
                if (sep <= 0) continue;
                string key = trimmed.Substring(0, sep).Trim().ToUpperInvariant();
                string val = trimmed.Substring(sep + 1).Trim();

                switch (key)
                {
                    case "GENRE_CORRECTION": eval.GenreCorrection = val; break;
                    case "SECTION_CORRECTION": eval.SectionCorrection = val; break;
                    case "MODE_SUGGESTION": eval.ModeSuggestion = val; break;
                    case "ENERGY_ASSESSMENT": eval.EnergyAssessment = val; break;
                    case "STEP_DONE": eval.StepDone = val.ToUpperInvariant().StartsWith("Y"); break;
                    case "GOAL_DONE": eval.GoalDone = val.ToUpperInvariant().StartsWith("Y"); break;
                    case "SUGGESTION": eval.Suggestion = val; break;
                }
            }
            return eval;
        }

        public void Dispose()
        {
            Stop();
            _http.Dispose();
            _cts.Dispose();
        }
    }

    /// <summary>
    /// One step in a music direction plan.
    /// </summary>
    public class MusicPlanStep
    {
        public int Step { get; set; }
        public string Action { get; set; } = "";
        public string Value { get; set; } = "";
        public string DoneWhen { get; set; } = "";
    }

    /// <summary>
    /// Evaluation result from the AI music director.
    /// </summary>
    public class BrainEvaluation
    {
        public string GenreCorrection = "";
        public string SectionCorrection = "";
        public string ModeSuggestion = "";
        public string EnergyAssessment = "";
        public bool StepDone;
        public bool GoalDone;
        public string Suggestion = "";
        public string Goal = "";
        public int PlanIndex;
        public int PlanCount;
    }

    internal class ChatMsg
    {
        public string Role { get; set; } = "user";
        public string Content { get; set; } = "";
    }
}
