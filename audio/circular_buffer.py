"""
Circular audio buffer with dual-buffer FFT architecture.
Ported from StageSimWASAPI/CircularAudioBuffer.cs — thread-safe ring buffer
that feeds the FFT provider with the latest N samples.
"""

import threading
import numpy as np


class CircularAudioBuffer:
    def __init__(self, capacity: int):
        self._buffer = np.zeros(capacity, dtype=np.float32)
        self._write_pos = 0
        self._read_pos = 0
        self._lock = threading.Lock()

    def write(self, data: np.ndarray):
        with self._lock:
            count = len(data)
            cap = len(self._buffer)
            first_chunk = min(count, cap - self._write_pos)
            if first_chunk == count:
                self._buffer[self._write_pos:self._write_pos + count] = data
            else:
                self._buffer[self._write_pos:self._write_pos + first_chunk] = data[:first_chunk]
                self._buffer[0:count - first_chunk] = data[first_chunk:]
            self._write_pos = (self._write_pos + count) % cap

    def read_latest(self, count: int) -> np.ndarray | None:
        """Read the latest `count` samples, discarding older data."""
        with self._lock:
            available = self._available()
            if available < count:
                return None
            cap = len(self._buffer)
            to_skip = available - count
            self._read_pos = (self._read_pos + to_skip) % cap

            result = np.empty(count, dtype=np.float32)
            first_chunk = min(count, cap - self._read_pos)
            if first_chunk == count:
                result[:] = self._buffer[self._read_pos:self._read_pos + count]
            else:
                result[:first_chunk] = self._buffer[self._read_pos:self._read_pos + first_chunk]
                result[first_chunk:] = self._buffer[0:count - first_chunk]
            self._read_pos = (self._read_pos + count) % cap
            return result

    def _available(self) -> int:
        diff = self._write_pos - self._read_pos
        if diff < 0:
            diff += len(self._buffer)
        return diff

    def reset(self):
        with self._lock:
            self._read_pos = self._write_pos
