"""
Audio analyzer with 8-band frequency analysis, envelope follower, spectral flux
beat detection, and kick drum isolation.
Ported from StageSimWASAPI/AudioAnalyzer.cs — the "brain" that feeds VisBrain.
"""

import numpy as np
import time
from .tempo_tracker import TempoTracker

# Band definitions (Hz) — matches stage sim exactly
BAND_NAMES = ['sub', 'bass', 'low_mid', 'mid', 'high_mid', 'presence', 'brilliance', 'air']
BAND_START_HZ = [10, 60, 250, 500, 2000, 4000, 6000, 12000]
BAND_END_HZ   = [60, 250, 500, 2000, 4000, 6000, 12000, 32000]
BAND_BOOSTS   = [1.2, 1.0, 1.0, 1.0, 1.1, 1.3, 1.5, 1.8]

FLUX_HISTORY_SIZE = 50


class AudioAnalyzer:
    def __init__(self, fft_size: int = 1024, sample_rate: int = 48000):
        self.fft_size = fft_size
        self.sample_rate = sample_rate

        # Config — matches stage sim defaults
        self.silence_threshold = 0.015
        self.attack_time = 0.005
        self.release_time = 0.08
        self.noise_floor = 0.02
        self.log_scale = 2.1
        self.max_output = 2.2
        self.spectrum_smoothing = 0.7
        self.input_gain = 500.0

        # Envelope follower state
        self._envelope = 0.0
        self._env_avg = 0.5
        self._env_min = 1.0
        self._env_max = 0.0
        self.force_silent = False

        # Silence detection with hysteresis
        self._is_silent = True
        self._silence_duration = 0.0
        self._audio_duration = 0.0
        self._last_state_change = time.perf_counter()

        # Peak tracking
        self._peak_level = 0.0
        self._peak_decay = 0.995

        # Per-band peaks
        self._band_peaks = np.zeros(8, dtype=np.float32)
        self._band_peak_decay = 0.998

        # Spectral flux
        self._prev_spectrum = np.zeros(fft_size // 2, dtype=np.float32)
        self._spectral_flux = 0.0
        self._onset_energy = 0.0

        # Adaptive beat detection
        self._flux_history = np.zeros(FLUX_HISTORY_SIZE, dtype=np.float32)
        self._flux_idx = 0
        self._flux_sum = 0.0
        self._bass_envelope = 0.0
        self._bass_prev = 0.0

        # Kick drum detector
        self._kick_level = 0.0
        self._kick_envelope = 0.0
        self._kick_prev = 0.0
        self._kick_fast_env = 0.0
        self._kick_hit_count = 0
        self._kick_miss_count = 0
        self.kick_confidence = 0.0

        # Temporal spectrum smoothing
        self._smoothed_spectrum = np.zeros(fft_size // 2, dtype=np.float32)

        # Band levels
        self._band_levels = np.zeros(8, dtype=np.float32)
        self._band_levels_smoothed = np.zeros(8, dtype=np.float32)

        # Outputs
        self.overall_level = 0.0
        self.beat_intensity = 0.0
        self.transient = 0.0
        self.transition_factor = 0.0
        self.dominant_band = 0
        self.dominant_band_level = 0.0
        self.beat_just_detected = False
        self._last_beat_time = 0.0
        self._beat_cooldown = 0.12

        self.tempo = TempoTracker()

    @property
    def envelope_val(self) -> float:
        return self._envelope

    @property
    def is_silent(self) -> bool:
        return self._is_silent

    @property
    def bpm(self) -> float:
        return self.tempo.bpm

    @property
    def tempo_confidence(self) -> float:
        return self.tempo.confidence

    @property
    def kick_level(self) -> float:
        return self._kick_level

    def reset(self):
        self._envelope = 0.0
        self._env_avg = 0.5
        self._env_min = 1.0
        self._env_max = 0.0
        self._is_silent = True
        self._silence_duration = 0.0
        self._audio_duration = 0.0
        self._peak_level = 0.0
        self._spectral_flux = 0.0
        self._onset_energy = 0.0
        self._band_peaks[:] = 0
        self._band_levels[:] = 0
        self._band_levels_smoothed[:] = 0
        self._prev_spectrum[:] = 0
        self._smoothed_spectrum[:] = 0
        self._last_state_change = time.perf_counter()
        self.tempo.reset()

    def process(self, raw_spectrum: np.ndarray, valid_bins: int, dt: float) -> np.ndarray:
        """Main processing: takes raw FFT magnitude spectrum, returns processed spectrum."""
        if raw_spectrum is None or valid_bins <= 0:
            self.overall_level = 0.0
            self.beat_intensity = 0.0
            self.transient = 0.0
            return self._smoothed_spectrum

        n = valid_bins
        now = time.perf_counter()

        if len(self._smoothed_spectrum) != n:
            self._smoothed_spectrum = np.zeros(n, dtype=np.float32)
            self._prev_spectrum = np.zeros(n, dtype=np.float32)

        # Temporal smoothing: v = k * v_prev + (1-k) * v_new
        scaled = raw_spectrum[:n] * self.input_gain
        self._smoothed_spectrum[:n] = (self.spectrum_smoothing * self._smoothed_spectrum[:n] +
                                       (1.0 - self.spectrum_smoothing) * scaled)

        # Dynamic range: log scaling with noise floor gating
        gated = np.maximum(self._smoothed_spectrum[:n] - self.noise_floor, 0.0)
        self._smoothed_spectrum[:n] = np.clip(np.log10(gated + 1.0) * self.log_scale, 0.0, self.max_output)

        # Overall audio level
        audio_level = float(np.max(self._smoothed_spectrum[:n]))

        # Envelope follower
        self._update_envelope(audio_level, dt)

        # Adaptive envelope tracking
        if not self._is_silent:
            alpha = 1.0 - np.exp(-dt * 0.5)
            self._env_avg = self._env_avg + (self._envelope - self._env_avg) * alpha
            alpha_min = 1.0 - np.exp(-dt * 0.3)
            self._env_min = self._env_min + (min(self._env_min, self._envelope) - self._env_min) * alpha_min
            self._env_max = self._env_max + (max(self._env_max, self._envelope) - self._env_max) * alpha_min

        # Silence detection
        self._detect_silence(audio_level, now)

        # Peak tracking
        self._update_peak(audio_level)

        # Spectral flux
        self._compute_spectral_flux(self._smoothed_spectrum[:n], n)

        # 8-band analysis
        self._extract_bands(self._smoothed_spectrum[:n], n, dt)

        # Kick drum detector (40-120Hz)
        nyquist = self.sample_rate / 2.0
        bins_per_hz = n / nyquist
        kick_start = int(np.clip(np.floor(40 * bins_per_hz), 0, n - 1))
        kick_end = int(np.clip(np.ceil(120 * bins_per_hz), kick_start + 1, n))
        kick_count = kick_end - kick_start
        kick_sum = float(np.sum(self._smoothed_spectrum[kick_start:kick_end]))
        self._kick_level = kick_sum / kick_count if kick_count > 0 else 0.0

        kick_fast_alpha = 0.8 if self._kick_level > self._kick_fast_env else 0.05
        self._kick_fast_env = (1 - kick_fast_alpha) * self._kick_fast_env + kick_fast_alpha * self._kick_level
        kick_slow_alpha = 1.0 - np.exp(-dt / 0.5)
        self._kick_envelope = (1 - kick_slow_alpha) * self._kick_envelope + kick_slow_alpha * self._kick_level
        self._kick_prev = self._kick_level

        kick_ratio = self._kick_fast_env - self._kick_envelope
        kick_onset = np.clip(kick_ratio / max(self._kick_envelope * 0.5, 0.05), 0, 3)

        # Bass onset
        bass_now = (self._band_levels[0] + self._band_levels[1]) * 0.5
        bass_delta = bass_now - self._bass_prev
        self._bass_prev = bass_now
        bass_alpha = 0.3 if bass_now > self._bass_envelope else 0.08
        self._bass_envelope = (1 - bass_alpha) * self._bass_envelope + bass_alpha * bass_now
        bass_onset = np.clip(bass_delta / max(self._bass_envelope, 0.01), 0, 2)

        # Spectral flux onset
        flux_onset = self.transient

        # Kick confidence
        if kick_onset > 0.8:
            self._kick_hit_count += 1
            self._kick_miss_count = 0
        else:
            self._kick_miss_count += 1
        if self._kick_hit_count > 5 and self._kick_miss_count < 200:
            self.kick_confidence = min(1.0, self.kick_confidence + 0.01)
        else:
            self.kick_confidence = max(0.0, self.kick_confidence - 0.005)

        # Onset strength for tempo
        onset_strength = 0.0
        if kick_onset > 0.5:
            onset_strength += kick_onset * (0.5 + self.kick_confidence * 0.5)
        if bass_onset > 0.5:
            onset_strength += bass_onset * 0.3 * (1 - self.kick_confidence * 0.5)
        if flux_onset > 0.2:
            onset_strength += flux_onset * 0.4 * (1 - self.kick_confidence * 0.3)

        self.tempo.register_onset_strength(onset_strength, now)

        # Beat intensity
        self.beat_intensity = 0.0
        self.beat_just_detected = False
        raw_onset = False
        if not self._is_silent:
            if kick_onset > 0.5:
                self.beat_intensity = max(self.beat_intensity, kick_onset * (0.6 + self.kick_confidence * 0.2))
            if bass_onset > 0.5:
                self.beat_intensity = max(self.beat_intensity, bass_onset * 0.4 * (1 - self.kick_confidence * 0.3))
            if flux_onset > 0.2:
                self.beat_intensity = max(self.beat_intensity, flux_onset * 0.3 * (1 - self.kick_confidence * 0.2))

            if self.beat_intensity > 0.35 and (now - self._last_beat_time) > self._beat_cooldown:
                raw_onset = True
                self._last_beat_time = now

        if raw_onset:
            self.tempo.register_onset(now)

        tempo_beat = self.tempo.update(now)

        if self.tempo.confidence > 0.5:
            self.beat_just_detected = tempo_beat
            if raw_onset and not tempo_beat:
                time_since = now - self._last_beat_time
                if self.beat_intensity > 0.6 and time_since > self._beat_cooldown:
                    self.beat_just_detected = True
        else:
            self.beat_just_detected = raw_onset

        # Dominant band
        self.dominant_band = int(np.argmax(self._band_levels))
        self.dominant_band_level = float(self._band_levels[self.dominant_band])

        # Transition factor
        if self._is_silent:
            self.transition_factor = max(0.0, 1.0 - self._silence_duration / 2.0)
        else:
            self.transition_factor = min(1.0, self._audio_duration / 0.3)

        # Overall level
        self.overall_level = float(np.mean(self._band_levels))

        return self._smoothed_spectrum[:n]

    def _update_envelope(self, audio_level: float, dt: float):
        time_const = self.attack_time if audio_level > self._envelope else self.release_time
        alpha = np.exp(-dt / time_const)
        self._envelope = alpha * self._envelope + (1 - alpha) * audio_level

    def _detect_silence(self, audio_level: float, now: float):
        if audio_level < self.silence_threshold or self.force_silent:
            if not self._is_silent:
                self._is_silent = True
                self._last_state_change = now
            self._silence_duration = now - self._last_state_change
            self._audio_duration = 0.0
        else:
            if self._is_silent:
                self._is_silent = False
                self._last_state_change = now
            self._audio_duration = now - self._last_state_change
            self._silence_duration = 0.0

    def _update_peak(self, audio_level: float):
        if audio_level > self._peak_level:
            self._peak_level = self._peak_level + (audio_level - self._peak_level) * 0.3
        else:
            self._peak_level *= self._peak_decay
        self._peak_level = max(self._peak_level, 0.001)

    def _compute_spectral_flux(self, spectrum: np.ndarray, n: int):
        diff = spectrum[:n] - self._prev_spectrum[:n]
        flux = float(np.sum(np.maximum(diff, 0.0)))
        np.copyto(self._prev_spectrum[:n], spectrum[:n])

        self._spectral_flux = flux
        self._flux_sum -= self._flux_history[self._flux_idx]
        self._flux_history[self._flux_idx] = flux
        self._flux_sum += flux
        self._flux_idx = (self._flux_idx + 1) % FLUX_HISTORY_SIZE

        avg_flux = self._flux_sum / FLUX_HISTORY_SIZE
        self._onset_energy = max(flux - avg_flux * 1.5, 0.0)
        normalized = self._onset_energy / max(1.0, n)
        self.transient = float(np.clip(normalized * 8.0, 0.0, 1.0))

    def _extract_bands(self, spectrum: np.ndarray, n: int, dt: float):
        nyquist = self.sample_rate / 2.0
        bins_per_hz = n / nyquist

        for b in range(8):
            start = int(np.clip(np.floor(BAND_START_HZ[b] * bins_per_hz), 0, n - 1))
            end = int(np.clip(np.ceil(BAND_END_HZ[b] * bins_per_hz), start + 1, n))
            count = end - start
            avg = float(np.sum(spectrum[start:end])) / count if count > 0 else 0.0
            avg *= BAND_BOOSTS[b]
            avg = min(avg, self.max_output)
            self._band_levels[b] = avg
            self._band_peaks[b] = max(self._band_peaks[b] * self._band_peak_decay, avg)
            smooth = 1.0 - np.exp(-dt * 6.0)
            self._band_levels_smoothed[b] += (avg - self._band_levels_smoothed[b]) * smooth

    # --- Public accessors ---
    def get_band_level(self, idx: int) -> float:
        if 0 <= idx < 8:
            return float(self._band_levels_smoothed[idx])
        return 0.0

    def get_band_level_normalized(self, idx: int) -> float:
        if 0 <= idx < 8:
            norm = np.clip(self._band_levels_smoothed[idx] / 2.2, 0, 1)
            return float(np.power(norm, 0.7))
        return 0.0

    def get_sub_level(self) -> float:       return self.get_band_level_normalized(0)
    def get_bass_level(self) -> float:      return self.get_band_level_normalized(1)
    def get_low_mid_level(self) -> float:   return self.get_band_level_normalized(2)
    def get_mid_level(self) -> float:       return self.get_band_level_normalized(3)
    def get_high_mid_level(self) -> float:  return self.get_band_level_normalized(4)
    def get_presence_level(self) -> float:  return self.get_band_level_normalized(5)
    def get_brilliance_level(self) -> float: return self.get_band_level_normalized(6)
    def get_air_level(self) -> float:       return self.get_band_level_normalized(7)

    def get_overall_normalized(self) -> float:
        weights = np.array([1.5, 1.3, 1.0, 0.8, 0.6, 0.4, 0.3, 0.2])
        weighted = float(np.sum(self._band_levels_smoothed * weights)) / 6.1
        norm = np.clip(weighted / 3.5, 0, 1)
        return float(np.power(norm, 0.7))

    def get_envelope_normalized(self) -> float:
        norm = np.clip(self._envelope / 3.5, 0, 1)
        return float(np.power(norm, 0.7))

    def get_all_band_levels(self) -> np.ndarray:
        return np.array([self.get_band_level_normalized(i) for i in range(8)], dtype=np.float32)
