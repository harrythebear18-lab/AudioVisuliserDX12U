"""
RTX Audio Visualizer — main entry point.

High-fidelity GPU audio visualizer with:
  - C# AudioPipeline DLL (WASAPI capture → FFT → 8-band analyzer → LightingBrain)
  - pythonnet bridge — zero audio processing in Python
  - RDMA signal backbone (triple buffer + single-transfer GPU upload)
  - 7 visualization modes showcasing RTX 5060 GPU:
    0. Spectrum Bars    — 64-band analyzer with brain-driven colors
    1. Black Hole       — Gravitational lensing, relativistic accretion disk
    2. Audio Reactor    — Nuclear core with plasma arcs and cooling rings
    3. Liquid Metal     — Raymarched SDF metaballs with thin-film interference
    4. Cosmic Web       — Volumetric neural network with energy filaments
    5. Quantum Field    — Wavefunction visualization with beat-triggered collapse
    6. Neon City        — Cyberpunk cityscape with rain, fog, holographic billboards

Controls:
  ESC     — Quit
  M       — Next visualization mode
  N       — Previous visualization mode
  F       — Toggle fullscreen
"""

import sys
import time
import numpy as np

from render.window import Window
from render.gpu_renderer import GPURenderer
from audio.audio_engine import AudioEngine


class RTXAudioVisualizer:
    def __init__(self, width=1280, height=720, fft_size=2048, sample_rate=48000):
        self.width = width
        self.height = height
        self.fft_size = fft_size
        self.sample_rate = sample_rate

        self.window = None
        self.renderer = None
        self.audio = None
        self._running = False

    def initialize(self) -> bool:
        # Window + GL context
        self.window = Window(self.width, self.height, "RTX Audio Visualizer")
        self.window.init()
        ctx = self.window.ctx

        # Audio engine
        self.audio = AudioEngine(fft_size=self.fft_size, sample_rate=self.sample_rate)
        if not self.audio.start():
            print("WARNING: Audio capture failed — running in silent mode")

        # Start background audio processing thread (decoupled from render loop)
        self.audio.start_thread()

        # GPU renderer
        spectrum_bins = self.fft_size // 2
        self.renderer = GPURenderer(ctx, self.width, self.height, spectrum_bins)

        self._running = True
        print("\n=== RTX Audio Visualizer Ready ===")
        print("  M=Next Mode  N=Prev Mode  F=Fullscreen  H=Toggle HUD  ESC=Quit")
        print(f"  Mode: {self.renderer.get_mode()}\n")
        return True

    def run(self):
        if not self._running:
            return

        target_fps = 0  # uncapped; vsync controls framerate
        last_fps_print = time.perf_counter()
        frame_count = 0

        try:
            while self._running:
                # Handle events
                event = self.window.handle_events()
                if event is False:
                    break
                elif event == 'next_mode':
                    self.renderer.next_mode()
                elif event == 'prev_mode':
                    idx = (self.renderer._current_mode - 1) % len(self.renderer._modes)
                    self.renderer._current_mode = idx
                    print(f"Mode: {self.renderer.get_mode()}")
                elif event == 'toggle_fullscreen':
                    self.window.toggle_fullscreen()
                elif event == 'toggle_hud':
                    self.renderer.hud.toggle()
                elif isinstance(event, tuple) and event[0] == 'resize':
                    self.renderer.resize(event[1], event[2])
                    self.renderer.hud.resize(event[1], event[2])

                # Process audio in C# with real elapsed time
                dt = self.window.clock.get_time() / 1000.0
                if dt <= 0 or dt > 0.1:
                    dt = 1.0 / 60.0
                audio_data = self.audio.process_frame(dt)

                # Render
                if audio_data is not None:
                    self.renderer.render(audio_data, dt)
                else:
                    self.renderer.render(None, dt)

                # Flip
                self.window.flip(target_fps)

                # FPS print every 2 seconds
                frame_count += 1
                now = time.perf_counter()
                if now - last_fps_print > 2.0:
                    fps = self.window.fps
                    mode = self.renderer.get_mode()
                    bpm = audio_data.get('bpm', 0) if audio_data else 0
                    _section_names = ['Unknown', 'Intro', 'Verse', 'PreChorus', 'Chorus', 'BuildUp', 'Drop', 'Breakdown', 'Bridge', 'Interlude', 'Outro']
                    _sec_idx = int(audio_data.get('brain', {}).get('u_section', 0)) if audio_data else 0
                    section = _section_names[_sec_idx] if _sec_idx < len(_section_names) else '?'
                    print(f"FPS: {fps:.0f} | Mode: {mode} | BPM: {bpm:.0f} | Section: {section}")
                    last_fps_print = now
                    frame_count = 0

        except KeyboardInterrupt:
            print("\nInterrupted")
        except Exception as e:
            print(f"Error: {e}")
            import traceback
            traceback.print_exc()
        finally:
            self.cleanup()

    def cleanup(self):
        print("\n=== Cleaning up ===")
        if self.audio:
            self.audio.stop()
        if self.renderer:
            self.renderer.cleanup()
        if self.window:
            self.window.cleanup()
        print("=== Done ===")


def main():
    import argparse
    parser = argparse.ArgumentParser(description='RTX Audio Visualizer')
    parser.add_argument('--width', type=int, default=1280)
    parser.add_argument('--height', type=int, default=720)
    parser.add_argument('--fft-size', type=int, default=2048, help='FFT size (power of 2)')
    parser.add_argument('--sample-rate', type=int, default=48000)
    args = parser.parse_args()

    app = RTXAudioVisualizer(
        width=args.width,
        height=args.height,
        fft_size=args.fft_size,
        sample_rate=args.sample_rate,
    )

    if app.initialize():
        app.run()


if __name__ == "__main__":
    main()
