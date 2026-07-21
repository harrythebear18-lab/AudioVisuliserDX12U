using System;

namespace StageSimWASAPI.DSP
{
    /// <summary>
    /// Resonance DSP pipeline — enriches the existing audio pipeline with
    /// professional-grade analysis: LUFS, THD, phase correlation, level metering,
    /// and biquad-based band filtering. Runs alongside the existing FFTProvider/AudioAnalyzer.
    /// </summary>
    public sealed class DspPipeline : IDisposable
    {
        private readonly LUFSMeter _lufsMeter;
        private readonly PhaseCorrelator _phaseCorrelator;
        private readonly LevelMeter _levelMeterL;
        private readonly LevelMeter _levelMeterR;
        private readonly THDMeter _thdMeter;

        // Biquad band-pass filters for cleaner 8-band separation
        // (complements the existing FFT-based band analysis)
        private readonly BiquadFilter[] _bandFilters;

        private double _sampleRate;
        private bool _prepared;

        // Analysis results — accessible to AudioPipelineOrchestrator
        public float MomentaryLUFS => _lufsMeter.MomentaryLUFS;
        public float ShortTermLUFS => _lufsMeter.ShortTermLUFS;
        public float IntegratedLUFS => _lufsMeter.IntegratedLUFS;
        public float PhaseCorrelation => _phaseCorrelator.Correlation;
        public float PeakDbL => _levelMeterL.PeakDb;
        public float PeakDbR => _levelMeterR.PeakDb;
        public float RmsDbL => _levelMeterL.RmsDb;
        public float RmsDbR => _levelMeterR.RmsDb;
        public float CrestFactorDbL => _levelMeterL.CrestFactorDb;
        public float CrestFactorDbR => _levelMeterR.CrestFactorDb;
        public float THDPercentage => _thdMeter.THDPercentage;

        // Band-pass filter outputs (8 bands, matching AudioAnalyzer bands)
        public float[] BandLevels { get; } = new float[8];

        // Band center frequencies (Hz) — matches AudioAnalyzer band definitions
        private static readonly float[] BandCenterHz = {
            35f,   // sub:      10-60
            155f,  // bass:     60-250
            375f,  // low_mid:  250-500
            1250f, // mid:      500-2000
            3000f, // high_mid: 2000-4000
            5000f, // presence: 4000-6000
            9000f, // brilliance: 6000-12000
            16000f // air:      12000-32000
        };

        public DspPipeline()
        {
            _lufsMeter = new LUFSMeter();
            _phaseCorrelator = new PhaseCorrelator();
            _levelMeterL = new LevelMeter(5.0f, 500.0f, 300.0f, 300.0f);
            _levelMeterR = new LevelMeter(5.0f, 500.0f, 300.0f, 300.0f);
            _thdMeter = new THDMeter(2048);

            _bandFilters = new BiquadFilter[8];
            for (int i = 0; i < 8; i++)
            {
                _bandFilters[i] = new BiquadFilter(BiquadType.BandPass, BandCenterHz[i], 0.707f);
            }
        }

        public void Prepare(double sampleRate, int maxBlockSize)
        {
            _sampleRate = sampleRate;
            _lufsMeter.Prepare(sampleRate, maxBlockSize);
            _phaseCorrelator.Prepare(sampleRate, maxBlockSize);
            _levelMeterL.Prepare(sampleRate, maxBlockSize);
            _levelMeterR.Prepare(sampleRate, maxBlockSize);
            _thdMeter.Prepare(sampleRate, maxBlockSize);
            foreach (var f in _bandFilters)
                f.Prepare(sampleRate, maxBlockSize);
            _prepared = true;
        }

        /// <summary>
        /// Process a stereo audio block. left and right are float samples.
        /// Updates all meters and analysis outputs.
        /// </summary>
        public void ProcessStereo(ReadOnlySpan<float> left, ReadOnlySpan<float> right)
        {
            if (!_prepared || left.Length == 0) return;

            int n = Math.Min(left.Length, right.Length);

            // LUFS (EBU R128 K-weighted loudness)
            _lufsMeter.ProcessStereo(left, right);

            // Phase correlation
            _phaseCorrelator.ProcessStereo(left, right);

            // Per-channel level meters
            _levelMeterL.Process(left, Span<float>.Empty);
            _levelMeterR.Process(right, Span<float>.Empty);

            // THD on mono mix (left+right)/2
            Span<float> mono = stackalloc float[n];
            for (int i = 0; i < n; i++)
                mono[i] = (left[i] + right[i]) * 0.5f;
            _thdMeter.Process(mono, Span<float>.Empty);

            // Band-pass filter levels for each of the 8 bands
            Span<float> bandOut = stackalloc float[n];
            for (int b = 0; b < 8; b++)
            {
                _bandFilters[b].Process(mono, bandOut);
                float sum = 0;
                for (int i = 0; i < n; i++)
                    sum += bandOut[i] * bandOut[i];
                BandLevels[b] = MathF.Sqrt(sum / n);
            }
        }

        /// <summary>
        /// Process a mono audio block. Updates LUFS, level, THD, and band levels.
        /// Phase correlation requires stereo — skipped for mono input.
        /// </summary>
        public void ProcessMono(ReadOnlySpan<float> input)
        {
            if (!_prepared || input.Length == 0) return;

            // LUFS (mono — treat as both channels)
            _lufsMeter.Process(input, Span<float>.Empty);

            // Level meter
            _levelMeterL.Process(input, Span<float>.Empty);

            // THD
            _thdMeter.Process(input, Span<float>.Empty);

            // Band levels
            Span<float> bandOut = stackalloc float[input.Length];
            for (int b = 0; b < 8; b++)
            {
                _bandFilters[b].Process(input, bandOut);
                float sum = 0;
                for (int i = 0; i < input.Length; i++)
                    sum += bandOut[i] * bandOut[i];
                BandLevels[b] = MathF.Sqrt(sum / input.Length);
            }
        }

        public void Reset()
        {
            _lufsMeter.Reset();
            _phaseCorrelator.Reset();
            _levelMeterL.Reset();
            _levelMeterR.Reset();
            _thdMeter.Reset();
            foreach (var f in _bandFilters)
                f.Reset();
            Array.Clear(BandLevels, 0, BandLevels.Length);
        }

        public void Dispose()
        {
            // BiquadFilters are managed objects, no native resources
            // Nothing to explicitly dispose
        }
    }
}
