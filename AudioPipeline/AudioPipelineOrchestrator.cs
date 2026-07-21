using System;
using System.Runtime.InteropServices;
using StageSimWASAPI.DSP;

namespace StageSimWASAPI
{
    // Flat struct that maps directly to the Python RDMA SignalBus / UBO layout.
    // Python reads this via pythonnet — no audio processing in Python at all.
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct AudioFrame
    {
        // 8 band levels (sub, bass, low_mid, mid, high_mid, presence, brilliance, air)
        public float Band0; public float Band1; public float Band2; public float Band3;
        public float Band4; public float Band5; public float Band6; public float Band7;

        // Beat / transient / envelope
        public float BeatIntensity;
        public float Transient;
        public float Envelope;
        public float Overall;

        // Tempo
        public float BPM;
        public float TempoConfidence;

        // Kick
        public float KickLevel;
        public float KickConfidence;

        // Stereo
        public float StereoBalance;
        public float StereoWidth;
        public float LeftEnergy;
        public float RightEnergy;

        // Brain state — intensities
        public float EffectIntensity;
        public float MovementIntensity;
        public float DimmerIntensity;
        public float LaserIntensity;
        public float BlinderIntensity;
        public float MovingLightIntensity;
        public float StaticLightIntensity;

        // Brain state — fixture on/off
        public int MovingLightsOn;
        public int LasersOn;
        public int StaticLightsOn;
        public int BlindersOn;
        public int StrobeOn;

        // Brain state — color/hue
        public float BaseHue;
        public float SectionHueCenter;
        public float SectionHueRange;

        // Brain state — triggers
        public int TriggerFlash;
        public int TriggerStrobe;
        public int TriggerSmoke;
        public int TriggerPyro;
        public int TriggerRandomFlash;
        public float RandomFlashIntensity;

        // Brain state — group behavior
        public int GroupBehaviorMode;
        public float GroupBehaviorPhase;
        public int DesiredEffectMode;
        public int ShouldChangeEffectMode;

        // Brain state — beat/phrase
        public int BeatCount;
        public int PhraseBeat;
        public float SectionConfidence;

        // Colors (normalized 0-1)
        public float ColorR; public float ColorG; public float ColorB;
        public float Color2R; public float Color2G; public float Color2B;
        public float Color3R; public float Color3G; public float Color3B;

        // Triggers (0 or 1)
        public int BeatDetected;
        public int Section;

        // Status
        public int IsSilent;
        public int DominantBand;

        // Spectrum data (first 512 bins — enough for visualizer)
        // Python reads this separately via GetSpectrum()
    }

    // Main orchestrator — audio pipeline with triple-buffered FFT and quad-buffered visuals.
    // Flow: WASAPI capture → circular buffer → triple-buffered FFT → brain → quad-buffered visuals → RDMA transport
    // The brain controls visuals/timing from the 8 frequency bands.
    public class AudioPipelineOrchestrator : IDisposable
    {
        private WASAPICapture _capture;
        private CircularAudioBuffer _circularBuffer;
        private AudioAnalyzer _analyzer;
        private LightingBrain _brain;
        private DspPipeline _dspPipeline;

        // Triple-buffered FFT — WASAPI thread writes, brain thread reads, slots recycled immediately
        private TripleBufferedFFT _tripleFFT;

        // Quad-buffered visuals — brain writes, renderer reads, slots recycled after GPU consumption
        private QuadBufferedVisuals _quadVisuals;

        // RDMA shared memory transport — zero-copy local frame delivery to renderer
        private RDMASharedTransport _rdma;
        private bool _rdmaEnabled = false;

        private float[] _fftBuffer;
        private float[] _fftOutput;
        private float[] _monoBuffer;
        private float[] _conversionBuffer;
        private float[] _lastSpectrum;
        private float[] _rdmaSpectrum;  // spectrum buffer for RDMA publish

        private int _fftSize;
        private int _channels;
        private int _sampleRate;
        private float _stereoBalance = 0f;
        private float _stereoWidth = 0f;
        private float _leftEnergy = 0f;
        private float _rightEnergy = 0f;
        private float _phaseCorrelation = 0.5f;  // 0.5 = uncorrelated (center)
        private float _time = 0f;
        private float _lastDataTime = 0f;
        private bool _running = false;
        private bool _disposed = false;

        // Latency tracking — fine-grained per-substage timing with smoothed averages
        private static readonly System.Diagnostics.Stopwatch _pipeTimer = System.Diagnostics.Stopwatch.StartNew();
        private const float LAT_SMOOTH = 0.15f;  // smoothing factor for running average

        // Timestamps (ticks) at each pipeline stage
        private long _tsCaptureWrite;       // WASAPI wrote to circular buffer
        private long _tsCircularRead;       // audio thread read from circular buffer
        private long _tsFFTCompute;         // FFT computation done
        private long _tsFFTPublish;         // FFT published to triple buffer
        private long _tsFFTConsume;         // visual thread consumed from triple buffer
        private long _tsBrainProcess;       // analyzer.Process() done
        private long _tsBrainUpdate;        // brain.Update() done
        private long _tsFramePublish;       // visual frame published to quad buffer

        // Smoothed latency results (ms) — running average for stable HUD display
        private float _latBufferDwellMs;    // time spent waiting in circular buffer
        private float _latDeinterleaveMs;   // de-interleave + stereo analysis
        private float _latFFTComputeMs;     // FFT computation
        private float _latTripleDwellMs;    // time spent waiting in triple buffer
        private float _latBrainProcessMs;   // analyzer.Process (bands, envelope, beats)
        private float _latBrainUpdateMs;    // brain.Update (intensities, sections, triggers)
        private float _latFrameBuildMs;     // building + publishing visual frame
        private float _latTotalPipelineMs;  // full: capture → frame publish

        // Split system: audio compute thread + visual generation thread
        private Thread _audioThread;    // WASAPI → circular buffer → FFT → triple buffer
        private Thread _visualThread;   // triple buffer consume → brain → quad buffer + RDMA
        private readonly object _threadLock = new object();
        private readonly ManualResetEventSlim _captureSignal = new ManualResetEventSlim(false, 0);

        // Audio thread buffers (only touched by audio thread) — pinned for direct memory access
        private float[] _audioFftBuffer;
        private float[] _audioFftOutput;
        private float[] _audioMonoBuffer;
        private float[] _audioLeftBuffer;
        private float[] _audioRightBuffer;
        private float[] _audioLeftOutput;
        private float[] _audioRightOutput;
        private GCHandle _pinAudioFft, _pinAudioOut, _pinAudioMono;

        // Visual thread buffers (only touched by visual thread) — pinned
        private float[] _visualFftBuffer;
        private float[] _visualSpectrum;
        private GCHandle _pinVisualFft, _pinVisualSpec;

        // Lock-free double buffer for AudioFrame (legacy compat for pythonnet callers)
        private AudioFrame _frameWrite;
        private AudioFrame _frameRead;
        private object _frameLock = new object();

        // Visual frame dimensions (set by renderer via RDMA)
        private float _renderWidth = 1280f;
        private float _renderHeight = 720f;

        public int SampleRate => _sampleRate;
        public int Channels => _channels;
        public int FFTSize => _fftSize;
        public bool IsRunning => _running;
        public bool RDMAEnabled => _rdmaEnabled;
        public AudioAnalyzer Analyzer => _analyzer;

        // Stereo spectrum — L/R FFT for 3D mirror mode
        private readonly object _stereoLock = new object();
        private float[] _latestLeftSpectrum = new float[1024];
        private float[] _latestRightSpectrum = new float[1024];
        public float[] GetLeftSpectrum() { lock (_stereoLock) return (float[])_latestLeftSpectrum.Clone(); }
        public float[] GetRightSpectrum() { lock (_stereoLock) return (float[])_latestRightSpectrum.Clone(); }

        // Per-band compressor state — 8 bands, envelope followers
        private float[] _bandEnv = new float[8];
        private float _lastCompTime;
        private readonly object _compLock = new object();

        // Per-song visual profile — adapts to each song, resets on silence
        public VisualProfile VisualProfile { get; } = new VisualProfile();

        // Apply log10 + BandBoosts + per-band compressor to raw FFT output for display
        private void ProcessSpectrumForDisplay(float[] spectrum, int n)
        {
            if (_analyzer == null) return;
            float nyquist = _sampleRate / 2f;
            float hzPerBin = nyquist / n;
            var boosts = _analyzer.BandBoosts;
            var thresholds = _analyzer.BandCompThreshold;
            var ratios = _analyzer.BandCompRatio;
            var attacks = _analyzer.BandCompAttack;
            var releases = _analyzer.BandCompRelease;

            // Time delta for compressor envelopes
            double now = System.Diagnostics.Stopwatch.GetTimestamp() / (double)System.Diagnostics.Stopwatch.Frequency;
            float dt = _lastCompTime > 0 ? (float)(now - _lastCompTime) : 0.016f;
            _lastCompTime = (float)now;
            dt = Math.Min(dt, 0.05f);

            // Per-band peak detection + compression
            float[] bandPeak = new float[8];
            int[] bandCount = new int[8];

            // First pass: log10 + boost, find band peaks
            for (int i = 0; i < n; i++)
            {
                float raw = spectrum[i] * _analyzer.InputGain;
                float logVal = (float)Math.Log10(raw + 1.0);
                float freq = i * hzPerBin;
                float gain = 1.0f;
                int bandIdx = 7;
                for (int b = 0; b < AudioAnalyzer.BandStartHz.Length - 1; b++)
                {
                    if (freq >= AudioAnalyzer.BandStartHz[b] && freq < AudioAnalyzer.BandStartHz[b + 1])
                    {
                        float t = (freq - AudioAnalyzer.BandStartHz[b]) / (AudioAnalyzer.BandStartHz[b + 1] - AudioAnalyzer.BandStartHz[b]);
                        gain = 1.0f + Mathf.Lerp(boosts[b], boosts[b + 1], t);
                        bandIdx = b;
                        break;
                    }
                }
                if (freq >= AudioAnalyzer.BandStartHz[AudioAnalyzer.BandStartHz.Length - 1])
                    gain = 1.0f + boosts[boosts.Length - 1];

                float boosted = logVal * gain;
                spectrum[i] = boosted;

                // Track peak per band
                if (boosted > bandPeak[bandIdx]) bandPeak[bandIdx] = boosted;
                bandCount[bandIdx]++;
            }

            // Second pass: per-band compression
            lock (_compLock)
            {
                for (int b = 0; b < 8; b++)
                {
                    if (bandCount[b] == 0) continue;
                    float peak = bandPeak[b];

                    // Envelope follower — fast attack, fast release
                    float attackCoeff = 1.0f - Mathf.Exp(-dt / (attacks[b] * 0.001f));
                    float releaseCoeff = 1.0f - Mathf.Exp(-dt / (releases[b] * 0.001f));

                    if (peak > _bandEnv[b])
                        _bandEnv[b] = Mathf.Lerp(_bandEnv[b], peak, attackCoeff);
                    else
                        _bandEnv[b] = Mathf.Lerp(_bandEnv[b], peak, releaseCoeff);

                    // Compression: if envelope above threshold, reduce gain
                    float threshold = thresholds[b];
                    float ratio = ratios[b];
                    float compGain = 1.0f;
                    if (_bandEnv[b] > threshold)
                    {
                        float overDb = _bandEnv[b] - threshold;
                        float reducedDb = overDb / ratio;
                        compGain = threshold + reducedDb;
                        compGain = compGain / _bandEnv[b];
                    }

                    // Apply compressed gain to all bins in this band
                    int bandStart = (int)(AudioAnalyzer.BandStartHz[b] / hzPerBin);
                    int bandEnd = (b < 7) ? (int)(AudioAnalyzer.BandStartHz[b + 1] / hzPerBin) : n;
                    bandStart = Math.Max(0, bandStart);
                    bandEnd = Math.Min(n, bandEnd);
                    for (int i = bandStart; i < bandEnd; i++)
                    {
                        spectrum[i] *= compGain;
                    }
                }
            }
        }

        // Access to quad buffer for direct C# renderers (bypasses RDMA)
        public QuadBufferedVisuals Visuals => _quadVisuals;

        public AudioPipelineOrchestrator(int fftSize = 1024)
        {
            _fftSize = fftSize;
            // Legacy buffers (still used by OnCaptureData conversion)
            _conversionBuffer = new float[8192];
            _lastSpectrum = new float[fftSize];
            _rdmaSpectrum = new float[fftSize];

            // Audio thread buffers — pinned for direct memory access
            _audioFftBuffer = new float[fftSize];
            _audioFftOutput = new float[fftSize];
            _audioMonoBuffer = new float[fftSize / 2];
            _audioLeftBuffer = new float[fftSize];
            _audioRightBuffer = new float[fftSize];
            _audioLeftOutput = new float[fftSize];
            _audioRightOutput = new float[fftSize];
            _pinAudioFft = GCHandle.Alloc(_audioFftBuffer, GCHandleType.Pinned);
            _pinAudioOut = GCHandle.Alloc(_audioFftOutput, GCHandleType.Pinned);
            _pinAudioMono = GCHandle.Alloc(_audioMonoBuffer, GCHandleType.Pinned);

            // Visual thread buffers — pinned
            _visualFftBuffer = new float[fftSize];
            _visualSpectrum = new float[fftSize];
            _pinVisualFft = GCHandle.Alloc(_visualFftBuffer, GCHandleType.Pinned);
            _pinVisualSpec = GCHandle.Alloc(_visualSpectrum, GCHandleType.Pinned);
            _fftBuffer = _visualFftBuffer; // legacy compat
            _fftOutput = _visualFftBuffer;
            _monoBuffer = _audioMonoBuffer;

            // Triple-buffered FFT — audio thread writes, visual thread reads, slots recycled immediately
            _tripleFFT = new TripleBufferedFFT(fftSize);

            // Quad-buffered visuals — visual thread writes, renderer reads, slots recycled after GPU
            _quadVisuals = new QuadBufferedVisuals(fftSize);
        }

        /// <summary>
        /// Enable RDMA shared memory transport for zero-copy frame delivery to renderer.
        /// Renderer reads directly from shared memory — no kernel transitions, no sync issues.
        /// </summary>
        public void EnableRDMA(string mapName = RDMASharedTransport.DefaultMapName)
        {
            _rdma = new RDMASharedTransport(mapName, _fftSize, writer: true);
            _rdmaEnabled = true;
            Console.WriteLine($"[AudioPipeline] RDMA transport enabled: {mapName}");
        }

        /// <summary>
        /// Set render dimensions (called by renderer so brain knows output resolution).
        /// </summary>
        public void SetRenderSize(int width, int height)
        {
            _renderWidth = width;
            _renderHeight = height;
        }

        public bool Start()
        {
            try
            {
                _capture = new WASAPICapture();
                _capture.DataAvailable += OnCaptureData;
                _capture.Start();

                _channels = Math.Min(_capture.Channels, 2);
                if (_channels < 1) _channels = 2;
                _sampleRate = _capture.SampleRate;
                if (_sampleRate <= 0) _sampleRate = 44100;

                int bufferSamples = _sampleRate; // 1 second — enough for thread scheduling jitter
                _circularBuffer = new CircularAudioBuffer(bufferSamples * _channels);

                _analyzer = new AudioAnalyzer(_fftSize, _sampleRate);
                _brain = new LightingBrain();
                _dspPipeline = new DspPipeline();
                _dspPipeline.Prepare(_sampleRate, _fftSize);

                _running = true;
                Console.WriteLine($"[AudioPipeline] Started: {_channels}ch, {_sampleRate}Hz, {_capture.BitsPerSample}bit");

                // Launch split system — audio compute + visual generation on separate threads
                StartSplitThreads();

                return true;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[AudioPipeline] Start failed: {ex.Message}");
                _running = false;
                return false;
            }
        }

        private void OnCaptureData(byte[] buffer, int length)
        {
            if (_circularBuffer == null || _capture == null) return;

            try
            {
                int bytesPerSample = _capture.BitsPerSample / 8;
                int sourceChannels = _capture.Channels;
                int channels = sourceChannels > 2 ? 2 : sourceChannels;

                int sampleFrames = length / (bytesPerSample * sourceChannels);
                int needed = sampleFrames * channels;

                if (needed > _conversionBuffer.Length)
                    _conversionBuffer = new float[needed];

                for (int i = 0; i < sampleFrames; i++)
                {
                    for (int c = 0; c < channels; c++)
                    {
                        int byteOffset = i * sourceChannels * bytesPerSample + c * bytesPerSample;
                        if (byteOffset + bytesPerSample > length) break;

                        if (bytesPerSample == 4)
                        {
                            float sample = BitConverter.ToSingle(buffer, byteOffset);
                            _conversionBuffer[i * channels + c] = Math.Clamp(sample, -1f, 1f);
                        }
                        else if (bytesPerSample == 2)
                        {
                            short s = BitConverter.ToInt16(buffer, byteOffset);
                            _conversionBuffer[i * channels + c] = s / 32768f;
                        }
                    }
                }

                _circularBuffer.Write(_conversionBuffer, 0, needed);
                _tsCaptureWrite = _pipeTimer.ElapsedTicks;
                _lastDataTime = _time;
                _captureSignal.Set();  // wake audio thread immediately
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[AudioPipeline] Capture error: {ex.Message}");
            }
        }

        // ═══════════════════════════════════════════════════════════════════
        // SPLIT SYSTEM — two threads, zero contention, respects signal integrity
        //
        // Audio Thread (CPU): WASAPI → circular buffer → FFT → triple buffer publish
        //   Pure signal processing, near-zero latency, no visual work.
        //
        // Visual Thread (CPU): triple buffer consume → brain → quad buffer + RDMA
        //   Brain computes from 8 bands. Maps fixture concepts to visualizer concepts.
        //   GPU only reads finished frames — never blocks audio.
        // ═══════════════════════════════════════════════════════════════════

        private void StartSplitThreads()
        {
            // High priority for both threads to minimize scheduling jitter
            _audioThread = new Thread(AudioComputeLoop) { IsBackground = true, Name = "AudioCompute", Priority = ThreadPriority.Highest };
            _visualThread = new Thread(VisualGenerateLoop) { IsBackground = true, Name = "VisualGenerate", Priority = ThreadPriority.AboveNormal };
            _audioThread.Start();
            _visualThread.Start();
            Console.WriteLine("[AudioPipeline] Split system running: AudioCompute + VisualGenerate threads");
        }

        private void AudioComputeLoop()
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            double lastTime = sw.Elapsed.TotalSeconds;

            while (_running)
            {
                // Wait for WASAPI capture callback to signal new data — zero polling
                _captureSignal.Wait(50);  // 50ms safety timeout
                _captureSignal.Reset();
                if (!_running) break;

                double now = sw.Elapsed.TotalSeconds;
                float dt = (float)(now - lastTime);
                lastTime = now;

                try
                {
                    _tsCircularRead = _pipeTimer.ElapsedTicks;
                    int available = _circularBuffer.ReadLatest(_audioFftBuffer, 0, _fftSize);
                    if (available < _fftSize) { Thread.Sleep(1); continue; }

                    // De-interleave + mono + stereo
                    float leftSum = 0f, rightSum = 0f;
                    float crossSum = 0f;  // L*R for phase correlation
                    int monoCount = 0;

                    if (_channels == 2)
                    {
                        int monoSize = _fftSize / 2;
                        for (int i = 0; i < monoSize && (i * 2 + 1) < _fftSize; i++)
                        {
                            float l = _audioFftBuffer[i * 2];
                            float r = _audioFftBuffer[i * 2 + 1];
                            _audioMonoBuffer[i] = (l + r) * 0.5f;
                            _audioLeftBuffer[i] = l;
                            _audioRightBuffer[i] = r;
                            leftSum += l * l; rightSum += r * r; crossSum += l * r; monoCount++;
                        }
                        _leftEnergy = Mathf.Clamp01((float)Math.Sqrt(leftSum / Math.Max(1, monoCount)) * 3.0f);
                        _rightEnergy = Mathf.Clamp01((float)Math.Sqrt(rightSum / Math.Max(1, monoCount)) * 3.0f);

                        // Phase correlation: normalized cross-correlation at zero lag
                        // +1 = mono/in-phase, 0 = uncorrelated, -1 = out-of-phase
                        float denom = (float)Math.Sqrt(leftSum * rightSum);
                        float rawCorr = denom > 0.001f ? crossSum / denom : 0f;
                        rawCorr = Mathf.Clamp(rawCorr, -1f, 1f);
                        // Remap -1..1 to 0..1 for shader use
                        float corrNorm = rawCorr * 0.5f + 0.5f;
                        _phaseCorrelation = Mathf.Lerp(_phaseCorrelation, corrNorm, 1f - Mathf.Exp(-dt * 10f));

                        float totalEnergy = _leftEnergy + _rightEnergy;
                        if (totalEnergy > 0.001f)
                        {
                            float rawBalance = (_rightEnergy - _leftEnergy) / totalEnergy;
                            _stereoBalance = Mathf.Lerp(_stereoBalance, Mathf.Clamp(rawBalance * 20.0f, -1f, 1f), 1f - Mathf.Exp(-dt * 15f));
                            float rawWidth = Mathf.Clamp01(Math.Abs(_rightEnergy - _leftEnergy) / totalEnergy * 20.0f);
                            _stereoWidth = Mathf.Lerp(_stereoWidth, rawWidth, 1f - Mathf.Exp(-dt * 10f));
                        }
                        Array.Copy(_audioMonoBuffer, _audioFftBuffer, monoSize);
                        for (int i = monoSize; i < _fftSize; i++) _audioFftBuffer[i] = 0f;
                    }

                    long tsAfterDeint = _pipeTimer.ElapsedTicks;

                    // Resonance DSP pipeline — LUFS, THD, phase correlation, level metering
                    if (_dspPipeline != null && _channels == 2)
                    {
                        int monoSize = _fftSize / 2;
                        _dspPipeline.ProcessStereo(
                            _audioLeftBuffer.AsSpan(0, monoSize),
                            _audioRightBuffer.AsSpan(0, monoSize));
                    }

                    // FFT → triple buffer
                    FFTProvider.ComputeMagnitudeSpectrum(_audioFftBuffer, _audioFftOutput, _fftSize);

                    // Stereo FFT — separate L and R for 3D mirror mode
                    if (_channels == 2)
                    {
                        int monoSize = _fftSize / 2;
                        for (int i = monoSize; i < _fftSize; i++) { _audioLeftBuffer[i] = 0f; _audioRightBuffer[i] = 0f; }
                        FFTProvider.ComputeMagnitudeSpectrum(_audioLeftBuffer, _audioLeftOutput, _fftSize);
                        FFTProvider.ComputeMagnitudeSpectrum(_audioRightBuffer, _audioRightOutput, _fftSize);
                        // Apply same log10 + BandBoosts processing as mono
                        ProcessSpectrumForDisplay(_audioLeftOutput, _fftSize / 2);
                        ProcessSpectrumForDisplay(_audioRightOutput, _fftSize / 2);
                        lock (_stereoLock)
                        {
                            Array.Copy(_audioLeftOutput, _latestLeftSpectrum, Math.Min(_fftSize / 2, 1024));
                            Array.Copy(_audioRightOutput, _latestRightSpectrum, Math.Min(_fftSize / 2, 1024));
                        }
                    }

                    _tsFFTCompute = _pipeTimer.ElapsedTicks;
                    _tripleFFT.Publish(_audioFftOutput, _fftSize);
                    _tsFFTPublish = _pipeTimer.ElapsedTicks;

                    // Substage latencies (smoothed)
                    float msPerTick = 1000f / System.Diagnostics.Stopwatch.Frequency;
                    _latBufferDwellMs = Mathf.Lerp(_latBufferDwellMs, (_tsCircularRead - _tsCaptureWrite) * msPerTick, LAT_SMOOTH);
                    _latDeinterleaveMs = Mathf.Lerp(_latDeinterleaveMs, (tsAfterDeint - _tsCircularRead) * msPerTick, LAT_SMOOTH);
                    _latFFTComputeMs = Mathf.Lerp(_latFFTComputeMs, (_tsFFTCompute - tsAfterDeint) * msPerTick, LAT_SMOOTH);

                    _lastDataTime = _time;
                }
                catch (Exception ex) { Console.WriteLine($"[AudioCompute] Error: {ex.Message}"); }
            }
        }

        private void VisualGenerateLoop()
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            double lastTime = sw.Elapsed.TotalSeconds;

            while (_running)
            {
                // Wait for audio thread to signal new FFT data — zero polling, zero dwell
                bool signaled = _tripleFFT.WaitForData(50);  // 50ms timeout as safety net
                if (!_running) break;

                double now = sw.Elapsed.TotalSeconds;
                float dt = (float)(now - lastTime);
                lastTime = now;
                _time += dt;
                Time.deltaTime = dt;

                try
                {
                    _tsFFTConsume = _pipeTimer.ElapsedTicks;
                    bool hasNewFFT = _tripleFFT.Consume(_visualFftBuffer, _fftSize);
                    bool hasData = (_time - _lastDataTime) < 0.5f;

                    if (!hasData)
                    {
                        _analyzer?.Reset();
                        WASAPIPlugin.Instance.StereoBalance = 0f;
                        WASAPIPlugin.Instance.StereoWidth = 0f;
                        WASAPIPlugin.Instance.PhaseCorrelation = 0.5f;
                        _tsBrainProcess = _pipeTimer.ElapsedTicks;
                        _brain?.Update(_analyzer, dt);
                        _tsBrainUpdate = _pipeTimer.ElapsedTicks;
                        PublishVisualFrame(false, false);
                    }
                    else if (!hasNewFFT)
                    {
                        WASAPIPlugin.Instance.StereoBalance = _stereoBalance;
                        WASAPIPlugin.Instance.StereoWidth = _stereoWidth;
                        WASAPIPlugin.Instance.PhaseCorrelation = _phaseCorrelation;
                        _tsBrainProcess = _pipeTimer.ElapsedTicks;
                        _brain.Update(_analyzer, dt);
                        _tsBrainUpdate = _pipeTimer.ElapsedTicks;
                        PublishVisualFrame(false, false);
                    }
                    else
                    {
                        if (_analyzer != null)
                        {
                            _analyzer.ForceSilent = (_leftEnergy < 0.008f && _rightEnergy < 0.008f);
                            _analyzer.Process(_visualFftBuffer, _fftSize / 2);
                        }
                        _tsBrainProcess = _pipeTimer.ElapsedTicks;
                        bool beat = _analyzer != null && _analyzer.BeatJustDetected;
                        if (beat) _brain.OnBeat(_analyzer);
                        WASAPIPlugin.Instance.StereoBalance = _stereoBalance;
                        WASAPIPlugin.Instance.StereoWidth = _stereoWidth;
                        WASAPIPlugin.Instance.PhaseCorrelation = _phaseCorrelation;
                        _brain.Update(_analyzer, dt);
                        _tsBrainUpdate = _pipeTimer.ElapsedTicks;

                        // Update per-song visual profile
                        float bassLevel = _analyzer?.GetSubLevel() ?? 0;
                        float trebleLevel = _analyzer?.GetTrebleLevel() ?? 0;
                        float totalLevel = _analyzer?.GetOverallNormalized() ?? 0;
                        VisualProfile.Update(
                            _analyzer?.GetEnvelopeNormalized() ?? 0,
                            _analyzer?.BPM ?? 120,
                            _brain?.SpectralClarity ?? 0.5f,
                            _stereoWidth,
                            bassLevel, trebleLevel, totalLevel,
                            (int)(_brain?.CurrentSection ?? LightingBrain.Section.Unknown),
                            dt, _analyzer?.IsSilent ?? true);

                        PublishVisualFrame(true, beat);
                    }

                    // Substage latencies (smoothed)
                    float msPerTick = 1000f / System.Diagnostics.Stopwatch.Frequency;
                    _latTripleDwellMs = Mathf.Lerp(_latTripleDwellMs, (_tsFFTConsume - _tsFFTPublish) * msPerTick, LAT_SMOOTH);
                    _latBrainProcessMs = Mathf.Lerp(_latBrainProcessMs, (_tsBrainProcess - _tsFFTConsume) * msPerTick, LAT_SMOOTH);
                    _latBrainUpdateMs = Mathf.Lerp(_latBrainUpdateMs, (_tsBrainUpdate - _tsBrainProcess) * msPerTick, LAT_SMOOTH);
                    _latFrameBuildMs = Mathf.Lerp(_latFrameBuildMs, (_tsFramePublish - _tsBrainUpdate) * msPerTick, LAT_SMOOTH);
                    _latTotalPipelineMs = Mathf.Lerp(_latTotalPipelineMs, (_tsFramePublish - _tsCaptureWrite) * msPerTick, LAT_SMOOTH);
                }
                catch (Exception ex) { Console.WriteLine($"[VisualGenerate] Error: {ex.Message}"); }
            }
        }

        /// <summary>
        /// Build and publish visual frame to quad buffer + RDMA.
        /// Maps brain fixture concepts → visualizer concepts (no smoke, no stage fixtures).
        /// </summary>
        private void PublishVisualFrame(bool hasData, bool beat)
        {
            var frame = new AudioFrame
            {
                Band0 = _analyzer?.GetSubLevel() ?? 0,
                Band1 = _analyzer?.GetBassLevel() ?? 0,
                Band2 = _analyzer?.GetLowMidLevel() ?? 0,
                Band3 = _analyzer?.GetMidLevel() ?? 0,
                Band4 = _analyzer?.GetHighMidLevel() ?? 0,
                Band5 = _analyzer?.GetBandLevelNormalized(5) ?? 0,
                Band6 = _analyzer?.GetTrebleLevel() ?? 0,
                Band7 = _analyzer?.GetBandLevelNormalized(7) ?? 0,
                BeatIntensity = _analyzer?.BeatIntensity ?? 0,
                Transient = _analyzer?.Transient ?? 0,
                Envelope = _analyzer?.GetEnvelopeNormalized() ?? 0,
                Overall = _analyzer?.GetOverallNormalized() ?? 0,
                BPM = _analyzer?.BPM ?? 0,
                TempoConfidence = _analyzer?.TempoConfidence ?? 0,
                KickLevel = _analyzer?.KickLevel ?? 0,
                KickConfidence = _analyzer?.KickConfidence ?? 0,
                StereoBalance = _stereoBalance,
                StereoWidth = _stereoWidth,
                LeftEnergy = _leftEnergy,
                RightEnergy = _rightEnergy,
                BeatDetected = beat ? 1 : 0,
                Section = (int)(_brain?.CurrentSection ?? LightingBrain.Section.Unknown),
                IsSilent = (_analyzer?.IsSilent ?? true) ? 1 : 0,
                DominantBand = _analyzer?.DominantBand ?? 0,
            };

            if (_brain != null)
            {
                frame.EffectIntensity = _brain.EffectIntensity;
                frame.MovementIntensity = _brain.MovementIntensity;
                frame.BaseHue = _brain.BaseHue;
                frame.SectionHueCenter = _brain.SectionHueCenter;
                frame.SectionHueRange = _brain.SectionHueRange;
                frame.BeatCount = _brain.BeatCount;
                frame.PhraseBeat = _brain.PhraseBeat;
                frame.SectionConfidence = _brain.SectionConfidence;
                var c = _brain.CurrentColor;
                frame.ColorR = c.r / 255f; frame.ColorG = c.g / 255f; frame.ColorB = c.b / 255f;
                var c2 = _brain.SecondaryColor;
                frame.Color2R = c2.r / 255f; frame.Color2G = c2.g / 255f; frame.Color2B = c2.b / 255f;
                var c3 = _brain.TertiaryColor;
                frame.Color3R = c3.r / 255f; frame.Color3G = c3.g / 255f; frame.Color3B = c3.b / 255f;
            }

            _frameWrite = frame;
            lock (_frameLock) { _frameRead = _frameWrite; }

            // Build visual frame — map brain fixture concepts to visualizer concepts
            var vf = new QuadBufferedVisuals.VisualFrame
            {
                Time = _time,
                Width = _renderWidth,
                Height = _renderHeight,
                Aspect = _renderWidth / _renderHeight,
                Band0 = frame.Band0, Band1 = frame.Band1, Band2 = frame.Band2, Band3 = frame.Band3,
                Band4 = frame.Band4, Band5 = frame.Band5, Band6 = frame.Band6, Band7 = frame.Band7,
                BeatIntensity = frame.BeatIntensity, BeatDetected = frame.BeatDetected,
                Transient = frame.Transient, Envelope = frame.Envelope, Overall = frame.Overall,
                BPM = frame.BPM, TempoConfidence = frame.TempoConfidence,
                KickLevel = frame.KickLevel, KickConfidence = frame.KickConfidence,
                StereoBalance = frame.StereoBalance, StereoWidth = frame.StereoWidth,
                LeftEnergy = frame.LeftEnergy, RightEnergy = frame.RightEnergy,
                EffectIntensity = frame.EffectIntensity,
                MovementIntensity = frame.MovementIntensity,
                // Map fixture intensities → visualizer intensities
                Brightness = _brain?.DimmerIntensity ?? 0,
                BeamIntensity = _brain?.LaserIntensity ?? 0,
                BloomIntensity = _brain?.BlinderIntensity ?? 0,
                DynamicLightIntensity = _brain?.MovingLightIntensity ?? 0,
                AmbientLightIntensity = _brain?.StaticLightIntensity ?? 0,
                // Map fixture on/off → visualizer active flags
                DynamicLightsActive = (_brain?.MovingLightsOn ?? false) ? 1 : 0,
                BeamsActive = (_brain?.LasersOn ?? false) ? 1 : 0,
                AmbientActive = (_brain?.StaticLightsOn ?? false) ? 1 : 0,
                BloomActive = (_brain?.BlindersOn ?? false) ? 1 : 0,
                // Visualizer-native triggers
                TriggerEffectBurst = (_brain?.TriggerEffectBurst ?? false) ? 1 : 0,
                EffectBurstType = _brain?.EffectBurstType ?? 0,
                EffectBurstIntensity = _brain?.EffectBurstIntensity ?? 0f,
                AtmosphereDensity = _brain?.AtmosphereDensity ?? 0f,
                ColorPulse = _brain?.ColorPulse ?? 0f,
                ShouldChangeEffectMode = (_brain?.ShouldChangeEffectMode ?? false) ? 1 : 0,
                BaseHue = frame.BaseHue, SectionHueCenter = frame.SectionHueCenter,
                SectionHueRange = frame.SectionHueRange,
                ColorR = frame.ColorR, ColorG = frame.ColorG, ColorB = frame.ColorB,
                Color2R = frame.Color2R, Color2G = frame.Color2G, Color2B = frame.Color2B,
                Color3R = frame.Color3R, Color3G = frame.Color3G, Color3B = frame.Color3B,
                BeatCount = frame.BeatCount, PhraseBeat = frame.PhraseBeat,
                SectionConfidence = frame.SectionConfidence, Section = frame.Section,
                IsSilent = frame.IsSilent, DominantBand = frame.DominantBand,
                GroupBehaviorMode = _brain?.GroupBehaviorMode ?? 0,
                GroupBehaviorPhase = _brain?.GroupBehaviorPhase ?? 0,
                DesiredEffectMode = _brain?.DesiredEffectMode ?? 0,
                PhaseCorrelation = _brain?.PhaseCorrelation ?? 0.5f,
                BeatAnticipation = _brain?.BeatAnticipation ?? 0f,
                SpectralClarity = _brain?.SpectralClarity ?? 0f,
                MotionPersistence = _brain?.MotionPersistence ?? 0f,
                SpectralCentroid = _analyzer?.SpectralCentroid ?? 0f,

                // Per-song visual profile
                ProfileEnergy = VisualProfile.EnergyLevel,
                ProfileBass = VisualProfile.BassHeaviness,
                ProfileTreble = VisualProfile.TrebleBrightness,
                ProfileTempo = VisualProfile.TempoFast,
                ProfilePunch = VisualProfile.TonalPunch,
                ProfileStereo = VisualProfile.StereoSpread,
                ProfileDynamic = VisualProfile.DynamicVariation,
                ProfileGlow = VisualProfile.GlowIntensity,
                ProfileBarScale = VisualProfile.BarHeightScale,
                ProfileMotionSpeed = VisualProfile.MotionSpeed,
                ProfileSaturation = VisualProfile.ColorSaturation,
                ProfilePerspective = VisualProfile.PerspectiveDepth,
                ProfileDominantSection = VisualProfile.DominantSection,
                ProfileDuration = VisualProfile.SongDuration,
                SpectralSpread = _analyzer?.SpectralSpread ?? 0f,
                DominantFrequency = _analyzer?.DominantFrequency ?? 0f,
                LatBufferDwellMs = _latBufferDwellMs,
                LatDeinterleaveMs = _latDeinterleaveMs,
                LatFFTComputeMs = _latFFTComputeMs,
                LatTripleDwellMs = _latTripleDwellMs,
                LatBrainProcessMs = _latBrainProcessMs,
                LatBrainUpdateMs = _latBrainUpdateMs,
                LatFrameBuildMs = _latFrameBuildMs,
                LatTotalPipelineMs = _latTotalPipelineMs,
            };

            // Resonance DSP metrics
            if (_dspPipeline != null)
            {
                vf.MomentaryLUFS = _dspPipeline.MomentaryLUFS;
                vf.ShortTermLUFS = _dspPipeline.ShortTermLUFS;
                vf.IntegratedLUFS = _dspPipeline.IntegratedLUFS;
                vf.THDPercentage = _dspPipeline.THDPercentage;
                vf.PhaseCorrelationDSP = _dspPipeline.PhaseCorrelation;
                vf.PeakDbL = _dspPipeline.PeakDbL;
                vf.PeakDbR = _dspPipeline.PeakDbR;
                vf.RmsDbL = _dspPipeline.RmsDbL;
                vf.RmsDbR = _dspPipeline.RmsDbR;
                vf.CrestFactorDbL = _dspPipeline.CrestFactorDbL;
                vf.CrestFactorDbR = _dspPipeline.CrestFactorDbR;
                vf.DspBand0 = _dspPipeline.BandLevels[0];
                vf.DspBand1 = _dspPipeline.BandLevels[1];
                vf.DspBand2 = _dspPipeline.BandLevels[2];
                vf.DspBand3 = _dspPipeline.BandLevels[3];
                vf.DspBand4 = _dspPipeline.BandLevels[4];
                vf.DspBand5 = _dspPipeline.BandLevels[5];
                vf.DspBand6 = _dspPipeline.BandLevels[6];
                vf.DspBand7 = _dspPipeline.BandLevels[7];
            }

            var spectrum = GetSpectrum();
            Array.Copy(spectrum, _rdmaSpectrum, Math.Min(spectrum.Length, _rdmaSpectrum.Length));
            _quadVisuals.Publish(ref vf, _rdmaSpectrum, _rdmaSpectrum.Length);

            // Latency: timestamp frame publish for total pipeline measurement
            _tsFramePublish = _pipeTimer.ElapsedTicks;

            if (_rdmaEnabled && _rdma != null)
                _rdma.PublishFrame(ref vf, _rdmaSpectrum);
        }

        // Legacy: returns latest frame. With split system, threads do all work.
        public AudioFrame Process(float dt)
        {
            if (!_running) return default;
            _time += dt;
            Time.deltaTime = dt;
            lock (_frameLock) return _frameRead;
        }

        // Python calls this to get the spectrum array (float[])
        public float[] GetSpectrum()
        {
            // Return the analyzer's log-scaled, smoothed spectrum for better visual distribution
            if (_analyzer != null)
                return _analyzer.GetSmoothedSpectrum();
            return _lastSpectrum;
        }

        // Python calls this to get the latest frame without processing
        public AudioFrame GetLatestFrame()
        {
            lock (_frameLock)
            {
                return _frameRead;
            }
        }

        public void Stop()
        {
            _running = false;
            if (_capture != null)
            {
                try { _capture.Stop(); _capture.Dispose(); } catch { }
                _capture = null;
            }
            if (_rdma != null)
            {
                try { _rdma.Dispose(); } catch { }
                _rdma = null;
                _rdmaEnabled = false;
            }
        }

        public void Dispose()
        {
            if (!_disposed)
            {
                Stop();
                _dspPipeline?.Dispose();
                // Free pinned buffers
                if (_pinAudioFft.IsAllocated) _pinAudioFft.Free();
                if (_pinAudioOut.IsAllocated) _pinAudioOut.Free();
                if (_pinAudioMono.IsAllocated) _pinAudioMono.Free();
                if (_pinVisualFft.IsAllocated) _pinVisualFft.Free();
                if (_pinVisualSpec.IsAllocated) _pinVisualSpec.Free();
                _disposed = true;
            }
        }
    }
}
