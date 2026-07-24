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

## Technical Implementation Standards

These standards codify the proven patterns from the gold-standard modes (4, 5, 6, 8, 10, 12, 13, 14, 15, 17, 21, 22, 23). Every mode rewrite or new mode must follow them.

### Includes

- **Required**: `audio_cb.hlsl`, `color_utils.hlsl`, `noise.hlsl`, `audio_reactive.hlsl`, `layers.hlsl`
- **For raymarched modes**: add `raymarch.hlsl`
- **For SDF surface modes**: add `sdf.hlsl`
- **For DSP-using modes**: add `dsp_cb.hlsl`
- **Forbidden**: `postfx.hlsl` and `applyPostFX()` in any mode that outputs to the shared pipeline. The pipeline owns tonemapping, bloom, grain, CA, and vignette.

### Per-Element Audio System

Use `audioSimElement(idx, total, a)` for per-source/per-particle audio data. This is the proven method across all gold-standard modes.

- **24 elements** is the sweet spot: enough density for rich interference, few enough for `[unroll]` loops
- Each element provides: `amplitude`, `ampL`, `ampR`, `pan`, `panOffset`, `intensity`, `transientScatter`, `freqFrac`
- Every visual element must trace its audio origin through this struct or direct spectrum sampling

### Noise Gate and Compression

Every source/particle must be noise-gated to avoid idle noise:

```hlsl
float gate = smoothstep(0.02, 0.08, e.amplitude);
```

Bass elements use a compressor curve (perceptual loudness):

```hlsl
float energy = (band < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
```

### DSP Additive Formulas (Never Replace Brain)

```hlsl
// LUFS — boosts density/emission
val *= (1.0 + lufsNormalized() * 0.2);

// Crest — sharpens edges/contrast
sharpness = 1.0 + crestFactorNormalized() * 0.5;

// THD — adds controlled roughness/turbulence
phase += thdNormalized() * noise * 0.05;

// Phase coherence — mono = coherent, stereo = complex
coherence = lerp(0.3, 1.0, phaseCoherence());
```

### Camera Setup

- Use `cameraRay(camPos, camTarget, p, fov)` from `raymarch.hlsl` — never manual 2D projection
- Camera orbit driven by: `a.section * 0.8 + Time * 0.03 * a.motSpeed` (section-driven, not idle)
- Stereo balance shifts camera: `a.stereoBal * 0.2`
- Stereo diff adjusts height: `a.stereoDiff * 0.15`
- FOV typically 0.35–1.0 depending on scene scale
- Flip screen coords for ray: `float2(-p.x, -p.y)` when needed

### Volumetric Raymarching (for field/volume modes)

```hlsl
float t = 0.15;           // start offset
float3 accum = 0.0;
float transmittance = 1.0;
float stepSize = 0.08;     // or adaptive

[loop] for (int i = 0; i < 48; i++) {
    float3 sp = camPos + rd * t;
    // Bounding volume check
    if (length(sp) > maxRadius) break;

    float density = fieldFunction(sp, ...);
    density *= smoothstep(0.002, 0.02, density);  // noise gate

    if (density > 0.003) {
        float3 pointCol = colorFunction(sp, ...);
        float depthFog = exp(-t * 0.08);
        float emission = density * intensity * depthFog;

        // Beer-Lambert extinction
        float sigma = density * 0.15 + 0.02;
        transmittance *= exp(-sigma * stepSize);

        accum += pointCol * emission * transmittance;
    }
    t += stepSize;  // or adaptive: max(0.04, stepSize - density * 0.03)
}
```

### SDF Surface Raymarching (for solid geometry modes)

```hlsl
float t = 0.05;
float marchGlow = 0.0;
float steps = 0.0;
bool hit = false;

[loop] for (int i = 0; i < 48; i++) {  // or 64 for complex SDFs
    float3 sp = camPos + rd * t;
    float d = sceneSDF(sp, a);
    marchGlow += 0.01 / (1.0 + d * d * 50.0);
    steps += 1.0;
    if (d < 0.001) { hit = true; break; }
    t += d * 0.5;  // 0.5 = safety factor
    if (t > 10.0) break;
}
float ao = 1.0 - steps / float(MAX_STEPS) * 0.5;
```

On hit: compute normal via finite differences, apply 2-3 light setup with diffuse + spec + fresnel, use `cleanLighting()` or inline equivalent.

### Golden Ratio Acoustic Mapping

For frequency-to-spatial mappings (wavelength, depth, source positioning):

```hlsl
#define PHI 1.618
float Cf = (Dx * PI) / PHI;  // Dx = frequency-dependent distance, Cf = compressed frequency
```

This applies golden ratio compression to circumference-derived values, producing natural acoustic-perception-aligned spatial mapping.

### Distinct Physical Events

Each audio event must produce a visually distinct physical response:

- **Beat** (`a.beat * a.tempoConf`): system-wide compression, contraction, or traveling wave through the field
- **Kick** (`a.kick * a.kickConf * exp(-a.beatPhase * 3.0)`): localized impulse, shockfront, radial burst, impact
- **Transient** (`a.transient`): rupture, scatter, spark emission, phase break, material disruption
- **Beat anticipation** (`a.beatAnt`): pre-beat tension, subtle build
- **Burst** (`a.burstTrig`, `a.burstInt`): event-type-dispatched flash via `effectBurst()`

Never collapse these into a single brightness pulse.

### Color System

- Primary: `a.brainCol`, `a.brainCol2`, `a.brainCol3` — the brain's palette
- Frequency mapping: `hsv(a.hueBase + freqFrac * a.hueRange, 0.6 * a.satur, 0.9)`
- Blend: `lerp(a.brainCol, a.brainCol2, freqFrac)` for frequency-positioned color
- Section tint: `a.section * 0.03`, color pulse: `a.colorPulse * 0.04`
- Never use flat block colors or hardcoded palettes

### Output Contract

```hlsl
// standardOverlays — subtle, never overpowering
col += standardOverlays(p, r, a) * 0.02;  // volumetric modes
// or 0.2-0.5 for surface/particle modes with more negative space

// HDR limiter — prevent bloom blowout before pipeline
float maxC = max(col.r, max(col.g, col.b));
if (maxC > 1.2) col *= 1.2 / maxC;  // 1.2 for most, 1.5 for dark volumetric modes

// Silence suppression
col *= (1.0 - a.isSilent * 0.98);  // or use `silence = 1.0 - a.isSilent` multiplier

return float4(col, 1.0);
```

### What Makes a Mode Showcase-Worthy

1. **Distinct silhouette**: recognizable in a single still frame — not a generic blob
2. **3D depth cues**: parallax, depth fog, occlusion, perspective scaling — never flat 2D
3. **Causal audio response**: viewer can see what the music is doing without HUD
4. **Multi-scale detail**: macro (form/structure) + meso (patterns/waves) + micro (shimmer/edges)
5. **Physical identity**: the mode IS a phenomenon (black hole, interference field, storm, tessellation), not a collection of effects
6. **Stereo spatial behavior**: L/R produces visible spatial separation, not just brightness changes
7. **Dynamic range response**: quiet passages are dark and minimal, loud passages are full and bright — driven by `a.gated`, `a.envelope`, `a.brightness`
8. **No block colors, no generic spheres, no glyph-like shapes** — everything is field-derived, wave-derived, or physically motivated

---

## 3D Spatial Audio Math

Use the following formulas for 3D spatial coordinate computation, audio attenuation, and HLSL vertex/density deformation.

### 1. Relative 3D Vector & Distance

Given Listener Position `L = (Lx, Ly, Lz)` and Audio Source `S = (Sx, Sy, Sz)`:

```
Relative Vector V = S - L
Distance d = sqrt(Vx^2 + Vy^2 + Vz^2)
Normalized Direction N = V / d
```

### 2. Distance Attenuation (Inverse Square / Clamped)

```
Gain A(d) = 1.0 / (1.0 + k * d^2)        [k = attenuation factor]
Clamped Range Gain = clamp(1.0 - (d / d_max), 0.0, 1.0)
```

### 3. 3D Spherical Coordinates (Azimuth & Elevation)

```
Azimuth  theta = atan2(Vx, Vz)
Elevation phi = asin(Vy / d)
```

### 4. 3D HLSL Vertex / Mesh Deformation Shader Math

For vertex position `P = (x, y, z)` displaced by 3D audio source `S` with frequency `f` and wave speed `c`:

```
Spatial Wavenumber k_w = (2 * PI * f) / c
Phase Shift phi_t = k_w * d - omega * time

Displacement Vector D_3D = Normal_v * sin(phi_t) * A(d) * Intensity
P_final = P + D_3D
```

### HLSL CBuffer & Vector Math Snippet

```hlsl
// Constant Buffer Layout for 3D Spatial Audio
cbuffer SpatialAudioBuffer : register(b0)
{
    float3 g_SourcePos;     // 3D Audio Source (X, Y, Z)
    float  g_Attenuation;   // Computed gain factor A(d)
    float3 g_ListenerPos;   // 3D Listener Position (X, Y, Z)
    float  g_Frequency;     // Peak frequency for spatial ripple
    float3 g_SpatialVector; // Normalized direction vector (N)
    float  g_Time;          // Global render time
};

// 3D Spatial Deformation Function
float3 Apply3DSpatialWave(float3 worldPos, float3 worldNormal)
{
    float dist = distance(worldPos, g_SourcePos);
    float wave = sin(dist * g_Frequency - g_Time * 4.0);

    // Attenuation falls off smoothly over 3D euclidean distance
    float spatialGain = g_Attenuation / (1.0 + 0.1 * dist * dist);

    // Displace vertex along normal scaled by 3D spatial gain
    return worldPos + (worldNormal * wave * spatialGain);
}
```
