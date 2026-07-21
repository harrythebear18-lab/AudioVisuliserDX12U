namespace StageSimWASAPI.DSP;

public sealed class LevelMeter : IDspModule
{
    private float _peakAttackMs;
    private float _peakReleaseMs;
    private float _rmsAttackMs;
    private float _rmsReleaseMs;
    private double _sampleRate;

    private float _peakAttackCoeff;
    private float _peakReleaseCoeff;
    private float _rmsAttackCoeff;
    private float _rmsReleaseCoeff;

    private float _currentPeak;
    private float _currentRms;

    public float PeakLinear => _currentPeak;
    public float PeakDb => ToDb(_currentPeak);
    public float RmsLinear => _currentRms;
    public float RmsDb => ToDb(_currentRms);
    public float CrestFactorDb => PeakDb - RmsDb;

    public LevelMeter(float peakAttackMs = 5.0f, float peakReleaseMs = 500.0f,
        float rmsAttackMs = 300.0f, float rmsReleaseMs = 300.0f)
    {
        _peakAttackMs = peakAttackMs;
        _peakReleaseMs = peakReleaseMs;
        _rmsAttackMs = rmsAttackMs;
        _rmsReleaseMs = rmsReleaseMs;
    }

    public void Prepare(double sampleRate, int maxBlockSize)
    {
        _sampleRate = sampleRate;
        _peakAttackCoeff = MathF.Exp(-1.0f / (_peakAttackMs * 0.001f * (float)_sampleRate));
        _peakReleaseCoeff = MathF.Exp(-1.0f / (_peakReleaseMs * 0.001f * (float)_sampleRate));
        _rmsAttackCoeff = MathF.Exp(-1.0f / (_rmsAttackMs * 0.001f * (float)_sampleRate));
        _rmsReleaseCoeff = MathF.Exp(-1.0f / (_rmsReleaseMs * 0.001f * (float)_sampleRate));
    }

    public void Process(ReadOnlySpan<float> input, Span<float> output)
    {
        float sumSquares = 0;
        float peak = 0;

        for (int i = 0; i < input.Length; i++)
        {
            float abs = MathF.Abs(input[i]);
            if (abs > peak) peak = abs;
            sumSquares += input[i] * input[i];
        }

        float rms = MathF.Sqrt(sumSquares / input.Length);

        float peakCoeff = peak > _currentPeak ? _peakAttackCoeff : _peakReleaseCoeff;
        _currentPeak = peak + peakCoeff * (_currentPeak - peak);

        float rmsCoeff = rms > _currentRms ? _rmsAttackCoeff : _rmsReleaseCoeff;
        _currentRms = rms + rmsCoeff * (_currentRms - rms);

        if (output.Length > 0)
            input.CopyTo(output);
    }

    public void Reset()
    {
        _currentPeak = 0;
        _currentRms = 0;
    }

    private static float ToDb(float linear) =>
        linear > 1e-10f ? 20.0f * MathF.Log10(linear) : -200.0f;
}
