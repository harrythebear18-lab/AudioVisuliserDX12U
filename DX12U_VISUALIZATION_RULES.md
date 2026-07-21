# DX12U Visualization Rules

## Purpose

These rules govern every visualizer mode marked for tuning or rewrite. The goal is high-fidelity, audio-driven phenomena built with the DX12U renderer, the audio brain, Resonance DSP telemetry, GPU rendering, and the shared HDR composite pipeline.

Modes are not static scenes, generic widgets, or arbitrary animations with audio pasted on top. Each mode must behave as a coherent phenomenon whose state is caused by the music.

## Authority and Scope

- The HUD mode list is authoritative for user-facing references: HUD modes are numbered `1-30`.
- Internal renderer indices are zero-based: `internal index = HUD mode - 1`.
- Each mode is developed and validated independently.
- Do not modify shared pipeline shaders, shared include files, root bindings, render passes, or global compositor behavior while working on an individual mode unless a separate, explicit pipeline task has been approved.

## Core Contract

```text
Audio brain / FFT / stereo
        ↓
Mode-specific physical parameters
        ↓
GPU simulation or field evolution
        ↓
HDR material, lighting, density, and depth
        ↓
Shared bloom / composite / tone-map pipeline
```

### Audio Brain Is the Source of Truth

The brain and spectrum are the primary drivers of all mode behaviour:

- Fine FFT spectrum controls per-frequency detail.
- Brain bands `b0-b7` control macro spectral regions.
- Beat, kick, transient, envelope, and overall energy control discrete and continuous events.
- Stereo L/R, balance, width, and phase-derived brain telemetry control real spatial behavior.
- Song section, phrase, colours, and visual profile control macro evolution and presentation.

Every significant visible event must have a traceable audio cause.

### DSP Is Additive

Resonance DSP refines a brain-driven visual; it does not replace the brain signal.

- LUFS refines energy density, exposure, density, or emission.
- Crest factor refines sharpness, structure, contrast, fragmentation, or material hardness.
- Phase coherence refines symmetry, interference, and spatial coherence.
- L/R peaks refine directional bias and local imbalance.
- THD refines controlled roughness, warmth, material instability, or chromatic complexity.
- DSP bands reinforce the corresponding brain-band region only.

Use DSP as a modifier of an existing brain-driven expression:

```hlsl
float bassMass = a.b0 * (1.0 + lufsNormalized() * 0.2);
float edgeSharpness = brainEdgeSharpness * (1.0 + crestFactorNormalized() * 0.25);
```

Do not replace normalized brain-band values with raw DSP bands:

```hlsl
// Forbidden: raw DSP replaces the primary brain signal.
float bassMass = DspBand0;
```

## GPU Responsibility

The GPU turns brain and DSP values into a coherent visual simulation. It should implement forces, fields, materials, geometry, density, light, and temporal continuity.

Valid GPU work includes:

- Particle integration, force fields, advection, flow, collisions, attraction, repulsion, and density accumulation.
- Raymarched volumes, signed-distance geometry, material response, scattering, fog, occlusion, and reflections.
- Heightfields, waves, deformation, fracture, growth, branching, propagation, and field displacement.
- HDR emission, Fresnel response, glints, caustics, shockfronts, light transport illusions, and depth layering.
- Feedback/history for trails, persistence, smoke-like continuity, and energy propagation when the mode architecture supports it.

## Time Rule

Time is permitted for continuity and for restrained supporting animation within an audio-driven system. Animation must reinforce the phenomenon's form, material, spatial composition, or rhythm; it must never become the primary source of visual interest.

Valid uses:

- Integrating brain-derived velocity.
- Advecting particles through an audio-derived field.
- Propagating a beat or kick impulse.
- Decaying energy, trails, density, waves, or collision effects.
- Maintaining a coherent physical state between audio frames.
- Slow camera drift, atmospheric flow, orbit, scan, shimmer, or material movement when it preserves composition and remains bounded by audio-derived energy, tempo, section, or state.

Invalid uses:

- Constant idle rotation with no audio cause.
- Random drifting points unrelated to a field or audio force.
- Static decorative objects with global amplitude scaling.
- Cosmetic motion that continues unchanged regardless of the music.
- Generic animation used to hide a weak silhouette, missing audio causality, or an otherwise static mode.

## Audio-to-Physics Mapping

Modes must assign exclusive, readable roles to audio data.

- **Sub / bass:** mass, gravity, pressure, foundation, displacement, large-scale motion.
- **Low-mid / mids:** topology, structure, folds, branches, propagation, flow direction, resonant form.
- **Highs:** micro-turbulence, edge detail, filaments, glints, discharge, spray, sparks, fine breakup.
- **Stereo:** directional force, asymmetric flow, spatial separation, parallax, source placement.
- **Beat:** coherent system-wide compression, expansion, or travelling wave.
- **Kick:** local impulse, impact, shockfront, uplift, collapse, fracture, or lensing surge.
- **Transient:** rupture, scattering, spark emission, collision, lightning, material break-up, or turbulence injection.
- **Section / phrase:** changes to the governing regime, biome, scale, density, palette, or complexity over musical time.

Do not map all audio inputs to the same brightness pulse.

## Spatial Spectrum Rule

When a mode uses the spectrum texture:

- Sample `v = 0.166` for left, `v = 0.5` for mono, and `v = 0.833` for right.
- Keep L/R paths independent when the mode promises spatial dispersion.
- Share only deliberate low-frequency content when physically appropriate.
- Preserve frequency ordering; do not scramble bins merely to fill geometry.
- Use logarithmic frequency placement where visual spacing must match perceptual musical spacing.

## Composite Pipeline Contract

The shared renderer owns final compositing.

- Mode shaders output HDR core visual data to Layer 0.
- Shared bloom extracts, blurs, and composites HDR highlights.
- Shared post-processing owns composite-level grain, chromatic aberration, vignette, and anamorphic treatment.
- Shared tone mapping converts HDR to the final LDR backbuffer.
- SkiaSharp is optional and reserved for sparse foreground elements, diagnostics, labels, rare particles, or details that benefit from its overlay path.

Mode shaders must not locally apply final tone mapping, final post-processing, or duplicate global compositing effects.

## Visual Quality Standard

A mode is ready to be marked good only when it has all of the following:

- A distinct, recognizable still-frame silhouette.
- A coherent physical identity over time.
- Macro, meso, and micro visual detail.
- Causal audio response that is readable without HUD data.
- Meaningful spatial stereo behavior where applicable.
- A clear focal point and controlled negative space.
- HDR highlights that benefit from shared bloom and tone mapping.
- No generic band-object layout unless that layout is the intentional core concept.
- No random or static behaviour that is not justified by the audio-driven system.

## Per-Mode Workflow

1. Identify the HUD mode number and resolve its internal index.
2. Define the phenomenon and its single-frame silhouette before implementation.
3. Assign brain data to physical parameters before writing visual code.
4. Assign DSP data as bounded, additive material or coherence modifiers.
5. Implement the core HDR Layer 0 visual only.
6. Verify the shader compiles and the shared pipeline remains untouched.
7. Restart and test against real music:
   - bass-only material
   - mid-dense material
   - high-frequency material
   - stereo-separated material
   - beat / kick / transient passages
   - quiet passages
8. Tune only the causal mapping that is visually weak.
9. Obtain user visual approval before changing the roadmap status to good.

## Forbidden Patterns

- Replacing brain bands with raw DSP band values.
- Generic time-driven orbits, drift, or random scatter with no audio force.
- Global brightness flashes standing in for physical response.
- Sharing L/R spectrum data where spatial separation is required.
- Letting unrelated audio bands compete for the same visual role.
- Applying final postfx or tone mapping inside an individual mode.
- Editing global shader or pipeline files during a per-mode task.
- Marking a mode good solely because it compiles or loads.
