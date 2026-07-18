"""
Radix-2 Cooley-Tukey FFT with Hann window.
Ported from StageSimWASAPI/FFTProvider.cs — produces magnitude spectrum
from real-valued input, normalized identically to the stage sim brain.
"""

import numpy as np


class FFTProvider:
    _window_cache: dict[int, np.ndarray] = {}

    @classmethod
    def compute_magnitude_spectrum(cls, samples: np.ndarray, size: int) -> np.ndarray:
        """Compute magnitude spectrum of real-valued input (length must be power of 2)."""
        if size <= 0 or (size & (size - 1)) != 0:
            return np.zeros(size, dtype=np.float32)

        window = cls._get_window(size)
        windowed = samples[:size].astype(np.float64) * window

        spectrum = np.fft.rfft(windowed, n=size)
        magnitude = np.abs(spectrum)

        # Normalize: 2/N (matches Unity GetSpectrumData and C# FFTProvider)
        magnitude *= 2.0 / size

        # Pad to full size (mirror for upper half)
        output = np.zeros(size, dtype=np.float32)
        half = size // 2
        output[:half + 1] = magnitude[:half + 1].astype(np.float32)
        if half + 1 < size:
            output[half + 1:] = magnitude[size - (half - 1):0:-1].astype(np.float32)

        return output

    @classmethod
    def _get_window(cls, size: int) -> np.ndarray:
        if size not in cls._window_cache:
            i = np.arange(size, dtype=np.float64)
            cls._window_cache[size] = 0.54 - 0.46 * np.cos(2.0 * np.pi * i / (size - 1))
        return cls._window_cache[size]
