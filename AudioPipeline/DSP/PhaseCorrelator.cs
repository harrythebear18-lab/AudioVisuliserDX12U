namespace StageSimWASAPI.DSP;

public sealed class PhaseCorrelator : IDspModule
{
    private float _correlation;
    private double _sampleRate;

    public float Correlation => _correlation;

    public void Prepare(double sampleRate, int maxBlockSize)
    {
        _sampleRate = sampleRate;
    }

    public void Process(ReadOnlySpan<float> input, Span<float> output)
    {
        if (output.Length > 0)
            input.CopyTo(output);
    }

    public float ProcessStereo(ReadOnlySpan<float> left, ReadOnlySpan<float> right)
    {
        int n = Math.Min(left.Length, right.Length);
        if (n == 0) return 0;

        float correlation = 0;
        float leftPower = 0;
        float rightPower = 0;

        for (int i = 0; i < n; i++)
        {
            correlation += left[i] * right[i];
            leftPower += left[i] * left[i];
            rightPower += right[i] * right[i];
        }

        if (leftPower > 0 && rightPower > 0)
            _correlation = Math.Clamp(correlation / MathF.Sqrt(leftPower * rightPower), -1.0f, 1.0f);
        else
            _correlation = 0;

        return _correlation;
    }

    public void Reset()
    {
        _correlation = 0;
    }
}
