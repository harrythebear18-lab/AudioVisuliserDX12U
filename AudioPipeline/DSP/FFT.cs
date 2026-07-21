namespace StageSimWASAPI.DSP;

public sealed class FFT : IDspModule
{
    private readonly int _size;
    private readonly float[] _real;
    private readonly float[] _imag;
    private readonly float[] _twiddleCos;
    private readonly float[] _twiddleSin;
    private readonly int[] _bitReverse;
    private double _sampleRate;

    public int Size => _size;
    public int BinCount => _size / 2;

    public FFT(int size)
    {
        if (size <= 0 || (size & (size - 1)) != 0)
            throw new ArgumentException("Size must be a power of 2", nameof(size));

        _size = size;
        _real = new float[size];
        _imag = new float[size];
        _twiddleCos = new float[size / 2];
        _twiddleSin = new float[size / 2];
        _bitReverse = new int[size];

        PrecomputeTwiddles();
        PrecomputeBitReverse();
    }

    public void Prepare(double sampleRate, int maxBlockSize)
    {
        _sampleRate = sampleRate;
    }

    public void Process(ReadOnlySpan<float> input, Span<float> output)
    {
        int n = _size;
        input.Slice(0, Math.Min(input.Length, n)).CopyTo(_real);
        if (input.Length < n)
            Array.Clear(_real, input.Length, n - input.Length);
        Array.Clear(_imag, 0, n);

        BitReversalPermutation();

        for (int stage = 1; stage < n; stage <<= 1)
        {
            int halfStage = stage;
            int stage2 = stage << 1;
            float step = -MathF.PI / halfStage;

            for (int k = 0; k < halfStage; k++)
            {
                float cos = MathF.Cos(step * k);
                float sin = MathF.Sin(step * k);

                for (int i = k; i < n; i += stage2)
                {
                    int j = i + halfStage;
                    float tempReal = cos * _real[j] - sin * _imag[j];
                    float tempImag = cos * _imag[j] + sin * _real[j];

                    _real[j] = _real[i] - tempReal;
                    _imag[j] = _imag[i] - tempImag;
                    _real[i] += tempReal;
                    _imag[i] += tempImag;
                }
            }
        }

        int halfN = n / 2;
        for (int i = 0; i < halfN && i < output.Length; i++)
        {
            output[i] = MathF.Sqrt(_real[i] * _real[i] + _imag[i] * _imag[i]) * (2.0f / n);
        }
    }

    public void Reset()
    {
        Array.Clear(_real, 0, _size);
        Array.Clear(_imag, 0, _size);
    }

    public double BinToFrequency(int bin) => bin * _sampleRate / _size;
    public int FrequencyToBin(double frequency) => (int)(frequency * _size / _sampleRate);

    private void PrecomputeTwiddles()
    {
        int half = _size / 2;
        for (int k = 0; k < half; k++)
        {
            float angle = -2.0f * MathF.PI * k / _size;
            _twiddleCos[k] = MathF.Cos(angle);
            _twiddleSin[k] = MathF.Sin(angle);
        }
    }

    private void PrecomputeBitReverse()
    {
        int n = _size;
        int bits = (int)Math.Log2(n);
        for (int i = 0; i < n; i++)
        {
            int rev = 0;
            int x = i;
            for (int b = 0; b < bits; b++)
            {
                rev = (rev << 1) | (x & 1);
                x >>= 1;
            }
            _bitReverse[i] = rev;
        }
    }

    private void BitReversalPermutation()
    {
        for (int i = 0; i < _size; i++)
        {
            int j = _bitReverse[i];
            if (j > i)
            {
                (_real[i], _real[j]) = (_real[j], _real[i]);
                (_imag[i], _imag[j]) = (_imag[j], _imag[i]);
            }
        }
    }
}
