"""
Python ctypes wrapper for the proven WASAPINative.dll from StageSimWASAPI.
This is the same C++ WASAPI loopback DLL that the StageSim project used —
it captures system audio output via Windows WASAPI COM interfaces.

DLL API (cdecl):
  int  WASAPI_StartCapture()           -> 0=ok, negative=error
  int  WASAPI_GetSampleRate()          -> sample rate
  int  WASAPI_GetChannels()            -> channel count
  int  WASAPI_GetBitsPerSample()       -> bits per sample
  int  WASAPI_ReadData(byte* buf, int) -> bytes read (0=no data, neg=error)
  void WASAPI_StopCapture()

The DLL returns raw interleaved PCM bytes. Python converts to float32
and de-interleaves L/R into CircularAudioBuffers — same flow as the
C# WASAPICapture.cs → AudioAnalyzer pipeline.

Falls back to sounddevice (WASAPI host API) if the DLL is not found.
"""

import os
import ctypes
import numpy as np
import threading
import time
from .circular_buffer import CircularAudioBuffer

DLL_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        'native', 'WASAPINative.dll')


class WASAPICapture:
    """
    Native WASAPI loopback capture via the proven WASAPINative.dll.
    Mirrors the C# StageSimWASAPI.WASAPICapture class exactly.
    """

    def __init__(self, fft_size: int = 2048, sample_rate: int = 48000):
        self.fft_size = fft_size
        self.sample_rate = sample_rate
        self.channels = 2
        self.bits_per_sample = 32

        buf_cap = fft_size * 8
        self._left_buf = CircularAudioBuffer(buf_cap)
        self._right_buf = CircularAudioBuffer(buf_cap)
        self._mono_buf = CircularAudioBuffer(buf_cap)

        self._running = False
        self._lock = threading.Lock()
        self._stereo_balance = 0.0
        self._stereo_width = 0.0
        self._last_data_time = 0.0

        self._dll = None
        self._thread = None
        self._using_native = False
        self._using_fallback = False
        self._fallback = None

        # Read buffer — same as C# (192000 bytes covers ~0.5s at 48k/32bit/stereo)
        self._read_buffer = (ctypes.c_ubyte * 192000)()

    def start(self) -> bool:
        if self._load_dll():
            if self._start_native():
                return True
        return self._start_fallback()

    def _load_dll(self) -> bool:
        if not os.path.exists(DLL_PATH):
            print(f"[WASAPICapture] DLL not found at {DLL_PATH}")
            return False
        try:
            self._dll = ctypes.CDLL(DLL_PATH)
            self._dll.WASAPI_StartCapture.restype = ctypes.c_int
            self._dll.WASAPI_StartCapture.argtypes = []
            self._dll.WASAPI_GetSampleRate.restype = ctypes.c_int
            self._dll.WASAPI_GetSampleRate.argtypes = []
            self._dll.WASAPI_GetChannels.restype = ctypes.c_int
            self._dll.WASAPI_GetChannels.argtypes = []
            self._dll.WASAPI_GetBitsPerSample.restype = ctypes.c_int
            self._dll.WASAPI_GetBitsPerSample.argtypes = []
            self._dll.WASAPI_ReadData.restype = ctypes.c_int
            self._dll.WASAPI_ReadData.argtypes = [ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int]
            self._dll.WASAPI_StopCapture.restype = None
            self._dll.WASAPI_StopCapture.argtypes = []
            return True
        except Exception as e:
            print(f"[WASAPICapture] Failed to load DLL: {e}")
            return False

    def _start_native(self) -> bool:
        try:
            hr = self._dll.WASAPI_StartCapture()
            if hr != 0:
                print(f"[WASAPICapture] WASAPI_StartCapture failed: error {hr}")
                return False

            self.channels = min(self._dll.WASAPI_GetChannels(), 2)
            self.sample_rate = self._dll.WASAPI_GetSampleRate()
            self.bits_per_sample = self._dll.WASAPI_GetBitsPerSample()
            self._running = True
            self._using_native = True

            self._thread = threading.Thread(target=self._capture_loop, daemon=True)
            self._thread.start()

            print(f"[WASAPICapture] Native WASAPI loopback: {self.sample_rate}Hz, "
                  f"{self.channels}ch, {self.bits_per_sample}bit")
            return True
        except Exception as e:
            print(f"[WASAPICapture] Native start error: {e}")
            return False

    def _capture_loop(self):
        """Poll the DLL for raw audio bytes, convert to float32, feed buffers."""
        bytes_per_sample = self.bits_per_sample // 8
        frame_bytes = bytes_per_sample * self.channels

        while self._running:
            try:
                bytes_read = self._dll.WASAPI_ReadData(self._read_buffer, len(self._read_buffer))
                if bytes_read > 0:
                    self._process_raw_bytes(bytes(bytes(self._read_buffer[:bytes_read]),
                                                  'raw', 'replace'), bytes_per_sample, frame_bytes)
            except Exception:
                pass
            time.sleep(0.005)  # 200Hz polling — same as C# Thread.Sleep(5)

    def _process_raw_bytes(self, raw: bytes, bytes_per_sample: int, frame_bytes: int):
        """Convert raw PCM bytes to float32 and feed circular buffers."""
        num_frames = len(raw) // frame_bytes
        if num_frames == 0:
            return

        self._last_data_time = time.perf_counter()

        if bytes_per_sample == 4:
            # 32-bit float (WASAPI mix format is typically float32)
            interleaved = np.frombuffer(raw[:num_frames * frame_bytes], dtype=np.float32)
            interleaved = interleaved.reshape(-1, self.channels)
        elif bytes_per_sample == 2:
            # 16-bit PCM
            interleaved = np.frombuffer(raw[:num_frames * frame_bytes], dtype=np.int16)
            interleaved = interleaved.reshape(-1, self.channels).astype(np.float32) / 32768.0
        else:
            return

        if self.channels >= 2:
            left = interleaved[:, 0].copy()
            right = interleaved[:, 1].copy()
            mono = ((left + right) * 0.5).astype(np.float32)
        else:
            mono = interleaved[:, 0].copy()
            left = mono
            right = mono

        self._left_buf.write(left.astype(np.float32))
        self._right_buf.write(right.astype(np.float32))
        self._mono_buf.write(mono.astype(np.float32))

        # Stereo metrics
        l_energy = float(np.sqrt(np.mean(left ** 2)))
        r_energy = float(np.sqrt(np.mean(right ** 2)))
        with self._lock:
            total = l_energy + r_energy
            if total > 1e-6:
                raw_bal = (r_energy - l_energy) / total
                self._stereo_balance = self._stereo_balance * 0.9 + raw_bal * 0.1
                raw_w = abs(r_energy - l_energy) / total
                self._stereo_width = self._stereo_width * 0.9 + raw_w * 0.1

    def _start_fallback(self) -> bool:
        """Fallback to sounddevice with WASAPI host API."""
        try:
            import sounddevice as sd
        except ImportError:
            print("[WASAPICapture] No audio backend available (install sounddevice)")
            return False

        try:
            host_apis = sd.query_hostapis()
            wasapi_idx = None
            for i, api in enumerate(host_apis):
                if 'wasapi' in api['name'].lower():
                    wasapi_idx = i
                    break

            if wasapi_idx is not None:
                api = host_apis[wasapi_idx]
                dev_idx = api['default_output_device']
                if dev_idx < 0:
                    dev_idx = api['default_input_device']
            else:
                dev_idx = sd.default.device[0]

            dev_info = sd.query_devices(dev_idx)
            self.sample_rate = int(dev_info['default_samplerate'])

            self._fallback = sd.InputStream(
                device=dev_idx,
                samplerate=self.sample_rate,
                channels=2,
                dtype='float32',
                blocksize=self.fft_size,
                callback=self._fallback_callback,
                latency='low',
            )
            self._fallback.start()
            self._running = True
            self._using_fallback = True
            print(f"[WASAPICapture] Fallback (sounddevice WASAPI): "
                  f"{self.sample_rate}Hz, device='{dev_info['name']}'")
            return True
        except Exception as e:
            print(f"[WASAPICapture] Fallback failed: {e}")
            return False

    def _fallback_callback(self, indata: np.ndarray, frames: int, time_info, status):
        if not self._running:
            return
        self._last_data_time = time.perf_counter()
        if indata.shape[1] >= 2:
            left = indata[:, 0].astype(np.float32).copy()
            right = indata[:, 1].astype(np.float32).copy()
            mono = ((left + right) * 0.5).astype(np.float32)
        else:
            mono = indata[:, 0].astype(np.float32).copy()
            left = mono
            right = mono

        self._left_buf.write(left)
        self._right_buf.write(right)
        self._mono_buf.write(mono)

        l_energy = float(np.sqrt(np.mean(left ** 2)))
        r_energy = float(np.sqrt(np.mean(right ** 2)))
        with self._lock:
            total = l_energy + r_energy
            if total > 1e-6:
                raw_bal = (r_energy - l_energy) / total
                self._stereo_balance = self._stereo_balance * 0.9 + raw_bal * 0.1
                raw_w = abs(r_energy - l_energy) / total
                self._stereo_width = self._stereo_width * 0.9 + raw_w * 0.1

    def get_mono_samples(self, count: int) -> np.ndarray | None:
        return self._mono_buf.read_latest(count)

    def get_left_samples(self, count: int) -> np.ndarray | None:
        return self._left_buf.read_latest(count)

    def get_right_samples(self, count: int) -> np.ndarray | None:
        return self._right_buf.read_latest(count)

    def get_stereo_metrics(self) -> tuple[float, float]:
        with self._lock:
            return self._stereo_balance, self._stereo_width

    def is_active(self) -> bool:
        if not self._running:
            return False
        if self._using_native:
            return time.perf_counter() - self._last_data_time < 0.5
        if time.perf_counter() - self._last_data_time > 0.5:
            return False
        return True

    def stop(self):
        self._running = False
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        if self._using_native and self._dll is not None:
            self._dll.WASAPI_StopCapture()
        if self._fallback is not None:
            try:
                self._fallback.stop()
                self._fallback.close()
            except Exception:
                pass
            self._fallback = None
        self._using_native = False
        self._using_fallback = False
