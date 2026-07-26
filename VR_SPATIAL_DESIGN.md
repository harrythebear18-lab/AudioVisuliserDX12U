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

## 7. Implementation Plan

### Phase 1: World Environment (spatial_encoder.hlsl)
- Add `SeWorld` struct and `seWorldEnvironment()` function
- Add depth-resolved glow (`seEmitGlowDepth()`)
- Add `SE_PROFILE_PSYCHOACOUSTIC` profile
- Add VR camera helper (`seCameraVR()`)

### Phase 2: Resonance Field (mode 37) Redesign
- Use PSYCHOACOUSTIC profile
- Configure world: subtle grid floor, fog density 0.06, dark ambient
- Camera: listener inside field, slow orbit, FOV 0.6
- Emitters: Chladni-patterned glow with depth fog
- Negative space: only active emitters render, gated aggressively

### Phase 3: Cosmic Web (mode 36) Migration
- Migrate from spatial_pipeline.hlsl to spatial_encoder.hlsl
- Use SPHERICAL profile with world environment
- Add filament rendering with depth fog
- Camera: outside looking in at web, FOV 0.5

### Phase 4: Neural Synapse (mode 38) Migration
- Migrate from spatial_pipeline.hlsl to spatial_encoder.hlsl
- Use HEMISPHERE profile with world environment
- Add synapse links with depth fog
- Camera: inside brain, FOV 0.7

### Phase 5: Future Modes
- Each new mode selects profile + world config
- Modes can request new profiles as needed (extensible)
- World environment parameters tune per mode concept

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
