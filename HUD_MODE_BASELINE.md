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
| 7 | 6 | Aurora Borealis (Ionospheric Curtain) | `dx_aurora.hlsl` | Tune | Volumetric curl-noise plasma curtains; bass=mass/thickness, mids=topology, highs=filaments, stereo=L/R placement, beat=pulse, kick=shockfront, transient=rupture; acceptable, needs tuning. |
| 8 | 7 | DNA Helix | `dx_dna_helix.hlsl` | Rewrite | |
| 9 | 8 | Spectrum Singularity | `dx_heartbeat.hlsl` | Good | |
| 10 | 9 | RTX Mesh | `dx_rtx_mesh.hlsl` | Good | |
| 11 | 10 | Spectrum Kaleidoscope | `dx_ray_marched.hlsl` | Rewrite | |
| 12 | 11 | Volumetric Clouds | `dx_volumetric_clouds.hlsl` | Good | |
| 13 | 12 | Fractal Dimensions | `dx_fractal_dimensions.hlsl` | Good | |
| 14 | 13 | Neural Network | `dx_neural_network.hlsl` | Rewrite | |
| 15 | 14 | Quantum Field | `dx_quantum_field.hlsl` | Good | |
| 16 | 15 | Holographic | `dx_holographic.hlsl` | Good | |
| 17 | 16 | Particle Storm | `dx_particle_storm.hlsl` | Good | |
| 18 | 17 | Spectrum Black Hole | `dx_crystal.hlsl` | Rewrite | |
| 19 | 18 | Spectrum Terrain | `dx_terrain.hlsl` | Good | |
| 20 | 19 | Spectrum Galaxy | `dx_galaxy.hlsl` | Rewrite | |
| 21 | 20 | Wave Pool + Tessellation | `dx_wave_tessellation.hlsl` | Good | |
| 22 | 21 | Audio Tessellation | `dx_audio_tessellation.hlsl` | Good | |
| 23 | 22 | Spectrum Vortex | `dx_compute_shaders.hlsl` | Rewrite | |
| 24 | 23 | Spectrum Reflections | `dx_rtx_reflections.hlsl` | Rewrite | |
| 25 | 24 | 3D Spectrum Bars | `dx_spectrum_3d.hlsl` | Good | |
| 26 | 25 | Spatial Dolby | `dx_spatial_dolby.hlsl` | Good | |
| 27 | 26 | Water Droplet Pool | `dx_water_droplets.hlsl` | Rewrite | |
| 28 | 27 | Matrix Rain | `dx_matrix_rain.hlsl` | Rewrite | |
| 29 | 28 | Audio Waveform Tunnel | `dx_waveform_tunnel.hlsl` | Rewrite | |
| 30 | 29 | Synthwave Grid | `dx_crystal_lattice.hlsl` | Rewrite | |
