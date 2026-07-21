namespace StageSimWASAPI.DSP;

public interface IDspModule
{
    void Prepare(double sampleRate, int maxBlockSize);
    void Process(ReadOnlySpan<float> input, Span<float> output);
    void Reset();
}
