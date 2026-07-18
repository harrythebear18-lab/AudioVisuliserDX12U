"""
Audio capture module — re-exports WASAPICapture from wasapi_capture.py.
Provides native C++ WASAPI loopback via DLL, with sounddevice fallback.
"""

from .wasapi_capture import WASAPICapture as AudioCapture
