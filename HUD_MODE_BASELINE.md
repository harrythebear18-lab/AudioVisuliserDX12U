# HUD Mode Baseline

Review every HUD mode after the shared HDR pipeline is confirmed healthy. Use the HUD number as the primary reference. Do not classify a mode from compilation alone; assess its actual visual composition, audio causality, spatial response, and behavior through the HDR composite path.

## Classification

- **Good**: Preserve the method; only minor follow-up work if explicitly requested.
- **Tune**: Visual method is sound, but causal audio mapping, material response, scale, or readability needs controlled refinement.
- **Rewrite**: Replace the visual method with a new audio-driven phenomenon under `DX12U_VISUALIZATION_RULES.md`.
- **Deferred**: Hold for a later decision.

| HUD | Internal | Display name | Shader | Classification | Visual notes |
|---:|---:|---|---|---|---|
| 1 | 0 | Quantum Bars | `dx_quantum_bars.hlsl` | Good | |
| 2 | 1 | Plasma Field | `dx_plasma_field.hlsl` | Good | |
| 3 | 2 | Neon Pulse | `dx_neon_pulse.hlsl` | Good | |
| 4 | 3 | Particle Flow | `dx_particle_flow.hlsl` | Good | |
| 5 | 4 | Audio Lichtenberg | `dx_waveform.hlsl` | Good | Branching discharge tree; bass=trunk mass, mid bands=topology (independent L/R), highs/air=filament tips, beat=traveling flash, kick=strike flare, transient=sparks. |
| 6 | 5 | Chladni Plate | `dx_sphere.hlsl` | Good | Standing-wave interference field; 8 mode-pairs per band, section=regime unlock, domBand=highlight, L/R energy=mode skew, beat=phase realign, kick=impulse ripple. |
| 7 | 6 | Aurora Borealis | `dx_aurora.hlsl` | Good | Raymarched volumetric ionospheric curtains (1-4 based on section). Bass=curtain mass/thickness, mids=topology (curl-noise fold), highs=micro-detail filaments. Stereo=L/R independent curtain placement. Beat=coherent brightness wave, kick=ground-level shockfront, transient=tearing rupture through curtain. DSP: LUFS→exposure, crest→density sharpness. No applyPostFX, no Time orbit. |
| 8 | 7 | DNA Helix | `dx_dna_helix.hlsl` | Rewrite | |
| 9 | 8 | Spectrum Singularity | `dx_heartbeat.hlsl` | Good | |
| 10 | 9 | RTX Mesh | `dx_rtx_mesh.hlsl` | Good | |
| 11 | 10 | Spectrum Kaleidoscope | `dx_ray_marched.hlsl` | Rewrite | |
| 12 | 11 | Volumetric Clouds | `dx_volumetric_clouds.hlsl` | Good | |
| 13 | 12 | Fractal Dimensions | `dx_fractal_dimensions.hlsl` | Good | |
| 14 | 13 | Acoustic Holography | `dx_neural_network.hlsl` | Good | 3D volumetric interference field raymarched through a volume where 8 spatial frequency components from L/R wavefront sources interfere; b0-b7=8 spatial frequency component energies (bass=long wavelength, highs=short, band energy compresses wavelength for pattern shape change), beat=reconstruction focus + pattern reconfiguration (phase jump), kick=phase discontinuity (perspective shift), transient=speckle + shell scatter, envelope=field density, overall=field energy, stereo L/R=independent 3D wavefront source positions & amplitudes (stereoWid=separation, stereoBal=shift, stereoDiff=vertical tilt), beatAnt=anticipatory pre-fringes, beatPhase=temporal phase, tempoPulse=pulsing density, section=regime (near-field→Fresnel→Fraunhofer), phraseBeat=macro density, speechMode=simplified, calmMode=quiescent, domBand=highlighted component, volume size=profBass+envelope, wavefront shells=band energy drives reach + beatPhase dri...[251 bytes truncated] |
| 15 | 14 | Quantum Field | `dx_quantum_field.hlsl` | Good | |
| 16 | 15 | Holographic | `dx_holographic.hlsl` | Good | |
| 17 | 16 | Particle Storm | `dx_particle_storm.hlsl` | Good | |
| 18 | 17 | Spectrum Black Hole | `dx_crystal.hlsl` | Rewrite | |
| 19 | 18 | Spectrum Terrain | `dx_terrain.hlsl` | Good | |
| 20 | 19 | Spectrum Galaxy | `dx_galaxy.hlsl` | Rewrite | |
| 21 | 20 | Wave Pool + Tessellation | `dx_wave_tessellation.hlsl` | Good | |
| 22 | 21 | Audio Tessellation | `dx_audio_tessellation.hlsl` | Good | |
| 23 | 22 | Acoustic Ferrofluid | `dx_compute_shaders.hlsl` | Good | SDF heightfield ferrofluid pool viewed at 3/4 angle. 24 spikes (3 per band) in distinct radial zones (b0 inner→b7 outer, 0.4 gap between bands, no overlap). Noise gate flattens spikes when band quiet. Compressor on b0-b3 (sqrt), linear b4-b7. Squared energy for highs = sharp transients. Beat breathing staggered (highs more). Kick eruption on bass. Transient surface jitter + speckle. Envelope swell. Section boost. Blackbody coloring (dark red→orange→white-hot tips). Metallic Fresnel + specular (power 80). tipAlpha fades peaks transparent instead of white blowout. DSP: LUFS→surface level, crest→spike sharpness, THD→roughness, phaseCoh→symmetry tint. Dynamic/punch/glow/energy additive. No local postfx, no Time orbit, pure trig. |
| 24 | 23 | Acoustic Droplets & Mirror Pool | `dx_rtx_reflections.hlsl` | Good | 24 dropping objects (3 pulses per band) fall from above into dark reflective liquid pool. Beat phase drives fall cycle with phase offsets per band/pulse. Objects fall fast (quadratic), impact creates expanding ripple rings, then sink. Noise gate + compressor on b0-b3. Kick = big bass splash + radius boost. Transient = scatter droplets on highs. Ray-traced liquid surface reflection (32 steps) shows drops mirrored below. Metallic Fresnel + specular (power 100). Ripple ring glow on surface per drop. Brain colors blend across bands. DSP: LUFS→pool level, crest→object sharpness, phaseCoh→color tint. No Time orbit, no applyPostFX. |
| 25 | 24 | 3D Spectrum Bars | `dx_spectrum_3d.hlsl` | Good | |
| 26 | 25 | Spatial Dolby | `dx_spatial_dolby.hlsl` | Good | |
| 27 | 26 | Water Droplet Pool | `dx_water_droplets.hlsl` | Rewrite | |
| 28 | 27 | Matrix Rain | `dx_matrix_rain.hlsl` | Rewrite | |
| 29 | 28 | Audio Waveform Tunnel | `dx_waveform_tunnel.hlsl` | Tuning | |
| 30 | 29 | Synthwave Grid | `dx_crystal_lattice.hlsl` | Rewrite | |
