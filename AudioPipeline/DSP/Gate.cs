namespace StageSimWASAPI.DSP;

public sealed class Gate : IDspModule
{
    private float _thresholdDb;
    private float _hysteresisDb;
    private float _attackMs;
    private float _releaseMs;
    private float _rangeDb;
    private double _sampleRate;

    private float _attackCoeff;
    private float _releaseCoeff;
    private float _envelope;
    private bool _gateOpen;
    private float _closedGain;

    public float ThresholdDb { get => _thresholdDb; set => _thresholdDb = value; }
    public float HysteresisDb { get => _hysteresisDb; set => _hysteresisDb = value; }
    public float AttackMs { get => _attackMs; set { _attackMs = value; UpdateCoeffs(); } }
    public float ReleaseMs { get => _releaseMs; set { _releaseMs = value; UpdateCoeffs(); } }
    public float RangeDb { get => _rangeDb; set { _rangeDb = value; _closedGain = MathF.Pow(10, value / 20); } }

    public Gate(float thresholdDb = -60.0f, float hysteresisDb = 6.0f,
        float attackMs = 1.0f, float releaseMs = 100.0f,
        float rangeDb = -80.0f)
    {
        _thresholdDb = thresholdDb;
        _hysteresisDb = hysteresisDb;
        _attackMs = attackMs;
        _releaseMs = releaseMs;
        _rangeDb = rangeDb;
        _closedGain = MathF.Pow(10, rangeDb / 20);
        _gateOpen = true;
    }

    public void Prepare(double sampleRate, int maxBlockSize)
    {
        _sampleRate = sampleRate;
        UpdateCoeffs();
    }

    public void Process(ReadOnlySpan<float> input, Span<float> output)
    {
        float thresholdLinear = MathF.Pow(10, _thresholdDb / 20);
        float openThreshold = thresholdLinear * MathF.Pow(10, _hysteresisDb / 20);
        float closeThreshold = thresholdLinear / MathF.Pow(10, _hysteresisDb / 20);

        for (int i = 0; i < input.Length; i++)
        {
            float absInput = MathF.Abs(input[i]);
            float coeff = absInput > _envelope ? _attackCoeff : _releaseCoeff;
            _envelope = absInput + coeff * (_envelope - absInput);

            if (!_gateOpen && _envelope > openThreshold)
                _gateOpen = true;
            else if (_gateOpen && _envelope < closeThreshold)
                _gateOpen = false;

            output[i] = input[i] * (_gateOpen ? 1.0f : _closedGain);
        }
    }

    public void Reset()
    {
        _envelope = 0;
        _gateOpen = true;
    }

    private void UpdateCoeffs()
    {
        _attackCoeff = MathF.Exp(-1.0f / (_attackMs * 0.001f * (float)_sampleRate));
        _releaseCoeff = MathF.Exp(-1.0f / (_releaseMs * 0.001f * (float)_sampleRate));
    }
}
