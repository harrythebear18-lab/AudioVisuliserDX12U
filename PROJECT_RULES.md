# PROJECT RULES — READ THIS AT START OF EVERY SESSION

## Project: RTX 5060 Blackwell Audio Visualizer (DX12 Ultimate)
- Language: C# with Vortice.Direct3D12 + Vortice.DXC
- Project root: C:\Users\htsou\CascadeProjects\RTXAudioVisualizer
- GPU: RTX 5060 Blackwell, Feature Level 12_2

## MANDATORY REFERENCE DOCUMENTS
1. `DX12U_SHADER_ROADMAP.md` — 21-mode roadmap, architecture, phased plan
2. `SHADER_QUALITY_GATE.md` — 7-section quality checklist for EVERY shader

## CRITICAL RULES
- Every shader MUST pass the SHADER_QUALITY_GATE.md checklist (7 sections)
- Every shader MUST compile with DXC ps_6_6 (not just fxc ps_5_0)
- NO random colour fills — structured visuals with focal points only
- NO simple shaders — minimum 3 layers, 6 audio mappings, 200-400 lines
- Follow the roadmap phases in order: Pipeline → Framework → Shaders → Integration
- Mode 1 (spectrum_3d) is LOCKED — do not modify
- Mode 3 (neon_tunnel) is good — do not modify
- Mode 2 (cosmic_fractal) needs rework — too ugly/random, needs structure

## DXC API (Vortice.DXC 3.8.3)
- Factory: `Dxc.CreateDxcCompiler<IDxcCompiler3>()` and `Dxc.CreateDxcUtils()`
- Compile: `compiler.Compile(string source, string[] args, IDxcIncludeHandler handler)` → `IDxcResult`
- Result: `result.GetStatus(out Result status)`, `result.GetResult()` → `IDxcBlob`, `result.GetErrorBuffer()` → `IDxcBlobEncoding`
- Blob: `blob.AsBytes()` → `byte[]`
- Include handler: `utils.CreateDefaultIncludeHandler()`
- Args: `-E main -T ps_6_6 -D DX12U=1 -Qstrip_reflect -Qstrip_debug -HV 2021 -O3`

## CURRENT STATUS
- DXC compiler initialized and working (falls back to fxc on arg errors)
- 3/5 modes load (chromatic_window + particle_nebula fail: "redefinition of 'brightness'")
- Composite PSO loads (via fxc fallback, needs DXC recompile)
- Bloom pipeline loads (via fxc fallback)
- Root signature: 3 params (2 CBV + 1 descriptor table with 4 SRVs) — needs expansion to 5 params
- Next: fix DXC arg format, fix broken shaders, expand root signature, create include framework
