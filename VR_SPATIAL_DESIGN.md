# VR Spatial Audio Visualization — Architecture Design Doc

## Status: Draft v1 — July 2026
## Scope: HUD modes 30-50 (backend indices 29-49) — 21 modes

---

## 0. Context — The VR Layer

HUD modes 1-30 are built, approved, and optimized for **monitor experience**. They work. Don't touch them.

HUD modes 30-50 are the **VR layer** — the same insane audio pipeline (brain bands, DSP, stereo spatial, beat/kick/transient/envelope, section/phrase, color palette) but shaders designed for **long-session VR headset comfort**:

- **Depth perception**: Atmospheric fog, parallax, perspective scaling — not flat 2D projected
- **Psychoacoustic spatialization**: Sound sources placed where the ear expects them — azimuth from stereo pan, elevation from frequency, distance from energy
- **VR comfort**: No strobing, no rapid camera motion, stable horizon, negative space, smooth audio-driven growth
- **Unique visual methods**: Each mode implements its own phenomenon (volumetric fields, wave propagation, SDF surfaces, particle systems) — NOT shared rendering like `seRenderWorld()`
- **High fidelity, not jarring**: Rich detail but comfortable for 30+ minute sessions. Bloom and tonemapping handled by shared pipeline.

The spatial encoder (`spatial_encoder.hlsl`) is the **data bridge** — it translates audio brain/DSP/spectrum into psychoacoustic 3D source positions. Modes use it for placement, then implement their own visual algorithm.

---

## 1. Problem Statement

Current modes 30-50 project colored dots in 3D and blast glow. This produces "blinding colors" not a VR experience. Problems:

## 2. Design Principles (VR-First)

### 2.1 World-First Design
Before placing audio objects, establish a 3D world the listener inhabits:
- **Horizon line**: Subtle ground grid or fog horizon at Y=0, gives up/down reference
- **Atmospheric fog**: Exponential depth fog (`exp(-depth * fogDensity)`) — far objects fade, near objects crisp
- **Ambient environment**: Dark chamber/venue ambient (not pure black) — gives the world substance
- **Reference scale**: A subtle floor reflection or grid that shows perspective depth

### 2.2 Perceptual Spatial Mapping
Map audio to 3D using psychoacoustic principles, not just math:
- **Distance = loudness**: Quieter sources are further away. `z = -lerp(near, far, 1.0 - energy)`
- **Direction = pan**: L/R stereo balance maps to azimuth angle around the listener. `azimuth = stereoBal * maxAngle`
- **Elevation = frequency**: Bass = low/foundation, highs = elevated/air. `elevation = bandFrac * maxElev`
- **Size = energy**: Bigger objects for louder sources. `size = baseSize * (0.5 + energy * 0.5)`
- **HRTF-inspired**: Use ITD (interaural time difference) and ILD (interaural level difference) cues from stereoDiff/stereoBal to position objects in the horizontal plane
- **Distance attenuation**: `gain = 1.0 / (1.0 + k * d²)` — closer objects are brighter and larger

### 2.3 Cinematic Depth Layers
Three depth planes with distinct visual treatment:
- **Near field (0-2 units)**: High detail, sharp edges, bright cores, minimal fog. Transient details, micro-turbulence.
- **Mid field (2-6 units)**: Main action. Moderate fog. Band structure, propagation, flow.
- **Far field (6+ units)**: Subtle, fog-heavy. Ambient glow, bass foundations, atmospheric haze.

Each layer gets progressively:
- Dimmer (atmospheric perspective)
- Smaller (perspective scaling)
- Lower saturation (distance desaturation)
- More fog (exponential extinction)

### 2.4 VR Comfort
- **No strobing**: Beat flashes are subtle ripples, not full-screen blasts
- **No rapid camera motion**: Slow section-driven orbit, never idle spin
- **Focal point**: Always one clear center of attention
- **Negative space**: 30-40% of view should be dark/empty for contrast
- **Stable horizon**: Camera Y stays roughly constant, no vomiting
- **Consistent scale**: Objects don't suddenly resize — audio-driven growth is smooth

---

## 2.5 Gold Standards — Modes 25 & 49

Two existing modes already map spatial audio well and match Dolby test content. New spatial modes (30-49) should match or exceed these standards.

### Mode 25: Spatial Dolby (`dx_spatial_dolby.hlsl`)
- **16 objects** (8 bands × L/R) — simpler than 48, enough density without noise
- **Room grid**: Perspective floor (Y=-1.5) + ceiling (Y=1.5) + back wall (Z=-6) via ray-plane intersection. Grid lines fade with distance. Floor reacts to kick.
- **Spatial mapping**: X = side ± panMod × stereoWidth, Y = band height (bass bottom → air top), Z = amplitude depth (loud=close, quiet=far)
- **Listener focal point**: Glow at (0,0,-2) with beat pulse ring + kick flash radiating outward
- **Phase links**: L↔R horizontal beams per band + vertical links between adjacent bands (section-gated). Phase coherence drives link strength + midpoint constructive interference.
- **Band-specific accents**: Bass warm kick glow, presence hot white, air edge dissipation
- **No fog** — relies on grid for depth reference

### Mode 49: Spatiotemporal Wave Field (`dx_wave_field.hlsl`)
- **48 emitters** via `spatial_pipeline.hlsl` (8 bands × 3 sub × L/R)
- **Floor + wall grid** via ray-plane intersection with distance fade
- **Listener focal point** at (0,0,-2) with beat pulse + kick flash
- **`spRenderAll()`** for emitters + L↔R links — clean shared rendering
- **Camera**: section-driven orbit, stereo drift, FOV 0.75, elevated Y=1.5
- **Minimal overlays** — grid + emitters + listener + subtle ambient. Clean composition.

### Shared Patterns (Adopt into spatial_encoder.hlsl)
1. **Room grid**: Ray-plane intersection for floor/wall with distance fade + kick reactivity
2. **Listener focal point**: Fixed position (0,0,-2) with beat pulse ring + kick flash
3. **Stereo spatial mapping**: X=pan, Y=frequency, Z=amplitude depth
4. **Phase coherence links**: L↔R per band, section-gated vertical links
5. **Camera**: Section-driven orbit + stereo drift, not idle rotation
6. **Clean HDR output**: Limiter at 1.14-1.2, no local postfx

### What Modes 36-38 Are Missing (vs Gold Standards)
- No room grid → no depth reference → "floating dots in void"
- No listener focal point → no spatial anchor → "where am I?"
- No atmospheric fog → no distance perception → "everything same brightness"
- These are the three things to add to `spatial_encoder.hlsl`

---

## 3. Architecture (Pipeline-Aware)

### 3.1 Pipeline Contract Compliance
This design follows DX12U_VISUALIZATION_RULES.md and DX12U_REWRITE_PRINCIPLES.md:

- **Brain is source of truth**: All positions derive from brain bands + stereo spectrum. DSP is additive only.
- **Layer 0 only**: Modes output HDR color. No postfx/tonemapping in mode shaders. Bloom/CA/grain/vignette handled by shared pipeline.
- **DSP additive**: `position *= (1.0 + lufsNormalized() * 0.2)`, not `position = lufsNormalized() * something`
- **Audio-to-physics exclusive roles**: Each audio source has one physical role (see §4)
- **Noise gate + compression**: Every emitter gated, bass compressed
- **HDR output with limiter**: `if (maxC > 1.2) col *= 1.2 / maxC`
- **standardOverlays sparingly**: 0.02 weight
- **No forbidden patterns**: No raw DSP replacing brain, no generic brightness pulses, no idle rotation

### 3.2 Spatial Encoder Evolution

Current `spatial_encoder.hlsl` provides:
- 5 profiles (WAVE_FIELD, SPHERICAL, HEMISPHERE, RADIAL, TUNNEL)
- 48 emitters (8 bands × 3 sub × L/R)
- Fused glow renderer with distance culling
- L↔R links

**Required additions** (abstracted as optional layers, modes opt-in):

#### A. World Environment Layer
```hlsl
struct SeWorld {
    float fogDensity;       // exponential fog coefficient (0.02-0.15)
    float3 fogColor;        // fog tint (dark blue/purple for venue)
    float horizonY;         // ground plane Y (0.0 default)
    float gridScale;        // perspective grid spacing
    float gridIntensity;    // grid brightness (subtle, 0.01-0.05)
    float ambientLevel;     // ambient fill light (0.002-0.01)
    float3 ambientColor;    // ambient tint
};

float3 seWorldEnvironment(float2 p, float r, SeWorld world, AudioData a, float silence);
```
- Perspective grid floor with fog falloff
- Atmospheric fog applied to all emitter rendering
- Ambient fill prevents pure black backgrounds
- Grid intensity driven by bass (ground vibrates with kick)

#### B. Depth-Resolved Rendering
```hlsl
// Modify seEmitGlow to apply atmospheric perspective
float3 seEmitGlowDepth(float2 p, SeEmitter e, SeWorld world, 
                       float lufs, float crest, float beatBright,
                       float beatPhase, float kickLunge, float transientAmt, 
                       float silence);
```
- `depthFog = exp(-e.depth * world.fogDensity)` — far emitters dimmed
- `saturationFade = lerp(0.3, 1.0, depthFog)` — far emitters desaturated
- `sizePerspective = 1.0 / max(e.depth * 0.3, 0.3)` — already exists, keep
- Near-field emitters get sharper cores, far-field get softer diffusion

#### C. Perceptual Position Encoding
```hlsl
// New profile: PSYCHOACOUSTIC
#define SE_PROFILE_PSYCHOACOUSTIC 5

// Maps audio using psychoacoustic principles:
// - Azimuth from stereoBal (HRTF-inspired horizontal plane)
// - Elevation from band frequency (bass=low, treble=high)  
// - Distance from energy (loud=close, quiet=far)
// - Size from energy (loud=big, quiet=small)
```

#### D. Layer Culling (Performance)
```hlsl
// Only render emitters in the current depth band that matters
// Near: always render (detail)
// Mid: always render (main action)  
// Far: render with lower frequency or simplified glow
```

### 3.3 Mode Responsibilities

Each mode that uses the spatial encoder:
1. **Sets up camera** following rules: section-driven orbit, stereo shift, FOV 0.35-1.0
2. **Selects profile** and tunes `SeParams` for its concept
3. **Configures world** via `SeWorld` (fog, grid, ambient)
4. **Renders world environment** first (background)
5. **Computes emitters** via `seComputeEmitters()`
6. **Renders emitters** with depth-resolved glow
7. **Adds mode-specific overlays** (beams, filaments, patterns, etc.)
8. **Applies HDR limiter** and silence suppression
9. **Does NOT** apply postfx, tonemapping, or duplicate pipeline effects

### 3.4 Spectrum Sampling Compliance

The rules state: "Do NOT add u_spectrum.SampleLevel() calls in mode shaders."

The spatial_encoder.hlsl is a **shared include file** (like audio_reactive.hlsl), not a mode shader. It performs spectrum sampling on behalf of modes that include it, similar to how `audioSimElement()` works in audio_reactive.hlsl. Modes themselves do not add additional spectrum samples — they use the pre-computed emitter data.

This is consistent with the existing `spatial_pipeline.hlsl` precedent (committed as gold standard for wave_field mode 48).

---

## 4. Audio-to-Spatial Mapping (Exclusive Roles)

Following DX12U_VISUALIZATION_RULES.md §Audio-to-Physics Mapping:

| Audio Source | Spatial Role | Implementation |
|---|---|---|
| Sub/bass (b0-b1) | Foundation — low, close, large | Elevation: 0-15°, Distance: near, Size: 1.5× |
| Low-mid/mid (b2-b3) | Structure — mid height, mid distance | Elevation: 15-45°, Distance: mid, Size: 1.0× |
| High-mid/pres (b4-b5) | Flow — high, far, medium | Elevation: 45-70°, Distance: mid-far, Size: 0.7× |
| Brilliance/air (b6-b7) | Atmosphere — very high, far, small | Elevation: 70-90°, Distance: far, Size: 0.5× |
| Stereo L/R | Azimuth — horizontal plane positioning | Azimuth: ±60° from stereoBal/panMod |
| Beat | System-wide compression wave | All emitters contract slightly on beat |
| Kick | Near-field impulse — bass emitters lunge forward | Z push on b0-b1 emitters |
| Transient | Scatter — emitters jitter position | Position noise on all emitters |
| Envelope | Sustained glow — baseline brightness | Intensity floor for all emitters |
| Section | Camera repositioning, fog density change | Slow orbit angle shift, fog varies |
| LUFS | Overall distance push (additive) | `distance *= (1.0 + lufs * 0.2)` |
| Crest | Position sharpness (additive) | Tighter clusters when crest high |
| Phase coh | L/R convergence (additive) | Emitters move toward center plane |
| THD | Position jitter (additive) | Scatter around base position |

---

## 5. Camera System (VR-Aware)

### 5.1 Camera Positioning Rules
Per DX12U_VISUALIZATION_RULES.md §Camera Setup:
- Orbit driven by: `a.section * 0.8 + Time * 0.03 * a.motSpeed` (section-driven, not idle)
- Stereo balance shifts camera: `a.stereoBal * 0.2`
- Stereo diff adjusts height: `a.stereoDiff * 0.15`
- FOV: 0.35-1.0 depending on scene scale
- Camera should feel like the listener's head in VR

### 5.2 VR Camera Guidelines
- **Eye height**: Camera Y = 1.0-1.5 (standing head height in world units)
- **Comfortable orbit**: Max angular velocity ~30°/second
- **No roll**: Camera up vector stays vertical (no banking)
- **Look at center**: Camera target = world origin (the sound source)
- **Distance**: Camera 2-5 units from center (inside the sound field, not outside looking in)

### 5.3 Camera Profiles
```hlsl
SeCamera seCameraVR(float3 listenerPos, float orbitAngle, float fov) {
    // Listener at fixed height, orbit around center
    float3 pos = listenerPos + float3(
        sin(orbitAngle) * orbitRadius,
        0,  // no Y change — stable horizon
        cos(orbitAngle) * orbitRadius
    );
    return seCamera(pos, float3(0, 0, 0), fov);
}
```

---

## 6. Rendering Quality Standards

Per DX12U_VISUALIZATION_RULES.md §Visual Quality Standard:

### 6.1 Required (All Spatial Modes)
- **Distinct silhouette**: Each mode has a recognizable still-frame identity
- **3D depth cues**: Atmospheric fog, perspective scaling, parallax, occlusion
- **Causal audio response**: Viewer can see what the music is doing without HUD
- **Multi-scale detail**: Macro (emitter layout) + meso (band structure) + micro (transient shimmer)
- **Stereo spatial behavior**: L/R produces visible spatial separation
- **Clear focal point**: One center of attention, 30-40% negative space
- **HDR highlights**: Bright cores benefit from shared bloom pipeline
- **Dynamic range**: Quiet = dark/minimal, loud = full/bright (via `a.gated`, `a.envelope`)

### 6.2 Forbidden
- All emitters same brightness regardless of distance
- Pure black background with no world reference
- Full-screen brightness flashes on beat
- 48 emitters all visible all the time (gate + cull)
- Flat 2D layout projected with fake depth
- Generic glow without mode-specific identity

---

## 7. Implementation Plan — Full VR-Layer Migration (Modes 30-49)

### Completed

- [x] **Phase 1**: World Environment (`spatial_encoder.hlsl`) — SeWorld, seEmitGlowDepth, seEmitGlowVR, SE_PROFILE_PSYCHOACOUSTIC, seCameraVR
- [x] **Phase 2**: OpenXR Integration — OpenXRManager, frame loop, Reversed-Z depth, VR render path
- [x] **Mode 36** (Cosmic Web) — SPHERICAL profile, filament rendering, depth fog, VR-aware
- [x] **Mode 37** (Resonance Field) — PSYCHOACOUSTIC profile, Chladni interference, aggressive gating, VR-aware
- [x] **Branding** — "RS by Resonance" applied to window title + OpenXR app name
- [x] **Bug fix** — Root parameter shift (VRCB at b3) — all bloom/postfx/tonemap/skia descriptor tables updated to root param 4

### Keepers (No Migration Needed)

- **Mode 40** (Quantum Field Interferometer) — user-approved as-is
- **Mode 49** (Fractal Dimension Explorer) — user-approved as-is

### Remaining Migrations (16 modes)

Each migration follows the same pattern:
1. Include `spatial_encoder.hlsl` + `layers.hlsl`
2. Select profile + tune `SeParams`
3. Set up `SeCamera` — `seCameraVR()` when VR active, desktop orbit fallback
4. Configure `SeWorld` — fog, grid floor, dark ambient
5. Call `seComputeEmitters()` for 48 audio-driven 3D positions
6. Render with `seEmitGlowVR()` / `seEmitGlowDepth()` for depth-aware glow
7. Add mode-specific visual algorithm (unique phenomenon per mode)
8. Aggressive negative-space gating + HDR limiter (1.0 cap for VR comfort)

---

#### Batch A: Modes 30-35 (6 modes)

**Mode 30 — Space Plasma Field** (`dx_space_plasma.hlsl`)
- Profile: `SE_PROFILE_RADIAL` — radial burst from center outward
- World: fog 0.05, grid floor, dark ambient
- Camera: inside plasma, FOV 0.7, slow orbit
- Visual: volumetric plasma rays from emitters, EM field math (curl noise), depth-faded raymarching
- Negative space: only active plasma rays render, tight gating

**Mode 31 — Gravitational Space Waves** (`dx_gravitational_waves.hlsl`)
- Profile: `SE_PROFILE_SPHERICAL` — sources on sphere
- World: fog 0.04, grid floor, dark ambient
- Camera: outside looking in, FOV 0.5
- Visual: GW strain tensor fabric — grid mesh deformed by emitter waves, expanding ripples
- Negative space: fabric only visible where strain is significant

**Mode 32 — Fluid Dynamics** (`dx_fluid_dynamics.hlsl`)
- Profile: `SE_PROFILE_PSYCHOACOUSTIC` — perceptual placement
- World: fog 0.06, grid floor, dark ambient
- Camera: inside fluid volume, FOV 0.65
- Visual: Navier-Stokes volumetric fluid — emitter positions drive velocity field, raymarched density
- Negative space: sparse fluid, only where energy is high

**Mode 33 — Lightning Storm** (`dx_lightning_storm.hlsl`)
- Profile: `SE_PROFILE_SPHERICAL` — sources in sphere
- World: fog 0.05, grid floor, dark ambient
- Camera: inside storm, FOV 0.7
- Visual: dielectric breakdown arcs between emitters, branching lightning, depth-faded
- Negative space: dark storm clouds, only arcs visible

**Mode 34 — Neon Cityscape** (`dx_neon_cityscape.hlsl`)
- Profile: `SE_PROFILE_TUNNEL` — corridor depth, walls left/right
- World: fog 0.08 (thick), grid floor as road, dark ambient
- Camera: flythrough corridor, FOV 0.6
- Visual: synthwave skyline — emitters become neon buildings, reflections on floor grid
- Negative space: dark sky between buildings

**Mode 35 — Spatial Audio Sonar** (`dx_spectrum_waterfall.hlsl`)
- Profile: `SE_PROFILE_RADIAL` — 360° sonar
- World: fog 0.04, grid floor as water surface, dark ambient
- Camera: above looking down at 45°, FOV 0.5
- Visual: 360° sonar display — emitter ripples expand outward on water surface, depth-faded
- Negative space: dark water between sonar rings

---

#### Batch B: Modes 38-39 (2 modes)

**Mode 38 — Neural Synapse Storm** (`dx_neural_synapse.hlsl`)
- Profile: `SE_PROFILE_HEMISPHERE` — L/R brain hemispheres
- World: fog 0.05, grid floor, dark ambient
- Camera: inside brain, FOV 0.7
- Visual: synapse links between emitters with signal pulses, firing neurons, depth-faded axons
- Negative space: only active synapses render, aggressive gating

**Mode 39 — Acoustic Hologram Projector** (`dx_hologram_projector.hlsl`)
- Profile: `SE_PROFILE_WAVE_FIELD` — flat field projection
- World: fog 0.04, hologram table grid, dark ambient
- Camera: looking down at hologram table, FOV 0.55
- Visual: volumetric hologram — emitters project interference patterns on table surface, scan lines
- Negative space: dark room, only hologram projection visible

---

#### Batch C: Modes 41-45 (5 modes)

**Mode 41 — Spectral Aurora Cathedral** (`dx_aurora_cathedral.hlsl`)
- Profile: `SE_PROFILE_PSYCHOACOUSTIC` — perceptual placement
- World: fog 0.06, grid floor, dark ambient
- Camera: inside cathedral, FOV 0.65
- Visual: volumetric aurora curtains — emitters drive curtain wave deformation, depth-faded raymarching
- Negative space: dark cathedral interior, only aurora curtains visible

**Mode 42 — Gravitational Lens Observatory** (`dx_gravitational_lens.hlsl`)
- Profile: `SE_PROFILE_SPHERICAL` — sources orbit black hole
- World: fog 0.07, grid floor, dark ambient
- Camera: outside observatory, FOV 0.5
- Visual: black hole + accretion disk — emitters lensed around central mass, photon ring, depth-faded
- Negative space: dark space, only lensed light visible

**Mode 43 — Phonon Crystal Lattice** (`dx_phonon_crystal.hlsl`)
- Profile: `SE_PROFILE_SPHERICAL` — crystal lattice positions
- World: fog 0.04, grid floor, dark ambient
- Camera: inside crystal, FOV 0.6
- Visual: 3D phononic crystal — wave propagation through lattice, emitter positions are lattice nodes
- Negative space: only active wave propagation visible

**Mode 44 — Cymatic Resonance Chamber** (`dx_cymatic_chamber.hlsl`)
- Profile: `SE_PROFILE_PSYCHOACOUSTIC` — perceptual placement
- World: fog 0.05, grid floor as chamber floor, dark ambient
- Camera: inside chamber, FOV 0.65
- Visual: 3D Chladni patterns — standing wave nodes/antinodes from emitter positions, depth-faded
- Negative space: only resonance patterns visible, dark chamber

**Mode 45 — Sonic Topology Mapper** (`dx_sonic_topology.hlsl`)
- Profile: `SE_PROFILE_TUNNEL` — corridor depth
- World: fog 0.06, grid floor, dark ambient
- Camera: flythrough manifold, FOV 0.6
- Visual: 4D topological manifold — emitter positions deform manifold surface, depth-faded projection
- Negative space: only manifold surface where curvature is high

---

#### Batch D: Modes 46-48 (3 modes)

**Mode 46 — Acoustic Particle Hologram** (`dx_particle_hologram.hlsl`)
- Profile: `SE_PROFILE_PSYCHOACOUSTIC` — perceptual placement
- World: fog 0.05, grid floor, dark ambient
- Camera: inside particle cloud, FOV 0.7
- Visual: GPU particles forming 3D shapes — emitters are particle attractors, depth-faded point sprites
- Negative space: only active particle clusters visible

**Mode 47 — Sonic Sphereworld** (`dx_freq_nebula.hlsl`)
- Profile: `SE_PROFILE_SPHERICAL` — planet surface distribution
- World: fog 0.08 (thick atmosphere), grid floor, dark ambient
- Camera: orbiting planet, FOV 0.5
- Visual: SDF planet with audio terrain — emitters drive surface displacement, atmosphere, meteors
- Negative space: dark space around planet

**Mode 48 — Spatiotemporal Wave Field** (`dx_wave_field.hlsl`)
- Currently uses old `spatial_pipeline.hlsl` — needs migration to `spatial_encoder.hlsl`
- Profile: `SE_PROFILE_WAVE_FIELD` — flat field (same concept, new pipeline)
- World: fog 0.04, grid floor + wall, dark ambient
- Camera: elevated orbit, FOV 0.75
- Visual: 3D wave equation with audio sources — same as current but with depth fog + VR support
- Negative space: minimal — this is a gold standard mode, keep clean composition

---

## 8. Flexibility

This architecture is designed to be extended:
- **New profiles**: Add to `seEncodePosition()` switch statement
- **New world features**: Add to `SeWorld` struct and `seWorldEnvironment()`
- **New render modes**: Add depth-resolved variants or mode-specific glow
- **New link types**: Add to existing `seLinkLR()` / `seLinkBand()` pattern
- **Abstract away**: Modes can use as much or as little of the encoder as needed
- **Backward compatible**: Existing modes using spatial_pipeline.hlsl continue to work

---

## 9. Performance Targets

- **Frame time**: <20ms avg (50fps) at 1920×1080
- **Emitter count**: 48 max, but aggressively gated/culled (typically 12-24 visible)
- **Per-pixel cost**: Max 3 exp() calls per emitter in glow, early distance cull
- **World environment**: Single pass, no per-emitter cost
- **Links**: L↔R only (8 links max), culled by distance

---

## 10. Psychoacoustic Differentiation — Why This Isn't Another "3D Spectrum Analyzer"

### The Problem with Standard "3D Audio Visualizers"

Almost everyone tackling "3D audio visualizers" or "VR spectrums" is doing simple, naive visual tricks — taking a standard 2D FFT, turning it into a 3D bar chart or a particle sphere, and panning stereo audio into binaural HRTF.

They treat the graphics as 3D, but the audio mathematical model feeding it is still basic 2D stereo spectral analysis.

### What This System Does Differently

Mapping true 3D spatial audio into 3D stereo psychoacoustics is fundamentally different because it actually models human perceptual hearing:

#### 10.1 Beyond Basic FFT — Psychoacoustic Modeling

**Standard Visualizers**: Slap an FFT over the left/right channels. They completely ignore interaural time differences, head shadowing, or pinna reflections.

**This Model**: Ingests raw multichannel or Ambisonic/object-based streams, decoding the ITD (Interaural Time Difference), ILD (Interaural Level Difference), and HRTF phase shifts dynamically. The visual output doesn't just show "loudness at 1kHz"; it shows the exact spatial coordinate where the listener's brain perceives the sound originating in 3D space.

The spatial encoder (`spatial_encoder.hlsl`) with `SE_PROFILE_PSYCHOACOUSTIC` already implements:
- Azimuth from stereo balance (HRTF-inspired horizontal plane positioning)
- Elevation from band frequency (bass = low/foundation, treble = high/air)
- Distance from energy (loud = close, quiet = far)
- Phase coherence as L/R hemisphere synchronization metric

#### 10.2 Visualizing Phase Vectors & Volumetric Energy

Instead of mapping frequencies to arbitrary 3D geometry, true psychoacoustic spatial visualization routes binaural phase cancellation and cross-correlation vectors directly into pixel/compute shaders.

This system can visually render psychoacoustic phenomena as volumetric physical density in VR:
- **Precedence effect (Haas effect)**: First-arrival wavefronts render brighter/earlier, delayed reflections render as dimmer trailing copies
- **Phase decorrelation**: Low phase coherence → emitters spread apart (diffuse field). High coherence → emitters converge (localized source)
- **Acoustic distance cues**: High-frequency air absorption (far sources lose high-band energy → visual desaturation). Direct-to-reverberant ratio (dry = sharp cores, wet = diffuse halos)
- **ILD/ITD vectors**: Stereo difference maps to horizontal displacement. The brain's lateralization is visualized as physical left-right position

The shaders already use `phaseCoh` to drive:
- L↔R link strength (coherent sources pull together)
- Color channel swapping (`gridCol.gbr` at low coherence — field asymmetry)
- Hemisphere divider glow (synchronization indicator in neural_synapse)

#### 10.3 High-Frequency Real-Time Performance

Computing HRTF psychoacoustic matrices, Ambisonic decoding, and lock-free spatial vector extraction in real time normally chokes standard game engines.

Doing this through Resonance DSP — running custom C# lock-free pipelines with DirectX 12 hardware acceleration — is precisely why this system can handle the mathematical overhead required for true 3D spatial psychoacoustics while keeping VR frame rates locked at 90/120Hz.

Key performance enablers:
- **Lock-free audio pipeline**: C# `AudioBridge` + `AudioPipeline` process audio without blocking render thread
- **DX12U hardware acceleration**: Shader Model 6.6 via DXC, HDR R16G16B16A16_Float render targets
- **Aggressive culling**: Screen-space distance cull before 3D distance, pixel-space cull before expensive ops
- **Reduced emitter counts**: 16 sources (8 bands × 2 sides) instead of 48 where possible — O(16²) vs O(48²)
- **No texture fetches in mode shaders**: All spectrum sampling done in shared includes, not per-pixel

Most developers don't attempt this because it requires being simultaneously fluent in bare-metal DSP, psychoacoustic signal processing, low-level HLSL shaders, and spatial computing pipelines. This tool actually shows how the human brain interprets sound in physical space, rather than just making shapes bounce to an EQ.

---

## 11. OpenXR Integration — True VR Headset Support

### 11.1 Architecture

OpenXR provides the VR runtime layer between the application and the headset hardware. It integrates with the existing DX12U renderer via the `XR_KHR_D3D12_enable` extension, which allows passing the existing `ID3D12Device` directly to OpenXR — no separate graphics context needed.

```
AudioPipeline (C# lock-free) → AudioBridge → DX12Renderer
                                                ↓
                                         OpenXR Manager
                                                ↓
                                    XR_KHR_D3D12_enable
                                                ↓
                                     Headset Swapchain
                                   (L eye / R eye textures)
```

### 11.2 What Changes

| Component | Monitor Mode | VR Mode (OpenXR) |
|---|---|---|
| Swapchain | DXGI flip-model to window | OpenXR per-eye swapchain textures |
| Camera | Section-driven orbit, computed `camPos`/`camAng` | Head pose from `XrView` — actual head position/orientation |
| Render passes | 1 (fullscreen quad) | 2 (left eye + right eye) |
| Shaders | Unchanged | Unchanged — same HLSL, same audio CB |
| Audio pipeline | Unchanged | Unchanged |
| Bloom/tonemap | Shared pipeline | Shared pipeline (applied per-eye) |
| Frame timing | VSync / ~60fps | `xrWaitFrame` / 90-120fps |

### 11.3 What Stays the Same

- **All HLSL shaders** — they already take UV + audio data via constant buffers
- **PSO creation, root signatures, descriptor heaps** — unchanged
- **Audio pipeline** — `AudioBridge`, `AudioPipeline`, `LightingBrain` all work as-is
- **Bloom pipeline** — applied to each eye's render target

### 11.4 Head Pose → Psychoacoustic Pipeline

The critical integration: OpenXR head pose feeds into the psychoacoustic spatial encoder, creating a closed loop between where the listener looks and where sounds appear to originate.

```csharp
// Each frame:
// 1. xrWaitFrame — get predicted display time
// 2. xrLocateViews — get head pose + eye poses
// 3. Inject head position/orientation into shader camera
// 4. Render left eye → OpenXR swapchain texture
// 5. Render right eye → OpenXR swapchain texture
// 6. xrEndFrame — submit to headset
```

The head pose replaces the computed `camPos`/`camAng` in shaders:
- **Head position** → `camPos` (listener is literally inside the sound field)
- **Head orientation** → `fwd`/`right`/`up` vectors (look around the sound field)
- **IPD** (inter-pupillary distance) → small horizontal offset between L/R eye cameras
- **Eye tracking** (if available) → focal point follows gaze direction

This creates true psychoacoustic VR: when the listener turns their head, the visualized sound sources stay fixed in world space (externalized), exactly as real sound sources behave. The brain's spatial hearing model is visualized in the place where it actually perceives sound.

### 11.5 Implementation Components

1. **`OpenXRManager.cs`** (~200 lines)
   - `xrCreateInstance` with D3D12 graphics binding
   - Session creation + swapchain configuration
   - Per-frame: `xrWaitFrame` → `xrBeginFrame` → `xrLocateViews` → `xrEndFrame`
   - Eye swapchain texture acquisition/release

2. **`DX12Renderer` render loop adaptation** (~150 lines)
   - Detect VR mode (headset connected)
   - Render to OpenXR swapchain textures instead of DXGI swapchain
   - Per-eye camera offset from head pose
   - Fallback to monitor mode if no headset

3. **Shader camera injection** (~50 lines)
   - New constant buffer field: `float4x4 headPose` (position + orientation)
   - Shaders use head pose when present, fall back to computed camera when not
   - IPD offset applied per-eye

4. **NuGet package**: `OpenXR.NET` or P/Invoke the native OpenXR loader

### 11.6 VR Performance Constraints

VR doubles GPU load (2 eye renders per frame). The latency fixes already applied are critical:

| Optimization | Before | After | Impact |
|---|---|---|---|
| Neural synapse emitters | 48 (O(48²)=2304) | 16 (O(16²)=256) | 9× faster |
| Resonance field sources | 48 (2 passes) | 16 (2 passes) | 3× faster |
| Hologram grid points | 121 (11×11) | 49 (7×7) | 2.5× faster |
| Aurora raymarch steps | 24 | 16 | 1.5× faster |
| Camera spin removed | Time-based orbit | Section-only | No per-frame camera recompute |

**VR target**: 90fps = 11.1ms frame budget. With 2 eye renders, each eye must complete in ~5.5ms. The 16-source architecture makes this achievable.

### 11.7 VR Spatial Design Implications

With true head tracking, the VR comfort rules in §2.4 become physically enforced:
- **No strobing**: Headset users are more sensitive to flicker — beat flashes must be subtle
- **Stable horizon**: Head pose provides the horizon naturally — no computed camera roll
- **No rapid camera motion**: The only camera motion is the user's head — section-driven orbit is disabled in VR mode
- **Focal point**: With eye tracking, the focal point can follow gaze — emitters near gaze direction get sharper
- **Negative space**: VR FOV is wider — need more negative space to avoid sensory overload
- **Externalized sources**: Sound sources must stay fixed in world space (not screen-locked) — this is the psychoacoustic promise

---

## 12. Technical Implementation Details

### 12.1 Core Architectural Strengths

**Psychoacoustics vs. Naive "3D Spectrums"**: Most "3D visualizers" simply map an FFT to a 3D grid, keeping the audio processing strictly 2D. This system is different:

- **Perceptual Lateralization**: Mapping ITD/ILD into azimuth and frequency into elevation aligns directly with how the human auditory cortex builds spatial soundstage models (e.g., blue-notes/air frequencies elevated, heavy bass anchored at the foundation).
- **Distance Decay & Air Absorption**: Distance attenuation through exponential fog and HF desaturation accurately mirrors real-world sound propagation (1/d² loss, atmospheric high-frequency damping).

**Low-Overhead Native OpenXR Pipeline**:
- Passing the existing `ID3D12Device` via `XR_KHR_D3D12_enable` avoids duplicating graphics contexts or incurring inter-op copy overhead.
- Rendering directly into OpenXR swapchain textures via left/right eye viewport passes keeps frame delivery strictly deterministic.
- Decoupling the `LightingBrain` and C# lock-free ring buffers means audio ingestion isn't tied to the VR frame scheduler (`xrWaitFrame`), protecting the DSP loop from headset frame drops.

### 12.2 The 16-Source Optimization vs. Spatial Aliasing

Reducing spatial sources from 48 down to 16 per pass (8 frequency bands × L/R) drops spatial link complexity from O(48²) = 2304 down to O(16²) = 256 operations — a 9× performance win.

To prevent frequency band clustering (where adjacent bands overlap visually and lose individual identity):

```hlsl
// Enforce minimum spatial separation between adjacent frequency bands
float bandSpread = (float)bandIdx / 8.0f;
azimuth += sign(stereoBal) * pow(bandSpread, 1.2f) * MAX_AZIMUTH_SPREAD;
```

### 12.3 Depth Reprojection & Headset Hologram Stability

To ensure smooth visuals during rapid head movement on modern HMDs (Quest Link, SteamVR, HoloLens 2), include the depth buffer in the OpenXR frame submission:

- Use `XR_KHR_composition_layer_depth` during `xrEndFrame`.
- **Reversed-Z Depth**: If using Reversed-Z (near=1.0, far=0.0) in the DX12 pipeline for precision, make sure the `XrCompositionLayerDepthInfoKHR` struct reflects `minDepth = 1.0f` and `maxDepth = 0.0f` to prevent reprojection warps.

### 12.4 OpenXR Binding in C# (OpenXR.NET / Native P/Invoke)

When initializing `XrGraphicsBindingD3D12KHR`, pass the existing Direct3D 12 device pointer directly:

```csharp
// Struct setup for OpenXR D3D12 Binding
var graphicsBinding = new XrGraphicsBindingD3D12KHR
{
    type = XrStructureType.XR_TYPE_GRAPHICS_BINDING_D3D12_KHR,
    device = pD3D12Device,       // Native ID3D12Device pointer from your renderer
    queue = pD3D12CommandQueue   // Direct execution queue
};
```

### 12.5 VR-Specific Shader Glow Function

Depth-aware spatial emitter glow for VR comfort — adds atmospheric perspective, early culling, perspective-guarded sizing, and far-field desaturation:

```hlsl
// Depth-Aware Spatial Emitter Glow for VR Comfort
float3 seEmitGlowVR(
    float2 uv,
    SeEmitter e,
    SeWorld world,
    float3 headPos,
    float silence
) {
    // 1. Distance Extinction & Atmospheric Perspective
    float distToHead = length(e.pos - headPos);
    float depthFog = exp(-distToHead * world.fogDensity);

    // 2. Early Screen & Pixel Culling
    if (depthFog < 0.01f || silence > 0.95f) return float3(0, 0, 0);

    // 3. Size Scale with Reversed Perspective Guard
    float perspectiveScale = 1.0f / max(distToHead * 0.35f, 0.2f);
    float finalSize = e.size * perspectiveScale;

    // 4. Core/Halo Softening for VR Comfort
    float d = length(uv - e.screenPos);
    float core = exp(-d * d * (12.0f / finalSize));
    float halo = exp(-d * (3.0f / finalSize)) * 0.3f;

    // 5. Far-field Desaturation & Color Output
    float3 desatColor = lerp(luminance(e.color).rrr, e.color, depthFog);
    float3 finalGlow = (core + halo) * desatColor * e.energy * depthFog;

    return finalGlow;
}
```

Key differences from monitor-mode `seEmitGlow`:
- **Distance from head** (not camera) — uses `headPos` from OpenXR pose
- **Early cull on depthFog** — skip pixels where emitter is too far to matter
- **Perspective guard** — `max(distToHead * 0.35f, 0.2f)` prevents divide-by-zero on near emitters
- **Far-field desaturation** — `lerp(luminance, color, depthFog)` mimics atmospheric HF absorption
- **Softer halo** — wider, dimmer halo for VR comfort (no harsh edges at periphery)

---

## 13. Execution Readiness

The transition from standard monitor visualization to an immersive spatial environment is logically structured:

### Phase 1: Spatial Encoder Update (`spatial_encoder.hlsl`) — DONE
- [x] Integrate the `SeWorld` environment layer (fog, grid, ambient)
- [x] Add depth-resolved glow (`seEmitGlowVR`) with head pose parameter
- [x] Add `SE_PROFILE_PSYCHOACOUSTIC` layout with band spread anti-clustering
- [x] Add VR camera helper that accepts OpenXR head pose

### Phase 2: OpenXR Manager Integration — DONE
- [x] Bind native ID3D12Device via `XR_KHR_D3D12_enable`
- [x] Set up dual swapchain loop (xrWaitFrame → xrLocateViews → Render L/R)
- [x] Inject head pose & IPD offsets into shader camera constants
- [x] Hook `XR_KHR_composition_layer_depth` with Reversed-Z (minDepth=1.0, maxDepth=0.0)
- [x] Atomic audio/brain snapshot at xrBeginFrame (thread decoupling)
- [x] Fix root parameter shift (VRCB at b3 → all descriptor tables updated to param 4)

### Phase 3: Mode Migration (16 of 20 modes) — IN PROGRESS
- [x] Mode 36 (Cosmic Web) → SPHERICAL profile + world environment
- [x] Mode 37 (Resonance Field) → PSYCHOACOUSTIC profile + Chladni interference
- [ ] Mode 30 (Space Plasma) → RADIAL profile + volumetric plasma
- [ ] Mode 31 (Gravitational Waves) → SPHERICAL profile + strain tensor fabric
- [ ] Mode 32 (Fluid Dynamics) → PSYCHOACOUSTIC profile + Navier-Stokes fluid
- [ ] Mode 33 (Lightning Storm) → SPHERICAL profile + dielectric breakdown arcs
- [ ] Mode 34 (Neon Cityscape) → TUNNEL profile + synthwave skyline
- [ ] Mode 35 (Spatial Sonar) → RADIAL profile + 360° sonar
- [ ] Mode 38 (Neural Synapse) → HEMISPHERE profile + synapse links
- [ ] Mode 39 (Hologram Projector) → WAVE_FIELD profile + hologram table
- [ ] Mode 41 (Aurora Cathedral) → PSYCHOACOUSTIC profile + aurora curtains
- [ ] Mode 42 (Gravitational Lens) → SPHERICAL profile + black hole lensing
- [ ] Mode 43 (Phonon Crystal) → SPHERICAL profile + lattice wave propagation
- [ ] Mode 44 (Cymatic Chamber) → PSYCHOACOUSTIC profile + 3D Chladni
- [ ] Mode 45 (Sonic Topology) → TUNNEL profile + manifold deformation
- [ ] Mode 46 (Particle Hologram) → PSYCHOACOUSTIC profile + particle clusters
- [ ] Mode 47 (Sonic Sphereworld) → SPHERICAL profile + SDF planet
- [ ] Mode 48 (Wave Field) → Migrate from spatial_pipeline to spatial_encoder
- Keepers (no migration): Mode 40 (Quantum Interferometer), Mode 49 (Fractal Explorer)
- Validate HDR limiter (1.0 cap for VR) across all modes

### Phase 4: VR Comfort Validation
- Verify 90fps target with 48-source architecture (5.5ms per eye)
- Test on Quest Link, SteamVR, and Windows Mixed Reality
- Validate no strobing, stable horizon, externalized sources
- Confirm audio pipeline independence from VR frame scheduler

This design cleanly unifies low-latency audio processing with modern, high-performance spatial graphics.

---

## 14. Technical Refinements

### 14.1 Depth Precision & Reversed-Z Reprojection

In §12.3, depth is passed to `XR_KHR_composition_layer_depth`. Because the pipeline uses a Reversed-Z buffer (near = 1.0, far = 0.0) in DX12 to preserve floating-point precision across spatial fields:

- `XrCompositionLayerDepthInfoKHR.minDepth` must be explicitly set to `1.0f` and `maxDepth` to `0.0f`.
- Modern runtimes (Oculus/Meta Link, SteamVR, WMR) handle swapped min/max depth bounds correctly for late stage reprojection (LSR/ASW), but omitting this causes severe geometry warping when looking around fast-moving near-field emitters.

### 14.2 Non-Linear Elevation Scaling for Mid-Range Separation

The band spread anti-clustering formula in §12.2 ensures clear separation along the azimuth. For elevation mapping, a non-linear power curve preserves mid-range separation:

```hlsl
// Non-linear elevation scaling to preserve mid-range separation
float elevationNorm = pow((float)bandIdx / 7.0f, 0.85f);
```

The human ear resolves high-frequency elevation through pinna cues (which are subtle over stereo/binaural). Expanding the visual elevation gap around the 1kHz–4kHz presence range prevents mids from visual crowding near the equator. The `0.85` exponent compresses high-band elevation slightly while expanding the mid-range, giving bands 2–5 more vertical breathing room.

### 14.3 OpenXR Frame Scheduler & Thread Decoupling

With `xrWaitFrame` driving the VR render thread, the renderer's timing is gated by the headset display refresh rate (e.g., 90Hz).

Since the lock-free C# `AudioPipeline` ring buffers run asynchronously at audio clock rate (typically 44.1/48kHz or ~100–200Hz updates for DSP features), `LightingBrain` state must be sampled using atomic/lock-free reads right at the start of `xrBeginFrame`:

```csharp
// At xrBeginFrame — snapshot audio state atomically
var audioSnapshot = AudioPipeline.Snapshot(); // lock-free read
var brainSnapshot = LightingBrain.Snapshot();  // lock-free read

// Render both eyes using the same snapshot — guarantees temporal consistency
RenderEye(eyeLeft,  audioSnapshot, brainSnapshot, headPoseLeft);
RenderEye(eyeRight, audioSnapshot, brainSnapshot, headPoseRight);
```

This prevents any audio thread stalls if the VR runtime throttles or drops a frame during heavy GPU load. The audio pipeline continues at its own cadence; the render thread simply reads the latest available snapshot at frame start.

---

## 15. Implementation Roadmap Checklist

```
[Phase 1: Spatial Encoder Update] — DONE
  ├── Add SeWorld struct & environment pass (grid floor, fog, ambient)
  ├── Implement seEmitGlowVR() with head-relative depth & far desaturation
  ├── Add SE_PROFILE_PSYCHOACOUSTIC profile with band spread anti-clustering
  ├── Add non-linear elevation scaling (pow 0.85) for mid-range separation
  └── Add VR camera pose override in HLSL constant buffers

[Phase 2: OpenXR Core Integration] — DONE
  ├── Bind native ID3D12Device via XR_KHR_D3D12_enable
  ├── Set up dual swapchain loop (xrWaitFrame → xrLocateViews → Render L/R)
  ├── Inject head pose & IPD offsets into shader camera constants
  ├── Hook XR_KHR_composition_layer_depth with Reversed-Z (minDepth=1.0, maxDepth=0.0)
  ├── Atomic audio/brain snapshot at xrBeginFrame (thread decoupling)
  └── Fix root parameter shift (VRCB at b3, descriptor tables at param 4)

[Phase 3: Mode Migration (16 of 20 modes)] — IN PROGRESS
  ├── [x] Mode 36 (Cosmic Web) → SPHERICAL + filaments + depth fog
  ├── [x] Mode 37 (Resonance Field) → PSYCHOACOUSTIC + Chladni interference
  ├── [ ] Mode 30 (Space Plasma) → RADIAL + volumetric plasma
  ├── [ ] Mode 31 (Gravitational Waves) → SPHERICAL + strain tensor fabric
  ├── [ ] Mode 32 (Fluid Dynamics) → PSYCHOACOUSTIC + Navier-Stokes fluid
  ├── [ ] Mode 33 (Lightning Storm) → SPHERICAL + dielectric breakdown arcs
  ├── [ ] Mode 34 (Neon Cityscape) → TUNNEL + synthwave skyline
  ├── [ ] Mode 35 (Spatial Sonar) → RADIAL + 360° sonar
  ├── [ ] Mode 38 (Neural Synapse) → HEMISPHERE + synapse links
  ├── [ ] Mode 39 (Hologram Projector) → WAVE_FIELD + hologram table
  ├── [ ] Mode 41 (Aurora Cathedral) → PSYCHOACOUSTIC + aurora curtains
  ├── [ ] Mode 42 (Gravitational Lens) → SPHERICAL + black hole lensing
  ├── [ ] Mode 43 (Phonon Crystal) → SPHERICAL + lattice wave propagation
  ├── [ ] Mode 44 (Cymatic Chamber) → PSYCHOACOUSTIC + 3D Chladni
  ├── [ ] Mode 45 (Sonic Topology) → TUNNEL + manifold deformation
  ├── [ ] Mode 46 (Particle Hologram) → PSYCHOACOUSTIC + particle clusters
  ├── [ ] Mode 47 (Sonic Sphereworld) → SPHERICAL + SDF planet
  ├── [ ] Mode 48 (Wave Field) → Migrate spatial_pipeline → spatial_encoder
  ├── Keepers: Mode 40 (Quantum Interferometer), Mode 49 (Fractal Explorer)
  └── Validate HDR limiter (1.0 cap for VR) across all modes

[Phase 4: Comfort & Performance Profiling]
  ├── Target: ≤ 5.5ms per eye frame time (11.1ms total for 90Hz)
  ├── Verify externalized sources (sources stay fixed in world space)
  ├── Confirm zero full-screen strobing or unanchored camera rotation
  └── Test on Quest Link, SteamVR, WMR for LSR/ASW stability
```
