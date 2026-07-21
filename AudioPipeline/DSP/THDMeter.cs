namespace StageSimWASAPI.DSP;

public sealed class THDMeter : IDspModule
{
    private readonly FFT _fft;
    private readonly HannWindow _window;
    private readonly float[] _windowedBuffer;
    private readonly float[] _magnitudeSpectrum;
    private double _sampleRate;

    public float THDPercentage { get; private set; }

    public THDMeter(int fftSize = 2048)
    {
        _fft = new FFT(fftSize);
        _window = new HannWindow(fftSize);
        _windowedBuffer = new float[fftSize];
        _magnitudeSpectrum = new float[fftSize / 2];
    }

    public void Prepare(double sampleRate, int maxBlockSize)
    {
        _sampleRate = sampleRate;
        _fft.Prepare(sampleRate, maxBlockSize);
        _window.Prepare(sampleRate, maxBlockSize);
    }

    public void Process(ReadOnlySpan<float> input, Span<float> output)
    {
        if (output.Length > 0)
            input.CopyTo(output);

        int n = Math.Min(input.Length, _windowedBuffer.Length);
        input.Slice(0, n).CopyTo(_windowedBuffer);
        if (n < _windowedBuffer.Length)
            Array.Clear(_windowedBuffer, n, _windowedBuffer.Length - n);

        _window.ApplyInPlace(_windowedBuffer);
        _fft.Process(_windowedBuffer, _magnitudeSpectrum);

        int fundamentalBin = FindFundamentalBin();
        if (fundamentalBin <= 0)
        {
            THDPercentage = 0;
            return;
        }

        float fundamentalPower = _magnitudeSpectrum[fundamentalBin] * _magnitudeSpectrum[fundamentalBin];
        if (fundamentalPower < 1e-20f)
        {
            THDPercentage = 0;
            return;
        }

        float harmonicPower = 0;
        int maxBin = _magnitudeSpectrum.Length;
        for (int h = 2; fundamentalBin * h < maxBin; h++)
        {
            float mag = _magnitudeSpectrum[fundamentalBin * h];
            harmonicPower += mag * mag;
        }

        THDPercentage = MathF.Sqrt(harmonicPower / fundamentalPower) * 100.0f;
    }

    public void Reset()
    {
        THDPercentage = 0;
        Array.Clear(_windowedBuffer, 0, _windowedBuffer.Length);
        Array.Clear(_magnitudeSpectrum, 0, _magnitudeSpectrum.Length);
    }

    private int FindFundamentalBin()
    {
        float maxMag = 0;
        int maxBin = 0;
        int minBin = (int)(20.0 * _fft.Size / _sampleRate);
        int maxSearchBin = (int)(_sampleRate / 2 * _fft.Size / _sampleRate);

        for (int i = minBin; i < maxSearchBin && i < _magnitudeSpectrum.Length; i++)
        {
            if (_magnitudeSpectrum[i] > maxMag)
            {
                maxMag = _magnitudeSpectrum[i];
                maxBin = i;
            }
        }

        return maxBin;
    }
}
