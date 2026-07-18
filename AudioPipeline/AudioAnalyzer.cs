using System;

namespace StageSimWASAPI
{
    // Ported from gpu_audio_visualizer's vis_algorithm.py + audio_pipeline.py
    // Provides log-scaled dynamic range, envelope follower, spectral flux beat detection,
    // and 8-band frequency analysis with per-band boost factors.
    public class AudioAnalyzer
    {
        // Band definitions (Hz) — matches GPU visualizer
        public static readonly string[] BandNames = {
            "sub", "bass", "low_mid", "mid", "high_mid", "presence", "brilliance", "air"
        };
        public static readonly float[] BandStartHz = { 10f, 60f, 250f, 500f, 2000f, 4000f, 6000f, 12000f };
        private static readonly float[] BandEndHz   = { 60f, 250f, 500f, 2000f, 4000f, 6000f, 12000f, 32000f };

        // Config
        public float SilenceThreshold = 0.016f;
        public float AttackTime = 0.005f;   // 5ms attack
        public float ReleaseTime = 0.08f;   // 80ms release
        public float NoiseFloor = 0.02f;
        public float LogScale = 2.1f;
        public float MaxOutput = 2.2f;
        public float SpectrumSmoothing = 0.0f;  // No data smoothing — visual decay is in the shader

        // Input gain: compensates for FFT normalization (2/N with N=2048 = 0.00098)
        // Original StageSim used 500 with N=1024. Scaled for 2048: 500 * 2 = 1000
        public float InputGain = 1000f;

        // FX scaling — equalize visual levels across spectrum
        // Log10 magnitudes: lows ~3-4, highs ~0.5-1. Boosts lift highs to match.
        // Sub=0, Bass=0.1, LowMid=0.25, Mid=1.0, HighMid=1.5, Presence=2.0, Brilliance=2.75, Air=3.5
        public float[] BandBoosts = { 0.0f, 0.1f, 0.25f, 1.0f, 1.5f, 2.0f, 2.75f, 3.5f };

        // Per-band fast-release compressor settings
        // Each band has: threshold, ratio, attack(ms), release(ms)
        // Fast release keeps transients punchy but prevents any band from dominating
        public float[] BandCompThreshold = { 2.5f, 2.5f, 2.0f, 1.8f, 1.5f, 1.2f, 1.0f, 0.8f };
        public float[] BandCompRatio     = { 3.0f, 3.0f, 4.0f, 4.0f, 5.0f, 6.0f, 8.0f, 10.0f };
        public float[] BandCompAttack    = { 2.0f, 2.0f, 2.0f, 2.0f, 1.5f, 1.5f, 1.0f, 1.0f };
        public float[] BandCompRelease   = { 50f,  40f,  35f,  30f,  25f,  20f,  15f,  10f  };

        // State — envelope follower
        private float _envelope = 0f;
        // Running average of envelope for adaptive normalization
        private float _envAvg = 0f;  // start at zero — no false floor
        private float _envMin = 1f;
        private float _envMax = 0f;
        // External silence override — set when L/R energy is below threshold
        public bool ForceSilent = false;

        // State — silence detection with hysteresis
        private bool _isSilent = true;
        private float _silenceDuration = 0f;
        private float _audioDuration = 0f;
        private float _lastStateChange = 0f;

        // State — peak tracking (for reporting only, not normalization)
        private float _peakLevel = 0f;
        private float _peakDecay = 0.995f;  // faster decay so normalization tracks current level

        // State — per-band peaks for independent normalization
        private float[] _bandPeaks;
        private float _bandPeakDecay = 0.998f;

        // State — spectral flux (beat/onset detection)
        private float[] _prevSpectrum;
        private float _spectralFlux = 0f;
        private float _onsetEnergy = 0f;

        // State — adaptive beat detection
        private float[] _fluxHistory;
        private int _fluxHistoryIdx = 0;
        private const int FLUX_HISTORY_SIZE = 50; // ~1 second at 50fps
        private float _fluxHistorySum = 0f;
        private float _bassEnvelope = 0f;
        private float _bassPrev = 0f;

        // State — kick drum detector (40-120Hz isolated)
        private float _kickLevel = 0f;
        private float _kickEnvelope = 0f;
        private float _kickPrev = 0f;
        private float _kickFastEnv = 0f;
        private int _kickHitCount = 0;
        private int _kickMissCount = 0;
        public float KickConfidence { get; private set; }
        public float KickLevel => _kickLevel;

        // State — hi-hat detector (8-15kHz isolated)
        private float _hatLevel = 0f;
        private float _hatEnvelope = 0f;
        private float _hatPrev = 0f;
        private float _hatFastEnv = 0f;
        public float HatLevel => _hatLevel;

        // State — temporal spectrum smoothing
        private float[] _smoothedSpectrum;

        // State — band levels (processed, 0-2.2 range)
        private float[] _bandLevels;
        private float[] _bandLevelsSmoothed;

        // Public access to band levels for external analysis
        public float[] Bands => _bandLevels;

        // Output
        public float OverallLevel { get; private set; }
        public float BeatIntensity { get; private set; }
        public float Transient { get; private set; }
        public float Envelope => _envelope;
        public bool IsSilent => _isSilent;
        public float TransitionFactor { get; private set; }
        public int DominantBand { get; private set; }
        public float DominantBandLevel { get; private set; }
        public float SpectralClarity { get; private set; }  // 0=noise, 1=tonal
        public float SpectralCentroid { get; private set; } // Hz, brightness-weighted mean frequency
        public float SpectralSpread { get; private set; }   // Hz, std-dev around centroid
        public float DominantFrequency { get; private set; } // Hz, strongest bin frequency

        // Beat event flag — set true for one frame when a new beat is detected
        public bool BeatJustDetected { get; private set; }
        private float _lastBeatTime = 0f;
        private float _beatCooldown = 0.12f; // 120ms min between beats

        // Tempo tracker — estimates BPM and predicts beat grid
        public TempoTracker Tempo { get; private set; }
        public float BPM => Tempo != null ? Tempo.BPM : 0f;
        public float TempoConfidence => Tempo != null ? Tempo.Confidence : 0f;

        private int _fftSize;
        private int _sampleRate;

        public AudioAnalyzer(int fftSize, int sampleRate)
        {
            _fftSize = fftSize;
            _sampleRate = sampleRate;
            _bandPeaks = new float[BandNames.Length];
            _bandLevels = new float[BandNames.Length];
            _bandLevelsSmoothed = new float[BandNames.Length];
            _prevSpectrum = new float[fftSize / 2];
            _smoothedSpectrum = new float[fftSize / 2];
            _fluxHistory = new float[FLUX_HISTORY_SIZE];
            Tempo = new TempoTracker();
            _lastStateChange = Time.realtimeSinceStartup;
        }

        public void Reset()
        {
            _envelope = 0f;
            _envAvg = 0f;
            _envMin = 1f;
            _envMax = 0f;
            _isSilent = true;
            _silenceDuration = 0f;
            _audioDuration = 0f;
            _peakLevel = 0f;
            _spectralFlux = 0f;
            _onsetEnergy = 0f;
            Array.Clear(_bandPeaks, 0, _bandPeaks.Length);
            Array.Clear(_bandLevels, 0, _bandLevels.Length);
            Array.Clear(_bandLevelsSmoothed, 0, _bandLevelsSmoothed.Length);
            Array.Clear(_prevSpectrum, 0, _prevSpectrum.Length);
            Array.Clear(_smoothedSpectrum, 0, _smoothedSpectrum.Length);
            _lastStateChange = Time.realtimeSinceStartup;
            if (Tempo != null) Tempo.Reset();
        }

        // Main processing: takes raw FFT magnitude spectrum, returns processed spectrum
        public float[] Process(float[] rawSpectrum, int validBins)
        {
            if (rawSpectrum == null || validBins <= 0)
            {
                OverallLevel = 0f;
                BeatIntensity = 0f;
                Transient = 0f;
                return _smoothedSpectrum;
            }

            int n = validBins;
            float now = Time.realtimeSinceStartup;
            float dt = Time.deltaTime;

            // --- Temporal smoothing: v = k * v_prev + (1-k) * v_new ---
            if (_smoothedSpectrum.Length != n)
            {
                _smoothedSpectrum = new float[n];
                _prevSpectrum = new float[n];
            }

            float nyquist = _sampleRate / 2f;
            float hzPerBin = nyquist / n;

            for (int i = 0; i < n; i++)
            {
                // Raw spectrum with input gain, then log10 compression
                float raw = rawSpectrum[i] * InputGain;
                float logVal = (float)Math.Log10(raw + 1.0);

                // FX scaling: per-band boost to equalize visual levels
                // Lifts highs to compensate FFT energy roll-off
                float freq = i * hzPerBin;
                float gain = 1.0f;
                for (int b = 0; b < BandStartHz.Length - 1; b++)
                {
                    if (freq >= BandStartHz[b] && freq < BandStartHz[b + 1])
                    {
                        float tBlend = (freq - BandStartHz[b]) / (BandStartHz[b + 1] - BandStartHz[b]);
                        gain = 1.0f + Mathf.Lerp(BandBoosts[b], BandBoosts[b + 1], tBlend);
                        break;
                    }
                }
                if (freq >= BandStartHz[BandStartHz.Length - 1])
                    gain = 1.0f + BandBoosts[BandBoosts.Length - 1];

                _smoothedSpectrum[i] = logVal * gain;
            }

            // --- Overall audio level ---
            float audioLevel = 0f;
            for (int i = 0; i < n; i++)
                audioLevel = Mathf.Max(audioLevel, _smoothedSpectrum[i]);

            // --- Envelope follower with attack/release ---
            UpdateEnvelope(audioLevel, dt);

            // --- Adaptive envelope tracking for normalization ---
            // Running average, min, max for song-relative dynamic range
            if (!_isSilent)
            {
                _envAvg = Mathf.Lerp(_envAvg, _envelope, 1f - Mathf.Exp(-dt * 0.5f));
                _envMin = Mathf.Lerp(_envMin, Mathf.Min(_envMin, _envelope), 1f - Mathf.Exp(-dt * 0.3f));
                _envMax = Mathf.Lerp(_envMax, Mathf.Max(_envMax, _envelope), 1f - Mathf.Exp(-dt * 0.3f));
            }

            // --- Silence detection with hysteresis ---
            DetectSilence(audioLevel, now);

            // --- Peak tracking (reporting only) ---
            UpdatePeak(audioLevel);

            // --- Spectral flux (onset detection) ---
            ComputeSpectralFlux(_smoothedSpectrum, n);

            // --- 8-band frequency analysis ---
            ExtractBands(_smoothedSpectrum, n);

            // --- Beat detection: multi-strategy onset detection ---
            // Strategy 1: Kick drum detector — isolates 40-120Hz, very fast attack/release
            // Kicks have sharp transients in this range that bass lines don't
            float nyquistKick = _sampleRate / 2f;
            float binsPerHz = n / nyquistKick;
            int kickStartBin = Mathf.Clamp(Mathf.FloorToInt(40f * binsPerHz), 0, n - 1);
            int kickEndBin = Mathf.Clamp(Mathf.CeilToInt(120f * binsPerHz), kickStartBin + 1, n);

            float kickSum = 0f;
            int kickCount = kickEndBin - kickStartBin;
            for (int i = kickStartBin; i < kickEndBin; i++)
                kickSum += _smoothedSpectrum[i];
            _kickLevel = kickCount > 0 ? kickSum / kickCount : 0f;

            // Kick fast envelope (very fast attack, medium release) — catches transients
            float kickFastAlpha = _kickLevel > _kickFastEnv ? 0.8f : 0.05f;
            _kickFastEnv = (1f - kickFastAlpha) * _kickFastEnv + kickFastAlpha * _kickLevel;
            // Kick slow envelope (500ms) — background level
            float kickSlowAlpha = 1f - Mathf.Exp(-dt / 0.5f);
            _kickEnvelope = (1f - kickSlowAlpha) * _kickEnvelope + kickSlowAlpha * _kickLevel;
            float kickDelta = _kickLevel - _kickPrev;
            _kickPrev = _kickLevel;

            // Kick onset = fast envelope exceeding slow envelope (transient spike)
            float kickRatio = _kickFastEnv - _kickEnvelope;
            float kickOnset = Mathf.Clamp(kickRatio / Mathf.Max(_kickEnvelope * 0.5f, 0.05f), 0f, 3f);

            // Strategy 1b: Hi-hat detector — isolates 8-15kHz, fast attack/release
            // Hi-hats have sharp transients in this range
            int hatStartBin = Mathf.Clamp(Mathf.FloorToInt(8000f * binsPerHz), 0, n - 1);
            int hatEndBin = Mathf.Clamp(Mathf.CeilToInt(15000f * binsPerHz), hatStartBin + 1, n);

            float hatSum = 0f;
            int hatCount = hatEndBin - hatStartBin;
            for (int i = hatStartBin; i < hatEndBin; i++)
                hatSum += _smoothedSpectrum[i];
            _hatLevel = hatCount > 0 ? hatSum / hatCount : 0f;

            float hatFastAlpha = _hatLevel > _hatFastEnv ? 0.85f : 0.03f;
            _hatFastEnv = (1f - hatFastAlpha) * _hatFastEnv + hatFastAlpha * _hatLevel;
            float hatSlowAlpha = 1f - Mathf.Exp(-dt / 0.3f);
            _hatEnvelope = (1f - hatSlowAlpha) * _hatEnvelope + hatSlowAlpha * _hatLevel;
            float hatRatio = _hatFastEnv - _hatEnvelope;
            float hatOnset = Mathf.Clamp(hatRatio / Mathf.Max(_hatEnvelope * 0.5f, 0.02f), 0f, 3f);

            // Strategy 2: General bass onset (sub + bass bands)
            float bassNow = (_bandLevels[0] + _bandLevels[1]) * 0.5f;
            float bassDelta = bassNow - _bassPrev;
            _bassPrev = bassNow;
            float bassAlpha = bassNow > _bassEnvelope ? 0.3f : 0.08f;
            _bassEnvelope = (1f - bassAlpha) * _bassEnvelope + bassAlpha * bassNow;
            float bassOnset = Mathf.Clamp(bassDelta / Mathf.Max(_bassEnvelope, 0.01f), 0f, 2f);

            // Strategy 3: Spectral flux
            float fluxOnset = Transient;

            // Combine: prefer kick drum when it's present, fall back to bass/flux
            // Track kick confidence: if kick onsets fire consistently, we have a kick drum
            if (kickOnset > 0.8f)
            {
                _kickHitCount++;
                _kickMissCount = 0;
            }
            else
            {
                _kickMissCount++;
            }
            // Kick confidence rises when we see consistent kick hits, falls when we don't
            if (_kickHitCount > 5 && _kickMissCount < 200)
                KickConfidence = Mathf.Min(1f, KickConfidence + 0.01f);
            else
                KickConfidence = Mathf.Max(0f, KickConfidence - 0.005f);

            // Build onset strength signal for tempo tracker
            // Combine kick + hi-hat + bass + flux for robust tempo detection
            float onsetStrength = 0f;
            if (kickOnset > 0.5f)
                onsetStrength += kickOnset * (0.5f + KickConfidence * 0.5f);
            if (hatOnset > 0.5f)
                onsetStrength += hatOnset * 0.4f;  // hi-hat contributes to tempo
            if (bassOnset > 0.5f)
                onsetStrength += bassOnset * 0.3f * (1f - KickConfidence * 0.5f);
            if (fluxOnset > 0.2f)
                onsetStrength += fluxOnset * 0.4f * (1f - KickConfidence * 0.3f);

            // Feed onset strength to tempo tracker every frame (for autocorrelation)
            Tempo.RegisterOnsetStrength(onsetStrength, now);

            BeatIntensity = 0f;
            BeatJustDetected = false;
            bool rawOnset = false;
            if (!_isSilent)
            {
                // Combine all strategies for beat intensity
                if (kickOnset > 0.5f)
                    BeatIntensity = Mathf.Max(BeatIntensity, kickOnset * (0.6f + KickConfidence * 0.2f));
                if (hatOnset > 0.5f)
                    BeatIntensity = Mathf.Max(BeatIntensity, hatOnset * 0.3f);
                if (bassOnset > 0.5f)
                    BeatIntensity = Mathf.Max(BeatIntensity, bassOnset * 0.4f * (1f - KickConfidence * 0.3f));
                if (fluxOnset > 0.2f)
                    BeatIntensity = Mathf.Max(BeatIntensity, fluxOnset * 0.3f * (1f - KickConfidence * 0.2f));

                // Raw onset detection (for tempo estimation)
                float nowTime = Time.realtimeSinceStartup;
                if (BeatIntensity > 0.35f && (nowTime - _lastBeatTime) > _beatCooldown)
                {
                    rawOnset = true;
                    _lastBeatTime = nowTime;
                }
            }

            // --- Tempo-aware beat scheduling ---
            if (rawOnset)
            {
                Tempo.RegisterOnset(Time.realtimeSinceStartup);
            }

            // Check if tempo tracker predicts a beat this frame
            bool tempoBeat = Tempo.Update(Time.realtimeSinceStartup);

            // Fire beat if either raw onset or tempo prediction says so
            // Once tempo confidence is high, prefer tempo grid (smoother, more musical)
            if (Tempo.Confidence > 0.5f)
            {
                // High confidence: use tempo grid, but let raw onsets reinforce
                BeatJustDetected = tempoBeat;
                if (rawOnset && !tempoBeat)
                {
                    // Off-grid onset — only fire if it's strong and not too close to last beat
                    float timeSinceLast = Time.realtimeSinceStartup - _lastBeatTime;
                    if (BeatIntensity > 0.6f && timeSinceLast > _beatCooldown)
                        BeatJustDetected = true;
                }
            }
            else
            {
                // Low confidence: use raw onsets only
                BeatJustDetected = rawOnset;
            }

            // --- Find dominant band ---
            DominantBand = 0;
            DominantBandLevel = 0f;
            for (int b = 0; b < _bandLevels.Length; b++)
            {
                if (_bandLevels[b] > DominantBandLevel)
                {
                    DominantBandLevel = _bandLevels[b];
                    DominantBand = b;
                }
            }

            // --- Transition factor (smooth silence <-> audio) ---
            if (_isSilent)
                TransitionFactor = Mathf.Max(0f, 1f - _silenceDuration / 2f);
            else
                TransitionFactor = Mathf.Min(1f, _audioDuration / 0.3f);

            // --- Overall level: average of all bands ---
            float sum = 0f;
            for (int i = 0; i < _bandLevels.Length; i++)
                sum += _bandLevels[i];
            OverallLevel = sum / _bandLevels.Length;

            // --- Spectral clarity: crest factor of spectrum ---
            // High crest (peak >> average) = tonal/clear, low crest = noise/diffuse
            float specSum = 0f, specMax = 0f;
            int specN = Mathf.Min(n, 256);  // use lower half for clarity (most musical content)
            for (int i = 0; i < specN; i++)
            {
                float v = _smoothedSpectrum[i];
                specSum += v;
                if (v > specMax) specMax = v;
            }
            float specAvg = specSum / Mathf.Max(1, specN);
            float crest = specAvg > 0.001f ? specMax / specAvg : 1f;
            // Crest factor 1-10+ → map to 0-1, clamp
            SpectralClarity = Mathf.Clamp01((crest - 1f) / 5f);

            ComputeFrequencyFeatures(n, hzPerBin);

            return _smoothedSpectrum;
        }

        private void ComputeFrequencyFeatures(int n, float hzPerBin)
        {
            float weightedSum = 0f;
            float total = 0f;
            float maxVal = 0f;
            int maxIdx = 0;

            // Use all bins up to Nyquist for a faithful brightness-weighted estimate.
            for (int i = 0; i < n; i++)
            {
                float v = _smoothedSpectrum[i];
                weightedSum += i * v;
                total += v;
                if (v > maxVal)
                {
                    maxVal = v;
                    maxIdx = i;
                }
            }

            if (total > 0.001f)
            {
                float centroidBin = weightedSum / total;
                SpectralCentroid = centroidBin * hzPerBin;

                float spreadSum = 0f;
                for (int i = 0; i < n; i++)
                {
                    float diff = i - centroidBin;
                    spreadSum += diff * diff * _smoothedSpectrum[i];
                }
                SpectralSpread = MathF.Sqrt(spreadSum / total) * hzPerBin;
            }
            else
            {
                SpectralCentroid = 0f;
                SpectralSpread = 0f;
            }

            DominantFrequency = maxIdx * hzPerBin;
        }

        private void UpdateEnvelope(float audioLevel, float dt)
        {
            // Frame-rate independent attack/release
            // alpha = exp(-1 / (time_const * fps)) — but we use dt directly
            float timeConst = audioLevel > _envelope ? AttackTime : ReleaseTime;
            float alpha = Mathf.Exp(-dt / timeConst);
            _envelope = alpha * _envelope + (1f - alpha) * audioLevel;
        }

        private void DetectSilence(float audioLevel, float now)
        {
            // Consider silence if audio level is below threshold OR if external L/R energy check says silent
            if (audioLevel < SilenceThreshold || ForceSilent)
            {
                if (!_isSilent)
                {
                    _isSilent = true;
                    _lastStateChange = now;
                }
                _silenceDuration = now - _lastStateChange;
                _audioDuration = 0f;
            }
            else
            {
                if (_isSilent)
                {
                    _isSilent = false;
                    _lastStateChange = now;
                }
                _audioDuration = now - _lastStateChange;
                _silenceDuration = 0f;
            }
        }

        private void UpdatePeak(float audioLevel)
        {
            // Fast attack, slower decay — tracks recent peak, not all-time peak
            if (audioLevel > _peakLevel)
                _peakLevel = Mathf.Lerp(_peakLevel, audioLevel, 0.3f);
            else
                _peakLevel *= _peakDecay;
            _peakLevel = Mathf.Max(_peakLevel, 0.001f);
        }

        private void ComputeSpectralFlux(float[] spectrum, int n)
        {
            // Spectral flux = sum of positive differences (onset detection)
            float flux = 0f;
            for (int i = 0; i < n; i++)
            {
                float diff = spectrum[i] - _prevSpectrum[i];
                if (diff > 0f)
                    flux += diff;
            }
            Array.Copy(spectrum, _prevSpectrum, n);

            _spectralFlux = flux;

            // Update rolling flux history for adaptive threshold
            _fluxHistorySum -= _fluxHistory[_fluxHistoryIdx];
            _fluxHistory[_fluxHistoryIdx] = flux;
            _fluxHistorySum += flux;
            _fluxHistoryIdx = (_fluxHistoryIdx + 1) % FLUX_HISTORY_SIZE;

            float avgFlux = _fluxHistorySum / FLUX_HISTORY_SIZE;
            // Onset energy = how much this flux exceeds the rolling average
            _onsetEnergy = Mathf.Clamp(flux - avgFlux * 1.5f, 0f, float.MaxValue);
            // Normalize by number of bins to get a per-bin average, then scale
            float normalizedFlux = _onsetEnergy / Mathf.Max(1f, n);
            Transient = Mathf.Clamp(normalizedFlux * 8f, 0f, 1f);
        }

        private void ExtractBands(float[] spectrum, int n)
        {
            float nyquist = _sampleRate / 2f;
            float binsPerHz = n / nyquist;

            for (int b = 0; b < BandNames.Length; b++)
            {
                int start = Mathf.Clamp(Mathf.FloorToInt(BandStartHz[b] * binsPerHz), 0, n - 1);
                int end = Mathf.Clamp(Mathf.CeilToInt(BandEndHz[b] * binsPerHz), start + 1, n);

                float sum = 0f;
                int count = end - start;
                for (int i = start; i < end; i++)
                    sum += spectrum[i];
                float avg = count > 0 ? sum / count : 0f;

                // Apply per-band boost (1.0 + boost, so 0.0 = neutral)
                avg *= (1.0f + BandBoosts[b]);
                avg = Mathf.Clamp(avg, 0f, MaxOutput);

                _bandLevels[b] = avg;

                // Per-band peak tracking for independent normalization
                _bandPeaks[b] = Mathf.Max(_bandPeaks[b] * _bandPeakDecay, avg);

                // Smooth band level (frame-rate independent)
                float smooth = 1f - Mathf.Exp(-Time.deltaTime * 6f);
                _bandLevelsSmoothed[b] = Mathf.Lerp(_bandLevelsSmoothed[b], avg, smooth);
            }
        }

        // Public accessors for band levels (0-2.2 range, typically 0-1)
        public float GetBandLevel(int index)
        {
            if (index < 0 || index >= _bandLevelsSmoothed.Length) return 0f;
            return _bandLevelsSmoothed[index];
        }

        public float GetBandLevelNormalized(int index)
        {
            if (index < 0 || index >= _bandLevelsSmoothed.Length) return 0f;
            return _bandLevelsSmoothed[index];
        }

        // Convenience accessors matching old API
        public float GetBassLevel() => GetBandLevelNormalized(1);       // bass: 60-250Hz
        public float GetLowMidLevel() => GetBandLevelNormalized(2);     // low_mid: 250-500Hz
        public float GetMidLevel() => GetBandLevelNormalized(3);        // mid: 500-2000Hz
        public float GetHighMidLevel() => GetBandLevelNormalized(4);    // high_mid: 2-4kHz
        public float GetTrebleLevel() => GetBandLevelNormalized(6);     // brilliance: 6-12kHz
        public float GetSubLevel() => GetBandLevelNormalized(0);        // sub: 10-60Hz
        public float GetOverallNormalized()
        {
            // Weighted average: emphasize bass + sub + low_mid (most visible in lighting)
            float weighted = (_bandLevelsSmoothed[0] * 1.5f + _bandLevelsSmoothed[1] * 1.3f +
                              _bandLevelsSmoothed[2] * 1.0f + _bandLevelsSmoothed[3] * 0.8f +
                              _bandLevelsSmoothed[4] * 0.6f + _bandLevelsSmoothed[5] * 0.4f +
                              _bandLevelsSmoothed[6] * 0.3f + _bandLevelsSmoothed[7] * 0.2f) / 6.1f;
            return weighted;
        }

        // Envelope-based level — raw envelope, no normalization/clamping
        public float GetEnvelopeNormalized()
        {
            return _envelope;
        }

        public float[] GetSmoothedSpectrum() => _smoothedSpectrum;
    }
}
