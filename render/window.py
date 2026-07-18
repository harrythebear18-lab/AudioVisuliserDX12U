"""
Window manager — pygame + ModernGL OpenGL 4.6 context for RTX GPUs.
Handles window creation, input, resize, and the main render loop.
"""

import pygame
import moderngl
import ctypes
import numpy as np


class Window:
    def __init__(self, width=1280, height=720, title="RTX Audio Visualizer"):
        self.width = width
        self.height = height
        self.title = title
        self.ctx = None
        self.screen = None
        self.clock = pygame.time.Clock()
        self.fps = 0.0
        self._frame_count = 0
        self.running = False

    def init(self):
        pygame.init()

        # DPI awareness
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(2)
        except Exception:
            try:
                ctypes.windll.user32.SetProcessDPIAware()
            except Exception:
                pass

        # OpenGL 4.6 core profile
        pygame.display.gl_set_attribute(pygame.GL_CONTEXT_MAJOR_VERSION, 4)
        pygame.display.gl_set_attribute(pygame.GL_CONTEXT_MINOR_VERSION, 6)
        pygame.display.gl_set_attribute(pygame.GL_CONTEXT_PROFILE_MASK,
                                        pygame.GL_CONTEXT_PROFILE_CORE)
        pygame.display.gl_set_attribute(pygame.GL_DOUBLEBUFFER, 1)
        pygame.display.gl_set_attribute(pygame.GL_DEPTH_SIZE, 24)
        pygame.display.gl_set_attribute(pygame.GL_STENCIL_SIZE, 8)
        pygame.display.gl_set_attribute(pygame.GL_MULTISAMPLEBUFFERS, 1)
        pygame.display.gl_set_attribute(pygame.GL_MULTISAMPLESAMPLES, 4)

        flags = pygame.OPENGL | pygame.DOUBLEBUF | pygame.RESIZABLE
        self.screen = pygame.display.set_mode((self.width, self.height), flags)
        pygame.display.set_caption(self.title)

        # Center window
        try:
            hwnd = pygame.display.get_wm_info()['window']
            rect = ctypes.wintypes.RECT()
            ctypes.windll.user32.GetWindowRect(hwnd, ctypes.byref(rect))
            win_w = rect.right - rect.left
            win_h = rect.bottom - rect.top
            sw = ctypes.windll.user32.GetSystemMetrics(0)
            sh = ctypes.windll.user32.GetSystemMetrics(1)
            ctypes.windll.user32.SetWindowPos(hwnd, 0, (sw - win_w) // 2, (sh - win_h) // 2, 0, 0,
                                              0x0001 | 0x0004)
        except Exception:
            pass

        self.ctx = moderngl.create_context(require=460)
        self.ctx.enable(moderngl.PROGRAM_POINT_SIZE)
        self.ctx.enable(moderngl.BLEND)
        self.ctx.blend_func = moderngl.SRC_ALPHA, moderngl.ONE_MINUS_SRC_ALPHA

        # Print GPU info
        info = self.ctx.info
        print(f"\n=== GPU ===")
        print(f"  Renderer: {info.get('GL_RENDERER', '?')}")
        print(f"  Version:  {info.get('GL_VERSION', '?')}")
        print(f"  GLSL:     {info.get('GLSL_VERSION', '?')}")
        print(f"  Max Texture: {info.get('GL_MAX_TEXTURE_SIZE', '?')}")
        print(f"  Max SSBO: {info.get('GL_MAX_SHADER_STORAGE_BLOCK_SIZE', 0) / 1024 / 1024:.0f} MB")
        print(f"==========\n")

    def handle_events(self) -> str | bool:
        """Returns 'next_mode', 'prev_mode', 'toggle_fullscreen', or True/False."""
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                return False
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    return False
                elif event.key == pygame.K_m:
                    return 'next_mode'
                elif event.key == pygame.K_n:
                    return 'prev_mode'
                elif event.key == pygame.K_f:
                    return 'toggle_fullscreen'
                elif event.key == pygame.K_h:
                    return 'toggle_hud'
            elif event.type == pygame.VIDEORESIZE:
                self.width = event.w
                self.height = event.h
                self.ctx.viewport = (0, 0, event.w, event.h)
                return ('resize', event.w, event.h)
        return True

    def flip(self, target_fps=0):
        pygame.display.flip()
        if target_fps > 0:
            dt = self.clock.tick(target_fps) / 1000.0
        else:
            dt = self.clock.tick() / 1000.0
        self._frame_count += 1
        if self._frame_count % 30 == 0:
            self.fps = self.clock.get_fps()
        return dt

    def toggle_fullscreen(self):
        flags = pygame.OPENGL | pygame.DOUBLEBUF
        if self.screen.get_flags() & pygame.FULLSCREEN:
            flags |= pygame.RESIZABLE
            pygame.display.set_mode((self.width, self.height), flags)
        else:
            flags |= pygame.FULLSCREEN
            pygame.display.set_mode((self.width, self.height), flags)
        self.ctx.viewport = (0, 0, self.width, self.height)

    def cleanup(self):
        if self.ctx:
            self.ctx.release()
        pygame.quit()
