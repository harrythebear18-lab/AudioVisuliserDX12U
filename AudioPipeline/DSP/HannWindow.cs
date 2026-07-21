namespace StageSimWASAPI.DSP;

public sealed class HannWindow : IDspModule
{
    private readonly float[] _window;
    private readonly int _size;
    private double _sampleRate;

    public int Size => _size;

    public HannWindow(int size)
    {
        _size = size;
        _window = new float[size];
        ComputeWindow();
    }

    public void Prepare(double sampleRate, int maxBlockSize)
    {
        _sampleRate = sampleRate;
    }

    public void Process(ReadOnlySpan<float> input, Span<float> output)
    {
        int n = Math.Min(input.Length, _size);
        for (int i = 0; i < n; i++)
            output[i] = input[i] * _window[i];
    }

    public void ApplyInPlace(Span<float> buffer)
    {
        int n = Math.Min(buffer.Length, _size);
        for (int i = 0; i < n; i++)
            buffer[i] *= _window[i];
    }

    public void Reset() { }

    private void ComputeWindow()
    {
        int n = _size;
        for (int i = 0; i < n; i++)
            _window[i] = 0.5f - 0.5f * MathF.Cos(2.0f * MathF.PI * i / (n - 1));
    }
}
