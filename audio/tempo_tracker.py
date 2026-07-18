"""
Tempo tracker using autocorrelation of the Onset Strength Signal (OSS).
Ported from StageSimWASAPI/TempoTracker.cs — estimates BPM, predicts beat grid,
and corrects phase in real-time from detected onsets.
"""

import numpy as np
import time


class TempoTracker:
    OSS_BUFFER_SIZE = 300   # ~6 seconds at 50fps
    MIN_BPM = 50.0
    MAX_BPM = 200.0
    OSS_SAMPLE_RATE = 50.0  # approx frames per second
    TEMPO_HIST_BINS = 150   # 50-200 BPM, 1 BPM resolution
    PHASE_CORRECTION_RATE = 0.25

    def __init__(self):
        self._oss_buffer = np.zeros(self.OSS_BUFFER_SIZE, dtype=np.float32)
        self._oss_idx = 0
        self._oss_count = 0
        self._tempo_hist = np.zeros(self.TEMPO_HIST_BINS, dtype=np.float32)
        self._hist_decay = 0.98

        self.bpm = 0.0
        self.beat_period = 0.0
        self.confidence = 0.0
        self.next_beat_time = -1.0
        self.last_beat_time = -1.0
        self.beat_count = 0
        self._phase_error = 0.0
        self._last_onset_time = -1.0

    def reset(self):
        self._oss_buffer[:] = 0
        self._tempo_hist[:] = 0
        self._oss_idx = 0
        self._oss_count = 0
        self.bpm = 0.0
        self.beat_period = 0.0
        self.confidence = 0.0
        self.next_beat_time = -1.0
        self.last_beat_time = -1.0
        self.beat_count = 0
        self._phase_error = 0.0
        self._last_onset_time = -1.0

    def register_onset_strength(self, onset_strength: float, t: float):
        self._oss_buffer[self._oss_idx] = onset_strength
        self._oss_idx = (self._oss_idx + 1) % self.OSS_BUFFER_SIZE
        if self._oss_count < self.OSS_BUFFER_SIZE:
            self._oss_count += 1

        if self._oss_count >= 50 and (self._oss_idx % 25 == 0):
            self._estimate_tempo()

    def register_onset(self, t: float):
        self._last_onset_time = t
        if self.next_beat_time > 0 and self.beat_period > 0:
            elapsed = t - self.last_beat_time
            beats_from_last = elapsed / self.beat_period
            fractional = beats_from_last - round(beats_from_last)
            error = fractional * self.beat_period
            max_error = self.beat_period * 0.2
            if abs(error) < max_error:
                self._phase_error = error * self.PHASE_CORRECTION_RATE
        elif self.beat_period > 0:
            self.next_beat_time = t + self.beat_period
            self.last_beat_time = t

    def _estimate_tempo(self):
        if self._oss_count < 100:
            return

        start = (self._oss_idx - self._oss_count + self.OSS_BUFFER_SIZE) % self.OSS_BUFFER_SIZE
        oss = np.array([self._oss_buffer[(start + i) % self.OSS_BUFFER_SIZE]
                        for i in range(self._oss_count)], dtype=np.float64)

        min_lag = max(int(self.OSS_SAMPLE_RATE * 60.0 / self.MAX_BPM), 10)
        max_lag = int(self.OSS_SAMPLE_RATE * 60.0 / self.MIN_BPM)

        ac = np.zeros(max_lag + 1, dtype=np.float64)
        for lag in range(min_lag, max_lag + 1):
            if self._oss_count - lag <= 0:
                continue
            ac[lag] = np.mean(oss[:self._oss_count - lag] * oss[lag:self._oss_count])

        zero_lag = np.mean(oss ** 2)
        if zero_lag < 1e-4:
            return

        eac = np.zeros(max_lag + 1, dtype=np.float64)
        for lag in range(min_lag, max_lag + 1):
            eac[lag] = ac[lag] / zero_lag
            if lag * 2 <= max_lag:
                eac[lag] += (ac[lag * 2] / zero_lag) * 0.5
            if lag * 4 <= max_lag:
                eac[lag] += (ac[lag * 4] / zero_lag) * 0.25

        best_score = -1.0
        best_lag = 0
        for lag in range(min_lag, max_lag + 1):
            bpm = 60.0 * self.OSS_SAMPLE_RATE / lag
            log_bpm = np.log(bpm / 120.0)
            prior = np.exp(-0.5 * log_bpm ** 2 / 0.64)
            score = eac[lag] * prior
            if score > best_score:
                best_score = score
                best_lag = lag

        if best_lag > 0:
            est_period = best_lag / self.OSS_SAMPLE_RATE
            est_bpm = 60.0 / est_period
            if est_bpm < self.MIN_BPM:
                est_bpm *= 2
            if est_bpm > self.MAX_BPM:
                est_bpm *= 0.5
            est_period = 60.0 / est_bpm

            hist_bin = int(np.clip(round(est_bpm - self.MIN_BPM), 0, self.TEMPO_HIST_BINS - 1))
            self._tempo_hist *= self._hist_decay
            for i in range(max(0, hist_bin - 3), min(self.TEMPO_HIST_BINS, hist_bin + 4)):
                dist = i - hist_bin
                self._tempo_hist[i] += np.exp(-0.5 * dist ** 2) * best_score

            max_hist = 0.0
            max_bin = 0
            for i in range(self.TEMPO_HIST_BINS):
                if self._tempo_hist[i] > max_hist:
                    max_hist = self._tempo_hist[i]
                    max_bin = i

            smooth_bpm = self.MIN_BPM + max_bin
            smooth_period = 60.0 / smooth_bpm

            if self.beat_period <= 0:
                self.beat_period = smooth_period
                self.bpm = smooth_bpm
            else:
                self.beat_period = self.beat_period * 0.8 + smooth_period * 0.2
                self.bpm = 60.0 / self.beat_period

            hist_sum = float(np.sum(self._tempo_hist))
            self.confidence = np.clip(max_hist / hist_sum * 3.0, 0, 1) if hist_sum > 0 else 0.0

            if self.next_beat_time < 0 and self._last_onset_time > 0:
                self.next_beat_time = self._last_onset_time + self.beat_period
                self.last_beat_time = self._last_onset_time

    def update(self, now: float) -> bool:
        if self.confidence < 0.2 or self.beat_period <= 0 or self.next_beat_time < 0:
            return False
        adjusted = self.next_beat_time + self._phase_error
        self._phase_error *= 0.9
        if now >= adjusted:
            self.last_beat_time = adjusted
            self.next_beat_time = adjusted + self.beat_period
            self.beat_count += 1
            if self.next_beat_time < now:
                self.next_beat_time = now + self.beat_period
            return True
        return False
