using System;
using UnityEngine;

namespace StageSimWASAPI
{
    // Tempo estimation using autocorrelation of the Onset Strength Signal (OSS).
    // Based on the approach used by librosa and academic literature:
    //   1. Accumulate onset strength into a rolling OSS buffer
    //   2. Compute generalized autocorrelation (enhanced with harmonics x2, x4)
    //   3. Find dominant peak in the perceptually-weighted BPM range (50-200)
    //   4. Use a log-normal prior centered at 120 BPM to resolve octave ambiguity
    //   5. Predict beat grid from the estimated period + phase
    //   6. Onsets correct the grid phase in real-time
    public class TempoTracker
    {
        // OSS buffer — stores onset strength per frame, sampled at ~50fps
        private const int OSS_BUFFER_SIZE = 300;  // ~6 seconds at 50fps
        private float[] _ossBuffer;
        private int _ossIdx = 0;
        private int _ossCount = 0;

        // Autocorrelation range
        private const float MIN_BPM = 50f;
        private const float MAX_BPM = 200f;
        private const float OSS_SAMPLE_RATE = 50f;  // approx frames per second

        // Tempo state
        public float BPM { get; private set; }
        public float BeatPeriod { get; private set; }  // seconds per beat
        public float Confidence { get; private set; }
        public float NextBeatTime { get; private set; }
        public float LastBeatTime { get; private set; }
        public int BeatCount { get; private set; }

        // Phase correction
        private float _phaseError = 0f;
        private const float PHASE_CORRECTION_RATE = 0.25f;

        // Tempo smoothing — accumulate estimates in a histogram
        private const int TEMPO_HIST_BINS = 150;  // 50-200 BPM, 1 BPM resolution
        private float[] _tempoHist;
        private float _histDecay = 0.98f;

        // Last onset time for phase tracking
        private float _lastOnsetTime = -1f;

        public TempoTracker()
        {
            _ossBuffer = new float[OSS_BUFFER_SIZE];
            _tempoHist = new float[TEMPO_HIST_BINS];
            BPM = 0f;
            BeatPeriod = 0f;
            Confidence = 0f;
            NextBeatTime = -1f;
            LastBeatTime = -1f;
            BeatCount = 0;
        }

        public void Reset()
        {
            Array.Clear(_ossBuffer, 0, _ossBuffer.Length);
            Array.Clear(_tempoHist, 0, _tempoHist.Length);
            _ossIdx = 0;
            _ossCount = 0;
            BPM = 0f;
            BeatPeriod = 0f;
            Confidence = 0f;
            NextBeatTime = -1f;
            LastBeatTime = -1f;
            BeatCount = 0;
            _phaseError = 0f;
            _lastOnsetTime = -1f;
        }

        // Called every frame with the current onset strength (spectral flux or kick intensity)
        public void RegisterOnsetStrength(float onsetStrength, float time)
        {
            // Store onset strength into circular buffer
            _ossBuffer[_ossIdx] = onsetStrength;
            _ossIdx = (_ossIdx + 1) % OSS_BUFFER_SIZE;
            if (_ossCount < OSS_BUFFER_SIZE) _ossCount++;

            // Only re-estimate tempo every ~0.5 seconds (every ~25 frames)
            if (_ossCount >= 50 && (_ossIdx % 25 == 0))
            {
                EstimateTempo();
            }
        }

        // Called when a discrete onset is detected (for phase correction)
        public void RegisterOnset(float time)
        {
            _lastOnsetTime = time;

            // Phase correction: if we have a beat grid, snap it to this onset
            if (NextBeatTime > 0f && BeatPeriod > 0f)
            {
                // How far is this onset from the nearest grid beat?
                float elapsed = time - LastBeatTime;
                float beatsFromLast = elapsed / BeatPeriod;
                float fractionalBeats = beatsFromLast - Mathf.Round(beatsFromLast);
                float error = fractionalBeats * BeatPeriod;

                float maxError = BeatPeriod * 0.2f;
                if (Mathf.Abs(error) < maxError)
                {
                    _phaseError = error * PHASE_CORRECTION_RATE;
                }
            }
            else if (BeatPeriod > 0f)
            {
                // No grid yet — start from this onset
                NextBeatTime = time + BeatPeriod;
                LastBeatTime = time;
            }
        }

        private void EstimateTempo()
        {
            // Need at least 2 seconds of data
            if (_ossCount < 100) return;

            // Build a linear buffer from the circular buffer (most recent _ossCount frames)
            float[] oss = new float[_ossCount];
            int start = (_ossIdx - _ossCount + OSS_BUFFER_SIZE) % OSS_BUFFER_SIZE;
            for (int i = 0; i < _ossCount; i++)
            {
                oss[i] = _ossBuffer[(start + i) % OSS_BUFFER_SIZE];
            }

            // Compute generalized autocorrelation: IFFT(|FFT(oss)|^0.5)
            // We use a simpler direct autocorrelation since we don't have FFT here
            // and the buffer is small enough (300 samples)

            int minLag = Mathf.RoundToInt(OSS_SAMPLE_RATE * 60f / MAX_BPM);  // ~15 frames at 200 BPM
            int maxLag = Mathf.RoundToInt(OSS_SAMPLE_RATE * 60f / MIN_BPM);  // ~60 frames at 50 BPM
            // Skip very short lags — they always have high self-correlation
            minLag = Mathf.Max(minLag, 10);  // at least 10 frames (~0.2s = 300 BPM max)

            // Compute autocorrelation for lags in the BPM range
            float[] ac = new float[maxLag + 1];
            for (int lag = minLag; lag <= maxLag; lag++)
            {
                float sum = 0f;
                int count = 0;
                for (int i = 0; i < _ossCount - lag; i++)
                {
                    sum += oss[i] * oss[i + lag];
                    count++;
                }
                ac[lag] = count > 0 ? sum / count : 0f;
            }

            // Normalize autocorrelation by dividing by the zero-lag energy
            // This prevents high-energy signals from always scoring high
            float zeroLagEnergy = 0f;
            for (int i = 0; i < _ossCount; i++)
                zeroLagEnergy += oss[i] * oss[i];
            zeroLagEnergy /= Mathf.Max(1, _ossCount);
            if (zeroLagEnergy < 0.0001f) return;

            // Harmonic enhancement: enhance harmonics (x2, x4) to resolve octave errors
            // EAm[n] = Am[n] + Am[2n] + Am[4n]
            float[] eac = new float[maxLag + 1];
            for (int lag = minLag; lag <= maxLag; lag++)
            {
                eac[lag] = ac[lag] / zeroLagEnergy;  // normalized
                if (lag * 2 <= maxLag) eac[lag] += (ac[lag * 2] / zeroLagEnergy) * 0.5f;
                if (lag * 4 <= maxLag) eac[lag] += (ac[lag * 4] / zeroLagEnergy) * 0.25f;
            }

            // Apply perceptual prior: log-normal centered at 120 BPM
            // This helps pick the "musically correct" tempo when there are octave ambiguities
            // Stronger prior to fight the bias toward fast tempos
            float bestScore = -1f;
            int bestLag = 0;
            for (int lag = minLag; lag <= maxLag; lag++)
            {
                float bpm = 60f * OSS_SAMPLE_RATE / lag;
                // Log-normal prior weight (centered at 120, std ~0.8 in log space)
                float logBpm = Mathf.Log(bpm / 120f);
                float prior = Mathf.Exp(-0.5f * logBpm * logBpm / 0.64f);  // stronger prior
                float score = eac[lag] * prior;
                if (score > bestScore)
                {
                    bestScore = score;
                    bestLag = lag;
                }
            }

            if (bestLag > 0)
            {
                float estimatedPeriod = bestLag / OSS_SAMPLE_RATE;
                float estimatedBpm = 60f / estimatedPeriod;

                // Clamp to reasonable range
                if (estimatedBpm < MIN_BPM) estimatedBpm *= 2f;
                if (estimatedBpm > MAX_BPM) estimatedBpm *= 0.5f;
                estimatedPeriod = 60f / estimatedBpm;

                // Accumulate into tempo histogram for smoothing
                int histBin = Mathf.Clamp(Mathf.RoundToInt(estimatedBpm - MIN_BPM), 0, TEMPO_HIST_BINS - 1);
                // Decay histogram
                for (int i = 0; i < TEMPO_HIST_BINS; i++)
                    _tempoHist[i] *= _histDecay;
                // Add Gaussian spike
                for (int i = Mathf.Max(0, histBin - 3); i <= Mathf.Min(TEMPO_HIST_BINS - 1, histBin + 3); i++)
                {
                    float dist = i - histBin;
                    _tempoHist[i] += Mathf.Exp(-0.5f * dist * dist) * bestScore;
                }

                // Find histogram peak
                float maxHist = 0f;
                int maxHistBin = 0;
                for (int i = 0; i < TEMPO_HIST_BINS; i++)
                {
                    if (_tempoHist[i] > maxHist)
                    {
                        maxHist = _tempoHist[i];
                        maxHistBin = i;
                    }
                }

                float smoothBpm = MIN_BPM + maxHistBin;
                float smoothPeriod = 60f / smoothBpm;

                // Update tempo
                if (BeatPeriod <= 0f)
                {
                    BeatPeriod = smoothPeriod;
                    BPM = smoothBpm;
                }
                else
                {
                    // Blend: 80% old, 20% new — very stable
                    BeatPeriod = BeatPeriod * 0.8f + smoothPeriod * 0.2f;
                    BPM = 60f / BeatPeriod;
                }

                // Confidence based on histogram peak strength relative to total
                float histSum = 0f;
                for (int i = 0; i < TEMPO_HIST_BINS; i++)
                    histSum += _tempoHist[i];
                Confidence = histSum > 0f ? Mathf.Clamp01(maxHist / histSum * 3f) : 0f;

                // Initialize beat grid if we don't have one
                if (NextBeatTime < 0f && _lastOnsetTime > 0f)
                {
                    NextBeatTime = _lastOnsetTime + BeatPeriod;
                    LastBeatTime = _lastOnsetTime;
                }
            }
        }

        // Called every frame. Returns true if a beat should fire this frame.
        public bool Update(float now)
        {
            if (Confidence < 0.2f || BeatPeriod <= 0f || NextBeatTime < 0f)
                return false;

            // Apply phase correction
            float adjustedNext = NextBeatTime + _phaseError;
            _phaseError *= 0.9f;

            if (now >= adjustedNext)
            {
                LastBeatTime = adjustedNext;
                NextBeatTime = adjustedNext + BeatPeriod;
                BeatCount++;

                // If we've drifted too far ahead (e.g. after silence), resync
                if (NextBeatTime < now)
                    NextBeatTime = now + BeatPeriod;

                return true;
            }

            return false;
        }
    }
}
