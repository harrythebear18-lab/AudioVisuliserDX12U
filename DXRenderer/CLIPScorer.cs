using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace DXRenderer;

/// <summary>
/// CLIP image-text similarity scorer using ONNX Runtime.
/// Loads ViT-B/32 CLIP models, pre-computes text embeddings for all mode descriptions,
/// then scores captured frames against the current mode's text prompt via cosine similarity.
///
/// Model files expected in models/clip/:
///   clip_image_encoder.onnx  — input: pixel_values (1,3,224,224) float32 → output: image_embeds (1,512)
///   clip_text_encoder.onnx   — input: input_ids (1,77) int32, attention_mask (1,77) int32 → output: text_embeds (1,512)
///   clip_vocab.json          — HuggingFace CLIP vocab
///   clip_merges.txt          — HuggingFace CLIP BPE merges
///
/// Use scripts/export_clip_onnx.py to generate ONNX models from HuggingFace.
/// </summary>
public class CLIPScorer : IDisposable
{
    private readonly InferenceSession? _imageSession;
    private readonly InferenceSession? _textSession;
    private readonly CLIPTokenizer? _tokenizer;
    private readonly Dictionary<string, float[]> _textEmbeddings = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _lock = new();

    // CLIP normalization constants
    private static readonly float[] Mean = { 0.48145466f, 0.4578275f, 0.40821073f };
    private static readonly float[] Std = { 0.26862954f, 0.26130258f, 0.27577711f };

    public bool IsAvailable { get; }

    // Latest score for HUD display
    public float CurrentScore { get; private set; }
    public string CurrentMode { get; private set; } = "";
    public string StatusMessage { get; private set; } = "Not initialized";

    // Per-mode score history for logging
    private readonly Dictionary<string, List<float>> _scoreHistory = new(StringComparer.OrdinalIgnoreCase);
    private int _scoreCount = 0;

    public CLIPScorer(string? modelsDir = null)
    {
        modelsDir ??= FindModelsDir();
        CurrentMode = "";

        if (string.IsNullOrEmpty(modelsDir))
        {
            StatusMessage = "Models directory not found. Expected models/clip/ with ONNX + tokenizer files.";
            IsAvailable = false;
            return;
        }

        string imagePath = Path.Combine(modelsDir, "clip_image_encoder.onnx");
        string textPath = Path.Combine(modelsDir, "clip_text_encoder.onnx");
        string vocabPath = Path.Combine(modelsDir, "clip_vocab.json");
        string mergesPath = Path.Combine(modelsDir, "clip_merges.txt");

        // Check all files exist
        var missing = new List<string>();
        if (!File.Exists(imagePath)) missing.Add("clip_image_encoder.onnx");
        if (!File.Exists(textPath)) missing.Add("clip_text_encoder.onnx");
        if (!File.Exists(vocabPath)) missing.Add("clip_vocab.json");
        if (!File.Exists(mergesPath)) missing.Add("clip_merges.txt");

        if (missing.Count > 0)
        {
            StatusMessage = $"Missing model files: {string.Join(", ", missing)}. See scripts/export_clip_onnx.py";
            DebugLogger.Warn($"[CLIPScorer] {StatusMessage}");
            IsAvailable = false;
            return;
        }

        try
        {
            // Load tokenizer
            _tokenizer = new CLIPTokenizer(vocabPath, mergesPath);
            if (!_tokenizer.IsAvailable)
            {
                StatusMessage = "Tokenizer failed to load";
                IsAvailable = false;
                return;
            }

            // Load ONNX sessions — CPU provider for reliability
            var options = new SessionOptions { GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL };
            _imageSession = new InferenceSession(imagePath, options);
            _textSession = new InferenceSession(textPath, options);

            // Pre-compute text embeddings for all mode prompts
            PrecomputeTextEmbeddings();

            IsAvailable = true;
            StatusMessage = $"Ready — {_textEmbeddings.Count} mode prompts embedded";
            DebugLogger.Info($"[CLIPScorer] {StatusMessage}");
        }
        catch (Exception ex)
        {
            StatusMessage = $"Init failed: {ex.Message}";
            DebugLogger.Warn($"[CLIPScorer] {StatusMessage}");
            IsAvailable = false;
        }
    }

    /// <summary>
    /// Pre-compute text embeddings for all known mode prompts at startup.
    /// This runs the text encoder once per prompt and caches the 512-dim embeddings.
    /// </summary>
    private void PrecomputeTextEmbeddings()
    {
        foreach (var (modeName, prompt) in ModePrompts)
        {
            var embedding = ComputeTextEmbedding(prompt);
            if (embedding != null)
            {
                _textEmbeddings[modeName] = embedding;
                DebugLogger.Info($"[CLIPScorer] Embedded '{modeName}': \"{prompt.Substring(0, Math.Min(60, prompt.Length))}...\"");
            }
        }
    }

    /// <summary>
    /// Run the CLIP text encoder on a text prompt and return the 512-dim embedding.
    /// </summary>
    private float[]? ComputeTextEmbedding(string text)
    {
        if (_tokenizer == null || _textSession == null) return null;

        int[] tokenIds = _tokenizer.Encode(text);
        int[] attentionMask = _tokenizer.GetAttentionMask(tokenIds);

        // Create input tensors — ONNX model expects int64 (long) for input_ids and attention_mask
        var idsTensor = new DenseTensor<long>(new[] { 1, CLIPTokenizer.MaxSeqLen });
        var maskTensor = new DenseTensor<long>(new[] { 1, CLIPTokenizer.MaxSeqLen });
        for (int i = 0; i < CLIPTokenizer.MaxSeqLen; i++)
        {
            idsTensor[0, i] = tokenIds[i];
            maskTensor[0, i] = attentionMask[i];
        }

        var inputs = new List<NamedOnnxValue>();

        // Try common input names
        var inputNames = _textSession.InputMetadata.Keys.ToList();
        foreach (var name in inputNames)
        {
            if (name.Contains("input_ids", StringComparison.OrdinalIgnoreCase))
                inputs.Add(NamedOnnxValue.CreateFromTensor(name, idsTensor));
            else if (name.Contains("attention_mask", StringComparison.OrdinalIgnoreCase))
                inputs.Add(NamedOnnxValue.CreateFromTensor(name, maskTensor));
        }

        using var results = _textSession.Run(inputs);
        var outputName = _textSession.OutputMetadata.Keys.First();
        var outputTensor = results.First().AsTensor<float>();

        // Extract the embedding (last dim is 512)
        var embedding = new float[512];
        var dims = outputTensor.Dimensions;
        if (dims.Length == 2)
        {
            for (int i = 0; i < 512; i++)
                embedding[i] = outputTensor[0, i];
        }
        else
        {
            // Fallback: just copy first 512 elements
            for (int i = 0; i < 512 && i < outputTensor.Length; i++)
                embedding[i] = outputTensor.GetValue(i);
        }

        return embedding;
    }

    /// <summary>
    /// Score a captured frame against the current mode's text embedding.
    /// Returns cosine similarity (typically -0.1 to 0.4 for CLIP).
    /// </summary>
    public float ScoreFrame(Bitmap frame, string modeName)
    {
        if (!IsAvailable || _imageSession == null) return 0f;

        lock (_lock) CurrentMode = modeName;

        if (!_textEmbeddings.TryGetValue(modeName, out var textEmbedding))
        {
            // Try fallback — use generic prompt
            if (!_textEmbeddings.TryGetValue("_default", out textEmbedding))
                return 0f;
        }

        try
        {
            // Preprocess image to (1, 3, 224, 224) float32
            var imageTensor = PreprocessImage(frame);

            // Run image encoder
            var inputs = new List<NamedOnnxValue>();
            var inputName = _imageSession.InputMetadata.Keys.First();
            inputs.Add(NamedOnnxValue.CreateFromTensor(inputName, imageTensor));

            using var results = _imageSession.Run(inputs);
            var outputTensor = results.First().AsTensor<float>();

            // Extract image embedding (512-dim)
            var imageEmbedding = new float[512];
            var dims = outputTensor.Dimensions;
            if (dims.Length == 2)
            {
                for (int i = 0; i < 512; i++)
                    imageEmbedding[i] = outputTensor[0, i];
            }
            else
            {
                for (int i = 0; i < 512 && i < outputTensor.Length; i++)
                    imageEmbedding[i] = outputTensor.GetValue(i);
            }

            // Cosine similarity
            float score = CosineSim(imageEmbedding, textEmbedding);

            lock (_lock)
            {
                CurrentScore = score;
                _scoreCount++;

                // Track per-mode history
                if (!_scoreHistory.ContainsKey(modeName))
                    _scoreHistory[modeName] = new List<float>();
                _scoreHistory[modeName].Add(score);

                // Keep last 20 scores per mode
                if (_scoreHistory[modeName].Count > 20)
                    _scoreHistory[modeName].RemoveAt(0);
            }

            // Log every 5th score to avoid spam
            if (_scoreCount % 5 == 0)
            {
                var avg = _scoreHistory[modeName].Average();
                DebugLogger.Info($"[CLIPScorer] Mode='{modeName}' score={score:F4} avg={avg:F4} (n={_scoreHistory[modeName].Count})");
            }

            return score;
        }
        catch (Exception ex)
        {
            DebugLogger.Warn($"[CLIPScorer] ScoreFrame failed: {ex.Message}");
            return 0f;
        }
    }

    /// <summary>
    /// Preprocess a Bitmap to CLIP's expected input format: (1, 3, 224, 224) float32, normalized.
    /// </summary>
    private DenseTensor<float> PreprocessImage(Bitmap frame)
    {
        const int size = 224;

        // Resize to 224x224 with bicubic interpolation
        using var resized = new Bitmap(size, size, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(resized))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.CompositingMode = CompositingMode.SourceCopy;
            g.DrawImage(frame, 0, 0, size, size);
        }

        // Extract pixels and normalize
        var data = resized.LockBits(new Rectangle(0, 0, size, size), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        int stride = data.Stride;
        byte[] pixels = new byte[stride * size];
        System.Runtime.InteropServices.Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
        resized.UnlockBits(data);

        // Build tensor: (1, 3, 224, 224) — CHW layout, normalized
        var tensor = new DenseTensor<float>(new[] { 1, 3, size, size });

        for (int y = 0; y < size; y++)
        {
            for (int x = 0; x < size; x++)
            {
                int idx = y * stride + x * 3;
                // Format24bppRgb is BGR
                float b = pixels[idx] / 255f;
                float g = pixels[idx + 1] / 255f;
                float r = pixels[idx + 2] / 255f;

                // Normalize: (channel - mean) / std
                tensor[0, 0, y, x] = (r - Mean[0]) / Std[0];
                tensor[0, 1, y, x] = (g - Mean[1]) / Std[1];
                tensor[0, 2, y, x] = (b - Mean[2]) / Std[2];
            }
        }

        return tensor;
    }

    private static float CosineSim(float[] a, float[] b)
    {
        float dot = 0, magA = 0, magB = 0;
        for (int i = 0; i < a.Length; i++)
        {
            dot += a[i] * b[i];
            magA += a[i] * a[i];
            magB += b[i] * b[i];
        }
        float denom = MathF.Sqrt(magA) * MathF.Sqrt(magB);
        return denom > 1e-8f ? dot / denom : 0f;
    }

    /// <summary>
    /// Get average CLIP score for a mode (for HUD display).
    /// </summary>
    public float GetAverageScore(string modeName)
    {
        lock (_lock)
        {
            if (_scoreHistory.TryGetValue(modeName, out var history) && history.Count > 0)
                return history.Average();
            return 0f;
        }
    }

    /// <summary>
    /// Get all mode scores for logging/debug.
    /// </summary>
    public Dictionary<string, float> GetAllAverageScores()
    {
        lock (_lock)
        {
            var result = new Dictionary<string, float>();
            foreach (var (mode, history) in _scoreHistory)
            {
                if (history.Count > 0)
                    result[mode] = history.Average();
            }
            return result;
        }
    }

    private static string? FindModelsDir()
    {
        // Search common locations relative to the executable
        // App runs from DXRenderer/bin/Debug/net10.0-windows10.0.26100.0/
        // Models live at RTXAudioVisualizer/models/clip/
        string[] candidates = {
            Path.Combine(AppContext.BaseDirectory, "models", "clip"),
            Path.Combine(AppContext.BaseDirectory, "..", "models", "clip"),
            Path.Combine(AppContext.BaseDirectory, "..", "..", "models", "clip"),
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "models", "clip"),
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "models", "clip"),
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "models", "clip"),
        };

        foreach (var dir in candidates)
        {
            if (Directory.Exists(dir))
                return Path.GetFullPath(dir);
        }
        return null;
    }

    public void Dispose()
    {
        _imageSession?.Dispose();
        _textSession?.Dispose();
    }

    // === CLIP-optimized text prompts per mode ===
    // These are natural language descriptions optimized for CLIP's image-text matching.
    // CLIP works best with "a screenshot of..." or "a 3D visualization of..." style prompts.
    private static readonly Dictionary<string, string> ModePrompts = new(StringComparer.OrdinalIgnoreCase)
    {
        ["quantum_bars"] = "a 3D music visualizer with glowing vertical frequency bars in a spectrum cityscape",
        ["plasma_field"] = "a 3D music visualizer with glowing plasma energy field with swirling vibrant colors",
        ["neon_pulse"] = "a 3D music visualizer with bright neon expanding rings with vivid saturated colors",
        ["neon_grid"] = "a 3D music visualizer with retro neon grid landscape with bright neon colors",
        ["particle_flow"] = "a 3D music visualizer with thousands of particles flowing through a tunnel in dynamic patterns",
        ["waveform"] = "a 3D music visualizer with audio tunnel corridor with reactive walls and depth perspective",
        ["vortex_tunnel"] = "a 3D music visualizer with tunnel vortex effect with depth perspective",
        ["sphere"] = "a 3D music visualizer with fluid metaball sphere with glossy wet surface and caustic patterns",
        ["liquid_mercury"] = "a 3D music visualizer with liquid metal mercury surface rippling with audio",
        ["aurora"] = "a 3D music visualizer with vibrant green teal purple aurora curtains flowing in a dark sky",
        ["aurora_borealis"] = "a 3D music visualizer with vibrant green teal purple aurora curtains flowing in a dark sky",
        ["dna_helix"] = "a 3D music visualizer with rotating DNA double helix with glowing strands and energy flow",
        ["heartbeat"] = "a 3D music visualizer with deep red pulsating heart shape with blue purple highlights",
        ["rtx_mesh"] = "a 3D music visualizer with deformable wireframe mesh with metallic surface and grid overlay",
        ["ray_marched"] = "a 3D music visualizer with morphing 3D objects with mandelbulb fractal and volumetric glow",
        ["volumetric_clouds"] = "a 3D music visualizer with volumetric cloud field with sunlight and atmospheric depth",
        ["fractal_dimensions"] = "a 3D music visualizer with 3D mandelbulb fractal with orbit trap coloring and deep structure",
        ["fractal_cosmos"] = "a 3D music visualizer with cosmic fractal patterns spiraling with music",
        ["neural_network"] = "a 3D music visualizer with neural network lattice with glowing neuron spheres and synapse connections",
        ["cosmic_web"] = "a 3D music visualizer with web of connected glowing nodes in 3D space",
        ["quantum_field"] = "a 3D music visualizer with quantum probability cloud with wave function interference patterns",
        ["holographic"] = "a 3D music visualizer with holographic cyan wireframe object with scan lines and grid floor",
        ["holographic_grid"] = "a 3D music visualizer with holographic scan lines and wireframe grid",
        ["particle_storm"] = "a 3D music visualizer with turbulent particle storm with dual vortex cores and swirling energy",
        ["wave_pool"] = "a 3D music visualizer with liquid water surface with ripple waves and caustic reflections",
        ["audio_ripple"] = "a 3D music visualizer with concentric ripple waves expanding from center",
        ["tessellation"] = "a 3D music visualizer with tessellated geometric surface with fault lines and wireframe",
        ["compute_shaders"] = "a 3D music visualizer with green matrix digital rain falling in a dark corridor",
        ["matrix_rain"] = "a 3D music visualizer with green matrix digital rain falling in a dark corridor",
        ["rtx_reflections"] = "a 3D music visualizer with reflective metallic objects orbiting with skybox reflections",
        ["wave_tessellation"] = "a 3D music visualizer with tessellated wave surface with colorful liquid shading",
        ["spectrum_3d"] = "a 3D music visualizer with stereo mirror spectrum analyzer bars in perspective depth",
        ["crystal_lattice"] = "a 3D music visualizer with crystal lattice refracting light with prismatic colors",
        ["fire_aura"] = "a 3D music visualizer with fire flames emanating with audio reactive intensity",
        ["geometric_mandala"] = "a 3D music visualizer with symmetrical geometric mandala patterns rotating",
        ["starfield_warp"] = "a 3D music visualizer with starfield warp speed lines effect",
        ["plasma_sphere"] = "a 3D music visualizer with glowing plasma orb with energy tendrils",
        ["lightning_storm"] = "a 3D music visualizer with electric lightning bolts flashing across dark sky",
        ["gravity_well"] = "a 3D music visualizer with gravitational black hole with matter spiraling inward",
        ["shatter_glass"] = "a 3D music visualizer with glass shattering patterns with prismatic refraction",
        ["ink_drop"] = "a 3D music visualizer with ink drops in water creating swirling colorful clouds",
        ["_default"] = "a 3D music visualizer with audio reactive visuals and colorful effects",
    };
}
