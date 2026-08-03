# Modular Architecture — RTX Audio Visualizer

**Version: 1.0 — August 2026**

---

## Overview

The RTX Audio Visualizer is a modular system composed of three independent but tightly integrated modules. Each module has a clear boundary, responsibility, and interface contract. Together they form the complete audio visualization pipeline — but each can be understood, validated, and evolved independently.

```
┌─────────────────────────────────────────────────────────────┐
│                    RTX AUDIO VISUALIZER                      │
│                                                             │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────────┐   │
│  │  Resonance  │   │    Show     │   │   RapidSpectrum │   │
│  │     DSP     │──▶│ Controller  │──▶│       RS        │   │
│  │             │   │   /Brain    │   │  Render Engine  │   │
│  │  Audio      │   │  Director,  │   │  DX12 Ultimate  │   │
│  │  Analysis,  │   │  Behavior,  │   │  HDR Pipeline,  │   │
│  │  FFT, LUFS, │   │  Profiles,  │   │  Shaders, PSO,  │   │
│  │  THD, Phase │   │  Colors     │   │  Bloom, Tonemap │   │
│  └─────────────┘   └─────────────┘   └─────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Module 1: Resonance DSP

**Role:** The audio analysis and digital signal processing foundation.

Resonance DSP is responsible for capturing audio, performing FFT analysis, computing psychoacoustic metrics, and producing structured telemetry for downstream modules. It is a self-contained signal processing pipeline that does not depend on any rendering or visual logic.

### Responsibilities

- **WASAPI Audio Capture:** Loopback capture from the system audio endpoint at native sample rate.
- **FFT Analysis:** Sub-microsecond FFT with configurable window size, producing fine-grained spectral bins.
- **Band Extraction:** 8-band crossover (b0–b7) covering sub-bass through air, with perceptual weighting.
- **Psychoacoustic Metrics:**
  - **LUFS** (integrated loudness) — normalized for density and emission control.
  - **THD** (total harmonic distortion) — normalized for roughness and material instability.
  - **Crest Factor** — normalized for sharpness and contrast.
  - **Phase Coherence** — mono/stereo coherence for symmetry and interference.
  - **L/R Peak** — directional bias and local imbalance.
- **Biquad DSP Bands:** 8 DSP-filtered bands that reinforce brain-band regions additively.
- **Beat/Kick/Transient Detection:** Rhythm tracking with tempo confidence, kick confidence, and transient spike detection.
- **Envelope Following:** Smoothed amplitude contour for dynamic range response.
- **Stereo Telemetry:** Width, balance, difference, and spatial position.

### Data Contract

Resonance DSP outputs two structured constant buffers to the GPU:

| Buffer | Register | Contents |
|--------|----------|----------|
| `AudioBrainCB` | `b0` | Beat, transient, envelope, overall energy, 8 bands, stereo width/balance/diff, motion speed, hue base/range/saturation, color pulse, beat anticipation, punch, energy, gated, glow, kick confidence, tempo confidence, section, phrase, brain colors (3), brightness, dynamic, dynLight, beam, atmosphere, isSilent |
| `DspCB` | `b2` | LUFS, crest factor, THD, phase coherence, L/R peaks, 8 DSP biquad bands |

### Key Files

| File | Language | Description |
|------|----------|-------------|
| `audio/audio_engine.py` | Python | Core audio engine — orchestrates capture, FFT, analysis |
| `audio/audio_analyzer.py` | Python | FFT, band extraction, psychoacoustic metric computation |
| `audio/audio_capture.py` | Python | WASAPI loopback capture |
| `audio/wasapi_capture.py` | Python | Low-level WASAPI interface |
| `audio/fft_provider.py` | Python | FFT computation with windowing |
| `audio/tempo_tracker.py` | Python | Beat/kick/transient detection and tempo tracking |
| `audio/vis_brain.py` | Python | Brain telemetry aggregation and color generation |
| `audio/circular_buffer.py` | Python | Lock-free circular audio buffer |
| `shaders/include/audio_cb.hlsl` | HLSL | AudioBrainCB struct definition and `AudioData` adapter |
| `shaders/include/dsp_cb.hlsl` | HLSL | DspCB struct definition and normalized accessor functions |
| `DXRenderer/AudioBridge.cs` | C# | C#-side audio data bridge to GPU constant buffers |

### Design Principles

- DSP is **additive** — it refines brain-driven visuals, never replaces the primary brain signal.
- All metrics are normalized to [0, 1] for stable shader consumption.
- The pipeline operates at audio frame rate, independent of render frame rate.
- Triple-buffered data transfer ensures no audio frame is dropped during render stalls.

---

## Module 2: Show Controller / Brain

**Role:** The creative director, behavior engine, and profile manager.

The Show Controller (also called "the Brain") sits between Resonance DSP and RapidSpectrum. It interprets audio telemetry, manages visual profiles, drives section-aware behavior, selects modes, and provides the creative intelligence that makes the visualizer feel musical rather than mechanical.

### Responsibilities

- **Visual Director:** Autonomous mode selection, scene transitions, and visual behavior based on song structure.
- **Behavior Graph:** Maps audio events (beat, kick, transient, section change) to visual responses (compression, expansion, color shift, burst effects).
- **Profile Management:** Per-song or per-section visual profiles controlling hue palette, saturation, motion speed, dynamic range, and atmosphere.
- **Color System:** Generates `brainCol`, `brainCol2`, `brainCol3` from hue base/range/saturation, section tint, and color pulse.
- **Section/Phrase Tracking:** Detects musical sections and phrases for macro-level visual evolution.
- **Effect Bursts:** Dispatches event-typed flash effects (beat shockwave, kick ring, transient scatter, section flash).
- **Visual Smoother:** Temporal smoothing of visual parameters to prevent jarring transitions.
- **AI Vision Feedback (optional):** CLIP-based scoring and Ollama vision feedback for autonomous quality assessment.

### Data Flow

```
Resonance DSP  ──▶  Show Controller  ──▶  RapidSpectrum
  (raw audio       (interpreted brain     (render commands
   telemetry)       telemetry + profiles)  + shader params)
```

The Show Controller transforms raw DSP metrics into creative decisions:
- Raw beat → beat pulse with tempo confidence weighting
- Raw kick → kick surge with exponential decay
- Raw section → section-aware palette shift and behavior regime change
- Raw envelope → dynamic range gating and brightness modulation

### Key Files

| File | Language | Description |
|------|----------|-------------|
| `DXRenderer/VisualDirectorBot.cs` | C# | Autonomous visual director — mode selection, transitions |
| `DXRenderer/VisualBehaviorGraph.cs` | C# | Behavior graph — audio event to visual response mapping |
| `DXRenderer/VisualSmoother.cs` | C# | Temporal smoothing of visual parameters |
| `DXRenderer/RenderGraph.cs` | C# | Render graph — pass ordering and dependency management |
| `DXRenderer/AdjustmentGraph.cs` | C# | Shader adjustment graph for autonomous tuning |
| `DXRenderer/ShaderAdjustments.cs` | C# | Per-shader parameter adjustments |
| `DXRenderer/AdaptiveShaderProfile.cs` | C# | Adaptive profiling for shader optimization |
| `DXRenderer/MasterShaderProfiles.cs` | C# | Master profile definitions |
| `DXRenderer/ShaderConstraintManifest.cs` | C# | Constraint validation for shader parameters |
| `DXRenderer/CLIPScorer.cs` | C# | CLIP-based visual quality scoring |
| `DXRenderer/CLIPTokenizer.cs` | C# | CLIP tokenizer for vision feedback |
| `DXRenderer/OllamaVisionFeedback.cs` | C# | Ollama-based vision feedback loop |
| `DXRenderer/FastVisionAnalyzer.cs` | C# | Fast vision analysis for real-time feedback |
| `DXRenderer/SubObjectProbe.cs` | C# | Sub-object detection for visual quality |
| `DXRenderer/WorkGraphProbe.cs` | C# | Work graph capability probing |
| `audio/vis_brain.py` | Python | Python-side brain telemetry and color generation |
| `render/brain_hud.py` | Python | Brain HUD display (Python-side) |
| `render/signal_bus.py` | Python | Signal bus — module-to-module communication |

### Design Principles

- The Brain is the **single source of truth** for creative decisions.
- RapidSpectrum never makes creative decisions — it only executes what the Brain commands.
- Resonance DSP never makes creative decisions — it only provides measurements.
- Section changes drive macro evolution; beat/kick drive micro events.
- All visual parameters are smoothed to prevent jarring transitions.

---

## Module 3: RapidSpectrum (RS) — Unified Rendering Engine

**Role:** The GPU rendering engine — executes visual commands from the Show Controller using DX12 Ultimate.

RapidSpectrum is the unified rendering engine that turns brain-directed visual commands into HDR pixels. It owns the GPU pipeline, shader compilation, PSO management, bloom/post-processing/tonemapping chain, and all rendering infrastructure. It does not interpret audio or make creative decisions — it renders what the Brain tells it to render.

### Responsibilities

- **DX12 Ultimate Pipeline:** Device initialization, command queues, descriptor heaps, root signatures, swap chain.
- **Shader Compilation:** DXC (ps_6_6) with FXC fallback, include preprocessing, shader cache.
- **PSO Management:** Graphics pipeline state creation and management for all modes.
- **HDR Render Pipeline:** R16G16B16A16_Float render targets, multi-pass bloom (extract, blur H, blur V, combine), post-FX, tone mapping.
- **Mode Rendering:** 55 visualizer modes (0–54), each with a dedicated pixel shader.
- **Spatial Encoder Modes:** Modes 30–48 use a specialized spatial rendering path with emitter glow and wave rings.
- **SkiaSharp Overlay:** 2D overlay compositor for HUD, diagnostics, and sparse foreground elements.
- **VR/OpenXR:** Stereo rendering with head tracking, IPD, and comfort scaling.
- **HUD Rendering:** Real-time overlay with audio brain metrics, DSP telemetry, pipeline latency, and mode info.
- **Pipeline Validation:** Frame time measurement, HUD/actual discrepancy detection, stall detection.

### Render Pipeline

```
Mode Pixel Shader (HDR)  ──▶  Layer 0 RT (R16G16B16A16)
                                    │
                    ┌───────────────┘
                    ▼
            Bloom Extract ──▶ Bloom Blur H ──▶ Bloom Blur V ──▶ Bloom Combine
                    │
                    ▼
            Post-FX (grain, CA, vignette)
                    │
                    ▼
            Tone Map (HDR → LDR)
                    │
                    ▼
            Skia Composite (overlay)
                    │
                    ▼
            Backbuffer (R8G8B8A8)
```

### Root Signature

| Slot | Type | Register | Binding |
|------|------|----------|---------|
| [0] | CBV | b0 | AudioBrainCB |
| [1] | CBV | b1 | TimeCB |
| [2] | CBV | b2 | DspCB |
| [3] | CBV | b3 | VRCB (OpenXR head pose) |
| [4] | Descriptor Table | t0–t7 | 8 SRVs (spectrum, layers, bloom, feedback, skia, noise) |
| [5] | Descriptor Table | u0–u3 | 4 UAVs (compute, particle, history, debug) |
| s0 | Sampler | — | Linear clamp (spectrum) |
| s1 | Sampler | — | Linear wrap (noise/feedback) |

### Key Files

| File | Language | Description |
|------|----------|-------------|
| `DXRenderer/DX12Renderer.cs` | C# | Core DX12 renderer — device, pipeline, PSO, render loop |
| `DXRenderer/DX12HUD.cs` | C# | HUD overlay rendering |
| `DXRenderer/DX11Renderer.cs` | C# | DX11 fallback renderer |
| `DXRenderer/IGraphicsBackend.cs` | C# | Graphics backend interface |
| `DXRenderer/IRenderer.cs` | C# | Renderer interface |
| `DXRenderer/UnifiedRenderer.cs` | C# | Unified renderer abstraction |
| `DXRenderer/SkiaOverlay.cs` | C# | SkiaSharp 2D overlay compositor |
| `DXRenderer/OpenXRManager.cs` | C# | OpenXR VR integration |
| `DXRenderer/DxcProbe.cs` | C# | DXC compiler capability probing |
| `DXRenderer/PipelineValidator.cs` | C# | Frame time validation and discrepancy logging |
| `DXRenderer/DebugLogger.cs` | C# | Logging infrastructure |
| `DXRenderer/Program.cs` | C# | Main entry point, input handling, mode switching |
| `shaders/dx_*.hlsl` | HLSL | 55 mode pixel shaders |
| `shaders/include/*.hlsl` | HLSL | Shared shader includes (audio_cb, dsp_cb, color_utils, noise, sdf, raymarch, layers, etc.) |
| `shaders/vs_*.hlsl` | HLSL | Vertex shaders |
| `shaders/cs_*.hlsl` | HLSL | Compute shaders |
| `shaders/dx_bloom_*.hlsl` | HLSL | Bloom pipeline shaders |
| `shaders/dx_postfx.hlsl` | HLSL | Post-processing shader |
| `shaders/dx_tonemap.hlsl` | HLSL | Tone mapping shader |
| `shaders/dx_skia_composite.hlsl` | HLSL | Skia compositor shader |

### Design Principles

- RapidSpectrum is a **pure renderer** — no creative decisions, no audio interpretation.
- The HDR pipeline is shared across all modes — no mode applies its own tonemapping or post-FX.
- Shader compilation uses DXC ps_6_6 with FXC ps_5_0 fallback.
- All modes output to the shared Layer 0 HDR render target.
- The bloom/post-FX/tonemap chain is owned by the engine, not individual modes.
- PSO creation is fail-safe — failed modes are skipped without crashing the engine.

---

## Module Interfaces

### Resonance DSP → Show Controller

```
AudioBrainCB (b0):  Beat, Transient, Envelope, Overall, 8 Bands, Stereo, Colors, Section...
DspCB (b2):         LUFS, Crest, THD, Phase, L/R Peaks, 8 DSP Bands
```

The Show Controller reads these buffers and transforms them into creative parameters:
- Beat × tempoConf → beatPulse
- Kick × kickConf × exp(-beatPhase × 3) → kickSurge
- Section → palette shift, behavior regime
- Envelope → dynamic range gating

### Show Controller → RapidSpectrum

The Show Controller provides:
- Current mode index (which pixel shader to use)
- Visual parameters embedded in AudioBrainCB (colors, brightness, dynamic, glow, etc.)
- Effect burst triggers (beatAnt, burstTrig, burstInt, colorPulse)
- Section/phrase state for macro evolution

RapidSpectrum consumes these as-is — it does not re-interpret or override them.

### RapidSpectrum → Display

The final output is an LDR R8G8B8A8 backbuffer, tone-mapped from the HDR pipeline, with optional SkiaSharp overlay composited on top.

---

## Validation and Testing

Each module can be validated independently:

- **Resonance DSP:** Verify FFT output, band levels, LUFS/THD/phase metrics against known test signals.
- **Show Controller:** Verify behavior graph mappings, profile transitions, color generation logic.
- **RapidSpectrum:** Verify shader compilation (DXC ps_6_6), PSO creation, HDR pipeline integrity, frame timing.

The `PipelineValidator` class provides cross-module validation by comparing HUD-reported FPS/latency against actual measured frame times, logging discrepancies and frame drops.

---

## Mode Registry

Modes 0–54 are registered in `DX12Renderer.cs` in two places:
1. `_displayNames` dictionary — user-facing display names
2. `modes` array in `LoadShaders()` — shader file mapping

| Mode Range | Category | Render Path |
|------------|----------|-------------|
| 0–29 | Original modes | Full bloom pipeline + SkiaSharp overlay |
| 30–48 | Spatial encoder modes | Spatial path (emitter glow, wave rings, reduced bloom) |
| 49–54 | Advanced modes | Full bloom pipeline + SkiaSharp overlay |

---

© 2026 RTX Audio Visualizer. All rights reserved.
