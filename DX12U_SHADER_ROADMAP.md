# DX12U Shader Roadmap v2 — Upgraded Pipeline
## RTX 5060 Blackwell Audio Visualizer — 30 Modes + Resonance DSP

---

## Mode Development Contract

All tuning and rewrite work must follow `DX12U_VISUALIZATION_RULES.md`. The contract requires brain-first audio causality, additive DSP refinement, HDR Layer 0 mode output, and prohibits global pipeline edits during an individual mode task.

## Current Architecture (Implemented)

### Root Signature (5 params)
```
[0] CBV b0 — AudioBrainCB (256 bytes: 16 float4s — beat, envelope, stereo, color, section, profiles)
[1] CBV b1 — TimeCB (16 bytes: time, deltaTime, frame, flags)
[2] CBV b2 — DspCB (64 bytes: 16 floats — LUFS, THD, phase, crest factor, 8 biquad bands)  ← NEW
[3] Descriptor Table — 8 SRVs (t0-t7): spectrum, layer0, layer1, bloom0, bloom1, feedback0, postfxTex, skiaTex
[4] Descriptor Table — 4 UAVs (u0-u3): compute output, particle buffer, history buffer, debug
    Static Samplers: s0 (clamp), s1 (wrap)
```

### HDR Multi-Pass Render Pipeline
```
Frame Timeline:
  1. Spectrum upload (CPU → GPU, 1024×3 R32_FLOAT)
  2. DSP constant buffer upload (b2: 16 floats — LUFS/THD/phase/crest/bands)
  3. Layer 0: Mode shader → layerTex0 (R16G16B16A16_Float HDR)
  4. Layer 1: Overlay shader → layerTex1 (R16G16B16A16_Float HDR)  [optional, overlay PSO missing]
  5. Bloom Extract: layerTex0 → bloomTex0 (half-res HDR)
  6. Bloom Blur H: bloomTex0 → bloomTex1
  7. Bloom Blur V: bloomTex1 → bloomTex0
  8. PostFX: layer0 + layer1 + bloom → postfxTex (R16G16B16A16_Float HDR)
     - Screen blend overlay, additive bloom, anamorphic, grain, CA, vignette
     - DSP: THD→grain warmth, phase→CA split, LUFS implicit via exposure
  9. Tone-map: postfxTex → backbuffer (R8G8B8A8_UNorm LDR)
     - ACES filmic, DSP: LUFS→exposure, crest→contrast
  10. SkiaSharp 2D overlay: alpha-blend HUD/text on backbuffer
  11. Present
```

### Shader Compilation
- **DXC SM6.6** primary (`ps_6_6`, `vs_6_6`) with fxc `ps_5_0` fallback
- **PreprocessIncludes()**: C#-side `#include` resolution for all shaders (mode + pipeline)
- All shaders compiled via `CompileShader(source, entry, filename, dxcTarget, fxcTarget)`
- Mode shaders: loaded in `LoadShaders()`, each gets its own PSO
- Pipeline shaders: loaded in dedicated methods (`LoadPostFxShader`, `LoadToneMapShader`, etc.)

### DSP Constant Buffer (b2) — Resonance DSP Pipeline
```
DspCB (16 floats, 64 bytes):
  [0] DspMomentaryLUFS    — momentary loudness (400ms window, -70..0 LUFS)
  [1] DspShortTermLUFS    — short-term loudness (3s sliding window)
  [2] DspIntegratedLUFS   — integrated loudness (EBU R128 gated, since reset)
  [3] DspTHDPercentage    — total harmonic distortion % (0..10+)
  [4] DspPhaseCorrelation — L/R stereo coherence (-1..+1)
  [5] DspPeakDbL          — peak level left (dB)
  [6] DspPeakDbR          — peak level right (dB)
  [7] DspCrestFactorDb    — crest factor / headroom (dB, 0..20+)
  [8-15] DspBand0..7      — 8 biquad band-pass RMS levels (sub, bass, low_mid, mid, high_mid, presence, brilliance, air)

Shader helpers (dsp_cb.hlsl):
  lufsNormalized()        — 0..1 from -70..0 LUFS
  crestFactorNormalized() — 0=compressed, 1=dynamic
  thdNormalized()         — 0=clean, 1=distorted
  phaseCoherence()        — 0=out-of-phase, 1=mono
```

### Design Philosophy: Multi-Layered Composite Pipeline
**Key architectural decision**: Leverage the existing multi-layer pipeline for rich,
layered visuals. Each mode shader focuses on its core GPU visual (raymarching, fields,
particles, geometry) and outputs to Layer 0. The shared pipeline handles HDR compositing,
bloom, postfx, and tonemapping. The SkiaSharp canvas overlay adds 2D elements (particles,
glow halos, frequency meters, beat rings) on top.

**Pipeline layers**:
```
Layer 0: Mode shader → layerTex0 (R16G16B16A16_Float HDR)
  - Core GPU visual: raymarching, SDF, fields, particles, geometry
  - Audio-reactive via AudioBrainCB (b0) + spectrum texture (t0)
  - DSP-complement via DspCB (b2): LUFS→subtle exposure boost, phase→mirror, etc.
  - DSP is ADDITIVE to brain data, never replaces it

Layer 1: Overlay shader → layerTex1 (HDR) [currently unused]
  - Secondary visual elements per-mode (e.g. wireframe overlay, HUD elements)
  - Future: per-mode overlay shaders for additional GPU layers

Bloom: Extract → Blur H → Blur V → Combine
  - Shared bloom pipeline, benefits all modes

PostFX: dx_postfx.hlsl composites layer0 + layer1 + bloom → postfxTex (HDR)
  - Screen blend, additive bloom, anamorphic, grain, CA, vignette
  - DSP: THD→grain warmth, phase→CA split, LUFS implicit via exposure

Tonemap: dx_tonemap.hlsl HDR → LDR
  - ACES filmic, DSP: LUFS→exposure, crest→contrast

SkiaSharp Canvas: SkiaOverlay.cs → skiaTex (R8G8B8A8_UNorm premul alpha)
  - 2D GPU-accelerated overlay: particles, glow halos, frequency meters, beat rings, text
  - Audio-reactive: driven by AudioUBO data
  - Alpha-blended on backbuffer via dx_skia_composite.hlsl

HUD: DX12HUD.cs → text overlay (BPM, mode name, section, etc.)
```

**Pattern for mode rewrites**:
```hlsl
#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"       // opt-in DSP complement
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"       // shared postfx — used by pipeline, not mode
#include "include/layers.hlsl"       // shared layers — starfield, blend modes

// Mode shader: focus on core visual only
// Output HDR color to layerTex0
// PostFX/Tonemap/Canvas handled by pipeline
// DSP complements brain: a.b0 * (1.0 + lufsNormalized() * 0.2) — boost, don't replace
```

**DSP Integration Rule**: DSP data must COMPLEMENT brain data, not compete with it.
- ✅ `h += a.b0 * 0.25 * (1.0 + lufsNormalized() * 0.2)` — brain signal boosted by DSP
- ❌ `h += DspBand0 * 0.25` — replaces brain with raw DSP (values 10-20x smaller, kills reactivity)
- ✅ `col += mirrorLayer * phaseCoherence() * 0.3` — DSP-only effect (brain has no phase)
- ❌ `col *= lufsNormalized()` — fights brain's brightness control

### Include System
```
shaders/
├── include/
│   ├── audio_cb.hlsl        — AudioBrainCB + TimeCB + AudioData struct + extractAudio() + screenToAspect
│   ├── dsp_cb.hlsl          — DspCB (b2) + lufsNormalized() + crestFactorNormalized() + thdNormalized() + phaseCoherence()
│   ├── color_utils.hlsl     — hsv(), RGB conversions, palette functions
│   ├── noise.hlsl           — hash21, hash11, value noise, gradient noise, FBM (fbm2_4)
│   ├── sdf.hlsl             — SDF primitives (sphere, box, torus, mandelbulb)
│   ├── raymarch.hlsl        — March loop, normals, soft shadows, AO
│   ├── audio_reactive.hlsl  — Spectrum sampling, band extraction, AudioElement struct, audioSimElement()
│   ├── postfx.hlsl          — tonemapACES, applyGrain, applyChromaticAberration, applyVignette, applyAnamorphic, applyPostFX
│   ├── easing.hlsl          — Smoothstep, exponential ease, audio-driven easing
│   ├── layers.hlsl          — blendScreen, blendAdd, starfield, standardOverlays, godRays
│   ├── simulation.hlsl      — Particle simulation utilities
│   └── vs_fullscreen.hlsl   — Shared fullscreen vertex shader (inline in C# currently)
├── dx_*.hlsl                — 30 mode shaders
├── dx_postfx.hlsl           — HDR composite pass (layer0 + layer1 + bloom → HDR)
├── dx_tonemap.hlsl          — HDR → LDR tone-map (ACES + DSP exposure/contrast)
├── dx_skia_composite.hlsl   — SkiaSharp 2D overlay alpha-blend
├── dx_bloom_extract.hlsl    — Bloom threshold extract
├── dx_bloom_blur_h.hlsl     — Bloom horizontal Gaussian blur
├── dx_bloom_blur_v.hlsl     — Bloom vertical Gaussian blur
├── dx_bloom_combine.hlsl    — Bloom additive combine
├── dx_composite.hlsl        — [MISSING] Legacy composite fallback
├── dx_overlay.hlsl          — [MISSING] Layer 1 overlay shader
├── cs_*.hlsl                — Compute shaders (particle sim, vortex)
├── gs_*.hlsl                — Geometry shaders
└── vs_mesh.hlsl             — Mesh vertex shader
```

---

## 30 Visualizer Modes — Current State

### Design Principles
- **Distinct visual language**: Each mode has its own aesthetic, color science, and post-processing
- **DSP-aware**: Modes opt-in to `dsp_cb.hlsl` for LUFS/crest/THD/phase/band reactivity
- **Audio truth**: Every visual element maps to a real audio or DSP feature
- **Depth via mixed dimensions**: 1D (bars/waveform) + 2D (fields/gradients) + 3D (raymarching/particles)
- **Section awareness**: Visuals evolve with music structure (intro → verse → chorus → drop → breakdown)
- **Anti-fatigue**: Smooth easing, rest periods, no strobing, clear focal point

### Full-Reimagination Rules for Red Modes
- **No preservation requirement**: A red mode may replace its current subject, composition, geometry, and motion language completely
- **One unmistakable silhouette**: Every rewrite needs a recognizable still-frame identity before secondary effects are added
- **Readable audio topology**: Frequency regions must occupy deliberate visual roles rather than driving every element globally
- **Reference extraction, not copying**: Reuse the strongest compositional ideas from prototypes while rebuilding their rendering, audio mapping, and polish
- **Pipeline-native output**: Layer 0 provides the core HDR scene; bloom, postfx, tonemap, and SkiaSharp overlays remain shared pipeline responsibilities
- **Cross-mode separation**: Do not approve a concept that overlaps an existing mode's primary silhouette, spatial layout, or motion language
- **Prototype references**:
  - Radial rainbow spectrum prototype → dense frequency rays, central aperture, bilateral depth, segmented amplitude tips, dark negative space
  - Cellular-grid prototype → evolving connected colonies, discrete square topology, central activity trace, high-contrast negative space

### HUD Numbering
- **HUD mode number = roadmap mode number + 1**. For example, HUD Mode 4 is roadmap Mode 3 (`particle_flow`), and HUD Mode 5 is roadmap Mode 4 (`waveform`).

### Status Legend (user-verified July 2026)
- ✅ **Good as-is**: Visual approach works well with multi-layer pipeline, keep current implementation
- 🟡 **Needs DSP/tuning**: Good visual base, needs DSP complement (additive, not replacing brain data) and/or tuning
- 🔴 **Rewrite**: Visual approach needs complete reimagining for multi-layer composite pipeline

### Current Tally
- ✅ **Good as-is**: 16 HUD modes (1, 2, 3, 4, 9, 10, 12, 13, 15, 16, 17, 19, 21, 22, 25, 26)
- 🟡 **Needs DSP/tuning**: 0 modes (deferred)
- 🔴 **Rewrite**: 14 HUD modes (5, 6, 7, 8, 11, 14, 18, 20, 23, 24, 27, 28, 29, 30)

---

### Mode 0: Quantum Bars — `dx_quantum_bars.hlsl`
**Display name**: Quantum Bars
**Status**: ✅ Good as-is
**Concept**: 128 3D frequency spectrum bars with quantum probability clouds, beat shockwaves, kick flash
**DSP**: Not integrated (optional future: LUFS→glow boost, phase→mirror bars)
**Audio mapping**: Bar height ← spectrum L/C/R, cloud ← transient, floor pulse ← kick, beat shockwave, quantum halos

### Mode 1: Plasma Field — `dx_plasma_field.hlsl`
**Display name**: Plasma Field
**Status**: ✅ Good as-is
**Concept**: 3-layer domain-warped FBM fluid: bass=large waves, mid=swirls, treble=filaments
**DSP**: Not integrated (optional future: LUFS→brightness boost, crest→turbulence)
**Audio mapping**: Flow ← BPM+stereo, turbulence ← bands, beat shockwave, kick distortion, transient sparks, 16 spectrum radial glows

### Mode 2: Neon Pulse — `dx_neon_pulse.hlsl`
**Display name**: Neon Pulse (Spectrum Tectonics)
**Status**: ✅ Good as-is
**Concept**: Audio-sculpted infinite canyon flyover, 32-step heightfield raymarch, 3 composed layers (sky, terrain, ribbons)
**DSP**: Not integrated (optional future: LUFS→fog, crest→ridge sharpness)
**Audio mapping**: 8 bands→terrain shape, beat→seismic ripple, kick→uplift, transient→fault cracks, stereo→camera lean, section→biome hue

### Mode 3: Particle Flow — `dx_particle_flow.hlsl`
**Display name**: Spectral Aperture
**Status**: ✅ Good as-is (user-verified)
**Concept**: Full reimagination based on the radial rainbow spectrum prototype — a deep central aperture surrounded by hundreds of frequency-resolved rays and segmented amplitude tips
**DSP**: Additive complement only: LUFS→ray luminance, crest→tip definition, phase→bilateral symmetry, THD→controlled chromatic roughness
**Audio mapping**: Fine spectrum bins→individual ray lengths, frequency→angular hue, L/R channels→opposed wings, sub/bass→aperture breathing, beat→radial compression, kick→depth impulse, transient→bright traveling tips
**Rewrite approach**:
- **Core silhouette**: Dark central aperture with two perspective-bent spectral wings expanding toward the frame edges
- **Depth construction**: Layered ray planes and logarithmic radial scaling create a tunnel without reusing Mode 28's fly-through ring structure
- **Frequency readability**: Preserve ordered rainbow progression and per-bin separation; avoid broad global pulses masking individual amplitudes
- **Motion**: Slow perspective drift and audio-driven depth breathing rather than constant vortex rotation
- **Foreground detail**: Bright segmented ray tips and sparse traveling particles handled by SkiaSharp; primary rays remain GPU-rendered in Layer 0
- **Negative space**: Preserve the prototype's dark central void and lower wedge so the spectrum remains legible at high density
- **Pipeline**: HDR ray field → Layer 0; shared bloom/postfx/tonemap; labels, tip particles, and optional orbit guides → SkiaSharp overlay
- **Distinct from Mode 24**: Mode 3 is a radial perspective aperture; Mode 24 remains a conventional mirrored 3D bar spectrum
- **Distinct from Mode 28**: Mode 3 faces an aperture from outside; Mode 28 travels through a waveform tunnel

### Mode 4: Waveform — `dx_waveform.hlsl`
**Display name**: Spectrum Ribbons (Cosmic Bloom)
**Status**: 🔴 Rewrite
**Concept**: Was rewritten as Cosmic Bloom (self-contained, DSP-integrated) but approach fought the multi-layer pipeline
**DSP**: Was integrated but self-contained postfx conflicted with shared pipeline
**Rewrite approach**: Redo for multi-layer composite — output core visual to Layer 0, let shared pipeline handle postfx/tonemap, use SkiaSharp for overlay elements

### Mode 5: Sphere — `dx_sphere.hlsl`
**Display name**: Spectrum Resonator
**Status**: 🔴 Rewrite (user baseline)
**Concept**: Raymarched sphere with directional spectrum displacement (theta=freq, phi=L/R), 3-light PBR, fresnel rim
**DSP**: Not integrated
**Audio mapping**: Radius←bass, displacement←spectrum, kick→shockwave, beat→emission, transient→crackles

### Mode 6: Aurora Borealis — `dx_aurora.hlsl`
**Display name**: Aurora Borealis (Spectrum Aurora)
**Status**: 🔴 Rewrite
**Concept**: 8 frequency-driven aurora curtains with multi-octave domain warp, L/R twin curtains, mountain silhouette
**DSP**: Not integrated
**Audio mapping**: Curtain height/brightness←amplitude, beat→shimmer, kick→ground glow, transient→flicker
**Rewrite approach**: Reimagine for multi-layer pipeline

### Mode 7: DNA Helix — `dx_dna_helix.hlsl`
**Display name**: DNA Helix (Spectrum Double Helix)
**Status**: 🔴 Rewrite
**Concept**: 48-segment 3D double helix with perspective, L/R stereo strands, base pair flashes, energy pulses
**DSP**: Not integrated
**Audio mapping**: Radius←amplitude, twist←treble, beat→base pair flash, kick→expansion, stereo→strand split
**Rewrite approach**: Reimagine for multi-layer pipeline

### Mode 8: Heartbeat — `dx_heartbeat.hlsl`
**Display name**: Spectrum Singularity
**Status**: ✅ Good — Acoustic Wavefront Propagator (rewritten)
**Concept**: 24 golden-ratio distributed acoustic sources on a Fibonacci sphere, each emitting expanding spherical wavefronts rendered as thin projected ring outlines in 3D perspective. Interference patterns emerge naturally from additive overlap. No particles, no SDF, no volumetric.
**DSP**: Integrated — LUFS→emission, crest→ring sharpness, THD→wavefront roughness, phase→interference coherence
**Audio mapping**: b0→expansion speed, b1→source radius, b2→topology, b3→wave count, b4→sharpness, b5→interference glow, b6→micro-ripple, b7→dissipation, beat→sync pulse, kick→bass impulse wave, transient→ring rupture

### Mode 9: RTX Mesh — `dx_rtx_mesh.hlsl`
**Display name**: RTX Mesh
**Status**: ✅ Good as-is
**Concept**: Deformable 3D mesh grid with audio-driven heightfield, 48-step raymarch, wireframe overlay, 2-light metallic
**DSP**: Not integrated (optional future: DSP bands→mesh zones)
**Audio mapping**: Displacement←spectrum L/C/R, kick→radial wave, beat→ripple, wireframe overlay, fresnel rim

### Mode 10: Ray Marched — `dx_ray_marched.hlsl`
**Display name**: Spectrum Kaleidoscope
**Status**: 🔴 Rewrite
**Concept**: 6-fold kaleidoscopic fractal with 8 iterations, orbit trap coloring, 64-step raymarch
**DSP**: Not integrated
**Audio mapping**: Bass→fold power, treble→rotation, beat→zoom, kick→fold explosion, transient→glitch
**Rewrite approach**: Reimagine for multi-layer pipeline

### Mode 11: Volumetric Clouds — `dx_volumetric_clouds.hlsl`
**Display name**: Volumetric Clouds
**Status**: ✅ Good as-is
**Concept**: 4-layer volumetric cloud field with sun lighting/shadows, BPM-driven wind, lightning on transients
**DSP**: Not integrated (optional future: THD→lightning character, LUFS→cloud density)
**Audio mapping**: Density←bass+envelope, dispersal←treble, wind←BPM, lightning←transient, god rays←brightness

### Mode 12: Fractal Dimensions — `dx_fractal_dimensions.hlsl`
**Display name**: Fractal Dimensions (Spectrum Mandelbox)
**Status**: ✅ Good as-is (user baseline)
**Concept**: 3D Mandelbox fractal with 8 iterations, orbit trap coloring from spectrum, 64-step raymarch
**DSP**: Not integrated
**Audio mapping**: Bass→fold scale, kick→fold morph, beat→zoom, transient→dimensional glitch
**Rewrite approach**: Reimagine for multi-layer pipeline

### Mode 13: Neural Network — `dx_neural_network.hlsl`
**Display name**: Synaptic Life
**Status**: 🔴 Rewrite
**Concept**: Full reimagination based on the cellular-grid prototype — an audio-reactive neural cellular automaton whose connected colonies grow, split, decay, and exchange signals across a dark circuit grid
**DSP**: Phase coherence→colony connectivity, LUFS→survival energy, crest→edge hardness, THD→mutation probability
**Audio mapping**: Eight bands→seed zones and colony colors, envelope→growth budget, beat→generation step, kick→local birth wave, transient→cell mutation, stereo balance→left/right propagation bias
**Rewrite approach**:
- **Core silhouette**: High-contrast connected cell islands with readable empty channels between colonies
- **Simulation look**: Discrete square cells and neighborhood rules; avoid particle clouds or conventional neuron-node diagrams
- **Signal layer**: A thin multiband activity trace crosses the field while colored pulses route through living cell paths
- **Temporal behavior**: Stable passages form persistent structures; energetic sections branch rapidly; silence causes gradual decay rather than immediate blackout
- **Pipeline**: GPU-rendered grid and colony state → Layer 0; signal markers, diagnostics, and sparse labels → SkiaSharp overlay
- **Distinct from Mode 14**: Mode 13 is an evolving topological organism; Mode 14 remains a fixed quantum particle lattice
- **Distinct from Mode 15**: Mode 13 changes connectivity over time; Mode 15 remains a perspective holographic frequency matrix

### Mode 14: Quantum Field — `dx_quantum_field.hlsl`
**Display name**: Quantum Field (Spectrum Lattice)
**Status**: ✅ Good as-is (user baseline)
**Concept**: 24x24 quantum particle lattice (576 particles), entanglement lines, wave function collapse on beat
**DSP**: Not integrated — needs additive DSP complement (phase→entanglement strength, LUFS→particle energy boost)
**Audio mapping**: Amplitude→position/energy/color, beat→collapse, transient→jitter, kick→ripple, phase→entanglement links

### Mode 15: Holographic — `dx_holographic.hlsl`
**Display name**: Holographic (Holo-Frequency Matrix)
**Status**: ✅ Good as-is (user baseline)
**Concept**: 32x16 perspective-tilted holographic frequency matrix, scan lines, glitch, flicker
**DSP**: Not integrated — needs additive DSP complement (THD→glitch intensity, phase→scan line split, LUFS→cell glow)
**Audio mapping**: Bar height←amplitude, L/R split, beat→bar pulse, kick→surge, transient→glitch, scan bar

### Mode 16: Particle Storm — `dx_particle_storm.hlsl`
**Display name**: Particle Storm (Spectrum Storm)
**Status**: ✅ Good as-is (user baseline)
**Concept**: 48 particles × 3 depth layers in storm orbit, lightning between active bins on transients
**DSP**: Not integrated — needs additive DSP complement (LUFS→particle density, crest→lightning intensity, bands→color zones)
**Audio mapping**: Amplitude→orbit radius, stereo→X drift, transient→scatter+lightning, kick→impulse, beat→contraction

### Mode 17: Crystal — `dx_crystal.hlsl`
**Display name**: Spectrum Black Hole
**Status**: 🔴 Rewrite
**Concept**: Volumetric raymarched black hole with spectrum-driven accretion disk, gravitational lensing, relativistic jets
**DSP**: Not integrated
**Audio mapping**: Event horizon←bass, disk←spectrum spiral, beat→photon ring, kick→gravitational wave, treble→jets
**Rewrite approach**: Reimagine for multi-layer pipeline — note overlap with mode 8 (Singularity), differentiate or merge

### Mode 18: Terrain — `dx_terrain.hlsl`
**Display name**: Spectrum Terrain
**Status**: ✅ Good as-is
**Concept**: Cinematic flyover with 96-step raymarch, ridged noise mountains, 5-layer surface coloring, atmospheric fog
**DSP**: Not integrated (optional future: DSP bands→terrain features, LUFS→fog)
**Audio mapping**: Elevation←spectrum (left=bass, right=treble), beat→elevation pulse, kick→earthquake, water+snow caps, banking camera

### Mode 19: Galaxy — `dx_galaxy.hlsl`
**Display name**: Spectrum Galaxy
**Status**: 🔴 Rewrite
**Concept**: 3D volumetric spiral galaxy with 4 logarithmic arms, core bulge, dust lanes, halo, 64-step raymarch
**DSP**: Not integrated
**Audio mapping**: Arm density←spectrum (bass=core, mid=arms, treble=halo), beat→pulse, kick→supernova, transient→star birth
**Rewrite approach**: Reimagine for multi-layer pipeline

### Mode 20: Wave Tessellation — `dx_wave_tessellation.hlsl`
**Display name**: Wave Pool + Tessellation
**Status**: ✅ Good as-is
**Concept**: Dual inverted tessellation meshes — bottom (sub/low-mid, 35% spectrum) + top (highs, 40% spectrum), Voronoi terrain
**DSP**: Not integrated (audio split recently adjusted this session)
**Audio mapping**: Bottom←sub/bass/low-mid (b0-b3 + spectrum), top←highs, wireframe + fault lines, blend at horizon

### Mode 21: Audio Tessellation — `dx_audio_tessellation.hlsl`
**Display name**: Audio Tessellation
**Status**: ✅ Good as-is (user baseline)
**Concept**: Voronoi tessellation terrain with audio-driven displacement and fault lines, amber/orange-black palette
**DSP**: Not integrated — needs additive DSP complement (bands→cell zones, LUFS→displacement boost, crest→fault sharpness)
**Audio mapping**: Displacement←FBM+spectrum, beat→fault line glow, self-contained (no shared postfx)

### Mode 22: Compute Shaders — `dx_compute_shaders.hlsl`
**Display name**: Spectrum Vortex
**Status**: 🔴 Rewrite
**Concept**: 3D raymarched volumetric tornado of frequency energy, 8 bands map to vortex heights
**DSP**: Not integrated
**Audio mapping**: Bass→width+rotation, treble→turbulence, beat→expansion, kick→intensification, transient→debris+lightning
**Rewrite approach**: Reimagine for multi-layer pipeline

### Mode 23: RTX Reflections — `dx_rtx_reflections.hlsl`
**Display name**: Spectrum Reflections
**Status**: 🔴 Rewrite
**Concept**: 8 metallic spheres orbit at spectrum-mapped positions on mirror floor, ray-traced reflections, PBR
**DSP**: Not integrated
**Audio mapping**: Radius/emission←frequency amplitude, beat→emission, kick→expansion, transient→floor ripples
**Rewrite approach**: Reimagine for multi-layer pipeline

### Mode 24: 3D Spectrum Bars — `dx_spectrum_3d.hlsl`
**Display name**: 3D Spectrum Bars
**Status**: ✅ Good as-is
**Concept**: Stereo mirror spectrum — bass in center, frequencies spread outward L/R, 128 bars per side
**DSP**: Not integrated (self-contained, no shared postfx)
**Audio mapping**: Left half←L channel, right half←R channel, fully brain-driven

### Mode 25: Spatial Dolby — `dx_spatial_dolby.hlsl`
**Display name**: Spatial Dolby
**Status**: ✅ Good — Enhanced 3D Spatial Soundscape (rewritten)
**Concept**: 8 brain bands split into 16 objects (L+R per band), each sampling its own stereo spectrum channel. L/R phase coherence drives horizontal beam links, adjacent band links are section-gated. Room grid, listener position, transient sound wave rings, beat pulse rings.
**DSP**: Integrated — LUFS→emission, crest→core sharpness, THD→position jitter, phase→L/R link coherence
**Audio mapping**: b0-b7→per-band L/R objects, beat→brighten+listener pulse, kick→bass lunge, transient→scatter+rings, section→vertical links unlock, envelope→emission gain

### Mode 26: Water Droplets — `dx_water_droplets.hlsl`
**Display name**: Water Droplet Pool
**Status**: 🔴 Rewrite
**Concept**: 3D water surface with damped sinusoid ripple propagation, droplet impacts on kick/transient
**DSP**: Not integrated
**Audio mapping**: Droplets←kick/transient, ripples←envelope, caustics←brightness, Fresnel reflections
**Rewrite approach**: Reimagine for multi-layer pipeline

### Mode 27: Matrix Rain — `dx_matrix_rain.hlsl`
**Display name**: 3D Rain Particles
**Status**: 🔴 Rewrite
**Concept**: Multiple parallax layers of falling streak particles, Matrix-style digital rain aesthetic
**DSP**: Not integrated
**Audio mapping**: Bass→fall speed, highs→density, kick→splash, depth layers
**Rewrite approach**: Reimagine for multi-layer pipeline

### Mode 28: Waveform Tunnel — `dx_waveform_tunnel.hlsl`
**Display name**: Audio Waveform Tunnel
**Status**: 🔴 Rewrite
**Concept**: Fly-through neon tunnel made of audio, polar coordinate approach, neon rings + angular lanes
**DSP**: Not integrated
**Audio mapping**: Tunnel shape←spectrum, bass→speed, FBM surface detail
**Rewrite approach**: Reimagine for multi-layer pipeline

### Mode 29: Crystal Lattice — `dx_crystal_lattice.hlsl`
**Display name**: Synthwave Grid
**Status**: 🔴 Rewrite
**Concept**: Tron/synthwave aesthetic — 3D perspective grid floor converging to horizon, particles on intersections
**DSP**: Not integrated
**Audio mapping**: Bass→grid forward motion, spectrum→grid point height, kick→shockwaves, particles pulse on intersections
**Rewrite approach**: Reimagine for multi-layer pipeline — strong candidate for SkiaSharp overlay integration

---

## Implementation Phases

### Phase 1: Pipeline Foundation ✅ COMPLETE
1. ✅ DXC SM6.6 compilation with fxc fallback
2. ✅ Root signature: 5 params (3 CBVs + 2 descriptor tables)
3. ✅ HDR multi-pass: layer0 → bloom → postfx → tonemap → skia overlay
4. ✅ Descriptor heap: 8 SRVs + 4 UAVs + 2 samplers
5. ✅ PreprocessIncludes() for all shaders (mode + pipeline)
6. ✅ Bloom pipeline: extract → blur H → blur V (4 shaders)
7. ✅ DSP constant buffer (b2): 16 floats uploaded per frame

### Phase 2: Modular Framework ✅ COMPLETE
1. ✅ `audio_cb.hlsl` — AudioBrainCB + TimeCB + AudioData + extractAudio()
2. ✅ `dsp_cb.hlsl` — DspCB + lufsNormalized() + crestFactorNormalized() + thdNormalized() + phaseCoherence()
3. ✅ `color_utils.hlsl` — hsv(), RGB conversions, palette functions
4. ✅ `noise.hlsl` — hash21, hash11, value noise, gradient noise, FBM
5. ✅ `sdf.hlsl` — SDF primitives (sphere, box, torus, mandelbulb)
6. ✅ `raymarch.hlsl` — March loop, normals, soft shadows, AO
7. ✅ `audio_reactive.hlsl` — Spectrum sampling, band extraction, audioSimElement()
8. ✅ `postfx.hlsl` — tonemapACES, applyGrain, applyChromaticAberration, applyVignette, applyAnamorphic
9. ✅ `easing.hlsl` — Smoothstep, exponential ease, audio-driven easing
10. ✅ `layers.hlsl` — blendScreen, blendAdd, starfield, standardOverlays, godRays
11. ✅ `simulation.hlsl` — Particle simulation utilities

### Phase 3: Mode Work (In Progress)
**Goal**: Leverage multi-layer composite pipeline for all modes. Good-as-is modes stay.
Needs-DSP modes get additive DSP complement. Rewrite modes get reimplemented for pipeline.

**Batch 1 — DSP Complement (🟡 Needs DSP/tuning — 6 modes) ✅ COMPLETE**:
- [x] Mode 8: Spectrum Singularity — LUFS→lensing boost, phase→disk symmetry, crest→disk sharpness
- [x] Mode 14: Quantum Field — phase→entanglement strength, LUFS→particle energy boost
- [x] Mode 15: Holographic — THD→glitch intensity, phase→scan line split, LUFS→cell glow
- [x] Mode 16: Particle Storm — LUFS→particle density, crest→lightning intensity, bands→color zones
- [x] Mode 21: Audio Tessellation — bands→cell zones, LUFS→displacement boost, crest→fault sharpness
- [x] Mode 25: Spatial Dolby — phase→spatial coherence, LUFS→field intensity, bands→spatial zones

**Batch 2 — Full Rewrites (🔴 Rewrite — 15 modes)**:
- [ ] Mode 3: Particle Flow — reimagine for multi-layer, SkiaSharp particle overlay
- [ ] Mode 4: Waveform — redo Cosmic Bloom for composite pipeline (Layer 0 + shared postfx)
- [ ] Mode 5: Sphere — reimagine, consider Layer 1 overlay
- [ ] Mode 6: Aurora — reimagine for multi-layer pipeline
- [ ] Mode 7: DNA Helix — reimagine for multi-layer pipeline
- [ ] Mode 10: Kaleidoscope — reimagine for multi-layer pipeline
- [ ] Mode 12: Fractal Dimensions — reimagine for multi-layer pipeline
- [ ] Mode 13: Neural Network — reimagine, SkiaSharp neuron overlay
- [ ] Mode 17: Crystal (Black Hole) — reimagine, differentiate from mode 8
- [ ] Mode 19: Galaxy — reimagine for multi-layer pipeline
- [ ] Mode 22: Compute Shaders — reimagine for multi-layer pipeline
- [ ] Mode 23: RTX Reflections — reimagine for multi-layer pipeline
- [ ] Mode 26: Water Droplets — reimagine for multi-layer pipeline
- [ ] Mode 27: Matrix Rain — reimagine for multi-layer pipeline
- [ ] Mode 28: Waveform Tunnel — reimagine for multi-layer pipeline
- [ ] Mode 29: Synthwave Grid — reimagine, strong SkiaSharp overlay candidate

**Batch 3 — Good as-is (✅ — 9 modes, no changes needed)**:
Modes 0, 1, 2, 9, 11, 18, 20, 24

**Rewrite pattern (multi-layer composite)**:
- Mode shader outputs HDR color to Layer 0 (core GPU visual only)
- Includes `audio_cb.hlsl` + `dsp_cb.hlsl` (opt-in) + `color_utils.hlsl` + `noise.hlsl` + `audio_reactive.hlsl`
- Includes `postfx.hlsl` + `layers.hlsl` — shared pipeline handles postfx/tonemap
- DSP complements brain data (additive, never replaces): `a.b0 * (1.0 + lufsNormalized() * 0.2)`
- SkiaSharp canvas handles 2D overlay (particles, meters, beat rings) — already built, mode-aware
- No self-contained postfx — let pipeline's bloom/postfx/tonemap do their job
- ~150-300 lines each (shorter than self-contained since pipeline handles post-processing)

### Phase 4: Pipeline Enhancements (Future)
1. [ ] Create `dx_overlay.hlsl` — Layer 1 overlay shader for secondary visual elements
2. [ ] Create `dx_composite.hlsl` — Legacy composite fallback (if needed)
3. [ ] Compute shader pipeline — UAV particle simulation for modes 22, 19
4. [ ] DXR 1.1 inline raytracing — for modes 9, 23
5. [ ] Work Graphs — GPU-driven particle systems (API probe needed)
6. [ ] Mesh shader pipeline — for modes 9, 20, 21 (tessellation replacement)
7. [ ] Feedback texture — previous frame for simulation memory (trails, persistence)

### Phase 5: Verification
1. Build clean with no errors
2. Run and verify all 30 modes load
3. Check debug output for shader compilation errors
4. Verify DXC compilation active (log should say "ps_6_6" not "ps_5_0")
5. Verify bloom pipeline works end-to-end
6. Verify DSP data flows to DSP-complement and rewritten modes (visual confirmation)
7. Verify SkiaSharp overlay renders correctly on all modes
8. Verify rewritten modes have distinct visual identities via core visual, not postfx

---

## DSP Integration Patterns

### Pattern 1: LUFS → Luminosity / Exposure
```hlsl
float lufs = lufsNormalized();  // 0..1
col *= (0.7 + lufs * 0.8);      // brighter when louder
```

### Pattern 2: Crest Factor → Contrast / Sharpness
```hlsl
float crest = crestFactorNormalized();  // 0=compressed, 1=dynamic
col = applyContrast(col, 0.8 + crest * 0.4);  // more contrast when dynamic
```

### Pattern 3: THD → Chromatic Aberration / Warmth
```hlsl
float thd = thdNormalized();  // 0=clean, 1=distorted
col.r *= (1.0 + thd * 0.15);
col.b *= (1.0 - thd * 0.08);
```

### Pattern 4: Phase Correlation → Stereo Mirror / Symmetry
```hlsl
float phase = phaseCoherence();  // 0=out-of-phase, 1=mono
// Ghost mirror layer appears when audio is mono (high coherence)
float ghostStrength = saturate(phase - 0.5) * 0.3;
col += mirrorLayer * ghostStrength;
```

### Pattern 5: 8 Biquad Bands → 8 Visual Elements
```hlsl
float bands[8] = { DspBand0, DspBand1, DspBand2, DspBand3, DspBand4, DspBand5, DspBand6, DspBand7 };
for (int i = 0; i < 8; i++) {
    float hue = ColorHue.base + i * 0.125;  // each band gets a hue slice
    float intensity = bands[i];
    col += drawElement(i, hue, intensity);
}
```

---

## Anti-Fatigue Guidelines
- **No strobing**: Beat flashes use exponential decay, not instant on/off
- **Rest periods**: Between drops, visuals calm down (lower brightness, slower motion)
- **Smooth transitions**: All audio-driven parameters use easing (lerp + smoothstep)
- **Color breathing**: Hue shifts are gradual, not jarring
- **Section awareness**: Verse = subtle, chorus = energetic, breakdown = minimal, drop = full power
- **Eye lead**: Always have a clear focal point (center bright, edges darker via vignette)
- **Motion coherence**: All elements move in related directions, not chaotic
