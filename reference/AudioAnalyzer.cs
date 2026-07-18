using System;
using UnityEngine;

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
        private static readonly float[] BandStartHz = { 10f, 60f, 250f, 500f, 2000f, 4000f, 6000f, 12000f };
        private static readonly float[] BandEndHz   = { 60f, 250f, 500f, 2000f, 4000f, 6000f, 12000f, 32000f };

        // Config
        public float SilenceThreshold = 0.016f;
        public float AttackTime = 0.005f;   // 5ms attack
        public float ReleaseTime = 0.08f;   // 80ms release
        public float NoiseFloor = 0.02f;
        public float LogScale = 2.1f;
        public float MaxOutput = 2.2f;
        public float SpectrumSmoothing = 0.7f;  // 70% old, 30% new

        // Input gain: compensates for FFT normalization (2/N with N=1024 = 0.002)
        // Scales raw magnitudes to ~1-15 range matching GPU visualizer expectations
        public float InputGain = 500f;

        // Per-band boost factors — higher frequencies get more boost since they're naturally quieter
        public float[] BandBoosts = { 1.2f, 1.0f, 1.0f, 1.0f, 1.1f, 1.3f, 1.5f, 1.8f };

        // State — envelope follower
        private float _envelope = 0f;
        // Running average of envelope for adaptive normalization
        private float _envAvg = 0.5f;  // seed with reasonable mid-range value
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
        private float _kickLevel = 0f;         // current kick band energy
        private float _kickEnvelope = 0f;      // slow-running envelope of kick band
        private float _kickPrev = 0f;          // previous frame kick level
        private float _kickFastEnv = 0f;       // fast envelope for transient detection
        private int _kickHitCount = 0;         // count of kick-like onsets
        private int _kickMissCount = 0;        // frames with no kick onset
        public float KickConfidence { get; private set; } // 0-1, how likely we have a kick drum
        public float KickLevel => _kickLevel;

        // State — temporal spectrum smoothing
        private float[] _smoothedSpectrum;

        // State — band levels (processed, 0-2.2 range)
        private float[] _bandLevels;
        private float[] _bandLevelsSmoothed;

        // Output
        public float OverallLevel { get; private set; }
        public float BeatIntensity { get; private set; }
        public float Transient { get; private set; }
        public float Envelope => _envelope;
        public bool IsSilent => _isSilent;
        public float TransitionFactor { get; private set; }
        public int DominantBand { get; private set; }
        public float DominantBandLevel { get; private set; }

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
            _envAvg = 0.5f;
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

            for (int i = 0; i < n; i++)
            {
                // Scale up raw FFT magnitudes to useful range before processing
                float scaled = rawSpectrum[i] * InputGain;
                _smoothedSpectrum[i] = SpectrumSmoothing * _smoothedSpectrum[i] +
                                       (1f - SpectrumSmoothing) * scaled;
            }

            // --- Dynamic range: log scaling with noise floor gating ---
            // log10(max(x - noise_floor, 0) + 1) * scale, clipped to MaxOutput
            for (int i = 0; i < n; i++)
            {
                float gated = Mathf.Max(_smoothedSpectrum[i] - NoiseFloor, 0f);
                _smoothedSpectrum[i] = Mathf.Clamp(
                    (float)Math.Log10(gated + 1.0) * LogScale, 0f, MaxOutput);
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
            float nyquist = _sampleRate / 2f;
            float binsPerHz = n / nyquist;
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
            // Only fires when there's a sharp increase above the background
            float kickRatio = _kickFastEnv - _kickEnvelope;
            float kickOnset = Mathf.Clamp(kickRatio / Mathf.Max(_kickEnvelope * 0.5f, 0.05f), 0f, 3f);

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
            // Weight kick more heavily when confidence is high
            float onsetStrength = 0f;
            if (kickOnset > 0.5f)
                onsetStrength += kickOnset * (0.5f + KickConfidence * 0.5f);
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

            return _smoothedSpectrum;
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

                // Apply per-band boost
                avg *= BandBoosts[b];
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
            // Normalize against MaxOutput for consistent dynamic range
            float norm = Mathf.Clamp01(_bandLevelsSmoothed[index] / 2.2f);
            return Mathf.Pow(norm, 0.7f);
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
            // Normalize with headroom — matches GetEnvelopeNormalized
            float norm = Mathf.Clamp01(weighted / 3.5f);
            return Mathf.Pow(norm, 0.7f);
        }

        // Envelope-based normalized level — smooth, tracks the overall audio energy closely
        public float GetEnvelopeNormalized()
        {
            // Fixed normalization — absolute level with headroom
            // Divisor of 3.5 gives: max PC volume ~0.8 (loud but not pegged), 
            // moderate volume ~0.4-0.6, quiet ~0.1-0.3
            float norm = Mathf.Clamp01(_envelope / 3.5f);
            return Mathf.Pow(norm, 0.7f);
        }
    }
}
