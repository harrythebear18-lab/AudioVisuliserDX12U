# DX12U Advanced Multilayered Shader Roadmap
## RTX 5060 Blackwell Audio Visualizer — 21 Mode Full Replacement

---

## Architecture Overview

### Pipeline Changes (Phase 1)

#### 1. DXC SM6.6+ Compilation
Replace fxc `ps_5_0` with DXC `ps_6_6` (pixel) and `vs_6_6` (vertex).
- Use `Vortice.DXC.IDxcCompiler3` with proper P/Invoke marshaling
- Arguments: `-T ps_6_6 -E main -D DX12U=1 -Q strip_reflect`
- Fallback to fxc `ps_5_0` if DXC unavailable (graceful degradation)
- Shader Model 6.6 unlocks: wave intrinsics, 16-bit floats, DXR 1.1 inline, `RWStructuredBuffer` in pixel shaders

#### 2. Root Signature Expansion
Current: 3 root params (2 CBVs + 1 descriptor table with 4 SRVs)
New: 5 root params
```
[0] CBV b0 — AudioCB (16 float4s = 256 bytes)
[1] CBV b1 — TimeCB (4 floats = 16 bytes)
[2] Descriptor Table — 8 SRVs (t0-t7): spectrum, layer0, layer1, bloom0, bloom1, feedback0, feedback1, noise
[3] Descriptor Table — 4 UAVs (u0-u3): compute output, particle buffer, history buffer, debug
[4] Static Samplers — 2 (linear clamp + linear wrap)
```

#### 3. Composite PSO Fix
The composite shader fails because it's compiled as `ps_5_0` but targets `R8G8B8A8_UNorm`.
Fix: compile composite with DXC `ps_6_6` and ensure RTV format matches PSO desc.
Also add HDR10 format option (`R10G10B10A2_UNorm`) for future HDR display support.

#### 4. Render Pass Structure (Multilayer)
```
Frame Timeline:
  1. Spectrum upload (CPU → GPU)
  2. Layer 0: Base visualizer shader → layerTex0 (R16G16B16A16_Float HDR)
  3. Layer 1: Overlay/secondary shader → layerTex1 (R16G16B16A16_Float HDR)
  4. Bloom Extract: layerTex0 → bloomTex0 (half-res)
  5. Bloom Blur H: bloomTex0 → bloomTex1
  6. Bloom Blur V: bloomTex1 → bloomTex0
  7. Composite: layer0 + layer1 + bloom → backbuffer (R8G8B8A8_UNorm or HDR)
  8. HUD overlay
```

### Modular Shader Framework (Phase 2)

#### Shared HLSL Include System
```
shaders/
├── include/
│   ├── audio_cb.hlsl        — AudioCB + TimeCB cbuffer definitions
│   ├── color_utils.hlsl     — HSV/RGB, temperature, palette functions
│   ├── noise.hlsl           — 2D/3D hash, value noise, gradient noise, FBM
│   ├── sdf.hlsl             — SDF primitives (sphere, box, torus, mandelbulb)
│   ├── raymarch.hlsl        — Raymarching framework (march loop, normals, lighting)
│   ├── audio_reactive.hlsl  — Spectrum sampling, band extraction, beat smoothing
│   ├── postfx.hlsl          — Tone mapping, bloom, vignette, chromatic aberration
│   ├── easing.hlsl          — Smoothstep, exponential ease, audio-driven easing
│   └── layers.hlsl          — Layer blending modes (screen, add, overlay, soft light)
├── dx_quantum_bars.hlsl     — Mode 0
├── dx_plasma_field.hlsl     — Mode 1
├── ... (21 modes total)
├── dx_composite.hlsl        — Updated composite shader
├── dx_overlay.hlsl          — Updated overlay shader
├── dx_bloom_extract.hlsl    — Bloom pipeline (existing, updated for SM6.6)
├── dx_bloom_blur_h.hlsl
├── dx_bloom_blur_v.hlsl
├── dx_bloom_combine.hlsl
└── vs_fullscreen.hlsl       — Shared fullscreen vertex shader
```

#### Shader Composition Pattern
Each mode shader follows this structure:
```hlsl
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"

// Layer 1: Background (2D noise field, depth atmosphere)
float3 backgroundLayer(float2 uv, AudioData a) { ... }

// Layer 2: Midground (3D raymarched geometry or 2.5D parallax)
float3 midgroundLayer(float2 uv, AudioData a) { ... }

// Layer 3: Foreground (1D spectrum bars, particles, waveform overlay)
float3 foregroundLayer(float2 uv, AudioData a) { ... }

// Layer 4: Post-processing (bloom, chromatic aberration, tone map)
float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    
    float3 col = float3(0, 0, 0);
    col = backgroundLayer(uv, a);
    col = blendScreen(col, midgroundLayer(uv, a));
    col = blendScreen(col, foregroundLayer(uv, a));
    
    col = applyBloom(col, a.bloom, a.bloomActive);
    col = applyChromaticAberration(col, uv, a.transient);
    col = tonemap(col);
    col = applyVignette(col, uv);
    
    return float4(col, 1.0);
}
```

---

## 21 Visualizer Modes

### Design Principles
- **Not visually fatiguing**: Rest periods between beats, smooth easing, avoid strobing
- **Audio truth**: Every visual element maps to a real audio feature
- **Depth via mixed dimensions**: 1D (bars/waveform) + 2D (fields/gradients) + 3D (raymarching/particles)
- **Section awareness**: Visuals evolve with music structure (intro → verse → chorus → drop → breakdown)
- **Modular**: Each shader is self-contained but shares include files

---

### Mode 0: Quantum Bars
**Concept**: 3D frequency spectrum bars with quantum probability clouds
**Dimensions**: 1D spectrum + 2D field + 3D bar extrusion
**Techniques**:
- 64 frequency bands rendered as 3D extruded bars with perspective
- Each bar has a quantum probability cloud (noise-based halo) around it
- Bars glow with audio-reactive intensity, bass bars thicker/taller
- Floor reflection (mirrored bars below y=0 with fade)
- Beat triggers bar "quantum jump" — height spike with smooth decay
**Audio mapping**:
- Bar height ← spectrum bins (log-scaled frequency)
- Bar color hue ← ColorHue.base + frequency position
- Cloud density ← Dynamics.transient
- Floor pulse ← Rhythm.kick
- Bar width ← Profile3.barScale

### Mode 1: Plasma Field
**Concept**: Flowing plasma fluid with audio-driven turbulence
**Dimensions**: 2D field + 2.5D depth displacement
**Techniques**:
- Domain-warped FBM noise field (3-4 octaves)
- Audio-reactive flow direction and speed
- Color palette shifts with frequency band dominance (bass=red, mid=green, treble=blue)
- Beat creates ripple waves that propagate outward from center
- Soft particle sparks along high-gradient edges
**Audio mapping**:
- Flow speed ← Profile3.motionSpeed * Rhythm.bpm
- Turbulence ← Dynamics.overall + Dynamics.transient
- Color shift ← ColorHue.base + section
- Ripple amplitude ← Rhythm.kick * kickConf
- Field brightness ← VisualIntensities.brightness

### Mode 2: Neon Pulse
**Concept**: Pulsing neon rings with chromatic glow and energy waves
**Dimensions**: 2D rings + 1D waveform overlay
**Techniques**:
- Concentric neon rings expand from center on each beat
- Ring thickness modulated by transient intensity
- Chromatic aberration on ring edges (R/G/B channel separation)
- Inner ring shows real-time waveform oscilloscope
- Outer rings show frequency band energy as polar bars
- Glow halo with multi-pass bloom integration
**Audio mapping**:
- Ring expansion ← beat trigger + time since last beat
- Ring color ← ColorHue shifts per ring
- Waveform ← stereo L/R spectrum texture
- Polar bars ← 8 frequency bands
- Chromatic shift ← Dynamics.transient

### Mode 3: Particle Flow
**Concept**: Thousands of particles flowing through audio-reactive vector field
**Dimensions**: 2D particle system + 3D depth layers
**Techniques**:
- 2D curl-noise vector field driving particle motion
- 4-6 depth layers with parallax (near=large/fast, far=small/slow)
- Particles leave fading trails (feedback buffer)
- Bass creates "gravity well" pulling particles inward
- Treble creates "explosion" pushing particles outward
- Particle color from palette, brightness from velocity
**Audio mapping**:
- Vector field strength ← Dynamics.envelope
- Gravity well ← Profile1.bass
- Explosion force ← Profile1.treble
- Trail length ← Profile2.dynamic
- Particle count density ← VisualIntensities.brightness

### Mode 4: Waveform
**Concept**: Multi-layered audio waveform with 3D depth and spectral coloring
**Dimensions**: 1D waveform + 2D spectral background + 3D wave extrusion
**Techniques**:
- 3 waveform layers: stereo L (top), mono (center), stereo R (bottom)
- Each waveform extruded into 3D ribbon with perspective
- Spectral gradient fill behind waveform (frequency → color)
- Beat markers as vertical pulse lines
- Smooth interpolation between spectrum texture samples
- Mirror reflection below center line
**Audio mapping**:
- Waveform shape ← spectrum texture rows 0, 1, 2
- Ribbon depth ← Dynamics.envelope
- Color gradient ← frequency band → hue mapping
- Beat markers ← Rhythm.kick + Rhythm.bpm
- Mirror fade ← Profile2.glow

### Mode 5: Sphere
**Concept**: Audio-reactive 3D sphere with surface displacement and energy aura
**Dimensions**: 3D raymarched sphere + 2D aura field
**Techniques**:
- Raymarched sphere with vertex displacement from FBM noise
- Surface ripples from bass frequencies
- Energy aura (volumetric glow) around sphere
- Sphere rotates with BPM, wobbles with transient
- Inner core visible through translucent surface (refraction approximation)
- Fresnel rim lighting with audio-reactive color
**Audio mapping**:
- Sphere radius ← Profile1.bass + Dynamics.envelope
- Surface displacement ← FBM(spectrum-influenced noise)
- Rotation speed ← Rhythm.bpm
- Aura intensity ← VisualIntensities.bloom
- Fresnel color ← ColorHue.base + section

### Mode 6: Aurora Borealis
**Concept**: Northern lights curtains waving to music with starfield backdrop
**Dimensions**: 2D aurora curtains + 2D starfield + 2.5D parallax
**Techniques**:
- Multiple aurora curtain layers using domain-warped noise
- Curtains wave vertically with audio-driven amplitude
- Color gradient: green → teal → purple → magenta (audio-shifted)
- Starfield background with twinkle (procedural stars)
- Ground silhouette at bottom (mountains/horizon)
- Reflection of aurora on virtual water surface
- Beat triggers aurora "brightening pulse" that travels along curtains
**Audio mapping**:
- Curtain amplitude ← Dynamics.envelope + Profile1.treble
- Curtain wave speed ← Profile3.motionSpeed
- Color shift ← ColorHue.base + section
- Star twinkle ← random + Dynamics.transient
- Brightness pulse ← Rhythm.kick
- Ground reflection intensity ← Profile2.glow

### Mode 7: DNA Helix
**Concept**: Double helix structure with audio-reactive base pairs and energy flow
**Dimensions**: 3D helix geometry + 2D energy field
**Techniques**:
- Two sinusoidal strands forming double helix (parametric)
- Base pair connecting bars between strands, height = frequency bins
- Energy particles flowing along helix strands
- Helix rotates and scales with music
- Depth perspective with fog for far strand fade
- Bass = wide helix, treble = tight helix twist
- Beat triggers "gene expression" — base pair flash
**Audio mapping**:
- Helix rotation ← Rhythm.bpm
- Helix radius ← Profile1.bass
- Twist frequency ← Profile1.treble
- Base pair height ← spectrum bins (64 bands)
- Energy flow speed ← Profile3.motionSpeed
- Base pair flash ← Rhythm.kick

### Mode 8: Heartbeat
**Concept**: Anatomical heart with ECG waveform and pulse waves
**Dimensions**: 2D heart silhouette + 1D ECG waveform + 2D pulse rings
**Techniques**:
- Stylized heart shape (parametric curve or SDF)
- Heart "beats" (scales) on each detected kick/beat
- ECG waveform line tracing across screen
- Pulse rings emanate from heart on each beat
- Blood vessel particle system around heart
- Color: deep red → crimson → bright red with beat intensity
- ECG line glows with bloom, fades behind
**Audio mapping**:
- Heart scale ← beat trigger (sharp pulse, smooth recovery)
- ECG waveform ← spectrum texture (amplitude = frequency)
- Pulse rings ← Rhythm.kick * kickConf
- Vessel particles ← Dynamics.overall
- Heart color intensity ← Profile1.energy
- ECG speed ← Rhythm.bpm

### Mode 9: RTX Mesh
**Concept**: Deformable 3D mesh grid with DXR reflections and audio-driven displacement
**Dimensions**: 3D mesh + DXR raytraced reflections
**Techniques**:
- Grid mesh (32x32 or 64x64) displaced by audio spectrum
- Mesh shader or vertex displacement in pixel shader raymarch
- DXR 1.1 inline raytracing for reflections on mesh surface
- Reflective floor beneath mesh
- Mesh height ← frequency bins mapped to grid position
- Wave propagation across mesh (ripple effect on beat)
- Metallic surface with audio-reactive roughness
**Audio mapping**:
- Mesh displacement ← spectrum bins → grid Z
- Ripple propagation ← Rhythm.kick
- Surface roughness ← Profile2.dynamic (smooth=high dynamic, rough=low)
- Reflection intensity ← VisualIntensities.dynLight
- Mesh rotation ← Profile3.perspective
- Color ← ColorHue + height-based gradient

### Mode 10: Ray Marched
**Concept**: Complex SDF scene with multiple morphing objects, soft shadows, ambient occlusion
**Dimensions**: Full 3D raymarching
**Techniques**:
- Multi-object SDF scene: sphere, torus, box, mandelbulb fragment
- Objects morph/blend with smin based on audio
- Soft shadows from multiple light sources
- Ambient occlusion via distance field
- Volumetric fog accumulation
- Specular highlights with audio-reactive light color
- Camera orbits scene, dolly on bass
- 80-128 march steps for quality
**Audio mapping**:
- Object blend ← Profile1.bass (morph factor)
- Camera dolly ← Profile1.bass
- Camera orbit ← Time + Rhythm.bpm
- Light color ← ColorHue.base + section
- Fog density ← VisualIntensities.atmos
- Specular intensity ← VisualIntensities.brightness
- Object twist ← Dynamics.transient

### Mode 11: Volumetric Clouds
**Concept**: 3D volumetric cloud field with audio-driven density and lightning
**Dimensions**: 3D raymarched clouds + 2D lightning
**Techniques**:
- Raymarched volumetric clouds using 3D noise density field
- Cloud density modulated by frequency bands (bass=thick, treble=wispy)
- Cloud lighting: sun direction with forward/back scattering
- Lightning flashes on transients (procedural fractal lightning bolts)
- Cloud movement (wind) driven by BPM
- God rays through cloud gaps
- Ground plane with cloud shadow projection
**Audio mapping**:
- Cloud density ← Profile1.bass + Dynamics.envelope
- Wind speed ← Rhythm.bpm
- Lightning trigger ← Dynamics.transient > threshold
- Lightning intensity ← VisualIntensities.beam
- God ray intensity ← VisualIntensities.brightness
- Cloud color ← ColorHue.base + time-of-day shift

### Mode 12: Fractal Dimensions
**Concept**: Mandelbulb 3D fractal with audio-driven power parameter and color cycling
**Dimensions**: 3D raymarched fractal
**Techniques**:
- Mandelbulb SDF (power parameter 2-8, audio-driven)
- Color from orbit trap (distance from origin during iteration)
- Audio drives fractal power → shape morphing
- Beat triggers "zoom" into fractal boundary
- Ambient color from iteration count
- Soft glow on high-iteration regions
- Camera slowly orbits and zooms
**Audio mapping**:
- Fractal power ← 2.0 + Profile1.bass * 4.0 (morphs shape)
- Zoom ← beat trigger (smooth zoom in, slow zoom out)
- Orbit trap color ← ColorHue.base + iteration count
- Glow ← VisualIntensities.bloom * high-iteration regions
- Camera orbit ← Time * 0.1
- Color cycle speed ← Profile3.motionSpeed

### Mode 13: Neural Network
**Concept**: Animated neural network with firing neurons and signal propagation
**Dimensions**: 2D node graph + 2.5D depth layers
**Techniques**:
- Procedural node layout (3-4 layers, 8-16 nodes per layer)
- Connection lines between layers with signal pulses traveling along them
- Nodes "fire" (flash bright) on beat/transient
- Signal propagation speed = BPM
- Background neural web pattern (subtle)
- Node cluster activity = frequency band energy
- Synaptic glow with bloom
- Depth: background nodes out of focus, foreground nodes sharp
**Audio mapping**:
- Node firing ← beat + transient triggers
- Signal speed ← Rhythm.bpm
- Layer activity ← frequency bands (layer 0=bass, layer N=treble)
- Connection thickness ← Profile2.dynamic
- Node glow ← VisualIntensities.bloom
- Background web ← VisualIntensities.ambient

### Mode 14: Quantum Field
**Concept**: Quantum particle field with probability waves and entanglement lines
**Dimensions**: 2D particle field + 1D probability waves
**Techniques**:
- 2D grid of quantum particles (procedural, ~500-1000)
- Particles oscillate with wave function (sine + noise)
- Probability density visualized as brightness
- Entanglement lines between nearby particles (fade with distance)
- Beat triggers "wave function collapse" — particles snap to positions
- Color from quantum state (phase → hue)
- Depth via particle size variation
**Audio mapping**:
- Wave amplitude ← Dynamics.envelope
- Wave frequency ← Rhythm.bpm
- Collapse trigger ← Rhythm.kick
- Particle energy ← Profile1.energy
- Entanglement density ← Profile2.stereo
- Phase color ← ColorHue.base + particle phase

### Mode 15: Holographic
**Concept**: Holographic display with scan lines, glitch effects, and 3D wireframe objects
**Dimensions**: 2D holographic overlay + 3D wireframe objects
**Techniques**:
- 3D wireframe objects (icosahedron, torus, cube) floating in holographic field
- Holographic scan lines (horizontal moving lines)
- Glitch effects on transients (RGB split, displacement, noise)
- Holographic flicker (subtle brightness oscillation)
- Grid floor with perspective
- Cyan/teal holographic color palette with audio-reactive shifts
- Object rotation and morph on beat
- Volumetric light cones from objects
**Audio mapping**:
- Object rotation ← Rhythm.bpm
- Glitch intensity ← Dynamics.transient
- Scan line speed ← Profile3.motionSpeed
- Object morph ← Profile1.bass
- Holographic flicker ← Dynamics.overall
- Color shift ← ColorHue.base + section
- Grid pulse ← Rhythm.kick

### Mode 16: Particle Storm
**Concept**: Chaotic particle storm with audio-driven vortex forces and lightning
**Dimensions**: 2D particle storm + 2D lightning + 2.5D depth
**Techniques**:
- Dense particle field (~2000+) with curl-noise turbulence
- Multiple vortex centers that move with music
- Particles change color based on velocity (blue=slow, white=fast)
- Lightning bolts between high-energy particles on transients
- Particle trails (motion blur approximation)
- Storm intensity builds with energy, calms with dynamics
- Depth: 3 particle layers (far/mid/near) with parallax
**Audio mapping**:
- Vortex strength ← Profile1.energy
- Vortex position ← stereo balance (L/R)
- Particle speed ← Dynamics.overall
- Lightning trigger ← Dynamics.transient
- Lightning intensity ← VisualIntensities.beam
- Color ← velocity-mapped + ColorHue.base
- Trail length ← Profile2.dynamic

### Mode 17: Wave Pool
**Concept**: Liquid surface with ripple waves from audio impacts
**Dimensions**: 2D height field + 3D perspective rendering
**Techniques**:
- Height field grid (64x64) rendered with perspective
- Multiple ripple sources: kick (center), snare (sides), hihat (random)
- Ripple propagation with wave equation approximation
- Surface color from depth (shallow=bright, deep=dark)
- Caustic patterns on virtual floor
- Surface normal-based lighting (specular highlights)
- Ambient reflection of sky gradient
**Audio mapping**:
- Ripple sources ← kick, transient, spectrum peaks
- Ripple amplitude ← Dynamics.envelope
- Wave speed ← Profile3.motionSpeed
- Surface color ← ColorHue.base + depth
- Caustic intensity ← VisualIntensities.brightness
- Specular ← VisualIntensities.dynLight
- Sky gradient ← ColorHue.center + section

### Mode 18: Tessellation
**Concept**: GPU tessellated surface with audio-driven displacement and adaptive LOD
**Dimensions**: 3D tessellated surface + 2D texture mapping
**Techniques**:
- Tessellated plane (SM6.6 hull/domain shaders or pixel shader approximation)
- Displacement from FBM noise + audio spectrum
- Adaptive tessellation factor (more triangles near camera, less far away)
- Wireframe mode toggle showing tessellation density
- Surface color from displacement height
- Beat creates "fault line" — sharp displacement ridge
- Gouraud shading with audio-reactive light direction
**Audio mapping**:
- Displacement ← FBM + spectrum bins
- Tessellation factor ← Profile2.dynamic (more detail when dynamic)
- Fault line ← Rhythm.kick
- Light direction ← rotates with Rhythm.bpm
- Surface color ← height-mapped palette + ColorHue
- Wireframe brightness ← VisualIntensities.brightness

### Mode 19: Compute Shaders
**Concept**: GPU compute shader driven particle system with audio input
**Dimensions**: 2D compute particles + 3D depth sorting
**Techniques**:
- Compute shader (CS) simulates 65536+ particles
- Particle forces: audio gravity, vortex, explosion, attraction
- Particle data in RWStructuredBuffer (position, velocity, color, life)
- Render pass draws particles as point sprites with additive blending
- Sort by depth for correct alpha blending
- Audio frequency bands map to spatial regions (bass=center, treble=edges)
- Beat triggers particle "burst" from center
**Audio mapping**:
- Gravity ← Profile1.bass (pulls to center)
- Explosion ← Rhythm.kick (radial burst)
- Vortex ← Profile3.motionSpeed (angular velocity)
- Particle color ← frequency band → hue
- Particle life ← Profile2.dynamic
- Burst count ← Dynamics.transient

### Mode 20: RTX Reflections
**Concept**: DXR raytraced scene with reflective objects and audio-reactive materials
**Dimensions**: 3D raytraced scene + DXR reflections
**Techniques**:
- DXR 1.1 inline raytracing from pixel shader
- 3-5 reflective objects (spheres, boxes) on reflective floor
- Objects move/orbit with music
- Raytraced reflections bounce between objects (1-2 bounces)
- Audio-reactive material properties (roughness, metallicity, emission)
- Beat triggers object emission pulse
- Ambient occlusion via raytraced shadow rays
- Skybox reflection with audio-reactive gradient
**Audio mapping**:
- Object position ← orbit with Rhythm.bpm
- Object emission ← beat trigger
- Material roughness ← Profile2.dynamic
- Material metallicity ← Profile1.bass
- Reflection brightness ← VisualIntensities.dynLight
- Skybox color ← ColorHue.base + section
- Floor reflection ← VisualIntensities.bloom

---

## Implementation Phases

### Phase 1: Pipeline Foundation (Steps 1-4)
1. Fix DXC SM6.6+ compilation in `DX12Renderer.cs`
2. Fix composite PSO format mismatch
3. Expand root signature (8 SRVs + 4 UAVs + 2 samplers)
4. Update descriptor heap creation and SRV layout
5. Verify build + runtime with existing shaders (backward compatible)

### Phase 2: Modular Framework (Step 5)
1. Create `shaders/include/` directory with shared headers
2. Write `audio_cb.hlsl` — unified cbuffer definitions
3. Write `color_utils.hlsl` — HSV/RGB, palettes, temperature
4. Write `noise.hlsl` — hash, value noise, gradient noise, FBM, curl noise
5. Write `sdf.hlsl` — SDF primitives and combinators
6. Write `raymarch.hlsl` — march loop, normals, soft shadows, AO
7. Write `audio_reactive.hlsl` — spectrum sampling, band extraction, beat smoothing
8. Write `postfx.hlsl` — tone mapping, bloom, vignette, chromatic aberration
9. Write `easing.hlsl` — smoothstep, exponential ease, audio-driven easing
10. Write `layers.hlsl` — blend modes (screen, add, overlay, soft light, multiply)
11. Create `vs_fullscreen.hlsl` — shared vertex shader

### Phase 3: Shader Implementation (Steps 6-7)
Batch 1 (Modes 0-6): Quantum Bars, Plasma Field, Neon Pulse, Particle Flow, Waveform, Sphere, Aurora
Batch 2 (Modes 7-13): DNA Helix, Heartbeat, RTX Mesh, Ray Marched, Volumetric Clouds, Fractal Dimensions, Neural Network
Batch 3 (Modes 14-20): Quantum Field, Holographic, Particle Storm, Wave Pool, Tessellation, Compute Shaders, RTX Reflections

Each shader:
- `#include` shared headers
- 3-4 visual layers (background, midground, foreground, postfx)
- Deep audio reactivity from all 16 AudioCB float4s + spectrum texture
- Anti-fatigue: smooth easing, rest periods, no strobing
- ~200-400 lines each

### Phase 4: Integration (Step 7)
1. Update `LoadShaders()` mode list to all 21 new modes
2. Update `CreateRootSignature()` for new binding layout
3. Update `Render()` pass structure if needed for compute/mesh shader modes
4. Update composite + overlay shaders for SM6.6
5. Update bloom pipeline shaders for SM6.6

### Phase 5: Verification (Step 8)
1. Build clean
2. Run and verify all 21 modes load
3. Check debug output for errors
4. Verify DXC compilation active (log should say "ps_6_6" not "ps_5_0")
5. Verify composite PSO creates successfully
6. Verify bloom pipeline works end-to-end

---

## Anti-Fatigue Guidelines
- **No strobing**: Beat flashes use exponential decay, not instant on/off
- **Rest periods**: Between drops, visuals calm down (lower brightness, slower motion)
- **Smooth transitions**: All audio-driven parameters use easing (lerp + smoothstep)
- **Color breathing**: Hue shifts are gradual, not jarring
- **Section awareness**: Verse = subtle, chorus = energetic, breakdown = minimal, drop = full power
- **Eye lead**: Always have a clear focal point (center bright, edges darker via vignette)
- **Motion coherence**: All elements move in related directions, not chaotic
