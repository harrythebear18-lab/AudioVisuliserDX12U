"""
Visualization Brain — intelligent decision layer that sits between AudioAnalyzer
and the GPU renderer. Ported from StageSimWASAPI/LightingBrain.cs.

Provides:
  - Section detection (intro, verse, build-up, drop, breakdown, outro) from energy trends
  - Phrase-level color changes (every 16 beats)
  - Energy-driven effect intensity curves
  - HSV color wheel with per-section hue centers
  - Beat-synced color wobble and stereo-aware hue shifts
  - Flash/strobe trigger decisions
"""

import numpy as np
import random
import time
from enum import IntEnum


class Section(IntEnum):
    UNKNOWN = 0
    INTRO = 1
    VERSE = 2
    PRE_CHORUS = 3
    CHORUS = 4
    BUILD_UP = 5
    DROP = 6
    BREAKDOWN = 7
    BRIDGE = 8
    INTERLUDE = 9
    OUTRO = 10


SECTION_HUE_CENTERS = {
    Section.INTRO: 0.75, Section.VERSE: 0.45, Section.PRE_CHORUS: 0.08,
    Section.CHORUS: 0.92, Section.BUILD_UP: 0.05, Section.DROP: 0.0,
    Section.BREAKDOWN: 0.58, Section.BRIDGE: 0.33, Section.INTERLUDE: 0.66,
    Section.OUTRO: 0.08, Section.UNKNOWN: 0.5,
}

SECTION_HUE_RANGES = {
    Section.INTRO: 0.1, Section.VERSE: 0.2, Section.PRE_CHORUS: 0.12,
    Section.CHORUS: 0.2, Section.BUILD_UP: 0.15, Section.DROP: 0.25,
    Section.BREAKDOWN: 0.15, Section.BRIDGE: 0.25, Section.INTERLUDE: 0.15,
    Section.OUTRO: 0.05, Section.UNKNOWN: 0.3,
}


def hsv_to_rgb(h: float, s: float, v: float) -> tuple[float, float, float]:
    h = h % 1.0
    s = max(0.0, min(1.0, s))
    v = max(0.0, min(1.0, v))
    hi = int(h * 6)
    f = h * 6 - hi
    p = v * (1 - s)
    q = v * (1 - f * s)
    t = v * (1 - (1 - f) * s)
    match hi % 6:
        case 0: return v, t, p
        case 1: return q, v, p
        case 2: return p, v, t
        case 3: return p, q, v
        case 4: return t, p, v
        case _: return v, p, q


class VisBrain:
    def __init__(self):
        self.section = Section.UNKNOWN
        self.section_confidence = 0.0
        self.beat_count = 0
        self.phrase_beat = 0
        self.phrase_count = 0

        # Energy tracking
        self._energy_history = 0.0
        self._energy_trend = 0.0
        self._peak_energy_recent = 0.0
        self._avg_energy = 0.0
        self._energy_smoothed = 0.0
        self._section_timer = 0.0
        self._song_min_energy = -1.0
        self._song_max_energy = -1.0
        self._energy_range = 0.0
        self._trend_accum = 0.0
        self._trend_timer = 0.0

        # Color wheel
        self._base_hue = 0.0
        self._hue_rotation_speed = 0.04
        self._section_hue_center = 0.5
        self._section_hue_range = 0.3

        # Colors
        self.current_color = (1.0, 0.0, 0.0)
        self.secondary_color = (1.0, 0.0, 0.4)

        # Effect decisions
        self.trigger_flash = False
        self.trigger_strobe = False
        self.effect_intensity = 0.0
        self.dimmer_intensity = 0.0
        self.movement_intensity = 0.0

        # Audio data
        self.kick_level = 0.0
        self.kick_confidence = 0.0
        self.bpm = 0.0
        self.tempo_confidence = 0.0
        self.stereo_balance = 0.0
        self.stereo_width = 0.0
        self.overall_normalized = 0.0
        self.spectral_clarity = 0.0
        self.beat_anticipation = 0.0
        self.phase_correlation = 0.5
        self.motion_persistence = 0.0

        # Cooldowns
        self._last_flash_time = -10.0
        self._last_strobe_time = -10.0
        self._rng = random.Random()

    def reset(self):
        self.section = Section.UNKNOWN
        self.section_confidence = 0.0
        self.beat_count = 0
        self.phrase_beat = 0
        self.phrase_count = 0
        self._energy_history = 0.0
        self._energy_trend = 0.0
        self._peak_energy_recent = 0.0
        self._avg_energy = 0.0
        self._energy_smoothed = 0.0
        self._section_timer = 0.0
        self._song_min_energy = -1.0
        self._song_max_energy = -1.0
        self._energy_range = 0.0
        self.current_color = (1.0, 0.0, 0.0)
        self.secondary_color = (1.0, 0.0, 0.4)
        self.trigger_flash = False
        self.trigger_strobe = False
        self.effect_intensity = 0.0
        self.dimmer_intensity = 0.0
        self.movement_intensity = 0.0

    def update(self, analyzer, dt: float, stereo_balance: float = 0.0, stereo_width: float = 0.0):
        self.trigger_flash = False
        self.trigger_strobe = False

        if analyzer is None or analyzer.is_silent:
            if self.section != Section.UNKNOWN or self.beat_count > 0:
                self.reset()
            self.section = Section.INTRO
            self.effect_intensity = 0.0
            self.dimmer_intensity = 0.0
            self.movement_intensity = 0.0
            return

        energy = analyzer.get_envelope_normalized()
        transient = analyzer.transient
        beat_intensity = analyzer.beat_intensity

        self.kick_level = analyzer.kick_level
        self.kick_confidence = analyzer.kick_confidence
        self.bpm = analyzer.bpm
        self.tempo_confidence = analyzer.tempo_confidence
        self.overall_normalized = analyzer.get_overall_normalized()
        self.stereo_balance = stereo_balance
        self.stereo_width = stereo_width

        # Color wheel rotation
        self._base_hue = (self._base_hue + self._hue_rotation_speed * dt) % 1.0

        # Energy trend tracking
        self._energy_smoothed += (energy - self._energy_smoothed) * (1 - np.exp(-dt * 4))
        self._trend_timer += dt
        if self._trend_timer >= 0.5:
            self._energy_trend = (self._energy_smoothed - self._energy_history) / self._trend_timer
            self._energy_history = self._energy_smoothed
            self._trend_timer = 0.0

        # Song-relative dynamic range
        if self._song_min_energy < 0 or self._song_max_energy < 0:
            self._song_min_energy = energy
            self._song_max_energy = energy * 1.2 + 0.01
        adapt_rate = 2.0 if self._energy_range < 0.05 else 0.3
        self._song_min_energy += (min(self._song_min_energy, energy) - self._song_min_energy) * (1 - np.exp(-dt * adapt_rate))
        self._song_max_energy += (max(self._song_max_energy, energy) - self._song_max_energy) * (1 - np.exp(-dt * adapt_rate))
        self._energy_range = max(0.05, self._song_max_energy - self._song_min_energy)

        self._peak_energy_recent = max(self._peak_energy_recent * 0.98, energy)
        self._avg_energy += (energy - self._avg_energy) * (1 - np.exp(-dt * 0.3))
        self._section_timer += dt

        # Section detection
        self._detect_section(energy, transient, dt)

        # Effect intensity curves
        self.effect_intensity = np.clip(np.power(self._energy_smoothed, 0.5), 0, 1)
        self.dimmer_intensity = np.clip(0.2 + self.effect_intensity * 0.8, 0, 1)
        bpm_factor = np.clip((self.bpm - 60) / 140, 0, 1)
        self.movement_intensity = np.clip(transient * 2 + self.effect_intensity * 0.2 + bpm_factor * 0.15, 0, 1)

        # Flash triggers — disabled, replaced by smooth bloom
        self.trigger_flash = False
        self.trigger_strobe = False

        # Motion persistence — crest factor + BPM + energy + section
        crest = self.spectral_clarity
        tempo_stab = self.tempo_confidence
        bpm_f = np.clip((self.bpm - 60) / 140, 0, 1)
        rel_e = np.clip((self._energy_smoothed - self._song_min_energy) / max(self._energy_range, 0.05), 0, 1)

        persist_base = np.interp(crest, [0, 1], [0.15, 0.7])
        persist_base *= np.interp(tempo_stab, [0, 1], [0.6, 1.15])
        persist_base += rel_e * 0.15
        persist_base *= np.interp(bpm_f * (1 - crest * 0.5), [0, 1], [1.1, 0.85])

        section_mod = 0.0
        if self.section == Section.DROP: section_mod = 0.2
        elif self.section == Section.BUILD_UP: section_mod = 0.15
        elif self.section == Section.CHORUS: section_mod = 0.1
        elif self.section == Section.BREAKDOWN: section_mod = -0.1
        elif self.section == Section.INTRO: section_mod = -0.15
        elif self.section == Section.OUTRO: section_mod = 0.05

        persist_target = np.clip(persist_base + section_mod, 0, 1)
        self.motion_persistence += (persist_target - self.motion_persistence) * (1 - np.exp(-dt * 1.5))

    def on_beat(self, analyzer):
        self.beat_count += 1
        self.phrase_beat = self.beat_count % 16

        if self.phrase_beat == 0:
            self.phrase_count += 1
            # Update section hue center/range
            self._section_hue_center = SECTION_HUE_CENTERS.get(self.section, 0.5)
            self._section_hue_range = SECTION_HUE_RANGES.get(self.section, 0.3)

    def _detect_section(self, energy: float, transient: float, dt: float):
        rel_energy = np.clip((energy - self._song_min_energy) / self._energy_range, 0, 1)
        rel_peak = np.clip((self._peak_energy_recent - self._song_min_energy) / self._energy_range, 0, 1)
        rel_avg = np.clip((self._avg_energy - self._song_min_energy) / self._energy_range, 0, 1)
        prev = self.section

        if rel_energy > 0.7 and rel_peak > 0.8 and self._energy_trend > -0.05:
            if self.section != Section.DROP or self._section_timer > 12:
                self.section = Section.DROP
                self.section_confidence = min(1.0, self.section_confidence + 0.1)
                self._section_timer = 0.0
        elif self._energy_trend > 0.03 and rel_energy > 0.3:
            if self.section != Section.BUILD_UP or self._section_timer > 8:
                self.section = Section.BUILD_UP
                self.section_confidence = min(1.0, self.section_confidence + 0.1)
                self._section_timer = 0.0
        elif self._energy_trend < -0.03 and rel_energy < 0.7 and rel_avg > 0.3:
            if self.section != Section.BREAKDOWN or self._section_timer > 8:
                self.section = Section.BREAKDOWN
                self.section_confidence = min(1.0, self.section_confidence + 0.1)
                self._section_timer = 0.0
        elif 0.15 < rel_energy < 0.6 and abs(self._energy_trend) < 0.03:
            if self._section_timer > 6:
                self.section = Section.VERSE
                self.section_confidence = min(1.0, self.section_confidence + 0.05)
        elif rel_energy < 0.2 and self._energy_trend < 0.03:
            if self._section_timer > 6:
                self.section = Section.INTRO
                self.section_confidence = min(1.0, self.section_confidence + 0.05)
        elif rel_energy < 0.15 and self._energy_trend < -0.02:
            if self._section_timer > 6:
                self.section = Section.OUTRO
                self.section_confidence = min(1.0, self.section_confidence + 0.05)

        self.section_confidence = max(0.0, self.section_confidence - dt * 0.02)

        if prev != self.section:
            self._section_timer = 0.0
            self._section_hue_center = SECTION_HUE_CENTERS.get(self.section, 0.5)
            self._section_hue_range = SECTION_HUE_RANGES.get(self.section, 0.3)

    def get_energy_color(self, energy01: float, light_index: int = 0) -> tuple[float, float, float]:
        """Get a color modulated by energy with per-light hue variation."""
        hue = (self._base_hue + self._section_hue_center) % 1.0
        light_offset = ((light_index % 4) / 4.0 - 0.5) * self._section_hue_range
        hue = (hue + light_offset) % 1.0
        energy_shift = (energy01 - 0.5) * self._section_hue_range
        hue = (hue + energy_shift) % 1.0
        hue = (hue + self.stereo_balance * 0.08) % 1.0
        beat_wobble = np.sin(self.beat_count * 0.7) * self._section_hue_range * 0.15
        hue = (hue + beat_wobble) % 1.0
        sat = np.clip(np.interp(energy01, [0, 1], [0.2, 1.0]) + (1 - self.stereo_width) * 0.1, 0, 1)
        val = np.clip(np.interp(energy01, [0, 1], [0.15, 1.0]) + self.kick_level * 0.15, 0, 1)
        return hsv_to_rgb(hue, sat, val)

    def get_beat_color(self, beat_in_phrase: int) -> tuple[float, float, float]:
        beat_hue_shift = (beat_in_phrase / 16.0) * self._section_hue_range
        hue = (self._base_hue + self._section_hue_center + beat_hue_shift) % 1.0
        sat = 1.0 if beat_in_phrase % 2 == 0 else 0.7
        val = 1.0 if beat_in_phrase % 4 == 0 else 0.75
        return hsv_to_rgb(hue, sat, val)

    def get_section_name(self) -> str:
        return self.section.name

    def get_brain_uniforms(self) -> dict:
        """Get all brain state as a dict suitable for shader uniforms."""
        r, g, b = self.get_energy_color(self.effect_intensity, 0)
        r2, g2, b2 = self.get_energy_color(self.effect_intensity, 2)
        return {
            'u_section': int(self.section),
            'u_section_confidence': self.section_confidence,
            'u_beat_count': self.beat_count,
            'u_phrase_beat': self.phrase_beat,
            'u_phrase_count': self.phrase_count,
            'u_effect_intensity': self.effect_intensity,
            'u_dimmer_intensity': self.dimmer_intensity,
            'u_movement_intensity': self.movement_intensity,
            'u_kick_level': self.kick_level,
            'u_kick_confidence': self.kick_confidence,
            'u_bpm': self.bpm,
            'u_tempo_confidence': self.tempo_confidence,
            'u_stereo_balance': self.stereo_balance,
            'u_stereo_width': self.stereo_width,
            'u_energy_smoothed': self._energy_smoothed,
            'u_base_hue': self._base_hue,
            'u_section_hue_center': self._section_hue_center,
            'u_section_hue_range': self._section_hue_range,
            'u_color': (r, g, b),
            'u_color2': (r2, g2, b2),
            'u_trigger_flash': 1.0 if self.trigger_flash else 0.0,
            'u_trigger_strobe': 1.0 if self.trigger_strobe else 0.0,
            'u_section_name': self.get_section_name(),
            'u_spectral_clarity': self.spectral_clarity,
            'u_beat_anticipation': self.beat_anticipation,
            'u_phase_correlation': self.phase_correlation,
            'u_motion_persistence': self.motion_persistence,
        }
