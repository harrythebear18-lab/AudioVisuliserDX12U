"""
Brain HUD — replicates the StageSim WASAPI overlay for the visualizer.
Renders brain/analyzer state as a text overlay on top of the GPU scene.
Uses pygame font rendering → texture → ModernGL fullscreen quad blit.
"""

import pygame
import moderngl
import numpy as np

# Quad will be rebuilt dynamically with correct position + UVs
_QUAD = np.zeros(16, dtype=np.float32)

_VERT = """
#version 460 core
in vec2 a_pos;
in vec2 a_uv;
out vec2 v_uv;
void main() {
    v_uv = a_uv;
    gl_Position = vec4(a_pos, 0.0, 1.0);
}
"""

_FRAG = """
#version 460 core
in vec2 v_uv;
out vec4 frag_color;
uniform sampler2D u_tex;
void main() {
    frag_color = texture(u_tex, v_uv);
}
"""

_SECTION_NAMES = [
    "Unknown", "Intro", "Verse", "PreChorus", "Chorus",
    "BuildUp", "Drop", "Breakdown", "Bridge", "Interlude", "Outro"
]


class BrainHUD:
    def __init__(self, ctx: moderngl.Context, width: int, height: int):
        self.ctx = ctx
        self.width = width
        self.height = height

        # Pygame font for text rendering
        pygame.font.init()
        self._font = pygame.font.SysFont("Consolas", 11)
        self._font_small = pygame.font.SysFont("Consolas", 10)

        # Shader program for blitting text texture
        self._prog = ctx.program(vertex_shader=_VERT, fragment_shader=_FRAG)
        self._quad_vbo = ctx.buffer(_QUAD.tobytes(), dynamic=True)
        self._vao = ctx.vertex_array(self._prog, [(self._quad_vbo, '2f 2f', 'a_pos', 'a_uv')])

        # Dynamic texture (recreated each frame)
        self._tex = None
        self._tex_w = 0
        self._tex_h = 0

        # HUD visibility
        self.visible = True
        self._update_timer = 0.0
        self._cached_lines = []

    def toggle(self):
        self.visible = not self.visible

    def _build_hud_text(self, audio_data: dict) -> list[str]:
        """Build the HUD text lines matching StageSim format."""
        if not audio_data:
            return ["[No audio data]"]

        bands = audio_data.get('band_levels', [0]*8)
        brain = audio_data.get('brain', {})
        beat_int = audio_data.get('beat_intensity', 0)
        transient = audio_data.get('transient', 0)
        envelope = audio_data.get('envelope', 0)
        overall = audio_data.get('overall', 0)
        bpm = audio_data.get('bpm', 0)
        tempo_conf = audio_data.get('tempo_confidence', 0)
        kick = audio_data.get('kick_level', 0)
        kick_conf = audio_data.get('kick_confidence', 0)
        beat_det = audio_data.get('beat_detected', False)
        is_silent = audio_data.get('is_silent', False)
        stereo_bal = audio_data.get('stereo_balance', 0)
        stereo_w = audio_data.get('stereo_width', 0)
        left_e = audio_data.get('left_energy', 0)
        right_e = audio_data.get('right_energy', 0)
        section_idx = brain.get('u_section', 0)
        section_name = _SECTION_NAMES[section_idx] if section_idx < len(_SECTION_NAMES) else "?"
        effect_int = brain.get('u_effect_intensity', 0)
        move_int = brain.get('u_movement_intensity', 0)
        base_hue = brain.get('u_base_hue', 0)
        color = brain.get('u_color', (0, 0, 0))
        color2 = brain.get('u_color2', (0, 0, 0))
        flash = brain.get('u_trigger_flash', 0) > 0
        strobe = brain.get('u_trigger_strobe', 0) > 0

        lines = []
        lines.append(("WASAPI Loopback: ", f"{'ON' if not is_silent else 'OFF'}", (0.3, 1.0, 0.3) if not is_silent else (1.0, 0.3, 0.3)))
        lines.append(("AudioPipeline: ", "ACTIVE", (0.3, 1.0, 0.3)))
        lines.append(("", "", (1, 1, 1)))
        lines.append((f"Beat:{beat_int:.3f} ", f"Trans:{transient:.3f} Env:{envelope:.3f}", (1, 1, 1)))
        lines.append((f"Sub:{bands[0]:.3f} ", f"Bass:{bands[1]:.3f} LMid:{bands[2]:.3f}", (1, 1, 1)))
        lines.append((f"Mid:{bands[3]:.3f} ", f"HMid:{bands[4]:.3f}", (1, 1, 1)))
        lines.append((f"Pres:{bands[5]:.3f} ", f"Bril:{bands[6]:.3f} Air:{bands[7]:.3f}", (1, 1, 1)))
        lines.append((f"Overall:{overall:.3f} ", f"Silent:{'Y' if is_silent else 'N'} Dom:{max(range(8), key=lambda i: bands[i])} Beat!:{'Y' if beat_det else 'N'}", (1, 1, 1)))
        lines.append((f"BPM:{bpm:.1f} ", f"Conf:{tempo_conf:.2f} Kick:{kick_conf:.2f}", (1, 1, 1)))
        lines.append((f"Stereo: ", f"L{left_e:.6f} R{right_e:.6f}", (0.8, 1.0, 0.8)))
        lines.append((f"  Bal:{stereo_bal:.2f} ", f"W:{stereo_w:.2f}", (1, 1, 1)))
        # Advanced analysis
        beat_ant = brain.get('u_beat_anticipation', 0)
        spectral_clarity = brain.get('u_spectral_clarity', 0)
        motion_persist = brain.get('u_motion_persistence', 0)
        lines.append((f"Anticip:{beat_ant:.2f} ", f"Clarity:{spectral_clarity:.2f} Persist:{motion_persist:.2f}", (0.8, 0.8, 1)))
        lines.append(("", "", (1, 1, 1)))
        phrase_beat = int(brain.get('u_phrase_beat', 0))
        lines.append((f"Section:{section_name} ", f"Phrase:{phrase_beat}/16 Eff:{effect_int:.2f}", (1, 0.8, 0.3)))
        lines.append((f"Move:{move_int:.2f} ", f"Hue:{base_hue:.3f}", (0.8, 0.8, 1)))
        lines.append((f"Color:({color[0]:.2f},{color[1]:.2f},{color[2]:.2f}) ", f"Color2:({color2[0]:.2f},{color2[1]:.2f},{color2[2]:.2f})", (color[0], color[1], color[2])))
        triggers = []
        if flash: triggers.append("FLASH")
        if strobe: triggers.append("STROBE")
        if triggers:
            lines.append((f"Triggers: ", " ".join(triggers), (1, 0.5, 0.2)))
        else:
            lines.append(("Triggers: ", "-", (0.5, 0.5, 0.5)))

        return lines

    def _render_to_texture(self, lines: list):
        """Render text lines to a pygame surface, then upload as GL texture."""
        # Calculate surface size
        line_h = 13
        padding = 6
        surf_w = 320
        surf_h = len(lines) * line_h + padding * 2

        # Create transparent surface
        surf = pygame.Surface((surf_w, surf_h), pygame.SRCALPHA)
        surf.fill((0, 0, 0, 140))  # semi-transparent dark background

        y = padding
        for item in lines:
            if len(item) == 3:
                label, value, color = item
            else:
                label, value, color = item, "", (1, 1, 1)

            # Convert float color to 0-255
            r, g, b = int(color[0]*255), int(color[1]*255), int(color[2]*255)

            # Render label
            label_surf = self._font.render(label, True, (200, 200, 200))
            surf.blit(label_surf, (padding, y))

            # Render value in color
            value_surf = self._font.render(value, True, (r, g, b))
            surf.blit(value_surf, (padding + label_surf.get_width(), y))

            y += line_h

        # Convert to numpy array for ModernGL
        data = pygame.image.tostring(surf, "RGBA")
        data = np.frombuffer(data, dtype=np.uint8)

        # Recreate texture if size changed
        if self._tex is None or self._tex_w != surf_w or self._tex_h != surf_h:
            if self._tex is not None:
                self._tex.release()
            self._tex = self.ctx.texture((surf_w, surf_h), 4, dtype='f1')
            self._tex.filter = (moderngl.LINEAR, moderngl.LINEAR)
            self._tex_w = surf_w
            self._tex_h = surf_h

        self._tex.write(data)

        # Build quad in top-left corner, flipped V for OpenGL
        # Screen NDC: top-left = (-1, 1), so we map texture top→top
        px = float(surf_w) / float(self.width) * 2.0  # width in NDC
        py = float(surf_h) / float(self.height) * 2.0  # height in NDC
        x0 = -1.0
        x1 = -1.0 + px
        y0 = 1.0 - py  # top of screen
        y1 = 1.0       # bottom of hud
        # UVs: flip V so text is right-side up
        quad = np.array([
            x0, y0, 0.0, 1.0,  # bottom-left  → uv (0, 1)
            x1, y0, 1.0, 1.0,  # bottom-right → uv (1, 1)
            x0, y1, 0.0, 0.0,  # top-left     → uv (0, 0)
            x1, y1, 1.0, 0.0,  # top-right    → uv (1, 0)
        ], dtype=np.float32)
        self._quad_vbo.write(quad.tobytes())

    def render(self, audio_data: dict, dt: float):
        if not self.visible:
            return

        # Update text every 50ms (20fps for HUD)
        self._update_timer -= dt
        if self._update_timer <= 0 or not self._cached_lines:
            self._update_timer = 0.05
            self._cached_lines = self._build_hud_text(audio_data)

        self._render_to_texture(self._cached_lines)

        # Blit text texture on top of scene
        if self._tex is not None:
            self._tex.use(0)
            self._prog['u_tex'].value = 0
            self.ctx.enable(moderngl.BLEND)
            self.ctx.blend_func = moderngl.SRC_ALPHA, moderngl.ONE_MINUS_SRC_ALPHA
            self.ctx.disable(moderngl.DEPTH_TEST)
            self._vao.render(moderngl.TRIANGLE_STRIP)
            self.ctx.enable(moderngl.DEPTH_TEST)

    def resize(self, width: int, height: int):
        self.width = width
        self.height = height
