"""
GPU renderer with multi-pass FBO pipeline, compute-shader particle system,
and postprocessing (bloom + chromatic aberration + film grain).

Architecture:
  1. Scene pass → renders visualization into FBO (raymarching / particles / geometry)
  2. Bloom pass → bright-pass blur of scene FBO
  3. Composite pass → scene + bloom + chromatic aberration + vignette + grain → screen

All audio data is uploaded as a 1D texture and SSBO uniform block so every
shader stage has access to the 8-band brain state.
"""

import os
import numpy as np
import moderngl
from render.signal_bus import SignalBus
from render.brain_hud import BrainHUD

SHADER_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'shaders')

# Fullscreen quad vertices (position.xy, texcoord.xy)
QUAD_VERTICES = np.array([
    -1.0, -1.0,  0.0, 0.0,
     1.0, -1.0,  1.0, 0.0,
    -1.0,  1.0,  0.0, 1.0,
     1.0,  1.0,  1.0, 1.0,
], dtype=np.float32)


_UBO_BLOCK = None

def _get_ubo_block() -> str:
    """Load and cache the shared UBO block definition (without #version line)."""
    global _UBO_BLOCK
    if _UBO_BLOCK is None:
        with open(os.path.join(SHADER_DIR, 'audio_ubo.glsl'), 'r') as f:
            raw = f.read()
        # Strip the #version line — the host shader already has one
        lines = raw.split('\n')
        _UBO_BLOCK = '\n'.join(l for l in lines if not l.strip().startswith('#version'))
    return _UBO_BLOCK

def _load_shader(name: str, inject_ubo: bool = False) -> str:
    """Load shader from file. If inject_ubo, insert the shared UBO block after the #version line."""
    path = os.path.join(SHADER_DIR, name)
    with open(path, 'r') as f:
        source = f.read()
    if inject_ubo:
        # GLSL requires #version to be the first statement — inject UBO after it
        lines = source.split('\n')
        insert_idx = 0
        for i, line in enumerate(lines):
            if line.strip().startswith('#version'):
                insert_idx = i + 1
                break
        lines.insert(insert_idx, _get_ubo_block())
        source = '\n'.join(lines)
    return source


class GPURenderer:
    def __init__(self, ctx: moderngl.Context, width: int, height: int, spectrum_bins: int):
        self.ctx = ctx
        self.width = width
        self.height = height
        self.spectrum_bins = spectrum_bins

        # Shared fullscreen quad
        self._quad_vbo = ctx.buffer(QUAD_VERTICES.tobytes())

        # --- Scene FBO (HDR) ---
        self._scene_fbo = ctx.framebuffer(
            color_attachments=[ctx.texture((width, height), 3, dtype='f4')],
            depth_attachment=ctx.depth_renderbuffer((width, height)),
        )
        self._scene_color = self._scene_fbo.color_attachments[0]
        self._scene_color.filter = (moderngl.LINEAR, moderngl.LINEAR)

        # --- Bloom FBO (half-res) ---
        bw, bh = width // 2, height // 2
        self._bloom_fbo = ctx.framebuffer(
            color_attachments=[ctx.texture((bw, bh), 3, dtype='f4')],
        )
        self._bloom_color = self._bloom_fbo.color_attachments[0]
        self._bloom_color.filter = (moderngl.LINEAR, moderngl.LINEAR)

        # --- RDMA Signal Bus: single-transfer GPU upload channel ---
        self.signal_bus = SignalBus(ctx, spectrum_bins)

        # --- Brain HUD overlay (replicates StageSim HUD) ---
        self.hud = BrainHUD(ctx, width, height)

        # --- Programs ---
        self._init_programs()
        self._init_particle_system()

        # State
        self._time = 0.0
        self._current_mode = 0
        self._modes = ['spectrum_bars', 'matrix_rain', 'wave_pool', 'reactive_metal', 'aurora', 'particle_galaxy', 'neon_tunnel']
        self._flash_strength = 0.0
        self._strobe_active = False
        self._strobe_timer = 0.0

        print(f"[GPURenderer] Initialized: {width}x{height}, {spectrum_bins} bins, "
              f"{self._num_particles} particles")

    def _init_programs(self):
        # Scene programs (one per mode)
        self._scene_programs = []
        scene_modes = ['spectrum_bars', 'matrix_rain', 'wave_pool', 'reactive_metal', 'aurora', 'particle_galaxy', 'neon_tunnel']
        for mode in scene_modes:
            fs_name = f'scene_{mode}_frag.glsl'
            try:
                prog = self.ctx.program(
                    vertex_shader=_load_shader('fullscreen_vert.glsl'),
                    fragment_shader=_load_shader(fs_name, inject_ubo=True),
                )
                self._scene_programs.append(prog)
            except Exception as e:
                print(f"[GPURenderer] Failed to load {fs_name}: {e}")
                # Fallback: use nebula
                prog = self.ctx.program(
                    vertex_shader=_load_shader('fullscreen_vert.glsl'),
                    fragment_shader=_load_shader('scene_nebula_frag.glsl', inject_ubo=True),
                )
                self._scene_programs.append(prog)

        # Bloom bright-pass + blur
        self._bloom_program = self.ctx.program(
            vertex_shader=_load_shader('fullscreen_vert.glsl'),
            fragment_shader=_load_shader('bloom_frag.glsl'),
        )  # bloom doesn't need audio UBO

        # Postprocess (composite + chromatic aberration + vignette + grain)
        self._post_program = self.ctx.program(
            vertex_shader=_load_shader('fullscreen_vert.glsl'),
            fragment_shader=_load_shader('postprocess_frag.glsl', inject_ubo=True),
        )

        # Particle compute shader
        try:
            self._particle_compute = self.ctx.compute_shader(
                _load_shader('particles_compute.glsl', inject_ubo=True)
            )
        except Exception as e:
            print(f"[GPURenderer] Compute shader failed: {e}")
            self._particle_compute = None

        # Particle render program
        self._particle_program = self.ctx.program(
            vertex_shader=_load_shader('particle_vert.glsl', inject_ubo=True),
            fragment_shader=_load_shader('particle_frag.glsl'),
        )

        # VAOs for fullscreen passes
        self._quad_vao = self.ctx.vertex_array(
            self._scene_programs[0],
            [(self._quad_vbo, '2f 2f', 'a_pos', 'a_uv')],
        )

    def _init_particle_system(self):
        self._num_particles = 100_000
        # SSBO: pos.xyz, vel.xyz, life, size = 8 floats per particle
        self._particle_ssbo = self.ctx.buffer(reserve=self._num_particles * 8 * 4, dynamic=True)

        # Initialize particle data on CPU then upload
        data = np.zeros(self._num_particles * 8, dtype=np.float32)
        for i in range(self._num_particles):
            idx = i * 8
            # Spherical distribution
            theta = np.random.uniform(0, 2 * np.pi)
            phi = np.arccos(np.random.uniform(-1, 1))
            r = np.random.uniform(0.5, 3.0)
            data[idx]     = r * np.sin(phi) * np.cos(theta)   # x
            data[idx + 1] = r * np.sin(phi) * np.sin(theta)   # y
            data[idx + 2] = r * np.cos(phi)                   # z
            # Velocity
            data[idx + 3] = np.random.uniform(-0.1, 0.1)
            data[idx + 4] = np.random.uniform(-0.1, 0.1)
            data[idx + 5] = np.random.uniform(-0.1, 0.1)
            # Life + size
            data[idx + 6] = np.random.uniform(0, 1)
            data[idx + 7] = np.random.uniform(1.0, 4.0)
        self._particle_ssbo.write(data.tobytes())

        # Particle VAO
        self._particle_vao = self.ctx.vertex_array(
            self._particle_program,
            [(self._particle_ssbo, '3f 3f f f', 'a_position', 'a_velocity', 'a_life', 'a_size')],
        )

        # Bind SSBO to compute shader
        if self._particle_compute is not None:
            self._particle_ssbo.bind_to_storage_buffer(0)

    def set_mode(self, mode_name: str):
        if mode_name in self._modes:
            self._current_mode = self._modes.index(mode_name)

    def next_mode(self):
        self._current_mode = (self._current_mode + 1) % len(self._modes)
        print(f"[GPURenderer] Mode: {self._modes[self._current_mode]}")

    def get_mode(self) -> str:
        return self._modes[self._current_mode]

    def resize(self, width: int, height: int):
        self.width = width
        self.height = height
        # Recreate FBOs
        self._scene_fbo = self.ctx.framebuffer(
            color_attachments=[self.ctx.texture((width, height), 3, dtype='f4')],
            depth_attachment=self.ctx.depth_renderbuffer((width, height)),
        )
        self._scene_color = self._scene_fbo.color_attachments[0]
        self._scene_color.filter = (moderngl.LINEAR, moderngl.LINEAR)

        bw, bh = width // 2, height // 2
        self._bloom_fbo = self.ctx.framebuffer(
            color_attachments=[self.ctx.texture((bw, bh), 3, dtype='f4')],
        )
        self._bloom_color = self._bloom_fbo.color_attachments[0]
        self._bloom_color.filter = (moderngl.LINEAR, moderngl.LINEAR)

    def render(self, audio_data: dict, dt: float):
        if audio_data is None:
            audio_data = self._zero_data()

        self._time += dt

        # Update flash/strobe decay
        self._flash_strength = max(0.0, self._flash_strength - dt * 4.0)
        brain = audio_data.get('brain', {})
        if brain.get('u_trigger_flash', 0) > 0:
            self._flash_strength = 1.0
        if brain.get('u_trigger_strobe', 0) > 0:
            self._strobe_active = True
            self._strobe_timer = 0.3
        if self._strobe_active:
            self._strobe_timer -= dt
            if self._strobe_timer <= 0:
                self._strobe_active = False

        # --- RDMA: single-transfer upload via SignalBus ---
        self.signal_bus.upload(audio_data)
        self.signal_bus.bind(spectrum_unit=0, ubo_binding=0, spectrum_l_unit=1, spectrum_r_unit=2)

        # --- Compute shader: update particles on GPU ---
        if self._particle_compute is not None:
            self._particle_compute['u_time'].value = self._time
            self._particle_compute['u_dt'].value = dt
            self._particle_compute['u_spectrum'].value = 0
            workgroups = (self._num_particles + 63) // 64
            self._particle_compute.run(workgroups, 1, 1)

        # --- Pass 1: Scene render ---
        self._render_scene(audio_data)

        # --- Pass 2: Bloom ---
        self._render_bloom()

        # --- Pass 3: Postprocess (composite to screen) ---
        self._render_postprocess(audio_data)

        # --- Pass 4: Brain HUD overlay ---
        self.hud.render(audio_data, dt)

    def _render_scene(self, audio_data: dict):
        self._scene_fbo.use()
        self.ctx.viewport = (0, 0, self.width, self.height)
        self.ctx.clear(0.0, 0.0, 0.0, 1.0)

        mode = self._current_mode
        if mode >= len(self._scene_programs):
            mode = 0
        prog = self._scene_programs[mode]

        # Rebuild VAO with correct program
        vao = self.ctx.vertex_array(prog, [(self._quad_vbo, '2f 2f', 'a_pos', 'a_uv')])

        # Set uniforms safely
        self._set_common_uniforms(prog, audio_data)
        if 'u_time' in prog:
            prog['u_time'].value = self._time
        if 'u_resolution' in prog:
            prog['u_resolution'].value = (self.width, self.height)
        if 'u_spectrum' in prog:
            prog['u_spectrum'].value = 0

        vao.render(moderngl.TRIANGLE_STRIP)

        # Render particles on top if in a mode that uses them
        # (currently no modes use the particle system, but it's available)
        # if mode == X: self._render_particles(audio_data)

    def _render_particles(self, audio_data: dict):
        prog = self._particle_program
        if 'u_time' in prog:
            prog['u_time'].value = self._time
        if 'u_resolution' in prog:
            prog['u_resolution'].value = (self.width, self.height)
        brain = audio_data.get('brain', {})
        color = brain.get('u_color', (1.0, 0.0, 0.0))
        color2 = brain.get('u_color2', (1.0, 0.0, 0.4))
        if 'u_color' in prog:
            prog['u_color'].value = color
        if 'u_color2' in prog:
            prog['u_color2'].value = color2
        if 'u_beat_intensity' in prog:
            prog['u_beat_intensity'].value = audio_data.get('beat_intensity', 0.0)
        if 'u_overall' in prog:
            prog['u_overall'].value = audio_data.get('overall', 0.0)
        if 'u_kick_level' in prog:
            prog['u_kick_level'].value = audio_data.get('kick_level', 0.0)

        self.ctx.enable(moderngl.BLEND)
        self.ctx.blend_func = moderngl.SRC_ALPHA, moderngl.ONE  # additive
        self._particle_vao.render(moderngl.POINTS, vertices=self._num_particles)
        self.ctx.blend_func = moderngl.SRC_ALPHA, moderngl.ONE_MINUS_SRC_ALPHA

    def _render_bloom(self):
        self._bloom_fbo.use()
        self.ctx.viewport = (0, 0, self._bloom_fbo.size[0], self._bloom_fbo.size[1])
        self.ctx.clear(0.0, 0.0, 0.0, 1.0)

        vao = self.ctx.vertex_array(self._bloom_program, [(self._quad_vbo, '2f 2f', 'a_pos', 'a_uv')])
        self._scene_color.use(location=0)
        if 'u_scene' in self._bloom_program:
            self._bloom_program['u_scene'].value = 0
        self._bloom_program['u_resolution'].value = self._bloom_fbo.size
        vao.render(moderngl.TRIANGLE_STRIP)

    def _render_postprocess(self, audio_data: dict):
        # Render to default framebuffer (screen)
        self.ctx.screen.use()
        self.ctx.viewport = (0, 0, self.width, self.height)
        self.ctx.clear(0.0, 0.0, 0.0, 1.0)

        vao = self.ctx.vertex_array(self._post_program, [(self._quad_vbo, '2f 2f', 'a_pos', 'a_uv')])

        self._scene_color.use(location=0)
        self._bloom_color.use(location=1)
        if 'u_scene' in self._post_program:
            self._post_program['u_scene'].value = 0
        if 'u_bloom' in self._post_program:
            self._post_program['u_bloom'].value = 1

        self._post_program['u_time'].value = self._time
        self._post_program['u_resolution'].value = (self.width, self.height)
        self._post_program['u_flash'].value = self._flash_strength
        self._post_program['u_strobe'].value = 1.0 if self._strobe_active else 0.0

        brain = audio_data.get('brain', {})
        color = brain.get('u_color', (1.0, 0.0, 0.0))
        self._post_program['u_tint'].value = color

        vao.render(moderngl.TRIANGLE_STRIP)

    def _set_common_uniforms(self, prog, audio_data: dict):
        brain = audio_data.get('brain', {})
        color = brain.get('u_color', (1.0, 0.0, 0.0))
        color2 = brain.get('u_color2', (1.0, 0.0, 0.4))

        # Only set non-UBO uniforms (colors and section are still regular uniforms)
        if 'u_color' in prog:
            prog['u_color'].value = color
        if 'u_color2' in prog:
            prog['u_color2'].value = color2
        if 'u_section' in prog:
            prog['u_section'].value = int(brain.get('u_section', 0))

    def _zero_data(self) -> dict:
        return {
            'spectrum': np.zeros(self.spectrum_bins, dtype=np.float32),
            'band_levels': np.zeros(8, dtype=np.float32),
            'beat_intensity': 0.0, 'transient': 0.0, 'envelope': 0.0,
            'overall': 0.0, 'bpm': 0.0, 'tempo_confidence': 0.0,
            'kick_level': 0.0, 'kick_confidence': 0.0, 'is_silent': True,
            'stereo_balance': 0.0, 'stereo_width': 0.0,
            'beat_detected': False,
            'brain': {
                'u_color': (0.5, 0.5, 0.5), 'u_color2': (0.3, 0.3, 0.3),
                'u_effect_intensity': 0.0, 'u_movement_intensity': 0.0,
                'u_base_hue': 0.0, 'u_section_hue_center': 0.5,
                'u_section_hue_range': 0.3, 'u_section': 0,
                'u_trigger_flash': 0.0, 'u_trigger_strobe': 0.0,
            }
        }

    def cleanup(self):
        for prog in self._scene_programs:
            prog.release()
        self._bloom_program.release()
        self._post_program.release()
        self._particle_program.release()
        if self._particle_compute is not None:
            self._particle_compute.release()
        self._quad_vbo.release()
        self._particle_ssbo.release()
        self.signal_bus.cleanup()
        self._scene_fbo.release()
        self._bloom_fbo.release()
