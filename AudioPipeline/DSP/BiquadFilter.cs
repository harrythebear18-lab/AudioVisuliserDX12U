namespace StageSimWASAPI.DSP;

public enum BiquadType
{
    LowPass,
    HighPass,
    BandPass,
    Notch,
    AllPass,
    Peaking,
    LowShelf,
    HighShelf
}

public sealed class BiquadFilter : IDspModule
{
    private BiquadType _type;
    private float _frequency;
    private float _q;
    private float _gainDb;
    private double _sampleRate;

    private float _a1, _a2, _b0, _b1, _b2;
    private float _z1, _z2;

    public BiquadType Type => _type;
    public float Frequency => _frequency;
    public float Q => _q;
    public float GainDb => _gainDb;

    public BiquadFilter(BiquadType type, float frequency, float q = 0.707f, float gainDb = 0.0f)
    {
        _type = type;
        _frequency = frequency;
        _q = q;
        _gainDb = gainDb;
    }

    public void SetParameters(BiquadType type, float frequency, float q, float gainDb)
    {
        _type = type;
        _frequency = frequency;
        _q = q;
        _gainDb = gainDb;
        if (_sampleRate > 0)
            ComputeCoefficients();
    }

    public void Prepare(double sampleRate, int maxBlockSize)
    {
        _sampleRate = sampleRate;
        ComputeCoefficients();
    }

    public void Process(ReadOnlySpan<float> input, Span<float> output)
    {
        for (int i = 0; i < input.Length; i++)
        {
            float x = input[i];
            float y = _b0 * x + _z1;
            _z1 = _b1 * x - _a1 * y + _z2;
            _z2 = _b2 * x - _a2 * y;
            output[i] = y;
        }
    }

    public void Reset()
    {
        _z1 = 0;
        _z2 = 0;
    }

    private void ComputeCoefficients()
    {
        float w0 = 2.0f * MathF.PI * _frequency / (float)_sampleRate;
        float cosW = MathF.Cos(w0);
        float sinW = MathF.Sin(w0);
        float alpha = sinW / (2.0f * _q);
        float A = MathF.Pow(10.0f, _gainDb / 40.0f);

        float b0, b1, b2, a0, a1, a2;

        switch (_type)
        {
            case BiquadType.LowPass:
                b0 = (1 - cosW) / 2;
                b1 = 1 - cosW;
                b2 = (1 - cosW) / 2;
                a0 = 1 + alpha;
                a1 = -2 * cosW;
                a2 = 1 - alpha;
                break;

            case BiquadType.HighPass:
                b0 = (1 + cosW) / 2;
                b1 = -(1 + cosW);
                b2 = (1 + cosW) / 2;
                a0 = 1 + alpha;
                a1 = -2 * cosW;
                a2 = 1 - alpha;
                break;

            case BiquadType.BandPass:
                b0 = alpha;
                b1 = 0;
                b2 = -alpha;
                a0 = 1 + alpha;
                a1 = -2 * cosW;
                a2 = 1 - alpha;
                break;

            case BiquadType.Notch:
                b0 = 1;
                b1 = -2 * cosW;
                b2 = 1;
                a0 = 1 + alpha;
                a1 = -2 * cosW;
                a2 = 1 - alpha;
                break;

            case BiquadType.AllPass:
                b0 = 1 - alpha;
                b1 = -2 * cosW;
                b2 = 1 + alpha;
                a0 = 1 + alpha;
                a1 = -2 * cosW;
                a2 = 1 - alpha;
                break;

            case BiquadType.Peaking:
                b0 = 1 + alpha * A;
                b1 = -2 * cosW;
                b2 = 1 - alpha * A;
                a0 = 1 + alpha / A;
                a1 = -2 * cosW;
                a2 = 1 - alpha / A;
                break;

            case BiquadType.LowShelf:
                {
                    float sqA = MathF.Sqrt(A);
                    b0 = A * ((A + 1) - (A - 1) * cosW + 2 * sqA * alpha);
                    b1 = 2 * A * ((A - 1) - (A + 1) * cosW);
                    b2 = A * ((A + 1) - (A - 1) * cosW - 2 * sqA * alpha);
                    a0 = (A + 1) + (A - 1) * cosW + 2 * sqA * alpha;
                    a1 = -2 * ((A - 1) + (A + 1) * cosW);
                    a2 = (A + 1) + (A - 1) * cosW - 2 * sqA * alpha;
                }
                break;

            case BiquadType.HighShelf:
                {
                    float sqA = MathF.Sqrt(A);
                    b0 = A * ((A + 1) + (A - 1) * cosW + 2 * sqA * alpha);
                    b1 = -2 * A * ((A - 1) + (A + 1) * cosW);
                    b2 = A * ((A + 1) + (A - 1) * cosW - 2 * sqA * alpha);
                    a0 = (A + 1) - (A - 1) * cosW + 2 * sqA * alpha;
                    a1 = 2 * ((A - 1) - (A + 1) * cosW);
                    a2 = (A + 1) - (A - 1) * cosW - 2 * sqA * alpha;
                }
                break;

            default:
                b0 = 1; b1 = 0; b2 = 0; a0 = 1; a1 = 0; a2 = 0;
                break;
        }

        _b0 = b0 / a0;
        _b1 = b1 / a0;
        _b2 = b2 / a0;
        _a1 = a1 / a0;
        _a2 = a2 / a0;
    }
}
