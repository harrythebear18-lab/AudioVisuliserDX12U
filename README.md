# RTX Audio Visualizer DX12U

A high-fidelity, real-time GPU audio visualizer for Windows, built on **DirectX 12 Ultimate** with HLSL shader-based rendering. It captures system audio via WASAPI, performs FFT analysis through a C# audio pipeline, and drives 50 distinct visualization modes rendered entirely on the GPU. Modes 29–49 use a shared **spatial encoder** backend with psychoacoustic spatial mapping and **OpenXR VR support**.

## Features

- **50 visualization modes** — from spectrum bars to raymarched fractals, psychoacoustic spatial visualizations, and VR-native audio field rendering
- **Psychoacoustic spatial modes** — modes 29–49 visualize auditory phenomena: interaural level/time differences, room impulse response, spectral masking, critical bands, standing waves, and more
- **OpenXR VR support** — stereo rendering with head tracking, IPD offset, VR comfort guidelines (brightness caps, stable horizon, 16-source culling)
- **Spatial encoder backend** — shared `spatial_encoder.hlsl` maps audio data to 3D positions using psychoacoustic profiles (spherical, radial, tunnel, hemisphere, wave field, psychoacoustic)
- **Real-time audio analysis** — WASAPI loopback capture, 8-band spectrum analyzer, tempo/beat detection, kick/transient detection, LUFS, crest factor, THD, phase coherence
- **Fully GPU-rendered** — all visuals are pixel shaders in HLSL, compiled at runtime via DXC
- **DX12 Ultimate support** — leverages DXR, mesh shaders, and work graphs where available
- **Audio-reactive everything** — bass, mids, highs, kick, beat, transient, stereo balance, LUFS, crest, THD, phase coherence, and spectrum data all feed into shader uniforms
- **Soft tone mapping + additive budget** — Reinhard tone mapping and active-emitter normalization prevent brightness stacking on busy music tracks
- **Ollama vision feedback** — optional AI-driven visual quality assessment loop

## Architecture

```
AudioPipeline (C# DLL)
    └── WASAPI Capture → FFT → 8-Band Analyzer → LightingBrain
         ↓
    RDMA Triple Buffer (zero-copy GPU upload)
         ↓
    DX12Renderer (C#)
    └── HLSL Pixel Shaders (50 modes, runtime-compiled via DXC)
         └── Audio constant buffers + spectrum textures → shader uniforms
```

### Components

| Component | Description |
|-----------|-------------|
| `AudioPipeline/` | C# DLL — WASAPI audio capture, FFT, band analysis, tempo/kick detection |
| `DXRenderer/` | C# DX12 renderer — swap chain, shader compilation, constant buffers, mode management |
| `RDMAReader/` | RDMA signal backbone — triple-buffered zero-copy data transfer |
| `shaders/` | 50 HLSL pixel shaders + shared includes (audio, noise, SDF, raymarch, postfx, spatial encoder) |
| `shaders/include/` | Shared shader libraries — `audio_cb.hlsl`, `noise.hlsl`, `sdf.hlsl`, `raymarch.hlsl`, `postfx.hlsl`, `audio_reactive.hlsl`, `layers.hlsl`, `color_utils.hlsl`, `dsp_cb.hlsl`, `spatial_encoder.hlsl` |
| `DXRenderer/OpenXRManager.cs` | OpenXR VR integration — stereo rendering, head pose, IPD, comfort settings |
| `audio/` | Python audio engine bridge (legacy/alternative path) |
| `render/` | Python GPU renderer bridge (legacy/alternative path) |
| `electron/` | Electron-based UI shell |
| `models/` | ONNX models for CLIP-based vision feedback |
| `native/` | Pre-built native DLLs (AudioPipeline, WASAPI) |

## Visualization Modes

| # | Key | Name | Description |
|---|-----|------|-------------|
| 0 | `quantum_bars` | Quantum Bars | 3D spectrum bars with quantum clouds |
| 1 | `plasma_field` | Plasma Field | Domain-warped FBM fluid |
| 2 | `neon_pulse` | Neon Pulse | Concentric rings + waveform |
| 3 | `particle_flow` | Particle Flow | Curl-noise vector field |
| 4 | `waveform` | Spectrum Ribbons | Multi-layer 3D waveform ribbons |
| 5 | `sphere` | Spectrum Resonator | Raymarched displaced sphere + aura |
| 6 | `aurora` | Aurora Borealis | Curtains + starfield |
| 7 | `dna_helix` | DNA Helix | Double helix + energy flow |
| 8 | `heartbeat` | Spectrum Singularity | Heart SDF + ECG + pulse rings |
| 9 | `rtx_mesh` | RTX Mesh | Deformable grid + reflective floor |
| 10 | `ray_marched` | Spectrum Kaleidoscope | Kaleidoscopic fractal |
| 11 | `volumetric_clouds` | Volumetric Clouds | 3D noise + lightning |
| 12 | `fractal_dimensions` | Fractal Dimensions | Mandelbulb + orbit trap |
| 13 | `neural_network` | Neural Network | Firing neurons + signals |
| 14 | `quantum_field` | Quantum Field | Probability waves + entanglement |
| 15 | `holographic` | Holographic | Wireframe + scan lines + glitch |
| 16 | `particle_storm` | Particle Storm | Vortex + lightning |
| 17 | `crystal` | Spectrum Black Hole | Gravitational lensing + accretion disk |
| 18 | `terrain` | Spectrum Terrain | Ridged noise mountains flyover |
| 19 | `galaxy` | Spectrum Galaxy | Volumetric spiral arms + core bulge |
| 20 | `wave_tessellation` | Wave Pool + Tessellation | Tessellated water surface |
| 21 | `audio_tessellation` | Audio Tessellation | Voronoi terrain with audio |
| 22 | `compute_shaders` | Spectrum Vortex | 3D raymarched vortex |
| 23 | `rtx_reflections` | Spectrum Reflections | Chrome spheres + mirror floor |
| 24 | `spectrum_3d` | 3D Spectrum Bars | 3D frequency bars |
| 25 | `spatial_dolby` | Spatial Dolby | 3D spatial audio field |
| 26 | `water_droplets` | Water Droplet Pool | 3D ripple physics with droplet impacts |
| 27 | `matrix_rain` | 3D Rain Particles | Falling streaks with parallax depth + audio-reactive density |
| 28 | `waveform_tunnel` | Audio Waveform Tunnel | Neon polar tunnel flythrough with spectrum-modulated rings |
| 29 | `crystal_lattice` | Synthwave Grid | Tron-style perspective grid with sun and audio shockwaves |
| 30 | `space_plasma` | Auditory Soundfield | ILD/ITD stereo localization — interaural level difference beams and time-difference wavefronts |
| 31 | `gravitational_waves` | Acoustic Room Response | Room impulse response — direct sound, image source reflections, room modes, reverb tail |
| 32 | `fluid_dynamics` | Fluid Dynamics | Navier-Stokes volumetric fluid simulation |
| 33 | `lightning_storm` | Spectral Masking Cascade | Auditory masking — simultaneous masking shadows, forward temporal masking, critical band edges |
| 34 | `neon_cityscape` | Neon Cityscape | Synthwave skyline with neon windows and reflections |
| 35 | `spectrum_waterfall` | Spatial Audio Sonar | 360° immersive 3D sonar display with range rings |
| 36 | `cosmic_web` | Gravitational Wavefield | Spacetime fabric with gravitational wells |
| 37 | `laser_show` | Resonance Field | 3D Chladni standing wave patterns at spatial audio positions |
| 38 | `neural_synapse` | Neural Synapse Storm | 3D neural network with synapse firing |
| 39 | `hologram_projector` | Acoustic Hologram Projector | Volumetric hologram table with wave field surface |
| 40 | `quantum_interferometer` | Quantum Field Interferometer | Wave-particle duality visualization |
| 41 | `aurora_cathedral` | Spectral Aurora Cathedral | Volumetric aurora curtains driven by psychoacoustic emitters |
| 42 | `gravitational_lens` | Gravitational Lens Observatory | Black hole + accretion disk with relativistic effects |
| 43 | `phonon_crystal` | Phonon Crystal Lattice | 3D phononic crystal wave propagation |
| 44 | `cymatic_chamber` | Cymatic Resonance Chamber | 3D Chladni patterns on parallel surfaces |
| 45 | `sonic_topology` | Sonic Topology Mapper | Manifold deformation with wireframe mesh |
| 46 | `particle_hologram` | Acoustic Particle Hologram | Particle clusters that converge on beats and explode on kicks |
| 47 | `freq_nebula` | Sonic Sphereworld | Planet terrain displacement with volumetric atmosphere |
| 48 | `wave_field` | Spatiotemporal Wave Field | 3D wave equation with audio sources |
| 49 | `fractal_explorer` | Fractal Dimension Explorer | Morphing 3D Mandelbulb with audio-driven parameters |

## Audio Data Available to Shaders

Each shader receives a structured `AudioData` buffer with:

- **8 frequency bands** (`b0`–`b7`) — sub-bass, bass, low-mids, high-mids, presence, brilliance, air, sparkle
- **Kick** — detected kick drum onset with confidence (`kick`, `kickConf`)
- **Beat** — tempo-tracked beat phase
- **Transient** — general transient onset detection
- **Stereo** — balance and difference (`stereoBal`, `stereoDiff`), stereo width (`stereoWid`)
- **LUFS** — integrated loudness (`lufsNormalized`)
- **Crest factor** — peak-to-RMS ratio (`crestFactorNormalized`)
- **THD** — total harmonic distortion (`thdNormalized`)
- **Phase coherence** — L/R phase correlation (`phaseCoherence`)
- **Spectrum texture** — full FFT spectrum sampled via `u_spectrum`
- **Motion** — speed, brightness, saturation, bloom controls
- **Section/scene** — automatic scene detection for color shifts
- **Brain palette** — 3 brain-derived colors (`brainCol`, `brainCol2`, `brainCol3`) + hue base/range/saturation

## Controls

- **ESC** — Quit
- **M** — Next visualization mode
- **N** — Previous visualization mode
- **F** — Toggle fullscreen

## Building

### Prerequisites

- Windows 10/11 (10.0.26100.0+ recommended)
- .NET 10 SDK
- DirectX 12 Ultimate-capable GPU (NVIDIA RTX series recommended)
- DXC compiler (bundled with Vortice.Dxc)
- Visual Studio 2022 (optional, for C++ native components)

### Build

```bash
cd DXRenderer
dotnet build -c Debug
```

### Run

```bash
cd DXRenderer/bin/Debug/net10.0-windows10.0.26100.0
DXRenderer.exe
```

## Shader Development

Shaders are HLSL pixel shaders compiled at runtime. Each mode is a single `.hlsl` file in `shaders/dx_*.hlsl` with a `main` entry point.

Shared includes in `shaders/include/` provide:

- `audio_cb.hlsl` — AudioData struct, constant buffer, spectrum sampler
- `color_utils.hlsl` — HSV/RGB conversions, palette functions
- `noise.hlsl` — Hash, value noise, FBM, curl noise
- `sdf.hlsl` — Signed distance functions (sphere, capsule, box, etc.)
- `raymarch.hlsl` — Ray marching helpers, camera ray generation
- `postfx.hlsl` — Bloom, tonemapping, vignette, scanlines
- `audio_reactive.hlsl` — Audio-driven overlays, starfield, god rays
- `layers.hlsl` — Blend modes, layer compositing, soft tone mapping (`softReinhard`), additive budget (`budgetPass`)
- `dsp_cb.hlsl` — DSP metrics: LUFS, crest factor, THD, phase coherence
- `spatial_encoder.hlsl` — 3D audio-to-spatial mapping with psychoacoustic profiles, emitter glow, L/R links, listener focal point, world environment, VR rendering

To add a new mode:
1. Create `shaders/dx_your_mode.hlsl` with a `float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target` entry point
2. Include `spatial_encoder.hlsl` and `layers.hlsl` for VR spatial modes (29+)
3. Add the mode key to the modes array and display names in `DX12Renderer.cs`
4. Use `softReinhard(col)` instead of hard HDR clamp for tone mapping
5. Use `seActiveCount(emit)` for additive budget normalization
6. Rebuild and run

See `VR_SPATIAL_DESIGN.md` for the full VR spatial audio design document covering psychoacoustic mapping, VR comfort guidelines, and the spatial encoder architecture.

## License

Private project. All rights reserved.

## Repository

[https://github.com/harrythebear18-lab/AudioVisuliserDX12U](https://github.com/harrythebear18-lab/AudioVisuliserDX12U)
