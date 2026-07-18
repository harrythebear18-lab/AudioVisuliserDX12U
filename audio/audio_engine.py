"""
Audio engine — uses the C# AudioPipeline DLL for all audio processing.
C# handles: WASAPI capture → FFT → 8-band analyzer → brain → AudioFrame.
Python just reads the frame and feeds it through the RDMA triple buffer to the GPU.
No audio processing in Python — ultra low latency.
"""

import numpy as np
import time
import threading
import os
import sys

# pythonnet — bridge to C# DLL via .NET Core runtime
# Must set env vars BEFORE importing clr
_native_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'native')
_cfg_path = os.path.join(_native_dir, 'AudioPipeline.runtimeconfig.json')
_dll_path = os.path.join(_native_dir, 'AudioPipeline.dll')

os.environ['PYTHONNET_RUNTIME'] = 'coreclr'
os.environ['PYTHONNET_RUNTIME_CONFIG'] = _cfg_path

import clr
import System
clr.AddReference(_dll_path)
from StageSimWASAPI import AudioPipelineOrchestrator, AudioFrame

# RDMA backbone
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from render.signal_bus import TripleBuffer


class AudioEngine:
    """
    Thin Python wrapper around the C# AudioPipelineOrchestrator.
    C# does all audio processing; Python just transfers data to RDMA backbone.
    """

    def __init__(self, fft_size: int = 1024, sample_rate: int = 48000):
        self.fft_size = fft_size
        self.sample_rate = sample_rate

        # C# orchestrator — does everything natively
        self._orchestrator = AudioPipelineOrchestrator(fft_size)

        # RDMA backbone: triple buffer for lock-free audio→render transfer
        spectrum_bins = fft_size // 2
        self.triple_buffer = TripleBuffer(spectrum_bins)

        self._running = False
        self._process_thread = None
        self._process_running = False

        # Cache for spectrum array
        self._spectrum = np.zeros(spectrum_bins, dtype=np.float32)

    def start(self) -> bool:
        if not self._orchestrator.Start():
            return False
        self.sample_rate = self._orchestrator.SampleRate
        self._running = True
        print(f"[AudioEngine] C# pipeline running at {self.sample_rate}Hz, FFT {self.fft_size}")
        return True

    def start_thread(self):
        """No-op — C# DLL has its own capture thread. Process() is called from render loop."""
        print("[AudioEngine] C# capture thread active (no Python thread needed)")

    def _process_loop(self):
        """Background thread: call C# Process() at ~120fps, write to triple buffer."""
        # Attach this thread to the .NET runtime (required by pythonnet)
        clr.AddReference("System")
        target_dt = 1.0 / 120.0
        last_time = time.perf_counter()
        while self._process_running and self._running:
            now = time.perf_counter()
            dt = now - last_time
            last_time = now
            try:
                self.process_frame(dt)
            except Exception as e:
                print(f"[AudioEngine] Process error: {e}")
                time.sleep(0.1)
            elapsed = time.perf_counter() - now
            sleep_time = target_dt - elapsed
            if sleep_time > 0:
                time.sleep(sleep_time)

    def process_frame(self, dt: float) -> dict | None:
        """
        Call C# Process(dt), map AudioFrame to dict, write through RDMA backbone.
        """
        if not self._running:
            return None

        # C# does all the work — capture, FFT, analyzer, brain
        frame = self._orchestrator.Process(float(dt))
        if frame is None:
            return None

        # Diagnostic: L/R range check
        if not hasattr(self, '_dbg'):
            self._dbg = 0
        self._dbg += 1
        if self._dbg % 120 == 0:
            print(f"  [L/R] L={frame.LeftEnergy:.3f} R={frame.RightEnergy:.3f} Bal={frame.StereoBalance:.3f} W={frame.StereoWidth:.3f} Eff={frame.EffectIntensity:.3f} Dim={frame.DimmerIntensity:.3f}")

        # Get spectrum from C# (float[]) — convert via list since C# arrays don't support Python slicing
        cs_spectrum = self._orchestrator.GetSpectrum()
        bins = min(len(cs_spectrum), self.fft_size // 2)
        spec_list = [float(cs_spectrum[i]) for i in range(bins)]
        self._spectrum[:bins] = np.array(spec_list, dtype=np.float32)

        # Map AudioFrame struct to the dict format the renderer expects
        data = {
            'spectrum': self._spectrum[:bins].copy(),
            'spectrum_l': self._spectrum[:bins].copy(),
            'spectrum_r': self._spectrum[:bins].copy(),
            'band_levels': np.array([
                frame.Band0, frame.Band1, frame.Band2, frame.Band3,
                frame.Band4, frame.Band5, frame.Band6, frame.Band7,
            ], dtype=np.float32),
            'beat_detected': bool(frame.BeatDetected),
            'beat_intensity': float(frame.BeatIntensity),
            'transient': float(frame.Transient),
            'envelope': float(frame.Envelope),
            'overall': float(frame.Overall),
            'bpm': float(frame.BPM),
            'tempo_confidence': float(frame.TempoConfidence),
            'kick_level': float(frame.KickLevel),
            'kick_confidence': float(frame.KickConfidence),
            'is_silent': bool(frame.IsSilent),
            'stereo_balance': float(frame.StereoBalance),
            'stereo_width': float(frame.StereoWidth),
            'left_energy': float(frame.LeftEnergy),
            'right_energy': float(frame.RightEnergy),
            'brain': {
                'u_color': (float(frame.ColorR), float(frame.ColorG), float(frame.ColorB)),
                'u_color2': (float(frame.Color2R), float(frame.Color2G), float(frame.Color2B)),
                'u_effect_intensity': float(frame.EffectIntensity),
                'u_movement_intensity': float(frame.MovementIntensity),
                'u_dimmer_intensity': float(frame.DimmerIntensity),
                'u_laser_intensity': float(frame.LaserIntensity),
                'u_blinder_intensity': float(frame.BlinderIntensity),
                'u_moving_light_intensity': float(frame.MovingLightIntensity),
                'u_static_light_intensity': float(frame.StaticLightIntensity),
                'u_moving_lights_on': bool(frame.MovingLightsOn),
                'u_lasers_on': bool(frame.LasersOn),
                'u_static_lights_on': bool(frame.StaticLightsOn),
                'u_blinders_on': bool(frame.BlindersOn),
                'u_strobe_on': bool(frame.StrobeOn),
                'u_base_hue': float(frame.BaseHue),
                'u_section_hue_center': float(frame.SectionHueCenter),
                'u_section_hue_range': float(frame.SectionHueRange),
                'u_trigger_flash': 1.0 if frame.TriggerFlash else 0.0,
                'u_trigger_strobe': 1.0 if frame.TriggerStrobe else 0.0,
                'u_trigger_smoke': 1.0 if frame.TriggerSmoke else 0.0,
                'u_trigger_pyro': 1.0 if frame.TriggerPyro else 0.0,
                'u_trigger_random_flash': 1.0 if frame.TriggerRandomFlash else 0.0,
                'u_random_flash_intensity': float(frame.RandomFlashIntensity),
                'u_group_behavior_mode': int(frame.GroupBehaviorMode),
                'u_group_behavior_phase': float(frame.GroupBehaviorPhase),
                'u_desired_effect_mode': int(frame.DesiredEffectMode),
                'u_should_change_effect_mode': bool(frame.ShouldChangeEffectMode),
                'u_beat_count': int(frame.BeatCount),
                'u_phrase_beat': int(frame.PhraseBeat),
                'u_section_confidence': float(frame.SectionConfidence),
                'u_section': int(frame.Section),
            },
        }

        # Write through RDMA backbone (triple buffer)
        self.triple_buffer.write(data)

        return data

    def read_latest(self) -> dict | None:
        """Read latest audio data from the triple buffer (non-blocking)."""
        return self.triple_buffer.read()

    def stop(self):
        self._process_running = False
        self._running = False
        if self._process_thread is not None:
            self._process_thread.join(timeout=2.0)
            self._process_thread = None
        self._orchestrator.Stop()
