using System;
using System.Threading;

namespace StageSimWASAPI
{
    /// <summary>
    /// Lock-free quad buffer for visual frames.
    ///
    /// Four slots: Brain writes one, GPU reads the latest, two more ready.
    /// Data flagged for overwrite immediately after GPU consumes it.
    ///
    /// Flow: Brain → [Slot 0/1/2/3] → GPU reads latest → slot marked dirty → brain reuses
    /// Maintains cache headroom — only ever holds max 4 frames, old ones recycled.
    ///
    /// This is the in-process transport — for cross-process, use RDMASharedTransport.
    /// Both share the same VisualFrame struct so consumers don't care which transport they're on.
    /// </summary>
    public class QuadBufferedVisuals
    {
        public struct VisualFrame
        {
            public float Time;
            public float Width;
            public float Height;
            public float Aspect;

            // 8 frequency bands (from brain)
            public float Band0, Band1, Band2, Band3;
            public float Band4, Band5, Band6, Band7;

            // Brain dynamics
            public float BeatIntensity;
            public float BeatDetected;
            public float Transient;
            public float Envelope;
            public float Overall;
            public float BPM;
            public float TempoConfidence;
            public float KickLevel;
            public float KickConfidence;

            // Stereo
            public float StereoBalance;
            public float StereoWidth;
            public float LeftEnergy;
            public float RightEnergy;

            // Visualizer intensities (mapped from brain fixture concepts)
            public float EffectIntensity;        // overall effect drive
            public float MovementIntensity;      // camera/object motion speed
            public float Brightness;             // scene brightness (was DimmerIntensity)
            public float BeamIntensity;          // beam/line shader (was LaserIntensity)
            public float BloomIntensity;         // bloom/glow (was BlinderIntensity)
            public float DynamicLightIntensity;  // dynamic light source (was MovingLightIntensity)
            public float AmbientLightIntensity;  // ambient fill (was StaticLightIntensity)

            // Visualizer triggers (visualizer-native, replaces stage-sim fixture triggers)
            public int DynamicLightsActive;      // moving lights on/off
            public int BeamsActive;              // beams on/off
            public int AmbientActive;            // ambient lights on/off
            public int BloomActive;              // bloom on/off
            public int TriggerEffectBurst;       // one-shot visual effect
            public int EffectBurstType;          // 0=radial, 1=shockwave, 2=colorwave, 3=sparkle
            public float EffectBurstIntensity;   // 0-1 scale
            public float AtmosphereDensity;      // 0-1 haze/fog density
            public float ColorPulse;             // 0-1 smooth color pulse
            public int ShouldChangeEffectMode;

            // Color
            public float BaseHue;
            public float SectionHueCenter;
            public float SectionHueRange;
            public float ColorR, ColorG, ColorB;
            public float Color2R, Color2G, Color2B;
            public float Color3R, Color3G, Color3B;

            // Rhythm / phrase
            public int BeatCount;
            public int PhraseBeat;
            public float SectionConfidence;
            public int Section;
            public int IsSilent;
            public int DominantBand;

            // Group behavior
            public float GroupBehaviorMode;
            public float GroupBehaviorPhase;
            public float DesiredEffectMode;

            // Advanced analysis
            public float PhaseCorrelation;   // -1 to +1, L/R coherence
            public float BeatAnticipation;   // 0-1, ramps up before next beat
            public float SpectralClarity;    // 0-1, tonal vs noise (1=tonal)
            public float MotionPersistence;  // 0-1, trail/decay length from crest factor + BPM + energy + section

            // Frequency-domain features (Hz)
            public float SpectralCentroid;   // brightness-weighted mean frequency
            public float SpectralSpread;     // standard deviation around centroid
            public float DominantFrequency;  // frequency of the strongest bin

            // Pipeline latency (milliseconds) — fine-grained per-substage
            public float LatBufferDwellMs;     // time in circular buffer
            public float LatDeinterleaveMs;    // de-interleave + stereo analysis
            public float LatFFTComputeMs;      // FFT computation
            public float LatTripleDwellMs;     // time in triple buffer
            public float LatBrainProcessMs;    // analyzer.Process
            public float LatBrainUpdateMs;     // brain.Update
            public float LatFrameBuildMs;      // frame build + publish
            public float LatRenderMs;          // GPU render + present (set by renderer)
            public float LatTotalPipelineMs;   // full: capture → frame publish + render

            // Spectrum (variable length, stored separately)
            public int SpectrumLength;

            // VisualProfile — per-song adaptive visualization personality
            public float ProfileEnergy;        // 0-1 overall song energy
            public float ProfileBass;          // 0-1 bass heaviness
            public float ProfileTreble;        // 0-1 treble brightness
            public float ProfileTempo;         // 0=slow, 1=fast
            public float ProfilePunch;         // 0=diffuse, 1=tonal/punchy
            public float ProfileStereo;        // 0-1 stereo spread
            public float ProfileDynamic;       // 0-1 dynamic range variation
            public float ProfileGlow;          // 0-1 glow/bloom intensity
            public float ProfileBarScale;      // bar height multiplier
            public float ProfileMotionSpeed;   // animation speed multiplier
            public float ProfileSaturation;    // color saturation
            public float ProfilePerspective;   // 0-1 depth effect strength
            public int ProfileDominantSection; // most common section
            public float ProfileDuration;      // song duration in seconds

            // Resonance DSP — professional audio analysis (LUFS, THD, phase, crest factor)
            public float MomentaryLUFS;        // EBU R128 momentary loudness (LUFS)
            public float ShortTermLUFS;        // EBU R128 short-term loudness (LUFS)
            public float IntegratedLUFS;       // EBU R128 integrated loudness (LUFS)
            public float THDPercentage;        // Total Harmonic Distortion (%)
            public float PhaseCorrelationDSP;  // -1 to +1, from Resonance PhaseCorrelator
            public float PeakDbL;              // Peak level left channel (dB)
            public float PeakDbR;              // Peak level right channel (dB)
            public float RmsDbL;               // RMS level left channel (dB)
            public float RmsDbR;               // RMS level right channel (dB)
            public float CrestFactorDbL;       // Crest factor left (dB) — headroom indicator
            public float CrestFactorDbR;       // Crest factor right (dB)
            public float DspBand0;             // Biquad band-pass levels (8 bands)
            public float DspBand1;
            public float DspBand2;
            public float DspBand3;
            public float DspBand4;
            public float DspBand5;
            public float DspBand6;
            public float DspBand7;
        }

        private readonly VisualFrame[] _frames;
        private readonly float[][] _spectra;       // 4 spectrum buffers
        private readonly int[] _flags;             // 0=empty, 1=written, 2=reading, 3=dirty
        private int _writeSlot;
        private int _latestSlot;
        private readonly int _spectrumSize;

        public QuadBufferedVisuals(int spectrumSize = 1024)
        {
            _spectrumSize = spectrumSize;
            _frames = new VisualFrame[4];
            _spectra = new float[4][];
            _flags = new int[4];
            for (int i = 0; i < 4; i++)
            {
                _spectra[i] = new float[spectrumSize];
                _flags[i] = 0;
            }
            _writeSlot = 0;
            _latestSlot = -1;
        }

        /// <summary>
        /// Brain publishes a new visual frame + spectrum.
        /// Finds empty or dirty slot, fills it, marks written.
        /// </summary>
        public void Publish(ref VisualFrame frame, float[] spectrum, int specLen)
        {
            // Find empty or dirty slot
            for (int attempt = 0; attempt < 4; attempt++)
            {
                int slot = (_writeSlot + attempt) % 4;

                // Try empty
                if (Interlocked.CompareExchange(ref _flags[slot], 2, 0) == 0)
                {
                    WriteSlot(slot, ref frame, spectrum, specLen);
                    return;
                }

                // Try dirty (consumed by GPU)
                if (Interlocked.CompareExchange(ref _flags[slot], 2, 3) == 3)
                {
                    WriteSlot(slot, ref frame, spectrum, specLen);
                    return;
                }
            }

            // All slots busy — overwrite oldest written slot to maintain cache headroom
            int overwrite = _writeSlot;
            Interlocked.Exchange(ref _flags[overwrite], 2);
            WriteSlot(overwrite, ref frame, spectrum, specLen);
        }

        private void WriteSlot(int slot, ref VisualFrame frame, float[] spectrum, int specLen)
        {
            _frames[slot] = frame;
            int len = Math.Min(specLen, _spectrumSize);
            if (spectrum != null && len > 0)
                Array.Copy(spectrum, _spectra[slot], len);
            _frames[slot].SpectrumLength = len;

            Interlocked.Exchange(ref _flags[slot], 1); // written
            Interlocked.Exchange(ref _latestSlot, slot);
            _writeSlot = (slot + 1) % 4;
        }

        /// <summary>
        /// GPU/renderer consumes the latest visual frame.
        /// Copies frame + spectrum into output, marks slot dirty immediately.
        /// Returns false if no new data.
        /// </summary>
        public bool Consume(out VisualFrame frame, float[] outSpectrum, int specMaxLen)
        {
            frame = default;
            int slot = Interlocked.Exchange(ref _latestSlot, -1);
            if (slot < 0) return false;

            if (Interlocked.CompareExchange(ref _flags[slot], 2, 1) != 1)
                return false;

            frame = _frames[slot];
            int len = Math.Min(frame.SpectrumLength, Math.Min(specMaxLen, _spectrumSize));
            if (outSpectrum != null && len > 0)
                Array.Copy(_spectra[slot], outSpectrum, len);

            Interlocked.Exchange(ref _flags[slot], 3); // dirty — ready for overwrite
            return true;
        }

        public bool HasData => Interlocked.CompareExchange(ref _latestSlot, -1, -1) >= 0;

        /// <summary>
        /// Try consume — returns spectrum array directly (no copy needed).
        /// Convenience overload for C# renderers.
        /// </summary>
        public bool TryConsume(out VisualFrame frame, out float[] spectrum)
        {
            frame = default;
            spectrum = null;

            int slot = Interlocked.Exchange(ref _latestSlot, -1);
            if (slot < 0) return false;

            if (Interlocked.CompareExchange(ref _flags[slot], 2, 1) != 1)
                return false;

            frame = _frames[slot];
            spectrum = _spectra[slot];

            Interlocked.Exchange(ref _flags[slot], 3);
            return true;
        }
    }
}
