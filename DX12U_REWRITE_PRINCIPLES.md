# DX12U Rewrite Principles — Mode Rewrite Constraints

## 1. Audio Data: Use What Exists

### Brain Provides Everything
`AudioData` struct (from `extractAudio()`) already contains:
- 8 mono bands: `a.b0`–`a.b7`
- Stereo: `a.specL`, `a.specR`, `a.stereoDiff`, `a.stereoBal`, `a.stereoWid`, `a.leftEn`, `a.rightEn`
- Dynamics: `a.beat`, `a.kick`, `a.transient`, `a.envelope`, `a.overall`, `a.energy`
- Timing: `a.beatPhase`, `a.beatPeriod`, `a.tempoPulse`, `a.bpm`, `a.tempoConf`
- Profile: `a.profBass`, `a.profTreb`, `a.dynamic`, `a.punch`, `a.glow`
- Section: `a.section`, `a.phraseBeat`, `a.shouldChg`
- Color: `a.brainCol`, `a.brainCol2`, `a.brainCol3`, `a.hueBase`, `a.hueCenter`, `a.hueRange`, `a.satur`
- Detection: `a.isSilent`, `a.gated`, `a.speechMode`, `a.calmMode`, `a.voiceActivity`
- DSP: `lufsNormalized()`, `crestFactorNormalized()`, `thdNormalized()`, `phaseCoherence()`, `DspBand0–7`

### No Extra Texture Samples
- Do NOT add `u_spectrum.SampleLevel()` calls in mode shaders
- All data comes from `AudioData` + DSP helpers
- The brain already sampled everything

### Pure Math Abstractions (allowed + encouraged)
```hlsl
// Per-band L/R split — no extra samples
float phaseCoh = phaseCoherence();
float bandL = band * (0.5 + a.stereoDiff * 0.5 * phaseCoh);
float bandR = band * (0.5 - a.stereoDiff * 0.5 * phaseCoh);

// Per-band transient — highs react more
float bandTr = a.transient * lerp(0.3, 1.5, bt);

// Per-band compressor — bass tamed, highs linear
float energy = (band < 4) ? pow(rawEnergy, 0.5) : rawEnergy;

// Per-band noise gate
float gate = smoothstep(0.02, 0.08, rawEnergy);
```

## 2. Rendering Techniques — Go Wild

Use the full toolkit, mix and match per mode:
- **SDF raymarching** — heightfields, metaballs, fractals, distance fields
- **Volumetric raymarching** — density accumulation through 3D fields
- **SDF layers** — multiple distance fields blended with `smin`/`smax`
- **Particle systems** — GPU-side point clouds, orbiting/swarming/flowing
- **Ray-traced reflections** — secondary ray bounces off surfaces
- **Feedback texture** (t5) — previous frame for trails, persistence, wave propagation
- **Domain repetition** (`opRep`) — infinite grids, lattices, arrays
- **Twist/elongation** (`opTwist`, `opElongate`) — organic deformation
- **Curl noise flow fields** — particle advection, fluid-like motion
- **FBM domain warping** — organic flowing patterns
- **Mandelbulb SDF** — fractal geometry with audio-driven power
- **Heightfield SDFs** — liquid surfaces, terrain, ferrofluid
- **Metaball blending** — `smin` for organic blob merging

## 3. Pipeline Rules

### Layer 0 Only
- Mode shader outputs HDR color to Layer 0
- NO `applyPostFX()` — shared pipeline handles bloom, grain, CA, vignette, tonemap
- NO local tonemapping (`acesTonemap`, `cleanFinish`)
- NO `postfx.hlsl` include in rewritten modes

### Time Usage
- `Time` allowed for: continuity, decay, wave propagation, slow drift bounded by audio
- `Time` NOT allowed for: constant idle rotation, cosmetic motion, random scatter
- `a.beatPhase` preferred over raw `Time` for rhythmic phenomena

### HDR Output
- Output linear HDR color, let pipeline tonemap
- Brightness limiter: `if (maxC > 1.5) col *= 1.5 / maxC;`
- `standardOverlays()` sparingly (0.02 weight)

## 4. Audio-to-Physics Mapping (Exclusive Roles)

| Audio Source | Physical Role |
|---|---|
| Sub/bass (b0-b1) | Mass, gravity, pressure, foundation, large-scale displacement |
| Low-mid/mid (b2-b3) | Topology, structure, folds, branches, propagation |
| High-mid/pres (b4-b5) | Flow direction, resonance, medium detail |
| Brilliance/air (b6-b7) | Micro-turbulence, filaments, glints, spray, fine breakup |
| Stereo L/R | Directional force, asymmetric flow, spatial separation |
| Beat | Coherent system-wide compression/expansion/traveling wave |
| Kick | Local impulse, impact, shockfront, eruption, collapse |
| Transient | Rupture, scattering, sparks, collision, material break-up |
| Envelope | Sustained energy, density, glow, swell |
| Section/phrase | Regime change, biome, scale, density, palette shift |
| LUFS | Energy density, exposure, emission boost (additive) |
| Crest | Sharpness, structure, contrast, material hardness |
| Phase | Symmetry, interference, spatial coherence |
| THD | Roughness, warmth, instability, chromatic complexity |

### No Generic Brightness Pulses
- Each audio source must have a distinct, readable physical effect
- Stagger transient response: bass less, highs more
- Stagger beat breathing: bass less, highs more

## 5. Quality Standard

### Required
- Distinct still-frame silhouette
- Macro (shape) + meso (band structure) + micro (transient detail)
- Causal audio response readable without HUD
- Stereo spatial behavior
- Clear focal point + negative space
- HDR highlights for bloom

### Noise Gate + Compressor
```hlsl
float gate = smoothstep(0.02, 0.08, rawEnergy);
float energy = (band < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
result *= gate;
```

### Silence
```hlsl
float silence = 1.0 - a.isSilent;
col += effect * silence;
```

## 6. DSP Integration (Additive Only)
```hlsl
// CORRECT
float bassMass = a.b0 * (1.0 + lufsNormalized() * 0.2);
float edgeSharp = brainEdge * (1.0 + crestFactorNormalized() * 0.25);
// WRONG
float bassMass = DspBand0;
```

## 7. Per-Mode Workflow
1. Read existing shader
2. Define phenomenon + silhouette
3. Assign brain → physics (table above)
4. Add DSP as additive modifiers
5. Implement Layer 0 visual (SDF/volumetric/particles/heightfield — go wild)
6. Verify: no `applyPostFX`, no `postfx.hlsl`, no extra spectrum samples
7. Build + run + visual test
8. **Commit immediately**
9. Update HUD_MODE_BASELINE.md + display name

## 8. Rewrite Queue

| HUD | Current Name | Shader | Concept |
|---|---|---|---|
| 14 | Acoustic Holography (lost) | `dx_neural_network.hlsl` | Volumetric interference field |
| 8 | DNA Helix | `dx_dna_helix.hlsl` | TBD |
| 9 | Spectrum Singularity | `dx_heartbeat.hlsl` | TBD |
| 11 | Spectrum Kaleidoscope | `dx_ray_marched.hlsl` | TBD |
| 18 | Spectrum Black Hole | `dx_crystal.hlsl` | TBD |
| 20 | Spectrum Galaxy | `dx_galaxy.hlsl` | TBD |
| 27 | Water Droplet Pool | `dx_water_droplets.hlsl` | TBD |
| 28 | Matrix Rain | `dx_matrix_rain.hlsl` | TBD |
| 30 | Synthwave Grid | `dx_crystal_lattice.hlsl` | TBD |
