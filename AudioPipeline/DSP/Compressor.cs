namespace StageSimWASAPI.DSP;

public sealed class Compressor : IDspModule
{
    private float _thresholdDb;
    private float _ratio;
    private float _attackMs;
    private float _releaseMs;
    private float _kneeDb;
    private float _makeupDb;
    private double _sampleRate;

    private float _attackCoeff;
    private float _releaseCoeff;
    private float _envelope;
    private float _makeupGainLinear;

    public float ThresholdDb { get => _thresholdDb; set => _thresholdDb = value; }
    public float Ratio { get => _ratio; set => _ratio = value; }
    public float AttackMs { get => _attackMs; set { _attackMs = value; UpdateCoeffs(); } }
    public float ReleaseMs { get => _releaseMs; set { _releaseMs = value; UpdateCoeffs(); } }
    public float KneeDb { get => _kneeDb; set => _kneeDb = value; }
    public float MakeupDb { get => _makeupDb; set { _makeupDb = value; _makeupGainLinear = MathF.Pow(10, value / 20); } }

    public Compressor(float thresholdDb = -20.0f, float ratio = 4.0f,
        float attackMs = 10.0f, float releaseMs = 100.0f,
        float kneeDb = 6.0f, float makeupDb = 0.0f)
    {
        _thresholdDb = thresholdDb;
        _ratio = ratio;
        _attackMs = attackMs;
        _releaseMs = releaseMs;
        _kneeDb = kneeDb;
        _makeupDb = makeupDb;
        _makeupGainLinear = MathF.Pow(10, makeupDb / 20);
    }

    public void Prepare(double sampleRate, int maxBlockSize)
    {
        _sampleRate = sampleRate;
        UpdateCoeffs();
    }

    public void Process(ReadOnlySpan<float> input, Span<float> output)
    {
        float thresholdLinear = MathF.Pow(10, _thresholdDb / 20);

        for (int i = 0; i < input.Length; i++)
        {
            float absInput = MathF.Abs(input[i]);
            float target = absInput;

            float coeff = absInput > _envelope ? _attackCoeff : _releaseCoeff;
            _envelope = target + coeff * (_envelope - target);

            float gainReduction = 1.0f;
            if (_envelope > thresholdLinear)
            {
                float overDb = 20 * MathF.Log10(_envelope / thresholdLinear + 1e-10f);
                float compressedDb = overDb / _ratio;
                gainReduction = MathF.Pow(10, -(overDb - compressedDb) / 20);
            }

            output[i] = input[i] * gainReduction * _makeupGainLinear;
        }
    }

    public void Reset()
    {
        _envelope = 0;
    }

    private void UpdateCoeffs()
    {
        _attackCoeff = MathF.Exp(-1.0f / (_attackMs * 0.001f * (float)_sampleRate));
        _releaseCoeff = MathF.Exp(-1.0f / (_releaseMs * 0.001f * (float)_sampleRate));
    }
}
