using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace DXRenderer;

/// <summary>
/// CLIP BPE tokenizer — byte-level byte-pair encoding matching OpenAI's CLIP implementation.
/// Loads vocab.json and merges.txt from HuggingFace clip-vit-base-patch32.
/// Encodes text to token IDs (max 77) with SOT/EOT tokens for CLIP text encoder.
/// </summary>
public class CLIPTokenizer
{
    private readonly Dictionary<string, int> _vocab;
    private readonly Dictionary<(string, string), int> _mergesRank;
    private readonly Dictionary<int, char> _byteEncoder;
    private readonly Dictionary<char, int> _byteDecoder;

    public const int SOTToken = 49406;
    public const int EOTToken = 49407;
    public const int MaxSeqLen = 77;
    public const int VocabSize = 49408;

    private static readonly Regex TokenPattern = new(
        @"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+",
        RegexOptions.Compiled);

    public bool IsAvailable { get; }

    public CLIPTokenizer(string vocabPath, string mergesPath)
    {
        _byteEncoder = BuildByteEncoder();
        _byteDecoder = _byteEncoder.ToDictionary(kv => kv.Value, kv => kv.Key);
        _vocab = new Dictionary<string, int>();
        _mergesRank = new Dictionary<(string, string), int>();

        try
        {
            LoadVocab(vocabPath);
            LoadMerges(mergesPath);
            IsAvailable = _vocab.Count > 0 && _mergesRank.Count > 0;
        }
        catch (Exception ex)
        {
            DebugLogger.Warn($"[CLIPTokenizer] Failed to load: {ex.Message}");
            IsAvailable = false;
        }
    }

    /// <summary>
    /// Encode text to CLIP token IDs. Prepends SOT, appends EOT, pads to 77.
    /// </summary>
    public int[] Encode(string text)
    {
        if (!IsAvailable) return Array.Empty<int>();

        text = text.ToLowerInvariant().Trim();
        var tokens = new List<int> { SOTToken };

        foreach (Match m in TokenPattern.Matches(text))
        {
            string token = m.Value;
            // Byte-encode: each UTF-8 byte → unicode char
            byte[] bytes = Encoding.UTF8.GetBytes(token);
            var encoded = new StringBuilder(bytes.Length);
            foreach (byte b in bytes)
                encoded.Append(_byteEncoder[b]);

            // BPE encode
            var bpeTokens = BPE(encoded.ToString());
            foreach (var bt in bpeTokens)
            {
                if (_vocab.TryGetValue(bt, out int id))
                    tokens.Add(id);
            }
        }

        tokens.Add(EOTToken);

        // Pad or truncate to MaxSeqLen
        var result = new int[MaxSeqLen];
        int copyLen = Math.Min(tokens.Count, MaxSeqLen);
        Array.Copy(tokens.ToArray(), result, copyLen);
        // Remaining slots stay 0 (padding)
        return result;
    }

    /// <summary>
    /// Get attention mask: 1 for real tokens, 0 for padding.
    /// </summary>
    public int[] GetAttentionMask(int[] tokenIds)
    {
        var mask = new int[MaxSeqLen];
        for (int i = 0; i < MaxSeqLen; i++)
            mask[i] = tokenIds[i] != 0 ? 1 : 0;
        return mask;
    }

    private string[] BPE(string token)
    {
        if (token.Length <= 1) return new[] { token };

        var word = token.Select(c => c.ToString()).ToList();

        while (word.Count > 1)
        {
            // Find the pair with the lowest merge rank
            (string, string)? minPair = null;
            int minRank = int.MaxValue;
            for (int i = 0; i < word.Count - 1; i++)
            {
                var pair = (word[i], word[i + 1]);
                if (_mergesRank.TryGetValue(pair, out int rank) && rank < minRank)
                {
                    minRank = rank;
                    minPair = pair;
                }
            }
            if (minPair == null) break;

            // Merge all instances of the minimum pair
            var newWord = new List<string>(word.Count);
            int j = 0;
            while (j < word.Count)
            {
                if (j < word.Count - 1 && word[j] == minPair.Value.Item1 && word[j + 1] == minPair.Value.Item2)
                {
                    newWord.Add(word[j] + word[j + 1]);
                    j += 2;
                }
                else
                {
                    newWord.Add(word[j]);
                    j++;
                }
            }
            word = newWord;
        }

        return word.ToArray();
    }

    private void LoadVocab(string path)
    {
        var json = File.ReadAllText(path);
        using var doc = JsonDocument.Parse(json);
        foreach (var prop in doc.RootElement.EnumerateObject())
            _vocab[prop.Name] = prop.Value.GetInt32();
        DebugLogger.Info($"[CLIPTokenizer] Loaded {_vocab.Count} vocab entries from {Path.GetFileName(path)}");
    }

    private void LoadMerges(string path)
    {
        var lines = File.ReadAllLines(path);
        int rank = 0;
        foreach (var line in lines)
        {
            if (line.StartsWith("#") || string.IsNullOrWhiteSpace(line)) continue;
            var parts = line.Split(' ', 2);
            if (parts.Length == 2)
                _mergesRank[(parts[0], parts[1])] = rank;
            rank++;
        }
        DebugLogger.Info($"[CLIPTokenizer] Loaded {_mergesRank.Count} BPE merges from {Path.GetFileName(path)}");
    }

    /// <summary>
    /// Build the byte-to-unicode mapping used by CLIP's BPE.
    /// Maps bytes 0-255 to unique unicode characters so BPE can operate on bytes.
    /// </summary>
    private static Dictionary<int, char> BuildByteEncoder()
    {
        var bs = new List<int>();
        for (int i = 33; i <= 126; i++) bs.Add(i);   // !-~
        for (int i = 161; i <= 172; i++) bs.Add(i);   // ¡-¬
        for (int i = 174; i <= 255; i++) bs.Add(i);   // ®-ÿ

        var cs = new List<int>(bs);
        int n = 0;
        for (int b = 0; b < 256; b++)
        {
            if (!bs.Contains(b))
            {
                bs.Add(b);
                cs.Add(256 + n);
                n++;
            }
        }

        var result = new Dictionary<int, char>(256);
        for (int i = 0; i < bs.Count; i++)
            result[bs[i]] = (char)cs[i];
        return result;
    }
}
