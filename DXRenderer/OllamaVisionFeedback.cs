using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace DXRenderer;

/// <summary>
/// AI visual critic using a two-model Ollama pipeline:
///
/// 1. Vision model (qwen2.5vl:7b) — captures a screenshot, observes the
///    visualizer and describes what it sees in natural language.
///    Temperature: low (0.2) for consistent observation.
///    Like smc-autosort's VisionSystem.ask_vision().
///
/// 2. Text model (qwen2.5-coder:7b) — takes that observation + a constraint
///    manifest listing every shader uniform with its type, range, and semantics,
///    plus master reference profiles, then outputs concrete shader parameter
///    adjustments bounded to real uniforms.
///    Temperature: medium (0.4) for creative but grounded suggestions.
///    Like smc-autosort's GoalPlanner ollama.chat() with constrained actions.
///
/// Adjustments are stored as keyframe curves in an AdjustmentGraph (lightweight,
/// interpolated over time) rather than raw dumps. Each frame the graph is sampled
/// and translated back into AudioUBO/RenderGraph values.
///
/// Also runs FastVisionAnalyzer for pixel-level stats between LLM calls.
/// </summary>
public class OllamaVisionFeedback : IDisposable
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(60) };
    private readonly IntPtr _hwnd;
    private readonly string _visionModel;
    private readonly string _textModel;
    private readonly string _ollamaUrl;
    private readonly TimeSpan _interval;
    private readonly CancellationTokenSource _cts = new();
    private Task? _worker;
    private readonly FastVisionAnalyzer _fastVision;
    private readonly AdjustmentGraph _graph;
    private CLIPScorer? _clipScorer;

    // Temperature per model stage — vision is observational (low temp),
    // text is creative translation (medium temp)
    private float _visionTemp = 0.2f;
    private float _textTemp = 0.4f;

    private readonly object _lock = new();

    // Latest vision observation (natural language from vision model)
    private string _visionObservation = "";

    // Latest text model output (raw, before parsing into ShaderAdjustments)
    private string _textOutput = "";

    // Parsed adjustments from text model (pending — not auto-applied)
    private ShaderAdjustments? _adjustments;

    // Auto-apply mode: when false (default), AI only observes. When true,
    // AI auto-applies adjustments each cycle. Per-mode override via AutonomousModes.
    // Think of the AI as a dynamic shader factory — it generates on demand,
    // not constantly pushing changes. Some modes can be fully autonomous.
    public bool AutoApply { get; set; } = false;

    // Modes where AI is allowed to auto-apply adjustments (fully autonomous).
    // Default: none. Add mode names here to let the AI drive them.
    public HashSet<string> AutonomousModes { get; } = new(StringComparer.OrdinalIgnoreCase)
    {
        // Add mode names here to enable autonomous AI control, e.g.:
        // "particle_storm", "fractal_dimensions"
    };

    // One-shot request flag — set by RequestGenerate() to trigger a single
    // adjustment generation cycle on the next loop iteration
    private bool _generateRequested = false;

    /// <summary>
    /// Request a one-shot adjustment generation. The next loop iteration
    /// will capture a frame, observe it, and generate shader adjustments.
    /// Use this for on-demand "generate" button or chat commands.
    /// </summary>
    public void RequestGenerate()
    {
        lock (_lock) _generateRequested = true;
    }

    /// <summary>
    /// Clear all AI adjustments from the graph. Returns the visualizer
    /// to pure audio-driven defaults.
    /// </summary>
    public void ClearAdjustments()
    {
        _graph.Clear();
        lock (_lock) _adjustments = null;
        DebugLogger.Info("[OllamaFeedback] Adjustments cleared — back to audio-driven defaults");
    }

    /// <summary>
    /// Check if the current mode is in the autonomous set.
    /// </summary>
    public bool IsCurrentModeAutonomous
    {
        get
        {
            lock (_lock) return !string.IsNullOrEmpty(_currentMode) && AutonomousModes.Contains(_currentMode);
        }
    }

    // Legacy scores for backward compat with VisualDirectorBot / LightingBrain
    private float _visualEnergy = 0.5f;
    private float _visualMood = 0.5f;
    private float _colorBalance = 0.5f;
    private float _complexity = 0.5f;

    // Fast vision stats
    private float _fastBrightness = 0.5f;
    private float _fastMotion = 0f;
    private float _fastColorVariance = 0.5f;

    private string _lastResponse = "";
    private bool _isConnected = false;
    private int _consecutiveFailures = 0;

    // Current pipeline state context (sent to text model so it knows what's active)
    private string _currentMode = "";
    private string _currentMood = "";
    private float _currentBPM = 0f;
    private float _currentOverall = 0f;
    private float _currentSection = 0f;
    private string _lastModeForHistory = "";

    // Conversation context for multi-turn chat
    private readonly List<ChatMessage> _visionHistory = new();
    private readonly List<ChatMessage> _textHistory = new();
    private const int MaxHistoryMessages = 6;

    public float VisualEnergy { get { lock (_lock) return _visualEnergy; } }
    public float VisualMood { get { lock (_lock) return _visualMood; } }
    public float ColorBalance { get { lock (_lock) return _colorBalance; } }
    public float Complexity { get { lock (_lock) return _complexity; } }
    public string LastResponse { get { lock (_lock) return _lastResponse; } }
    public string VisionObservation { get { lock (_lock) return _visionObservation; } }
    public string TextOutput { get { lock (_lock) return _textOutput; } }
    public ShaderAdjustments? Adjustments { get { lock (_lock) return _adjustments; } }
    public AdjustmentGraph Graph => _graph;
    public bool IsConnected { get { lock (_lock) return _isConnected; } }
    public bool Enabled { get; set; } = false;

    // Adaptive profile manager — AI suggestions are routed through this
    // instead of directly overriding the UBO. The AI shapes the adaptive
    // baseline, which the director blends with reactive values.
    public AdaptiveProfileManager? AdaptiveProfiles { get; set; }

    public float FastBrightness { get { lock (_lock) return _fastBrightness; } }
    public float FastMotion { get { lock (_lock) return _fastMotion; } }
    public float FastColorVariance { get { lock (_lock) return _fastColorVariance; } }

    // CLIP image-text similarity score (0 = no match, ~0.3 = good match for CLIP)
    public float CLIPScore { get { lock (_lock) return _clipScore; } }
    public bool CLIPAvailable => _clipScorer?.IsAvailable ?? false;
    public string CLIPStatus => _clipScorer?.StatusMessage ?? "Not initialized";
    private float _clipScore = 0f;

    // Pipeline context setters — called by Program.cs each frame
    public void UpdatePipelineContext(string mode, string mood, float bpm, float overall, float section)
    {
        lock (_lock)
        {
            // Detect mode change — clear conversation histories so stale
            // observations from the previous mode don't carry over
            if (!string.IsNullOrEmpty(_currentMode) && _currentMode != mode)
            {
                _visionHistory.Clear();
                _textHistory.Clear();
                _graph.Clear();
                DebugLogger.Info($"[OllamaFeedback] Mode changed '{_currentMode}' -> '{mode}', cleared history & graph");
            }
            _currentMode = mode;
            _currentMood = mood;
            _currentBPM = bpm;
            _currentOverall = overall;
            _currentSection = section;
        }
    }

    public OllamaVisionFeedback(IntPtr hwnd, string visionModel = "qwen2.5vl:7b",
        string? ollamaUrl = null, float intervalSeconds = 6.0f,
        string? textModel = null, float visionTemp = 0.2f, float textTemp = 0.4f)
    {
        _hwnd = hwnd;
        _visionModel = visionModel;
        _textModel = textModel ?? "qwen2.5-coder:7b";
        _ollamaUrl = ollamaUrl?.TrimEnd('/') ?? "http://localhost:11434";
        _interval = TimeSpan.FromSeconds(Math.Max(2.0f, intervalSeconds));
        _visionTemp = visionTemp;
        _textTemp = textTemp;
        _fastVision = new FastVisionAnalyzer(hwnd);
        _graph = new AdjustmentGraph();

        // CLIP scorer — inline image-text similarity for mode identity verification
        // Gracefully degrades if model files aren't present
        try
        {
            _clipScorer = new CLIPScorer();
            if (_clipScorer.IsAvailable)
                DebugLogger.Info("[OllamaFeedback] CLIP scorer initialized — will log per-mode similarity scores");
            else
                DebugLogger.Info($"[OllamaFeedback] CLIP scorer not available: {_clipScorer.StatusMessage}");
        }
        catch (Exception ex)
        {
            DebugLogger.Info($"[OllamaFeedback] CLIP scorer init skipped: {ex.Message}");
            _clipScorer = null;
        }
    }

    public void Start()
    {
        if (_worker != null) return;
        _worker = Task.Run(async () => await Loop(), _cts.Token);
        DebugLogger.Info("[OllamaFeedback] Vision feedback loop started (disabled by default, press O to enable)");
    }

    /// <summary>
    /// Quick connectivity check — tests if Ollama is reachable and both models are available.
    /// </summary>
    public async Task<bool> CheckConnectionAsync()
    {
        try
        {
            var response = await _http.GetAsync($"{_ollamaUrl}/api/tags", _cts.Token);
            if (!response.IsSuccessStatusCode)
            {
                lock (_lock) _isConnected = false;
                return false;
            }

            var json = await response.Content.ReadAsStringAsync(_cts.Token);
            using var doc = JsonDocument.Parse(json);
            bool visionFound = false, textFound = false;
            if (doc.RootElement.TryGetProperty("models", out var models))
            {
                foreach (var m in models.EnumerateArray())
                {
                    var name = m.GetProperty("name").GetString() ?? "";
                    if (name.Equals(_visionModel, StringComparison.OrdinalIgnoreCase) ||
                        name.StartsWith(_visionModel + ":", StringComparison.OrdinalIgnoreCase))
                        visionFound = true;
                    if (name.Equals(_textModel, StringComparison.OrdinalIgnoreCase) ||
                        name.StartsWith(_textModel + ":", StringComparison.OrdinalIgnoreCase))
                        textFound = true;
                }
            }

            bool bothFound = visionFound && textFound;
            lock (_lock) _isConnected = bothFound;
            if (bothFound)
                DebugLogger.Info($"[OllamaFeedback] Connected — vision='{_visionModel}', text='{_textModel}'");
            else
                DebugLogger.Warn($"[OllamaFeedback] Models missing — vision:{(visionFound ? "ok" : "MISSING")} text:{(textFound ? "ok" : "MISSING")}. " +
                    $"Pull with: ollama pull {_visionModel} && ollama pull {_textModel}");
            return bothFound;
        }
        catch
        {
            lock (_lock) _isConnected = false;
            DebugLogger.Warn($"[OllamaFeedback] Cannot reach Ollama at {_ollamaUrl}. Is it running? (ollama serve)");
            return false;
        }
    }

    public void Stop()
    {
        _cts.Cancel();
        try { _worker?.Wait(TimeSpan.FromSeconds(2)); } catch { /* best effort */ }
    }

    public void Dispose()
    {
        Stop();
        _http.Dispose();
        _cts.Dispose();
        _clipScorer?.Dispose();
    }

    private async Task Loop()
    {
        await CheckConnectionAsync();

        while (!_cts.Token.IsCancellationRequested)
        {
            try
            {
                if (Enabled)
                {
                    // Fast pixel analysis runs every tick (no LLM needed)
                    UpdateFastVision();

                    // CLIP scoring — runs every tick when models are available (no LLM needed)
                    // Captures a frame and computes image-text similarity vs current mode's prompt
                    UpdateCLIPScore();

                    // Periodically re-check connection if we've had failures
                    if (!IsConnected && _consecutiveFailures > 0)
                        await CheckConnectionAsync();

                    if (IsConnected)
                    {
                        // Stage 1: Vision model observes the frame
                        string? observation = await ObserveFrameAsync();
                        if (observation != null)
                        {
                            // Stage 2: Text model generates adjustments ONLY if:
                            //   - AutoApply is on (global), OR
                            //   - Current mode is in AutonomousModes, OR
                            //   - A one-shot request was queued via RequestGenerate()
                            bool shouldGenerate;
                            lock (_lock)
                            {
                                shouldGenerate = AutoApply || IsCurrentModeAutonomous || _generateRequested;
                                _generateRequested = false; // consume one-shot
                            }

                            if (shouldGenerate)
                            {
                                string? adjustments = await TranslateToShaderAdjustmentsAsync(observation);
                                if (adjustments != null)
                                {
                                    var parsed = ShaderAdjustments.Parse(adjustments);
                                    lock (_lock)
                                    {
                                        _adjustments = parsed;
                                        _textOutput = adjustments;
                                        _lastResponse = adjustments;
                                        _isConnected = true;
                                        _consecutiveFailures = 0;
                                    }

                                    // Record into adjustment graph as keyframes (for HUD/debug)
                                    float now = (float)DateTime.UtcNow.TimeOfDay.TotalSeconds;
                                    _graph.RecordAdjustments(parsed, now);

                                    // Route through adaptive profiles — AI shapes the baseline,
                                    // not the UBO directly. The director blends adaptive with reactive.
                                    if (AdaptiveProfiles != null && parsed.HasAny)
                                    {
                                        var aiParams = ShaderAdjustmentsToContextParams(parsed);
                                        float weight = 0.15f; // gentle nudge — AI refines over time
                                        AdaptiveProfiles.ApplyAISuggestion(aiParams, weight);
                                        DebugLogger.Info($"[OllamaFeedback] Routed to adaptive profiles (weight={weight}) — {parsed.Suggestion}");
                                    }

                                    UpdateLegacyScores(parsed);

                                    DebugLogger.Info($"[OllamaFeedback] Applied: {_graph.ActiveCurveCount} curves, " +
                                        $"{_graph.TotalKeyframeCount} keyframes — {parsed.Suggestion}");
                                }
                            }
                            else
                            {
                                // Observation only — no adjustments pushed
                                lock (_lock)
                                {
                                    _isConnected = true;
                                    _consecutiveFailures = 0;
                                }
                                DebugLogger.Info($"[OllamaFeedback] Observed '{_currentMode}' — brightness={_fastBrightness:F2} motion={_fastMotion:F2} clip={_clipScore:F4} (no adjustments pushed)");
                            }
                        }
                    }
                }
                await Task.Delay(_interval, _cts.Token);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                DebugLogger.Warn($"[OllamaFeedback] Loop error: {ex.Message}");
                await Task.Delay(TimeSpan.FromSeconds(5), _cts.Token);
            }
        }
    }

    /// <summary>
    /// Fast pixel-level analysis — runs between LLM calls for quick adjustments.
    /// </summary>
    private void UpdateFastVision()
    {
        try
        {
            var (brightness, motion, colorVariance) = _fastVision.Analyze();
            lock (_lock)
            {
                _fastBrightness = brightness;
                _fastMotion = motion;
                _fastColorVariance = colorVariance;
            }
        }
        catch { }
    }

    /// <summary>
    /// CLIP image-text similarity scoring — captures a frame and computes
    /// cosine similarity against the current mode's text description.
    /// Runs inline via ONNX Runtime, no LLM needed. Logs scores per mode.
    /// </summary>
    private void UpdateCLIPScore()
    {
        if (_clipScorer == null || !_clipScorer.IsAvailable) return;

        try
        {
            string mode;
            lock (_lock) mode = _currentMode;
            if (string.IsNullOrEmpty(mode)) return;

            // Capture a small frame for CLIP (224x224 is what CLIP expects)
            byte[] imageBytes = CaptureWindowJpeg(_hwnd, 224);
            using var ms = new MemoryStream(imageBytes);
            using var bmp = new Bitmap(ms);

            float score = _clipScorer.ScoreFrame(bmp, mode);
            lock (_lock) _clipScore = score;
        }
        catch { }
    }

    /// <summary>
    /// Update legacy score properties from parsed adjustments for backward compat
    /// with VisualDirectorBot and LightingBrain.
    /// </summary>
    private void UpdateLegacyScores(ShaderAdjustments adj)
    {
        lock (_lock)
        {
            if (adj.Intensity.HasValue) _visualEnergy = adj.Intensity.Value * 0.5f;
            if (adj.Brightness.HasValue) _visualEnergy = adj.Brightness.Value;
            if (adj.Satur.HasValue) _visualMood = adj.Satur.Value;
            if (adj.ColorShift.HasValue) _colorBalance = adj.ColorShift.Value;
            if (adj.EffectInt.HasValue) _complexity = adj.EffectInt.Value;
        }
    }

    /// <summary>
    /// Convert ShaderAdjustments (AI output) to ContextParams (adaptive profile input).
    /// Only maps the parameters that ContextParams tracks. The adaptive profile's
    /// sterile constraints will validate and clamp these values.
    /// </summary>
    private static AdaptiveShaderProfile.ContextParams ShaderAdjustmentsToContextParams(ShaderAdjustments adj)
    {
        var defaults = AdaptiveShaderProfile.ContextParams.Default();
        return new AdaptiveShaderProfile.ContextParams
        {
            Intensity   = adj.Intensity ?? defaults.Intensity,
            Speed       = adj.Speed ?? defaults.Speed,
            Brightness  = adj.Brightness ?? defaults.Brightness,
            Bloom       = adj.Bloom ?? defaults.Bloom,
            Satur       = adj.Satur ?? defaults.Satur,
            Zoom        = adj.Zoom ?? defaults.Zoom,
            ColorShift  = adj.ColorShift ?? defaults.ColorShift,
            EffectInt   = adj.EffectInt ?? defaults.EffectInt,
            Satisfaction = 0.5f,
            SampleCount = 0
        };
    }

    // === Stage 1: Vision model observes the frame ===

    /// <summary>
    /// Capture a screenshot and ask the vision model to describe what it sees.
    /// Low temperature (0.2) for consistent, observational output.
    /// Returns natural language observation or null on failure.
    /// </summary>
    private async Task<string?> ObserveFrameAsync()
    {
        byte[] imageBytes;
        try { imageBytes = CaptureWindowJpeg(_hwnd, 512); }
        catch (Exception ex)
        {
            DebugLogger.Warn($"[OllamaFeedback] Capture failed: {ex.Message}");
            return null;
        }

        string b64 = Convert.ToBase64String(imageBytes);

        string mode, mood;
        float bpm, overall, section;
        float fastB, fastM, fastC;
        lock (_lock)
        {
            mode = _currentMode; mood = _currentMood;
            bpm = _currentBPM; overall = _currentOverall; section = _currentSection;
            fastB = _fastBrightness; fastM = _fastMotion; fastC = _fastColorVariance;
        }

        var modeDesc = GetModeVisualDescription(mode);

        var prompt =
            "You are a shader tuning assistant for a DX12 Ultimate music visualizer.\n" +
            $"Current shader mode: {mode}\n" +
            $"What this mode should look like: {modeDesc}\n" +
            $"Mood preset: {mood}\n" +
            $"Music: BPM={bpm:F0}, energy={overall:F2}, section={section:F0}\n" +
            $"Fast pixel stats: brightness={fastB:F2}, motion={fastM:F2}, colorVariance={fastC:F2}\n\n" +
            $"IMPORTANT: You are observing the '{mode}' mode. Do NOT call it a waveform or oscilloscope.\n" +
            $"Describe what you ACTUALLY see in this {mode} visualization.\n\n" +
            "Observe and report in 3-5 sentences:\n" +
            "1. Overall scene: brightness, color palette, energy level\n" +
            "2. Audio reactivity: is it syncing well to the beat? Does energy match the music?\n" +
            "3. Visual quality: any issues? (clipping, banding, flat areas, muddy colors, too much bloom)\n" +
            "4. Tuning notes: what parameters would help dial this in? (be specific about what to change and why)\n" +
            "Be concise and technical. Focus on helping the developer tune the shader.";

        return await SendChatRequest(_visionModel, _visionHistory, prompt, b64, _visionTemp, 200);
    }

    // === Stage 2: Text model translates observation → shader adjustments ===

    /// <summary>
    /// Take the vision observation and ask the text model to produce
    /// concrete shader parameter adjustments within the constraint manifest.
    /// Medium temperature (0.4) for creative but grounded suggestions.
    /// </summary>
    private async Task<string?> TranslateToShaderAdjustmentsAsync(string observation)
    {
        string mode, mood;
        float bpm, overall;
        lock (_lock)
        {
            mode = _currentMode; mood = _currentMood;
            bpm = _currentBPM; overall = _currentOverall;
        }

        float fastB, fastM, fastC;
        lock (_lock)
        {
            fastB = _fastBrightness; fastM = _fastMotion; fastC = _fastColorVariance;
        }

        // Determine if brightness is already high — guide the model to REDUCE if so
        string brightnessGuidance = fastB switch
        {
            > 0.75f => $"MEASURED BRIGHTNESS IS HIGH ({fastB:F2}). If the observation mentions brightness issues, you should REDUCE BRIGHTNESS, not increase it.",
            < 0.25f => $"MEASURED BRIGHTNESS IS LOW ({fastB:F2}). Consider increasing BRIGHTNESS if the scene is too dark.",
            _ => $"Measured brightness is moderate ({fastB:F2}). Adjust only if the observation suggests it."
        };

        var prompt =
            ShaderConstraintManifest.BuildConstraintPrompt() + "\n" +
            $"=== CURRENT STATE ===\n" +
            $"Active mode: {mode}\n" +
            $"Mood: {mood}\n" +
            $"BPM: {bpm:F0}, Energy: {overall:F2}\n" +
            $"Measured pixel stats: brightness={fastB:F2}, motion={fastM:F2}, colorVariance={fastC:F2}\n" +
            $"{brightnessGuidance}\n\n" +
            $"=== VISION MODEL OBSERVATION ===\n" +
            $"{observation}\n\n" +
            $"Based on the observation above, output the parameter adjustments now.\n" +
            $"CRITICAL RULES:\n" +
            $"- If the observation says something is TOO HIGH or TOO BRIGHT, REDUCE that parameter.\n" +
            $"- If the observation says something is TOO LOW or TOO DARK, INCREASE that parameter.\n" +
            $"- Do NOT blindly increase parameters. Look at the measured pixel stats above.\n" +
            $"- If brightness is already 0.75+ and the scene looks bright, LOWER it.\n" +
            $"- Small targeted changes are better than sweeping ones.\n" +
            $"- Only use keys from the manifest, respect the ranges.\n" +
            $"- Consider how the current mode uses each parameter differently.\n" +
            $"- Each mode is distinct — don't try to make it look like the reference shaders.";

        return await SendChatRequest(_textModel, _textHistory, prompt, null, _textTemp, 300);
    }

    // === Chat API ===

    /// <summary>
    /// Send a chat request to Ollama /api/chat endpoint.
    /// Maintains conversation history per model for multi-turn context.
    /// </summary>
    private async Task<string?> SendChatRequest(
        string model, List<ChatMessage> history, string prompt,
        string? b64Image, float temperature, int maxTokens)
    {
        var messages = new List<object>();

        // Include conversation history
        lock (_lock)
        {
            foreach (var msg in history)
                messages.Add(new { role = msg.Role, content = msg.Content });
        }

        // Add current user message
        var userMsg = new Dictionary<string, object> { ["role"] = "user", ["content"] = prompt };
        if (b64Image != null)
            userMsg["images"] = new[] { b64Image };
        messages.Add(userMsg);

        var requestBody = new
        {
            model = model,
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

            // Update conversation history
            lock (_lock)
            {
                history.Add(new ChatMessage { Role = "user", Content = prompt });
                history.Add(new ChatMessage { Role = "assistant", Content = text });
                while (history.Count > MaxHistoryMessages)
                    history.RemoveAt(0);
            }

            // Store vision observation for HUD display
            if (b64Image != null)
            {
                lock (_lock) _visionObservation = text;
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
            var backoff = _consecutiveFailures > 3 ? TimeSpan.FromSeconds(30) : TimeSpan.FromSeconds(5);
            DebugLogger.Warn($"[OllamaFeedback] Chat request failed ({_consecutiveFailures}x): {ex.Message}");
            await Task.Delay(backoff, _cts.Token);
            return null;
        }
    }

    // === Mode visual descriptions for vision model context ===

    /// <summary>
    /// Returns a human-readable description of what each shader mode looks like.
    /// This gives the vision model context about what it's actually viewing,
    /// so it doesn't default to calling everything a "waveform".
    /// </summary>
    private static string GetModeVisualDescription(string mode)
    {
        return mode.ToLowerInvariant() switch
        {
            "quantum_bars" => "Vertical audio frequency bars arranged in a spectrum, with quantum-style glowing edges and particle effects. Bars pulse and change height with the music.",
            "wave_tessellation" => "A 3D tessellated mesh surface with wave-like displacement, colorful liquid-like shading, and wireframe overlay. The mesh deforms with bass and beat.",
            "spectrum_3d" => "A 3D stereo mirror spectrum analyzer with bass frequencies in the center spreading outward. Bars or beams arranged in perspective depth, mirroring left/right channels.",
            "particle_flow" => "Thousands of particles flowing in dynamic patterns, driven by audio frequencies. Particles change color, speed, and direction with the music.",
            "neon_grid" => "A retro neon grid landscape with horizon lines, sun/moon, and audio-reactive grid pulses. Synthwave aesthetic with bright neon colors.",
            "liquid_mercury" => "A liquid metal / mercury surface that ripples and flows with the audio. Reflective, metallic shading with smooth deformations.",
            "fractal_cosmos" => "A cosmic fractal pattern with spiraling shapes, star-like particles, and deep space colors. Fractals morph with the music.",
            "vortex_tunnel" => "A tunnel or vortex effect with depth perspective, walls made of audio-reactive patterns or geometry. Camera flies through the tunnel.",
            "crystal_lattice" => "A 3D crystal or gemstone lattice structure that refracts light and pulses with audio. Faceted surfaces with prismatic color splitting.",
            "fire_aura" => "Fire or flame-like particle effects emanating from the center or bottom, with audio-reactive intensity, color, and height.",
            "geometric_mandala" => "Symmetrical geometric mandala patterns that rotate, pulse, and transform with the music. Sacred geometry aesthetic.",
            "starfield_warp" => "A starfield with warp/speed lines effect, stars streak past the camera. Speed and density react to audio energy.",
            "audio_ripple" => "Concentric ripple waves emanating from center, like water drops. Ripples expand and distort with each beat.",
            "plasma_sphere" => "A central glowing plasma orb or sphere with energy tendrils, lightning-like effects, and color shifts driven by audio.",
            "holographic_grid" => "A holographic projection effect with scan lines, glitch artifacts, and a 3D wireframe grid. Cyberpunk hologram aesthetic.",
            "aurora_borealis" => "Northern lights / aurora effect with flowing colored curtains of light in a dark sky. Waves and shifts with audio.",
            "matrix_rain" => "Falling digital rain like the Matrix, with characters or glyphs cascading down. Speed and density react to audio.",
            "lightning_storm" => "Electric lightning bolts and arcs flashing across a dark sky, with thunder-like audio reactivity.",
            "gravity_well" => "A gravitational well or black hole effect with matter spiraling inward, distortion rings, and audio-reactive pull strength.",
            "shatter_glass" => "Glass shattering or cracking patterns that reform and break again with each beat. Prismatic light refraction.",
            "ink_drop" => "Ink or paint drops in water, creating swirling colorful clouds that expand and contract with audio.",
            "cosmic_web" => "A web of connected nodes and lines spanning 3D space, like a neural network or cosmic web. Nodes pulse with audio.",
            _ => $"The '{mode}' shader mode — a real-time audio-reactive visualization with unique visual characteristics."
        };
    }

    private static byte[] CaptureWindowJpeg(IntPtr hwnd, int maxSize)
    {
        // Get window client rect
        var rect = new NativeRect();
        if (!GetClientRect(hwnd, ref rect))
            throw new InvalidOperationException("GetClientRect failed");

        int w = rect.Right - rect.Left;
        int h = rect.Bottom - rect.Top;
        if (w <= 0 || h <= 0) throw new InvalidOperationException("Invalid window size");

        // Downscale to fit within maxSize
        float scale = Math.Min(1.0f, (float)maxSize / Math.Max(w, h));
        int dw = Math.Max(1, (int)(w * scale));
        int dh = Math.Max(1, (int)(h * scale));

        using var bmp = new Bitmap(dw, dh, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;

            // Try DWM thumbnail / print window first
            var hdc = g.GetHdc();
            bool ok = PrintWindow(hwnd, hdc, 0);
            g.ReleaseHdc(hdc);

            if (!ok)
            {
                // Fallback: bitblt from screen
                using var screen = new Bitmap(w, h, PixelFormat.Format24bppRgb);
                using (var sg = Graphics.FromImage(screen))
                {
                    var pt = new System.Drawing.Point(rect.Left, rect.Top);
                    ClientToScreen(hwnd, ref pt);
                    sg.CopyFromScreen(pt.X, pt.Y, 0, 0, new Size(w, h));
                }
                g.DrawImage(screen, 0, 0, dw, dh);
            }
        }

        using var ms = new MemoryStream();
        bmp.Save(ms, ImageFormat.Jpeg);
        return ms.ToArray();
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left, Top, Right, Bottom;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr hWnd, ref NativeRect lpRect);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool ClientToScreen(IntPtr hWnd, ref System.Drawing.Point lpPoint);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
}

/// <summary>
/// Simple chat message for Ollama /api/chat conversation history.
/// </summary>
internal class ChatMessage
{
    public string Role { get; set; } = "user";
    public string Content { get; set; } = "";
}
