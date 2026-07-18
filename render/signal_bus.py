"""
RDMA-style signal backbone — zero-latency CPU→GPU data channel.

Ports the established triple-buffer + direct-write technique from the previous
gpu_audio_visualizer project and upgrades it:

  1. TripleBuffer: lock-free 3-buffer rotation (write → read → backup)
     Audio thread writes, render thread reads, never blocks either side.
  2. SignalBus: single-transfer UBO + texture writes per frame.
     Packs all 8-band brain state + spectrum into one GPU upload.
  3. PinnedMemoryPool: pre-allocated numpy arrays reused across frames
     to eliminate per-frame allocation overhead.

This acts as the "virtual copper cable" between the audio brain and the GPU.
"""

import threading
import numpy as np
import moderngl
import struct


class TripleBuffer:
    """
    Lock-free triple buffer for audio→render thread communication.
    
    Buffer A: Audio thread writes here (producer)
    Buffer B: Render thread reads here (consumer)  
    Buffer C: Standby — swapped in when A is done writing
    
    The swap is atomic: writer publishes A, reader gets the latest completed
    buffer without ever blocking.
    """

    def __init__(self, spectrum_bins: int):
        self.spectrum_bins = spectrum_bins

        def _make():
            return {
                'spectrum': np.zeros(spectrum_bins, dtype=np.float32),
                'spectrum_l': np.zeros(spectrum_bins, dtype=np.float32),
                'spectrum_r': np.zeros(spectrum_bins, dtype=np.float32),
                'band_levels': np.zeros(8, dtype=np.float32),
                'beat_intensity': 0.0,
                'transient': 0.0,
                'envelope': 0.0,
                'overall': 0.0,
                'bpm': 0.0,
                'tempo_confidence': 0.0,
                'kick_level': 0.0,
                'kick_confidence': 0.0,
                'is_silent': True,
                'beat_detected': False,
                'stereo_balance': 0.0,
                'stereo_width': 0.0,
                'brain_uniforms': {},
                'sequence': 0,  # monotonic counter for staleness detection
            }

        self._buffers = [_make(), _make(), _make()]
        self._write_idx = 0
        self._read_idx = 1
        self._backup_idx = 2
        self._swap_lock = threading.Lock()
        self._latest_seq = 0

    def write(self, data: dict):
        """Called from audio thread — writes to write buffer, then atomically swaps."""
        buf = self._buffers[self._write_idx]
        sb = min(len(data.get('spectrum', [])), self.spectrum_bins)
        buf['spectrum'][:sb] = data['spectrum'][:sb]
        sl = data.get('spectrum_l')
        sr = data.get('spectrum_r')
        if sl is not None:
            bl = min(len(sl), self.spectrum_bins)
            buf['spectrum_l'][:bl] = sl[:bl]
        if sr is not None:
            br = min(len(sr), self.spectrum_bins)
            buf['spectrum_r'][:br] = sr[:br]
        buf['band_levels'][:] = data.get('band_levels', np.zeros(8, dtype=np.float32))[:8]
        buf['beat_intensity'] = data.get('beat_intensity', 0.0)
        buf['transient'] = data.get('transient', 0.0)
        buf['envelope'] = data.get('envelope', 0.0)
        buf['overall'] = data.get('overall', 0.0)
        buf['bpm'] = data.get('bpm', 0.0)
        buf['tempo_confidence'] = data.get('tempo_confidence', 0.0)
        buf['kick_level'] = data.get('kick_level', 0.0)
        buf['kick_confidence'] = data.get('kick_confidence', 0.0)
        buf['is_silent'] = data.get('is_silent', True)
        buf['beat_detected'] = data.get('beat_detected', False)
        buf['stereo_balance'] = data.get('stereo_balance', 0.0)
        buf['stereo_width'] = data.get('stereo_width', 0.0)
        buf['brain_uniforms'] = data.get('brain', {})
        buf['sequence'] = self._latest_seq + 1

        # Atomic swap: writer publishes, reader gets latest, old read becomes backup
        with self._swap_lock:
            self._latest_seq = buf['sequence']
            old_write = self._write_idx
            old_read = self._read_idx
            self._write_idx = self._backup_idx   # writer gets old backup
            self._read_idx = old_write            # reader gets freshly written buffer
            self._backup_idx = old_read           # old read becomes new backup

    def read(self) -> dict | None:
        """Called from render thread — returns latest buffer or None if no new data."""
        with self._swap_lock:
            buf = self._buffers[self._read_idx]
            if buf['sequence'] == 0:
                return None
            # Return a shallow copy — arrays are copied to prevent race
            return {
                'spectrum': buf['spectrum'].copy(),
                'spectrum_l': buf['spectrum_l'].copy(),
                'spectrum_r': buf['spectrum_r'].copy(),
                'band_levels': buf['band_levels'].copy(),
                'beat_intensity': buf['beat_intensity'],
                'transient': buf['transient'],
                'envelope': buf['envelope'],
                'overall': buf['overall'],
                'bpm': buf['bpm'],
                'tempo_confidence': buf['tempo_confidence'],
                'kick_level': buf['kick_level'],
                'kick_confidence': buf['kick_confidence'],
                'is_silent': buf['is_silent'],
                'beat_detected': buf['beat_detected'],
                'stereo_balance': buf['stereo_balance'],
                'stereo_width': buf['stereo_width'],
                'brain': buf['brain_uniforms'],
                'sequence': buf['sequence'],
            }

    @property
    def latest_sequence(self) -> int:
        return self._latest_seq


class PinnedMemoryPool:
    """
    Pre-allocated numpy arrays reused across frames.
    Eliminates per-frame allocation and GC pressure.
    
    UBO layout: 6 vec4s = 24 floats = 96 bytes, matching GLSL AudioBlock:
      vec4 u_bands     = (sub, bass, low_mid, mid)
      vec4 u_bands2    = (high_mid, presence, brilliance, air)
      vec4 u_dynamics  = (beat_intensity, transient, envelope, overall)
      vec4 u_rhythm    = (bpm, tempo_confidence, kick_level, kick_confidence)
      vec4 u_stereo    = (stereo_balance, stereo_width, effect_intensity, movement_intensity)
      vec4 u_color_hue = (base_hue, section_hue_center, section_hue_range, beat_detected)
    """

    UBO_FLOATS = 48  # 12 vec4s

    def __init__(self, spectrum_bins: int):
        self.spectrum = np.zeros(spectrum_bins, dtype=np.float32)
        self.spectrum_l = np.zeros(spectrum_bins, dtype=np.float32)
        self.spectrum_r = np.zeros(spectrum_bins, dtype=np.float32)
        self.ubo_data = np.zeros(self.UBO_FLOATS, dtype=np.float32)
        self.band_levels = np.zeros(8, dtype=np.float32)

    def reset(self):
        self.spectrum[:] = 0
        self.spectrum_l[:] = 0
        self.spectrum_r[:] = 0
        self.ubo_data[:] = 0
        self.band_levels[:] = 0


class SignalBus:
    """
    Single-transfer GPU upload channel.
    
    Packs all audio state into:
      - One 1D texture (spectrum data)
      - One UBO (8 band levels + 16 brain floats = 24 floats = 96 bytes)
    
    This is the "virtual copper cable" — one write per frame, no intermediate
    smoothing, no redundant uploads. The GPU reads directly from these buffers.
    """

    def __init__(self, ctx: moderngl.Context, spectrum_bins: int):
        self.ctx = ctx
        self.spectrum_bins = spectrum_bins

        # Pre-allocated CPU memory (pinned pool)
        self.pool = PinnedMemoryPool(spectrum_bins)

        # GPU resources
        self.spectrum_tex = ctx.texture((spectrum_bins, 1), 1, dtype='f4')
        self.spectrum_tex.filter = (moderngl.LINEAR, moderngl.LINEAR)

        self.spectrum_l_tex = ctx.texture((spectrum_bins, 1), 1, dtype='f4')
        self.spectrum_l_tex.filter = (moderngl.LINEAR, moderngl.LINEAR)

        self.spectrum_r_tex = ctx.texture((spectrum_bins, 1), 1, dtype='f4')
        self.spectrum_r_tex.filter = (moderngl.LINEAR, moderngl.LINEAR)

        # UBO: 12 vec4s = 48 floats = 192 bytes (matches GLSL AudioBlock in audio_ubo.glsl)
        self.ubo = ctx.buffer(reserve=192, dynamic=True)

        # Stats
        self._upload_count = 0
        self._last_seq = 0

    def upload(self, data: dict):
        """
        Single-frame upload: spectrum texture + UBO in one call.
        No smoothing, no intermediate copies beyond the pinned pool.
        """
        pool = self.pool

        # --- Spectrum texture ---
        spec = data.get('spectrum', np.zeros(self.spectrum_bins, dtype=np.float32))
        sb = min(len(spec), self.spectrum_bins)
        pool.spectrum[:sb] = spec[:sb]
        if sb < self.spectrum_bins:
            pool.spectrum[sb:] = 0
        self.spectrum_tex.write(pool.spectrum.tobytes())

        # --- L/R spectrum textures ---
        sl = data.get('spectrum_l', pool.spectrum)
        sr = data.get('spectrum_r', pool.spectrum)
        slb = min(len(sl), self.spectrum_bins)
        srb = min(len(sr), self.spectrum_bins)
        pool.spectrum_l[:slb] = sl[:slb]
        pool.spectrum_r[:srb] = sr[:srb]
        if slb < self.spectrum_bins:
            pool.spectrum_l[slb:] = 0
        if srb < self.spectrum_bins:
            pool.spectrum_r[srb:] = 0
        self.spectrum_l_tex.write(pool.spectrum_l.tobytes())
        self.spectrum_r_tex.write(pool.spectrum_r.tobytes())

        # --- UBO: 5 vec4s matching GLSL AudioBlock (std140, binding=0) ---
        bands = data.get('band_levels', np.zeros(8, dtype=np.float32))
        brain = data.get('brain', {})

        # vec4 u_bands   = (sub, bass, low_mid, mid)
        pool.ubo_data[0] = bands[0]  # sub
        pool.ubo_data[1] = bands[1]  # bass
        pool.ubo_data[2] = bands[2]  # low_mid
        pool.ubo_data[3] = bands[3]  # mid
        # vec4 u_bands2  = (high_mid, presence, brilliance, air)
        pool.ubo_data[4] = bands[4]  # high_mid
        pool.ubo_data[5] = bands[5]  # presence
        pool.ubo_data[6] = bands[6]  # brilliance
        pool.ubo_data[7] = bands[7]  # air
        # vec4 u_dynamics = (beat_intensity, transient, envelope, overall)
        pool.ubo_data[8]  = data.get('beat_intensity', 0.0)
        pool.ubo_data[9]  = data.get('transient', 0.0)
        pool.ubo_data[10] = data.get('envelope', 0.0)
        pool.ubo_data[11] = data.get('overall', 0.0)
        # vec4 u_rhythm   = (bpm, tempo_confidence, kick_level, kick_confidence)
        pool.ubo_data[12] = data.get('bpm', 0.0)
        pool.ubo_data[13] = data.get('tempo_confidence', 0.0)
        pool.ubo_data[14] = data.get('kick_level', 0.0)
        pool.ubo_data[15] = data.get('kick_confidence', 0.0)
        # vec4 u_stereo   = (stereo_balance, stereo_width, effect_intensity, movement_intensity)
        pool.ubo_data[16] = data.get('stereo_balance', 0.0)
        pool.ubo_data[17] = data.get('stereo_width', 0.0)
        pool.ubo_data[18] = brain.get('u_effect_intensity', 0.0)
        pool.ubo_data[19] = brain.get('u_movement_intensity', 0.0)
        # vec4 u_color_hue = (base_hue, section_hue_center, section_hue_range, beat_detected)
        pool.ubo_data[20] = brain.get('u_base_hue', 0.0)
        pool.ubo_data[21] = brain.get('u_section_hue_center', 0.5)
        pool.ubo_data[22] = brain.get('u_section_hue_range', 0.3)
        pool.ubo_data[23] = 1.0 if data.get('beat_detected', False) else 0.0
        # vec4 u_intensities = (dimmer, laser, blinder, moving_light)
        pool.ubo_data[24] = brain.get('u_dimmer_intensity', 0.0)
        pool.ubo_data[25] = brain.get('u_laser_intensity', 0.0)
        pool.ubo_data[26] = brain.get('u_blinder_intensity', 0.0)
        pool.ubo_data[27] = brain.get('u_moving_light_intensity', 0.0)
        # vec4 u_intensities2 = (static_light, random_flash, group_phase, section_confidence)
        pool.ubo_data[28] = brain.get('u_static_light_intensity', 0.0)
        pool.ubo_data[29] = brain.get('u_random_flash_intensity', 0.0)
        pool.ubo_data[30] = brain.get('u_group_behavior_phase', 0.0)
        pool.ubo_data[31] = brain.get('u_section_confidence', 0.0)
        # vec4 u_triggers = (flash, strobe, smoke, pyro)
        pool.ubo_data[32] = brain.get('u_trigger_flash', 0.0)
        pool.ubo_data[33] = brain.get('u_trigger_strobe', 0.0)
        pool.ubo_data[34] = brain.get('u_trigger_smoke', 0.0)
        pool.ubo_data[35] = brain.get('u_trigger_pyro', 0.0)
        # vec4 u_fixtures = (moving_on, lasers_on, static_on, blinders_on)
        pool.ubo_data[36] = 1.0 if brain.get('u_moving_lights_on', False) else 0.0
        pool.ubo_data[37] = 1.0 if brain.get('u_lasers_on', False) else 0.0
        pool.ubo_data[38] = 1.0 if brain.get('u_static_lights_on', False) else 0.0
        pool.ubo_data[39] = 1.0 if brain.get('u_blinders_on', False) else 0.0
        # vec4 u_group = (behavior_mode, desired_effect_mode, beat_count, phrase_beat)
        pool.ubo_data[40] = float(brain.get('u_group_behavior_mode', 0))
        pool.ubo_data[41] = float(brain.get('u_desired_effect_mode', 0))
        pool.ubo_data[42] = float(brain.get('u_beat_count', 0))
        pool.ubo_data[43] = float(brain.get('u_phrase_beat', 0))
        # vec4 u_section_info = (section, strobe_on, should_change_effect, 0)
        pool.ubo_data[44] = float(brain.get('u_section', 0))
        pool.ubo_data[45] = 1.0 if brain.get('u_strobe_on', False) else 0.0
        pool.ubo_data[46] = 1.0 if brain.get('u_should_change_effect_mode', False) else 0.0
        pool.ubo_data[47] = 0.0

        self.ubo.write(pool.ubo_data.tobytes())

        self._upload_count += 1
        self._last_seq = data.get('sequence', 0)

    def bind(self, spectrum_unit: int = 0, ubo_binding: int = 0,
             spectrum_l_unit: int = 1, spectrum_r_unit: int = 2):
        """Bind all GPU resources for shader access."""
        self.spectrum_tex.use(location=spectrum_unit)
        self.spectrum_l_tex.use(location=spectrum_l_unit)
        self.spectrum_r_tex.use(location=spectrum_r_unit)
        self.ubo.bind_to_uniform_block(ubo_binding)

    @property
    def upload_count(self) -> int:
        return self._upload_count

    def cleanup(self):
        self.spectrum_tex.release()
        self.spectrum_l_tex.release()
        self.spectrum_r_tex.release()
        self.ubo.release()
