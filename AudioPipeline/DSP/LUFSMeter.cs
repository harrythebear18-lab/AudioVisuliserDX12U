namespace StageSimWASAPI.DSP;

public sealed class LUFSMeter : IDspModule
{
    private readonly BiquadFilter _preFilter;
    private readonly BiquadFilter _rlbFilter;
    private double _sampleRate;
    private int _lastBlockSize;

    private float _momentaryLoudness = -70.0f;
    private float _shortTermLoudness = -70.0f;
    private float _integratedLoudness = -70.0f;

    // Momentary: 400ms window, Short-term: 3s window
    // EBU R128: momentary uses 400ms, short-term uses 3s
    private const float MOMENTARY_WINDOW_SEC = 0.4f;
    private const float SHORT_TERM_WINDOW_SEC = 3.0f;
    private const float GATING_THRESHOLD_LUFS = -70.0f;
    private const float RELATIVE_GATE_OFFSET = -10.0f; // -10 LU relative gate

    // Ring buffers for sliding window loudness measurement
    private float[] _blockLoudness;      // per-block loudness values
    private float[] _blockMeanSquares;   // per-block mean square values
    private int _blockCount;
    private int _blockIndex;
    private const int MAX_BLOCKS = 300;  // enough for 3s at ~10ms blocks

    // Integrated loudness accumulation
    private double _integratedSumSquares;
    private long _integratedBlockCount;
    private float _relativeGateLevel = -70.0f;
    private bool _relativeGateEstablished;

    public float MomentaryLUFS => _momentaryLoudness;
    public float ShortTermLUFS => _shortTermLoudness;
    public float IntegratedLUFS => _integratedLoudness;

    public LUFSMeter()
    {
        _preFilter = new BiquadFilter(BiquadType.HighShelf, 1500.0f, 0.707f, 4.0f);
        _rlbFilter = new BiquadFilter(BiquadType.HighPass, 38.0f, 0.5f);
        _blockLoudness = new float[MAX_BLOCKS];
        _blockMeanSquares = new float[MAX_BLOCKS];
    }

    public void Prepare(double sampleRate, int maxBlockSize)
    {
        _sampleRate = sampleRate;
        _preFilter.Prepare(sampleRate, maxBlockSize);
        _rlbFilter.Prepare(sampleRate, maxBlockSize);
    }

    public void Process(ReadOnlySpan<float> input, Span<float> output)
    {
        _preFilter.Process(input, output);
        _rlbFilter.Process(output, output);

        float sumSquares = 0;
        for (int i = 0; i < output.Length; i++)
            sumSquares += output[i] * output[i];

        float meanSquare = sumSquares / input.Length;
        _lastBlockSize = input.Length;
        UpdateLoudness(meanSquare, 1);
    }

    public void ProcessStereo(ReadOnlySpan<float> left, ReadOnlySpan<float> right)
    {
        int n = Math.Min(left.Length, right.Length);
        if (n == 0) return;

        Span<float> leftK = stackalloc float[n];
        Span<float> rightK = stackalloc float[n];

        _preFilter.Process(left, leftK);
        _rlbFilter.Process(leftK, leftK);
        _preFilter.Process(right, rightK);
        _rlbFilter.Process(rightK, rightK);

        float sumSquares = 0;
        for (int i = 0; i < n; i++)
        {
            sumSquares += leftK[i] * leftK[i];
            sumSquares += rightK[i] * rightK[i];
        }

        float meanSquare = sumSquares / (2.0f * n);
        _lastBlockSize = n;
        UpdateLoudness(meanSquare, 2);
    }

    private void UpdateLoudness(float meanSquare, int channelCount)
    {
        // Store block mean square in ring buffer
        _blockMeanSquares[_blockIndex] = meanSquare;
        _blockLoudness[_blockIndex] = meanSquare > 1e-12f
            ? Math.Clamp(-0.691f + 10.0f * MathF.Log10(meanSquare), -70.0f, 0.0f)
            : -70.0f;
        _blockIndex = (_blockIndex + 1) % MAX_BLOCKS;
        if (_blockCount < MAX_BLOCKS) _blockCount++;

        // Momentary: 400ms sliding window
        float blockDurationSec = _sampleRate > 0 && _lastBlockSize > 0
            ? (float)(_lastBlockSize / _sampleRate)
            : 0.01f;
        int momentaryBlocks = Math.Max(1, (int)(MOMENTARY_WINDOW_SEC / blockDurationSec));
        momentaryBlocks = Math.Min(momentaryBlocks, _blockCount);

        float msSum = 0;
        for (int i = 0; i < momentaryBlocks; i++)
        {
            int idx = (_blockIndex - 1 - i + MAX_BLOCKS) % MAX_BLOCKS;
            msSum += _blockMeanSquares[idx];
        }
        float msAvg = msSum / momentaryBlocks;
        if (msAvg > 1e-12f)
            _momentaryLoudness = Math.Clamp(-0.691f + 10.0f * MathF.Log10(msAvg), -70.0f, 0.0f);

        // Short-term: 3s sliding window
        int shortTermBlocks = Math.Max(1, (int)(SHORT_TERM_WINDOW_SEC / blockDurationSec));
        shortTermBlocks = Math.Min(shortTermBlocks, _blockCount);

        float stSum = 0;
        for (int i = 0; i < shortTermBlocks; i++)
        {
            int idx = (_blockIndex - 1 - i + MAX_BLOCKS) % MAX_BLOCKS;
            stSum += _blockMeanSquares[idx];
        }
        float stAvg = stSum / shortTermBlocks;
        if (stAvg > 1e-12f)
            _shortTermLoudness = Math.Clamp(-0.691f + 10.0f * MathF.Log10(stAvg), -70.0f, 0.0f);

        // Integrated: EBU R128 gated average
        // Only accumulate blocks above absolute gate (-70 LUFS)
        float blockLoudness = _blockLoudness[(_blockIndex - 1 + MAX_BLOCKS) % MAX_BLOCKS];
        if (blockLoudness > GATING_THRESHOLD_LUFS)
        {
            _integratedSumSquares += meanSquare;
            _integratedBlockCount++;

            // After 10s of content, establish relative gate at -10 LU from integrated
            if (_integratedBlockCount > 100 && !_relativeGateEstablished)
            {
                float prelimIntegrated = -0.691f + 10.0f * MathF.Log10((float)(_integratedSumSquares / _integratedBlockCount));
                _relativeGateLevel = prelimIntegrated + RELATIVE_GATE_OFFSET;
                _relativeGateEstablished = true;
            }

            // Compute integrated with relative gating
            if (_relativeGateEstablished && blockLoudness > _relativeGateLevel)
            {
                _integratedLoudness = -0.691f + 10.0f * MathF.Log10((float)(_integratedSumSquares / _integratedBlockCount));
            }
            else if (!_relativeGateEstablished)
            {
                _integratedLoudness = -0.691f + 10.0f * MathF.Log10((float)(_integratedSumSquares / _integratedBlockCount));
            }
        }
    }

    public void Reset()
    {
        _preFilter.Reset();
        _rlbFilter.Reset();
        _momentaryLoudness = -70.0f;
        _shortTermLoudness = -70.0f;
        _integratedLoudness = -70.0f;
        Array.Clear(_blockLoudness, 0, MAX_BLOCKS);
        Array.Clear(_blockMeanSquares, 0, MAX_BLOCKS);
        _blockCount = 0;
        _blockIndex = 0;
        _integratedSumSquares = 0;
        _integratedBlockCount = 0;
        _relativeGateLevel = -70.0f;
        _relativeGateEstablished = false;
    }
}
