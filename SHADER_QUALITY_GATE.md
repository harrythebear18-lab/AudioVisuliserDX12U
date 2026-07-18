# Shader Quality Gate Checklist
## Apply to EVERY shader mode — no exceptions

---

## 1. Layer Depth (minimum 3 visible layers)
- [ ] **Background layer** — 2D field, gradient, noise, or atmosphere (not flat black)
- [ ] **Midground layer** — 2.5D parallax, 3D raymarch, or structured geometry
- [ ] **Foreground layer** — 1D spectrum/waveform/particles reacting to audio
- [ ] Layers are visually distinguishable (depth fog, blur, or brightness falloff)
- [ ] Layers blend with purposeful blend mode (screen/add/overlay — not just overwrite)

## 2. Audio Reactivity (minimum 6 independent audio mappings)
- [ ] Bass band (Profile1.bass or Rhythm.kick) drives a visible structural change
- [ ] Mid band (Profile1.mid) drives color or motion
- [ ] Treble band (Profile1.treble) drives detail/sparkle/particles
- [ ] Beat (Rhythm.kick or Dynamics.transient) triggers a discrete event (pulse, flash, ripple)
- [ ] BPM (Rhythm.bpm) drives continuous motion speed
- [ ] Stereo width (Profile2.stereo) drives L/R separation or spread
- [ ] Envelope/dynamics (Dynamics.envelope) drives intensity/brightness
- [ ] Section awareness (ColorHue shifts with song section)
- [ ] Spectrum texture sampled (not just UBO scalars — actual frequency bin data)

## 3. Visual Structure (no random colour fills)
- [ ] Clear focal point (center brighter, edges darker via vignette)
- [ ] Structured geometry or pattern — not just noise filling the screen
- [ ] Colour palette is cohesive (analogous or complementary, not random rainbow)
- [ ] Negative space exists (screen is not 100% covered with max-intensity colour)
- [ ] Depth cues present (perspective, fog, parallax, or size variation)

## 4. Anti-Fatigue
- [ ] No strobing (beat flashes use exponential decay, not instant on/off)
- [ ] Rest periods (visuals calm between beats, not constantly at max intensity)
- [ ] Smooth easing on all audio-driven parameters (lerp + smoothstep)
- [ ] Hue shifts are gradual (no jarring colour jumps)
- [ ] Motion is coherent (elements move in related directions, not chaotic)

## 5. Post-Processing
- [ ] Tone mapping applied (ACES or Reinhard — no raw HDR clipping)
- [ ] Vignette (subtle darkening at edges, 0.3-0.5 intensity)
- [ ] Bloom integration (shader outputs bloom-friendly bright areas)
- [ ] Chromatic aberration on transients (subtle, only on beat spikes)
- [ ] Optional: film grain, lens distortion, scan lines (mode-dependent)

## 6. Code Quality
- [ ] Uses `#include` shared headers (audio_cb, color_utils, noise, etc.)
- [ ] No hardcoded magic numbers — audio-driven or named constants
- [ ] Clean function separation (backgroundLayer(), midgroundLayer(), foregroundLayer())
- [ ] 200-400 lines (substantial but not bloated)
- [ ] Compiles with DXC ps_6_6 (SM6.6+ features used where appropriate)
- [ ] No variable redefinition errors (unique variable names per scope)

## 7. DX12U Feature Usage (at least 1 per shader)
- [ ] Wave intrinsics (WaveActiveSum, WavePrefixSum for FFT acceleration)
- [ ] 16-bit floats (min16float where precision isn't critical)
- [ ] DXR 1.1 inline raytracing (TraceRay in pixel shader for reflections)
- [ ] Mesh shader dispatch (DispatchMesh for geometry generation)
- [ ] VRS (coarse shading on low-detail regions)
- [ ] Compute shader (RWStructuredBuffer for particle simulation)
- [ ] Note: Not all features per shader — but each shader should use at least 1

---

## Scoring
- **Pass all 7 sections**: Ship it
- **Fail 1 section**: Fix before shipping
- **Fail 2+ sections**: Rework the shader

## Red Flags (instant reject)
- Flat solid colour background
- Only 1-2 audio parameters used
- No depth/parallax/perspective (everything looks 2D flat)
- Random noise filling entire screen with no structure
- Strobing or flashing without decay
- Shader compiles only with fxc ps_5_0 (must compile with DXC ps_6_6)
- Under 100 lines (too simple for this pipeline)
