using System;
using System.Numerics;
using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D12;
using Vortice.Direct3D12.Debug;
using Vortice.DXGI;
using Vortice.D3DCompiler;
using Vortice.Dxc;
using Vortice.Mathematics;
using System.Text;
using SharpGen.Runtime;
using StageSimWASAPI;
using static Vortice.Direct3D12.D3D12;
using static Vortice.DXGI.DXGI;

namespace DXRenderer;

/// <summary>
/// D3D12 Ultimate renderer — Feature Level 12_2, DXR 1.1 inline raytracing,
/// mesh shaders, VRS, Shader Model 6.6+ via DXC.
/// Renders fullscreen-quad HLSL pixel shaders through D3D12 command lists,
/// descriptor heaps, and root signatures. Includes multi-pass bloom pipeline.
/// </summary>
public class DX12Renderer : IRenderer
{
    private ID3D12Device10 _device = null!;
    private IDXGISwapChain3 _swapChain = null!;
    private IDXGIFactory4 _factory = null!;
    private ID3D12CommandQueue _commandQueue = null!;
    private ID3D12Fence _fence = null!;
    private readonly AutoResetEvent _fenceEvent = new(false);
    private ulong _fenceValue;

    private const int FrameCount = 2;
    private int _frameIndex;
    private ID3D12CommandAllocator[] _commandAllocators = new ID3D12CommandAllocator[FrameCount];
    private ID3D12GraphicsCommandList6 _commandList = null!;

    private ID3D12Resource[] _renderTargets = new ID3D12Resource[FrameCount];
    private ID3D12DescriptorHeap _rtvHeap = null!;
    private uint _rtvDescriptorSize;

    private ID3D12Resource _layerTex0 = null!;
    private ID3D12DescriptorHeap _rtvHeapLayer = null!;
    private ID3D12Resource _layerTex1 = null!;
    private ID3D12DescriptorHeap _rtvHeapLayer1 = null!;

    // Feedback texture for simulation memory (previous frame output)
    private ID3D12Resource _feedbackTex0 = null!;

    private ID3D12RootSignature _rootSignature = null!;
    private ID3D12PipelineState _compositePSO = null!;

    private ID3D12Resource _vertexBuffer = null!;
    private ID3D12Resource _indexBuffer = null!;

    private ID3D12Resource _audioCB = null!;
    private ID3D12Resource _timeCB = null!;
    private IntPtr _audioCBPtr;
    private IntPtr _timeCBPtr;

    private ID3D12Resource _spectrumTexture = null!;
    private ID3D12Resource _spectrumUploadBuffer = null!;
    private IntPtr _spectrumUploadPtr;
    private uint _spectrumUploadSize;
    private bool _spectrumDirty;

    // Bloom pipeline resources
    private ID3D12Resource _bloomTexture = null!;
    private ID3D12Resource _bloomTexture2 = null!;
    private ID3D12PipelineState _bloomExtractPSO = null!;
    private ID3D12PipelineState _bloomBlurHPSO = null!;
    private ID3D12PipelineState _bloomBlurVPSO = null!;
    private ID3D12PipelineState _bloomCombinePSO = null!;
    private ID3D12DescriptorHeap _bloomRtvHeap = null!;
    private bool _bloomEnabled = true;

    // PostFX + Tone-map pipeline resources (multi-pass HDR compositing)
    private ID3D12Resource _postfxTex = null!;
    private ID3D12DescriptorHeap _postfxRtvHeap = null!;
    private ID3D12PipelineState _postfxPSO = null!;
    private ID3D12PipelineState _tonemapPSO = null!;

    // SkiaSharp 2D overlay layer
    private ID3D12Resource _skiaTex = null!;
    private ID3D12Resource _skiaUploadBuffer = null!;
    private IntPtr _skiaUploadPtr;
    private uint _skiaUploadSize;
    private ID3D12PipelineState _skiaPSO = null!;
    private SkiaOverlay? _skiaOverlay;
    private bool _skiaEnabled = true;
    private AudioUBO _currentAudioUBO;

    // Resonance DSP constant buffer (b2)
    private ID3D12Resource _dspCB = null!;
    private IntPtr _dspCBPtr;
    private const int DSP_CB_SIZE = 64; // 16 floats = 64 bytes

    private ID3D12DescriptorHeap _cbvSrvUavHeap = null!;
    private ID3D12DescriptorHeap _samplerHeap = null!;
    private uint _srvDescriptorSize;
    private ID3D12PipelineState _overlayPSO = null!;

    private Dictionary<string, ID3D12PipelineState> _pixelShaders = new();
    private List<string> _modeNames = new();
    private Dictionary<string, string> _displayNames = new()
    {
        { "quantum_bars", "Quantum Bars" },
        { "plasma_field", "Plasma Field" },
        { "neon_pulse", "Spectrum Tectonics" },
        { "particle_flow", "Spectrum Vortex" },
        { "waveform", "Audio Lichtenberg" },
        { "sphere", "Chladni Plate" },
        { "aurora", "Aurora Borealis" },
        { "dna_helix", "Spectrum Helix" },
        { "heartbeat", "Acoustic Wavefront Propagator" },
        { "rtx_mesh", "RTX Mesh" },
        { "ray_marched", "Spectrum Kaleidoscope" },
        { "volumetric_clouds", "Volumetric Clouds" },
        { "fractal_dimensions", "Spectrum Mandelbox" },
        { "neural_network", "Acoustic Holography" },
        { "quantum_field", "Spectrum Lattice" },
        { "holographic", "Holographic" },
        { "particle_storm", "Spectrum Storm" },
        { "crystal", "Ferrofluid Wavefield" },
        { "terrain", "Spectrum Terrain" },
        { "galaxy", "Spacetime Gravity Waves" },
        { "wave_tessellation", "Dual Tessellation" },
        { "audio_tessellation", "Audio Tessellation" },
        { "compute_shaders", "Ferrofluid Pool" },
        { "rtx_reflections", "Acoustic Droplets & Mirror Pool" },
        { "spectrum_3d", "3D Spectrum Bars" },
        { "spatial_dolby", "3D Spatial Soundscape" },
        { "water_droplets", "Seismic Tectonic Plate" },
        { "matrix_rain", "Audio-Reactive Mandelbulb" },
        { "waveform_tunnel", "Audio Waveform Tunnel" },
        { "crystal_lattice", "Synthwave Horizon" },
        { "space_plasma", "Space Plasma Field" },
        { "gravitational_waves", "Gravitational Space Waves" },
        { "fluid_dynamics", "Fluid Dynamics" },
        { "lightning_storm", "Lightning Storm" },
        { "neon_cityscape", "Neon Cityscape" },
        { "spectrum_waterfall", "Spatial Audio Sonar" },
        { "cosmic_web", "Gravitational Wavefield" },
        { "laser_show", "Resonance Field" },
        { "neural_synapse", "Neural Synapse Storm" },
        { "hologram_projector", "Acoustic Hologram Projector" },
        { "quantum_interferometer", "Quantum Field Interferometer" },
        { "aurora_cathedral", "Spectral Aurora Cathedral" },
        { "gravitational_lens", "Gravitational Lens Observatory" },
        { "phonon_crystal", "Phonon Crystal Lattice" },
        { "cymatic_chamber", "Cymatic Resonance Chamber" },
        { "sonic_topology", "Sonic Topology Mapper" },
        { "particle_hologram", "Acoustic Particle Hologram" },
        { "freq_nebula", "Sonic Sphereworld" },
        { "wave_field", "Spatiotemporal Wave Field" },
        { "fractal_explorer", "Fractal Dimension Explorer" },
    };
    private int _currentMode;
    private bool _shouldResetGPU = false;

    // Dragon head mesh — deferred (requires mesh shader PSO support)
    private ID3D12PipelineState _dragonPSO = null!;
    private bool _dragonUseMeshShader = false;

    // DX12 Ultimate feature support
    private bool _workGraphsSupported;
    private bool _dxrSupported;
    private bool _meshShadersSupported;
    private bool _vrsSupported;
    private int _dxrTier;
    private int _vrsTier;
    private bool _firstFrame = true;

    // Work graph resources
    private ID3D12StateObject? _workGraphStateObject;
    private ID3D12RootSignature? _workGraphRootSig;
    private ProgramIdentifier _workGraphProgramId;
    private ID3D12Resource? _workGraphBackingMemory;
    private ID3D12Resource? _workGraphOutputTex;
    private ulong _workGraphBackingMemSize;
    private bool _workGraphLoaded;
    private DX12HUD? _hud;
    private bool _hudVisible = true;
    private byte[]? _vsBytecode;

    // Bloom is handled by DX11 compositor — DX12 renders high-quality visualizer into shared texture
    // DX12 Ultimate uses DXC SM6.6+ compilation for inline raytracing and advanced shader features

    private QuadBufferedVisuals.VisualFrame _lastFrame;

    private int _width;
    private int _height;
    private float _time;
    private float _deltaTime;
    private bool _verbose = true;
    private int _frameCount = 0;
    private float _totalRenderTime = 0f;
    private float _minRenderTime = float.MaxValue;
    private float _maxRenderTime = float.MinValue;
    private bool _disposed = false;

    private static readonly System.Diagnostics.Stopwatch _renderTimer = System.Diagnostics.Stopwatch.StartNew();
    private long _renderStartTicks;
    public float RenderLatencyMs { get; private set; }

    public string BackendName
    {
        get
        {
            var features = new List<string>();
            if (_dxrSupported) features.Add("DXR");
            if (_meshShadersSupported) features.Add("MeshShaders");
            if (_vrsSupported) features.Add("VRS");
            if (_workGraphsSupported) features.Add("WorkGraphs");
            return features.Count > 0 ? $"D3D12U ({string.Join(",", features)})" : "D3D12";
        }
    }
    public bool SupportsWorkGraphs => _workGraphsSupported;
    public bool SupportsDXR => _dxrSupported;
    public bool SupportsMeshShaders => _meshShadersSupported;
    public bool SupportsVRS => _vrsSupported;
    public string CurrentMode => _modeNames.Count > 0 ? (_displayNames.TryGetValue(_modeNames[_currentMode], out var dn) ? dn : _modeNames[_currentMode]) : "";
    public int ModeCount => _modeNames.Count;
    public int CurrentModeIndex => _currentMode;
    public bool ShouldResetGPU => _shouldResetGPU;

    public string GetModeName(int index)
    {
        if (index < 0 || index >= _modeNames.Count) return "";
        return _displayNames.TryGetValue(_modeNames[index], out var dn) ? dn : _modeNames[index];
    }

    private bool _headless;

    public DX12Renderer(IntPtr hwnd, int width, int height, bool headless = false)
    {
        _width = width;
        _height = height;
        _headless = headless;
        Initialize(hwnd);
    }

    private void Initialize(IntPtr hwnd)
    {
        if (!D3D12.IsSupported(FeatureLevel.Level_12_0))
            throw new InvalidOperationException("D3D12 is not supported on this system");

#if DEBUG
        if (D3D12GetDebugInterface(out ID3D12Debug? debug).Success)
        {
            debug!.EnableDebugLayer();
            debug.Dispose();
        }
#endif

        _factory = CreateDXGIFactory2<IDXGIFactory4>(debug: false);

        IDXGIAdapter1? bestAdapter = null;
        using var factory6 = _factory.QueryInterfaceOrNull<IDXGIFactory6>();
        if (factory6 != null)
        {
            factory6.EnumAdapterByGpuPreference(0, GpuPreference.HighPerformance, out bestAdapter).CheckError();
        }
        else
        {
            for (uint i = 0; _factory.EnumAdapters1(i, out bestAdapter).Success; i++)
            {
                if ((bestAdapter!.Description1.Flags & AdapterFlags.Software) == AdapterFlags.None)
                    break;
                bestAdapter.Dispose();
                bestAdapter = null;
            }
        }

        if (bestAdapter == null)
            throw new InvalidOperationException("No suitable GPU adapter found");

        D3D12CreateDevice(bestAdapter, FeatureLevel.Level_12_2, out ID3D12Device? tempDevice).CheckError();
        _device = tempDevice.QueryInterface<ID3D12Device10>();
        tempDevice.Dispose();

        // ── DX12 Ultimate feature detection ──
        _workGraphsSupported = D3D12.IsSupported(FeatureLevel.Level_12_2);
        
        // Query DXR support via device interface
        try
        {
            using var d3d12Device5 = _device.QueryInterface<ID3D12Device5>();
            _dxrSupported = true;
            DebugLogger.Info("[DX12U] DXR: Supported (ID3D12Device5 available)");
        }
        catch
        {
            _dxrSupported = false;
            _dxrTier = 0;
            DebugLogger.Info("[DX12U] DXR: Not supported");
        }

        // Query mesh shaders support via device interface
        try
        {
            using var d3d12Device1 = _device.QueryInterface<ID3D12Device1>();
            _meshShadersSupported = true;
            DebugLogger.Info("[DX12U] Mesh Shaders: Supported (ID3D12Device1 available)");
        }
        catch
        {
            _meshShadersSupported = false;
            DebugLogger.Info("[DX12U] Mesh Shaders: Not supported");
        }

        // Query VRS support via device interface
        try
        {
            using var d3d12Device6 = _device.QueryInterface<ID3D12Device6>();
            _vrsSupported = true;
            DebugLogger.Info("[DX12U] VRS: Supported (ID3D12Device6 available)");
        }
        catch
        {
            _vrsSupported = false;
            _vrsTier = 0;
            DebugLogger.Info("[DX12U] VRS: Not supported");
        }

        DebugLogger.Info($"[DX12U] Device FL12_2: {_workGraphsSupported}");

        // Probe work graph types
        WorkGraphProbe.Probe();

        // Command queue
        _commandQueue = _device.CreateCommandQueue(CommandListType.Direct);
        _commandQueue.Name = "Graphics Queue";

        // Fence
        _fence = _device.CreateFence(0);

        // Swap chain (skip in headless mode — we render to shared texture)
        if (!_headless)
        {
            var swapChainDesc = new SwapChainDescription1
            {
                BufferCount = FrameCount,
                Width = (uint)_width,
                Height = (uint)_height,
                Format = Format.R8G8B8A8_UNorm,
                BufferUsage = Usage.RenderTargetOutput,
                SwapEffect = SwapEffect.FlipDiscard,
                SampleDescription = new SampleDescription(1, 0),
            };
            using var swapChain1 = _factory.CreateSwapChainForHwnd(_commandQueue, hwnd, swapChainDesc);
            _factory.MakeWindowAssociation(hwnd, WindowAssociationFlags.IgnoreAltEnter);
            _swapChain = swapChain1.QueryInterface<IDXGISwapChain3>();
            _frameIndex = (int)_swapChain.CurrentBackBufferIndex;
        }

        // RTV heap
        _rtvHeap = _device.CreateDescriptorHeap(
            new DescriptorHeapDescription(DescriptorHeapType.RenderTargetView, FrameCount));
        _rtvDescriptorSize = _device.GetDescriptorHandleIncrementSize(DescriptorHeapType.RenderTargetView);

        var rtvHandle = _rtvHeap.GetCPUDescriptorHandleForHeapStart();
        if (!_headless)
        {
            for (int i = 0; i < FrameCount; i++)
            {
                _renderTargets[i] = _swapChain.GetBuffer<ID3D12Resource>((uint)i);
                _device.CreateRenderTargetView(_renderTargets[i], null, rtvHandle);
                rtvHandle += (int)_rtvDescriptorSize;
            }
        }

        // Layer RTV
        _rtvHeapLayer = _device.CreateDescriptorHeap(
            new DescriptorHeapDescription(DescriptorHeapType.RenderTargetView, 1));

        _layerTex0 = _device.CreateCommittedResource(
            HeapType.Default,
            ResourceDescription.Texture2D(Format.R16G16B16A16_Float, (uint)_width, (uint)_height,
                flags: ResourceFlags.AllowRenderTarget),
            ResourceStates.Common,
            new ClearValue(Format.R16G16B16A16_Float, new Color4(0, 0, 0, 1)));
        _device.CreateRenderTargetView(_layerTex0, null, _rtvHeapLayer.GetCPUDescriptorHandleForHeapStart());

        _rtvHeapLayer1 = _device.CreateDescriptorHeap(
            new DescriptorHeapDescription(DescriptorHeapType.RenderTargetView, 1));
        _layerTex1 = _device.CreateCommittedResource(
            HeapType.Default,
            ResourceDescription.Texture2D(Format.R16G16B16A16_Float, (uint)_width, (uint)_height,
                flags: ResourceFlags.AllowRenderTarget),
            ResourceStates.Common,
            new ClearValue(Format.R16G16B16A16_Float, new Color4(0, 0, 0, 1)));
        _device.CreateRenderTargetView(_layerTex1, null, _rtvHeapLayer1.GetCPUDescriptorHandleForHeapStart());

        // Feedback texture for simulation memory (same format as layer)
        _feedbackTex0 = _device.CreateCommittedResource(
            HeapType.Default,
            ResourceDescription.Texture2D(Format.R16G16B16A16_Float, (uint)_width, (uint)_height,
                flags: ResourceFlags.AllowRenderTarget),
            ResourceStates.Common,
            new ClearValue(Format.R16G16B16A16_Float, new Color4(0, 0, 0, 1)));

        // CBV/SRV/UAV heap - 8 SRVs + 4 UAVs + padding
        var cbvDesc = new DescriptorHeapDescription(DescriptorHeapType.ConstantBufferViewShaderResourceViewUnorderedAccessView, 32)
        {
            Flags = DescriptorHeapFlags.ShaderVisible,
        };
        _cbvSrvUavHeap = _device.CreateDescriptorHeap(cbvDesc);
        _srvDescriptorSize = _device.GetDescriptorHandleIncrementSize(DescriptorHeapType.ConstantBufferViewShaderResourceViewUnorderedAccessView);

        // Sampler heap — 2 samplers: clamp + wrap
        var samplerDesc = new DescriptorHeapDescription(DescriptorHeapType.Sampler, 2)
        {
            Flags = DescriptorHeapFlags.ShaderVisible,
        };
        _samplerHeap = _device.CreateDescriptorHeap(samplerDesc);
        // s0 — linear clamp
        var samplerClamp = new SamplerDescription(Filter.MinMagLinearMipPoint,
            TextureAddressMode.Clamp, TextureAddressMode.Clamp, TextureAddressMode.Clamp);
        _device.CreateSampler(ref samplerClamp,
            _samplerHeap.GetCPUDescriptorHandleForHeapStart());
        // s1 — linear wrap
        var samplerWrap = new SamplerDescription(Filter.MinMagLinearMipPoint,
            TextureAddressMode.Wrap, TextureAddressMode.Wrap, TextureAddressMode.Wrap);
        _device.CreateSampler(ref samplerWrap,
            _samplerHeap.GetCPUDescriptorHandleForHeapStart() + (int)_device.GetDescriptorHandleIncrementSize(DescriptorHeapType.Sampler));

        // Command allocators + list
        for (int i = 0; i < FrameCount; i++)
        {
            _commandAllocators[i] = _device.CreateCommandAllocator(CommandListType.Direct);
            _commandAllocators[i].Name = $"Allocator {i}";
        }
        _commandList = _device.CreateCommandList<ID3D12GraphicsCommandList6>(
            CommandListType.Direct, _commandAllocators[0], null);
        _commandList.Close();
        _commandQueue.ExecuteCommandList(_commandList);
        _fenceValue++;
        _commandQueue.Signal(_fence, _fenceValue);

        // Constant buffers (upload heap, 256-byte aligned)
        uint audioCBSize = (uint)((Marshal.SizeOf<AudioUBO>() + 255) & ~255);
        uint timeCBSize = (uint)((Marshal.SizeOf<TimeCB>() + 255) & ~255);

        _audioCB = _device.CreateCommittedResource(
            HeapType.Upload,
            ResourceDescription.Buffer(audioCBSize),
            ResourceStates.GenericRead);
        unsafe { _audioCBPtr = new IntPtr(_audioCB.Map<byte>(0)); }

        _timeCB = _device.CreateCommittedResource(
            HeapType.Upload,
            ResourceDescription.Buffer(timeCBSize),
            ResourceStates.GenericRead);
        unsafe { _timeCBPtr = new IntPtr(_timeCB.Map<byte>(0)); }

        // DSP constant buffer (b2) — Resonance DSP metrics for shaders
        uint dspCBSize = (uint)((DSP_CB_SIZE + 255) & ~255);
        _dspCB = _device.CreateCommittedResource(
            HeapType.Upload,
            ResourceDescription.Buffer(dspCBSize),
            ResourceStates.GenericRead);
        unsafe { _dspCBPtr = new IntPtr(_dspCB.Map<byte>(0)); }

        // Spectrum texture on default heap + upload buffer for CPU→GPU copy
        // 3 rows: row 0 = left, row 1 = center, row 2 = right
        _spectrumTexture = _device.CreateCommittedResource(
            HeapType.Default,
            ResourceDescription.Texture2D(Format.R32_Float, 1024, 3),
            ResourceStates.CopyDest);
        
        // Upload buffer for spectrum data (1024 floats * 3 rows * 4 bytes = 12288)
        _spectrumUploadSize = 1024 * 3 * 4;
        _spectrumUploadBuffer = _device.CreateCommittedResource(
            HeapType.Upload,
            ResourceDescription.Buffer(_spectrumUploadSize),
            ResourceStates.GenericRead);
        
        // Use SetData helper instead of manual mapping
        _spectrumUploadBuffer.SetData(new float[1024 * 3]);

        // Bloom textures (downsampled for performance) - only create if bloom is enabled
        // Half resolution bloom textures
        if (_bloomEnabled)
        {
            _bloomTexture = _device.CreateCommittedResource(
                HeapType.Default,
                ResourceDescription.Texture2D(Format.R16G16B16A16_Float, (uint)(_width / 2), (uint)(_height / 2),
                    flags: ResourceFlags.AllowRenderTarget),
                ResourceStates.Common,
                new ClearValue(Format.R16G16B16A16_Float, new Color4(0, 0, 0, 1)));
            
            _bloomTexture2 = _device.CreateCommittedResource(
                HeapType.Default,
                ResourceDescription.Texture2D(Format.R16G16B16A16_Float, (uint)(_width / 2), (uint)(_height / 2),
                    flags: ResourceFlags.AllowRenderTarget),
                ResourceStates.Common,
                new ClearValue(Format.R16G16B16A16_Float, new Color4(0, 0, 0, 1)));

            // Bloom RTV heap
            _bloomRtvHeap = _device.CreateDescriptorHeap(
                new DescriptorHeapDescription(DescriptorHeapType.RenderTargetView, 2));

            // Create RTVs for bloom textures
            var bloomRtvHandle0 = _bloomRtvHeap.GetCPUDescriptorHandleForHeapStart();
            _device.CreateRenderTargetView(_bloomTexture, null, bloomRtvHandle0);
            var bloomRtvHandle1 = _bloomRtvHeap.GetCPUDescriptorHandleForHeapStart();
            bloomRtvHandle1.Ptr += _rtvDescriptorSize;
            _device.CreateRenderTargetView(_bloomTexture2, null, bloomRtvHandle1);
        }

        // PostFX HDR intermediate texture (full-res, same as layer textures)
        _postfxTex = _device.CreateCommittedResource(
            HeapType.Default,
            ResourceDescription.Texture2D(Format.R16G16B16A16_Float, (uint)_width, (uint)_height,
                flags: ResourceFlags.AllowRenderTarget),
            ResourceStates.Common,
            new ClearValue(Format.R16G16B16A16_Float, new Color4(0, 0, 0, 1)));
        _postfxRtvHeap = _device.CreateDescriptorHeap(
            new DescriptorHeapDescription(DescriptorHeapType.RenderTargetView, 1));
        _device.CreateRenderTargetView(_postfxTex, null, _postfxRtvHeap.GetCPUDescriptorHandleForHeapStart());

        // SkiaSharp 2D overlay texture (RGBA8, CPU-uploaded each frame)
        _skiaTex = _device.CreateCommittedResource(
            HeapType.Default,
            ResourceDescription.Texture2D(Format.R8G8B8A8_UNorm, (uint)_width, (uint)_height),
            ResourceStates.CopyDest);
        _skiaUploadSize = (uint)(_width * _height * 4);
        _skiaUploadSize = (_skiaUploadSize + 255) & ~255u; // 256-byte aligned
        _skiaUploadBuffer = _device.CreateCommittedResource(
            HeapType.Upload,
            ResourceDescription.Buffer(_skiaUploadSize),
            ResourceStates.GenericRead);
        unsafe { _skiaUploadPtr = new IntPtr(_skiaUploadBuffer.Map<byte>(0)); }
        // Initialize to transparent
        unsafe { new Span<byte>((void*)_skiaUploadPtr, (int)_skiaUploadSize).Clear(); }
        _skiaOverlay = new SkiaOverlay(_width, _height);

        // Fullscreen quad
        float[] quadVerts = {
            -1, -1, 0,  0, 0,
             1, -1, 0,  1, 0,
            -1,  1, 0,  0, 1,
             1,  1, 0,  1, 1,
        };
        uint[] quadIndices = { 0, 1, 2, 2, 1, 3 };

        uint vbSize = (uint)(quadVerts.Length * sizeof(float));
        _vertexBuffer = _device.CreateCommittedResource(
            HeapType.Upload,
            ResourceDescription.Buffer(vbSize),
            ResourceStates.GenericRead);
        _vertexBuffer.SetData(quadVerts);

        uint ibSize = (uint)(quadIndices.Length * sizeof(uint));
        _indexBuffer = _device.CreateCommittedResource(
            HeapType.Upload,
            ResourceDescription.Buffer(ibSize),
            ResourceStates.GenericRead);
        _indexBuffer.SetData(quadIndices);

        // Root signature
        CreateRootSignature();

        // Compile vertex shader
        string vsSource = """
            struct VSInput {
                float3 pos : POSITION;
                float2 uv : TEXCOORD0;
            };
            struct VSOutput {
                float4 pos : SV_POSITION;
                float2 uv : TEXCOORD0;
            };
            VSOutput main(VSInput input) {
                VSOutput output;
                output.pos = float4(input.pos, 1.0);
                output.uv = input.uv;
                return output;
            }
        """;
        // Compile vertex shader with DXC vs_6_6, fallback to fxc vs_5_0
        InitDXC();
        byte[] vsBytecodeArr;
        if (_dxcCompiler != null)
        {
            try { vsBytecodeArr = CompileWithDXC(vsSource, "main", "vs_6_6", "vs.hlsl")!; }
            catch { vsBytecodeArr = Compiler.Compile(vsSource, "main", "vs.hlsl", "vs_5_0").ToArray(); }
        }
        else
        {
            vsBytecodeArr = Compiler.Compile(vsSource, "main", "vs.hlsl", "vs_5_0").ToArray();
        }
        var vsBytecode = new ReadOnlySpan<byte>(vsBytecodeArr);
        _vsBytecode = vsBytecodeArr;

        // Load all pixel shaders as PSOs
        LoadShaders(vsBytecode);

        // Load composite + overlay shaders
        LoadCompositeShader(vsBytecode);
        LoadOverlayShader(vsBytecode);
        // Load PostFX + Tone-map shaders (multi-pass HDR pipeline)
        LoadPostFxShader(vsBytecode);
        LoadToneMapShader(vsBytecode);
        // Load SkiaSharp overlay composite shader
        LoadSkiaShader(vsBytecode);

        // Fallback blit PSO if composite failed
        if (_compositePSO == null)
        {
            try
            {
                string blitSource = """
                    Texture2D<float4> BaseLayer : register(t1);
                    SamplerState PointSampler : register(s0);
                    struct PSInput { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };
                    float4 main(PSInput input) : SV_TARGET {
                        return BaseLayer.Sample(PointSampler, input.uv);
                    }
                """;
                var blitBytecode = CompileShader(blitSource, "main", "blit.hlsl", "ps_6_6", "ps_5_0");
                var blitDesc = CreatePSODesc(vsBytecode, blitBytecode, Format.R8G8B8A8_UNorm);
                _compositePSO = _device.CreateGraphicsPipelineState(blitDesc);
                DebugLogger.Info("[DX12Renderer] Fallback blit PSO created");
            }
            catch (Exception e)
            {
                DebugLogger.Error($"[DX12Renderer] Fallback blit PSO failed: {e.Message}");
            }
        }

        bool bloomReady = _bloomEnabled && _bloomExtractPSO != null && _bloomBlurHPSO != null && _bloomBlurVPSO != null && _bloomCombinePSO != null;
        bool hdrPipelineReady = bloomReady && _postfxPSO != null && _tonemapPSO != null;
        string fallbackState = _compositePSO == null ? "unavailable" : hdrPipelineReady ? "available (inactive)" : "active";
        DebugLogger.Info($"[Pipeline] Startup validation: modes={_modeNames.Count}/50, bloom={(bloomReady ? "loaded" : "failed")}, postfx={(_postfxPSO != null ? "loaded" : "failed")}, tonemap={(_tonemapPSO != null ? "loaded" : "failed")}, overlay={(_overlayPSO != null ? "loaded" : "not configured")}, skia={(_skiaPSO != null && _skiaEnabled ? "loaded" : "disabled")}, fallback={fallbackState}");

        // Create SRV descriptors in the CBV/SRV/UAV heap
        // Layout (8 SRVs): [0]spectrum, [1]layer0, [2]layer1, [3]bloom0, [4]bloom1, [5]feedback0(null), [6]feedback1(null), [7]noise(null)
        var srvCpuHandle = _cbvSrvUavHeap.GetCPUDescriptorHandleForHeapStart();
        _device.CreateShaderResourceView(_spectrumTexture, null, srvCpuHandle);          // t0
        srvCpuHandle += (int)_srvDescriptorSize;
        _device.CreateShaderResourceView(_layerTex0, null, srvCpuHandle);                // t1
        srvCpuHandle += (int)_srvDescriptorSize;
        _device.CreateShaderResourceView(_layerTex1, null, srvCpuHandle);                // t2
        
        if (_bloomEnabled && _bloomTexture != null && _bloomTexture2 != null)
        {
            srvCpuHandle += (int)_srvDescriptorSize;
            _device.CreateShaderResourceView(_bloomTexture, null, srvCpuHandle);         // t3
            srvCpuHandle += (int)_srvDescriptorSize;
            _device.CreateShaderResourceView(_bloomTexture2, null, srvCpuHandle);        // t4
        }
        // t5: feedback texture (previous frame for simulation memory)
        srvCpuHandle += (int)_srvDescriptorSize;
        _device.CreateShaderResourceView(_feedbackTex0, null, srvCpuHandle);
        // t6: postfx HDR intermediate (for tonemap pass to read)
        srvCpuHandle += (int)_srvDescriptorSize;
        _device.CreateShaderResourceView(_postfxTex, null, srvCpuHandle);
        // t7: SkiaSharp 2D overlay texture
        srvCpuHandle += (int)_srvDescriptorSize;
        _device.CreateShaderResourceView(_skiaTex, null, srvCpuHandle);
        // UAV descriptors at offset 8: u0-u3 (null for now, future compute use)

        // Create HUD
        try
        {
            _hud = new DX12HUD(_device, _width, _height, vsBytecode);
            DebugLogger.Info("[DX12Renderer] HUD created");
        }
        catch (Exception e)
        {
            DebugLogger.Error($"[DX12Renderer] HUD creation failed: {e.Message}");
            _hud = null;
        }

        bestAdapter.Dispose();

        DebugLogger.Info($"[DX12Renderer] Initialized: {_width}x{_height}, {_modeNames.Count} modes, WorkGraphs={_workGraphsSupported}");
    }

    private void CreateRootSignature()
    {
        var rootParams = new RootParameter1[]
        {
            // [0] CBV b0 — AudioCB
            new(RootParameterType.ConstantBufferView, new RootDescriptor1(0, 0), ShaderVisibility.All),
            // [1] CBV b1 — TimeCB
            new(RootParameterType.ConstantBufferView, new RootDescriptor1(1, 0), ShaderVisibility.All),
            // [2] CBV b2 — DspCB (Resonance DSP: LUFS, THD, phase, crest factor, biquad bands)
            new(RootParameterType.ConstantBufferView, new RootDescriptor1(2, 0), ShaderVisibility.All),
            // [3] Descriptor Table — 8 SRVs (t0-t7): spectrum, layer0, layer1, bloom0, bloom1, feedback0, skiaTex, noise
            new(new RootDescriptorTable1 { Ranges = new[] { new DescriptorRange1(DescriptorRangeType.ShaderResourceView, 8, 0) } }, ShaderVisibility.Pixel),
            // [4] Descriptor Table — 4 UAVs (u0-u3): compute output, particle buffer, history buffer, debug
            new(new RootDescriptorTable1 { Ranges = new[] { new DescriptorRange1(DescriptorRangeType.UnorderedAccessView, 4, 0) } }, ShaderVisibility.Pixel),
        };

        var staticSamplers = new StaticSamplerDescription[]
        {
            // s0 — linear clamp (for spectrum sampling)
            new(0u, Filter.MinMagLinearMipPoint,
                TextureAddressMode.Clamp, TextureAddressMode.Clamp, TextureAddressMode.Clamp,
                shaderVisibility: ShaderVisibility.Pixel),
            // s1 — linear wrap (for noise/feedback textures)
            new(1u, Filter.MinMagLinearMipPoint,
                TextureAddressMode.Wrap, TextureAddressMode.Wrap, TextureAddressMode.Wrap,
                shaderVisibility: ShaderVisibility.Pixel),
        };

        var desc = new RootSignatureDescription1(RootSignatureFlags.AllowInputAssemblerInputLayout)
        {
            Parameters = rootParams,
            StaticSamplers = staticSamplers,
        };

        _rootSignature = _device.CreateRootSignature(desc);
    }

    private GraphicsPipelineStateDescription CreatePSODesc(ReadOnlySpan<byte> vsBytecode, ReadOnlySpan<byte> psBytecode, Format rtFormat)
    {
        return new GraphicsPipelineStateDescription
        {
            RootSignature = _rootSignature,
            VertexShader = vsBytecode.ToArray(),
            PixelShader = psBytecode.ToArray(),
            InputLayout = new InputLayoutDescription(new InputElementDescription[]
            {
                new InputElementDescription("POSITION", 0, Format.R32G32B32_Float, 0, 0, InputClassification.PerVertexData, 0),
                new InputElementDescription("TEXCOORD", 0, Format.R32G32_Float, 12, 0, InputClassification.PerVertexData, 0),
            }),
            SampleMask = uint.MaxValue,
            PrimitiveTopologyType = PrimitiveTopologyType.Triangle,
            RasterizerState = RasterizerDescription.CullNone,
            BlendState = BlendDescription.Opaque,
            DepthStencilState = new DepthStencilDescription { DepthEnable = false, DepthWriteMask = DepthWriteMask.All, StencilEnable = false },
            RenderTargetFormats = new Format[] { rtFormat },
            SampleDescription = new SampleDescription(1, 0),
            NodeMask = 0,
            CachedPSO = default,
            Flags = PipelineStateFlags.None,
        };
    }

    private static IDxcCompiler3? _dxcCompiler;
    private static IDxcUtils? _dxcUtils;
    private static IDxcIncludeHandler? _dxcIncludeHandler;
    private static bool _dxcInitialized;
    private static string? _shaderDir;

    // Preprocess #include directives by inlining file contents
    private static string PreprocessIncludes(string source, HashSet<string>? processed = null)
    {
        processed ??= new HashSet<string>();
        var lines = source.Split(new[] { "\r\n", "\r", "\n" }, StringSplitOptions.None);
        var result = new StringBuilder();
        foreach (var line in lines)
        {
            string trimmed = line.TrimStart();
            if (trimmed.StartsWith("#include"))
            {
                // Extract path between quotes
                int start = trimmed.IndexOf('"');
                int end = trimmed.LastIndexOf('"');
                if (start >= 0 && end > start && _shaderDir != null)
                {
                    string includePath = trimmed.Substring(start + 1, end - start - 1);
                    string fullPath = Path.Combine(_shaderDir, includePath);
                    // Also check include/ subdirectory (for includes within include files)
                    if (!File.Exists(fullPath))
                        fullPath = Path.Combine(_shaderDir, "include", includePath);
                    if (File.Exists(fullPath))
                    {
                        if (processed.Contains(fullPath))
                        {
                            // Already inlined — skip the #include line entirely
                            continue;
                        }
                        processed.Add(fullPath);
                        string includeSource = File.ReadAllText(fullPath);
                        result.AppendLine(PreprocessIncludes(includeSource, processed));
                        continue;
                    }
                }
            }
            result.AppendLine(line);
        }
        return result.ToString();
    }

    private static void InitDXC()
    {
        if (_dxcInitialized) return;
        _dxcInitialized = true;
        try
        {
            _dxcUtils = Dxc.CreateDxcUtils();
            _dxcIncludeHandler = _dxcUtils.CreateDefaultIncludeHandler();
            _dxcCompiler = Dxc.CreateDxcCompiler<IDxcCompiler3>();
            DebugLogger.Info("[DX12U] DXC compiler initialized successfully");
        }
        catch (Exception e)
        {
            DebugLogger.Warn($"[DX12U] DXC init failed, falling back to fxc: {e.Message}");
            _dxcCompiler = null;
        }
    }

    private static byte[]? CompileWithDXC(string source, string entryPoint, string targetProfile, string fileName)
    {
        if (_dxcCompiler == null || _dxcUtils == null)
            return null;

        string[] args = {
            "-E", entryPoint,
            "-T", targetProfile,
            "-D", "DX12U=1",
            "-Qstrip_reflect",
            "-Qstrip_debug",
            "-HV", "2021",
            "-O3",
        };

        IDxcResult? result = _dxcCompiler.Compile(source, args, _dxcIncludeHandler);
        if (result == null)
            return null;

        result.GetStatus(out SharpGen.Runtime.Result status);
        if (!status.Success)
        {
            IDxcBlobEncoding? errBlob = result.GetErrorBuffer();
            string errorMsg = "";
            if (errBlob != null)
            {
                errorMsg = System.Text.Encoding.UTF8.GetString(errBlob.AsBytes());
                errBlob.Dispose();
            }
            result.Dispose();
            throw new Exception($"DXC compile failed for {fileName}: {errorMsg}");
        }

        IDxcBlob? blob = result.GetResult();
        if (blob == null)
        {
            result.Dispose();
            return null;
        }

        byte[] bytecode = blob.AsBytes();
        blob.Dispose();
        result.Dispose();
        return bytecode;
    }

    private static string GetShaderCacheDir()
    {
        string cacheDir = Path.Combine(AppContext.BaseDirectory, "shader_cache");
        Directory.CreateDirectory(cacheDir);
        return cacheDir;
    }

    private static string ComputeSourceHash(string source, string target)
    {
        using var sha = System.Security.Cryptography.SHA256.Create();
        byte[] hashBytes = sha.ComputeHash(System.Text.Encoding.UTF8.GetBytes(source + "|" + target));
        return Convert.ToHexString(hashBytes)[..16];
    }

    private static byte[]? TryLoadCachedShader(string fileName, string target, string sourceHash)
    {
        try
        {
            string cacheFile = Path.Combine(GetShaderCacheDir(), $"{Path.GetFileNameWithoutExtension(fileName)}_{target}_{sourceHash}.dxbc");
            if (File.Exists(cacheFile))
            {
                return File.ReadAllBytes(cacheFile);
            }
        }
        catch { }
        return null;
    }

    private static void SaveCachedShader(string fileName, string target, string sourceHash, byte[] bytecode)
    {
        try
        {
            string cacheFile = Path.Combine(GetShaderCacheDir(), $"{Path.GetFileNameWithoutExtension(fileName)}_{target}_{sourceHash}.dxbc");
            File.WriteAllBytes(cacheFile, bytecode);
        }
        catch { }
    }

    private static byte[] CompileShader(string source, string entryPoint, string fileName, string dxcTarget, string fxcTarget)
    {
        InitDXC();

        if (_dxcCompiler != null)
        {
            string sourceHash = ComputeSourceHash(source, dxcTarget);

            // Try cache first
            byte[]? cached = TryLoadCachedShader(fileName, dxcTarget, sourceHash);
            if (cached != null)
            {
                DebugLogger.Info($"[DX12U] Cache hit: {fileName} ({cached.Length} bytes)");
                return cached;
            }

            try
            {
                byte[]? dxcResult = CompileWithDXC(source, entryPoint, dxcTarget, fileName);
                if (dxcResult != null)
                {
                    SaveCachedShader(fileName, dxcTarget, sourceHash, dxcResult);
                    return dxcResult;
                }
            }
            catch (Exception e)
            {
                DebugLogger.Warn($"[DX12U] DXC failed for {fileName}: {e.Message}");
            }
        }

        // Fallback to fxc
        return Compiler.Compile(source, entryPoint, fileName, fxcTarget).ToArray();
    }

    private void LoadShaders(ReadOnlySpan<byte> vsBytecode)
    {
        string[] searchPaths = {
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "shaders"),
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "shaders"),
            Path.Combine(AppContext.BaseDirectory, "shaders"),
            Path.Combine(AppContext.BaseDirectory, "..", "shaders"),
            @"C:\Users\htsou\CascadeProjects\RTXAudioVisualizer\shaders",
        };

        string shaderDir = "";
        foreach (var p in searchPaths)
        {
            if (Directory.Exists(p)) { shaderDir = p; break; }
        }
        if (string.IsNullOrEmpty(shaderDir))
        {
            DebugLogger.Error("[DX12Renderer] Shader directory not found!");
            return;
        }

        DebugLogger.Info($"[DX12Renderer] Shader dir: {shaderDir}");
        _shaderDir = shaderDir;

        string[] modes = {
            "quantum_bars",       // 0. Quantum Bars — 3D spectrum with quantum clouds
            "plasma_field",       // 1. Plasma Field — domain-warped FBM fluid
            "neon_pulse",         // 2. Spectrum Tectonics — audio-sculpted canyon flyover
            "particle_flow",      // 3. Spectrum Vortex — frequency-assigned particles in vortex
            "waveform",           // 4. Audio Lichtenberg — branching electrical discharge tree
            "sphere",             // 5. Chladni Plate — standing-wave interference resonance
            "aurora",             // 6. Aurora Borealis — curtains + starfield
            "dna_helix",          // 7. Spectrum Helix — 3D horizontal particle flow
            "heartbeat",          // 8. Acoustic Wavefront Propagator — expanding spherical wavefronts
            "rtx_mesh",           // 9. RTX Mesh — deformable grid + reflective floor
            "ray_marched",        // 10. Spectrum Kaleidoscope — kaleidoscopic fractal
            "volumetric_clouds",  // 11. Volumetric Clouds — 3D noise + lightning
            "fractal_dimensions", // 12. Spectrum Mandelbox — 3D box-fold fractal
            "neural_network",     // 13. Acoustic Holography — volumetric wave interference field
            "quantum_field",      // 14. Spectrum Lattice — frequency-driven quantum particle lattice
            "holographic",        // 15. Holographic — wireframe + scan lines + glitch
            "particle_storm",     // 16. Spectrum Storm — frequency-driven storm particles
            "crystal",            // 17. Ferrofluid Wavefield — SDF spike field with wave interference
            "terrain",            // 18. Spectrum Terrain — ridged noise mountains flyover
            "galaxy",             // 19. Spacetime Gravity Waves — gravitational wave fabric
            "wave_tessellation",  // 20. Dual Tessellation — dual inverted mesh
            "audio_tessellation", // 21. Audio Tessellation — Voronoi terrain with audio
            "compute_shaders",    // 22. Ferrofluid Pool — SDF heightfield with metallic shading
            "rtx_reflections",    // 23. Acoustic Droplets & Mirror Pool — falling objects + reflective liquid
            "spectrum_3d",        // 24. 3D Spectrum Bars
            "spatial_dolby",      // 25. 3D Spatial Soundscape — spatial audio field with band×channel separation
            "water_droplets",    // 26. Seismic Tectonic Plate — seismic wave grid mesh
            "matrix_rain",       // 27. Audio-Reactive Mandelbulb — 3D spherical fractal
            "waveform_tunnel",   // 28. Audio Waveform Tunnel — fly through waveform
            "crystal_lattice",   // 29. Synthwave Horizon — 3D raymarched neon landscape
            "space_plasma",      // 30. Space Plasma Field — volumetric plasma with EM field math
            "gravitational_waves",// 31. Gravitational Space Waves — GW strain tensor fabric
            "fluid_dynamics",    // 32. Fluid Dynamics — Navier-Stokes volumetric fluid
            "lightning_storm",   // 33. Lightning Storm — dielectric breakdown arcs
            "neon_cityscape",    // 34. Neon Cityscape — synthwave skyline + reflections
            "spectrum_waterfall",// 35. Spatial Audio Sonar — 360° immersive 3D sonar display
            "cosmic_web",        // 36. Gravitational Wavefield — spacetime fabric with gravitational wells
            "laser_show",        // 37. Resonance Field — 3D Chladni standing wave patterns at spatial audio positions
            "neural_synapse",    // 38. Neural Synapse Storm — 3D neural network with synapse firing
            "hologram_projector",// 39. Acoustic Hologram Projector — volumetric hologram table
            "quantum_interferometer", // 40. Quantum Field Interferometer — wave-particle duality
            "aurora_cathedral",  // 41. Spectral Aurora Cathedral — volumetric aurora curtains
            "gravitational_lens",// 42. Gravitational Lens Observatory — black hole + accretion disk
            "phonon_crystal",    // 43. Phonon Crystal Lattice — 3D phononic crystal wave propagation
            "cymatic_chamber",   // 44. Cymatic Resonance Chamber — 3D Chladni patterns
            "sonic_topology",    // 45. Sonic Topology Mapper — 4D topological manifold
            "particle_hologram", // 46. Acoustic Particle Hologram — GPU particles forming 3D shapes
            "freq_nebula",       // 47. Sonic Sphereworld — SDF planet with audio terrain, atmosphere, meteors
            "wave_field",        // 48. Spatiotemporal Wave Field — 3D wave equation with audio sources
            "fractal_explorer",  // 49. Fractal Dimension Explorer — morphing 3D Mandelbulb
        };

        foreach (var mode in modes)
        {
            string hlslFile = Path.Combine(shaderDir, $"dx_{mode}.hlsl");
            if (!File.Exists(hlslFile)) continue;

            try
            {
                string source = File.ReadAllText(hlslFile);
                source = PreprocessIncludes(source);
                string dxcTarget = "ps_6_6";
                string fxcTarget = "ps_5_0";
                DebugLogger.Info($"[DX12] Compiling {mode} ({source.Length} bytes)...");

                byte[] psBytecode = CompileShader(source, "main", $"dx_{mode}.hlsl", dxcTarget, fxcTarget);

                var psoDesc = CreatePSODesc(vsBytecode, psBytecode, Format.R16G16B16A16_Float);
                var pso = _device.CreateGraphicsPipelineState(psoDesc);
                _pixelShaders[mode] = pso;
                _modeNames.Add(mode);
                DebugLogger.Info($"[DX12] Loaded: {mode}");
            }
            catch (Exception e)
            {
                DebugLogger.Error($"[DX12Renderer] Failed to load {mode}: {e.Message}");
                File.AppendAllText(Path.Combine(DebugLogger.LogDirectory, "shader_errors_dx12.log"),
                    $"[{mode}] {e.Message}\n{e.StackTrace}\n");
            }
        }

        DebugLogger.Info($"[DX12Renderer] Total modes loaded: {_modeNames.Count}");

        // Load dragon head (currently deferred)
        LoadDragonHead(shaderDir);

        // Load bloom pipeline shaders
        LoadBloomShaders(shaderDir, _vsBytecode);
    }

    private void LoadDragonHead(string shaderDir)
    {
        // Dragon head deferred — mesh shader PSO creation is WIP
        DebugLogger.Info("[DX12] Dragon head mode deferred (mesh shader pipeline WIP)");
    }

    private ID3D12PipelineState CreateMeshShaderPSO(byte[] asBytecode, byte[] msBytecode, byte[] psBytecode)
    {
        // Build D3D12_PIPELINE_STATE_STREAM_DESC as a raw byte stream
        // Each subobject pair (type enum + payload struct) must be 8-byte aligned
        // We achieve this by writing: [uint type][4 bytes padding][payload]
        // then the next subobject starts at an 8-byte boundary

        // Pin shader bytecode so we have stable pointers
        var asGch = GCHandle.Alloc(asBytecode, GCHandleType.Pinned);
        var msGch = GCHandle.Alloc(msBytecode, GCHandleType.Pinned);
        var psGch = GCHandle.Alloc(psBytecode, GCHandleType.Pinned);

        try
        {
            // D3D12_SHADER_BYTECODE = { IntPtr pShaderBytecode; UInt64 BytecodeLength; } = 16 bytes on x64
            // D3D12_BLEND_DESC = { BOOL AlphaToCoverageEnable; BOOL IndependentBlendEnable; D3D12_RENDER_TARGET_BLEND_DESC[8] }
            //   D3D12_RENDER_TARGET_BLEND_DESC = { BOOL, BOOL, D3D12_BLEND, D3D12_BLEND, D3D12_BLEND_OP, D3D12_BLEND, D3D12_BLEND, D3D12_BLEND_OP, D3D12_LOGIC_OP, UINT8 }
            //   = 2*4 + 5*4 + 5*4 + 4 + 1 = ... actually each field is its native size
            //   BOOL=4, D3D12_BLEND=4(int enum), D3D12_BLEND_OP=4, D3D12_LOGIC_OP=4, UINT8=1
            //   Per RT: 4+4+4+4+4+4+4+4+4+1 = 37 bytes, but with packing it's likely 40 or 44
            // Actually D3D12 uses natural alignment — BOOL=4, enums=4, UINT8=1
            // Per RT blend desc: 2 BOOLs + 4 enums + 2 enums + 1 enum + 1 UINT8 = 2*4 + 6*4 + 1 = 33... 
            // This is getting complex. Let's use the actual struct sizes via Marshal.

            // Simpler approach: define each subobject as an aligned struct and write sequentially
            using var stream = new System.IO.MemoryStream(512);
            using var bw = new System.IO.BinaryWriter(stream);

            // Helper: write a subobject with 8-byte alignment
            // Pattern: [uint type][pad 4 bytes][payload bytes][pad to 8-byte boundary]
            void WriteAlignedSubObject(uint type, int payloadSize, Action writePayload)
            {
                long startPos = stream.Position;
                // Ensure we start at 8-byte boundary
                while (stream.Position % 8 != 0) bw.Write((byte)0);

                bw.Write(type);           // 4 bytes: subobject type
                bw.Write(0u);             // 4 bytes: padding to 8-byte align the payload
                long payloadStart = stream.Position;
                writePayload();
                // Pad payload to 8-byte boundary
                while (stream.Position % 8 != 0) bw.Write((byte)0);
            }

            // 1. RootSignature: ID3D12RootSignature* (IntPtr, 8 bytes)
            WriteAlignedSubObject(0u, 8, () =>
            {
                bw.Write(_rootSignature.NativePointer.ToInt64());
            });

            // 2. Amplification Shader: D3D12_SHADER_BYTECODE (16 bytes on x64)
            WriteAlignedSubObject(20u, 16, () =>
            {
                bw.Write(asGch.AddrOfPinnedObject().ToInt64());  // pShaderBytecode
                bw.Write((ulong)asBytecode.LongLength);           // BytecodeLength
            });

            // 3. Mesh Shader: D3D12_SHADER_BYTECODE
            WriteAlignedSubObject(21u, 16, () =>
            {
                bw.Write(msGch.AddrOfPinnedObject().ToInt64());
                bw.Write((ulong)msBytecode.LongLength);
            });

            // 4. Pixel Shader: D3D12_SHADER_BYTECODE
            WriteAlignedSubObject(2u, 16, () =>
            {
                bw.Write(psGch.AddrOfPinnedObject().ToInt64());
                bw.Write((ulong)psBytecode.LongLength);
            });

            // 5. Blend: D3D12_BLEND_DESC
            // Use Vortice's BlendDescription.Opaque and marshal it
            WriteAlignedSubObject(7u, 0, () =>
            {
                var blend = BlendDescription.Opaque;
                bw.Write(blend.AlphaToCoverageEnable ? 1 : 0);  // BOOL
                bw.Write(blend.IndependentBlendEnable ? 1 : 0); // BOOL
                for (int i = 0; i < 8; i++)
                {
                    var rt = blend.RenderTarget[i];
                    bw.Write(rt.BlendEnable ? 1 : 0);           // BOOL
                    bw.Write(rt.LogicOpEnable ? 1 : 0);         // BOOL
                    bw.Write((int)rt.SourceBlend);              // D3D12_BLEND enum
                    bw.Write((int)rt.DestinationBlend);
                    bw.Write((int)rt.BlendOperation);           // D3D12_BLEND_OP enum
                    bw.Write((int)rt.SourceBlendAlpha);
                    bw.Write((int)rt.DestinationBlendAlpha);
                    bw.Write((int)rt.BlendOperationAlpha);
                    bw.Write((int)rt.LogicOp);                  // D3D12_LOGIC_OP enum
                    bw.Write((byte)rt.RenderTargetWriteMask);   // UINT8
                    // Pad to 4-byte boundary within the struct
                    bw.Write((byte)0); bw.Write((byte)0); bw.Write((byte)0);
                }
            });

            // 6. SampleMask: UINT (4 bytes)
            WriteAlignedSubObject(8u, 4, () =>
            {
                bw.Write(uint.MaxValue);
            });

            // 7. Rasterizer: D3D12_RASTERIZER_DESC
            WriteAlignedSubObject(9u, 0, () =>
            {
                var rast = RasterizerDescription.CullNone;
                bw.Write((int)rast.FillMode);
                bw.Write((int)rast.CullMode);
                bw.Write(rast.FrontCounterClockwise ? 1 : 0);  // BOOL
                bw.Write(rast.DepthBias);                       // INT
                bw.Write(rast.DepthBiasClamp);                  // FLOAT
                bw.Write(rast.SlopeScaledDepthBias);            // FLOAT
                bw.Write(rast.DepthClipEnable ? 1 : 0);         // BOOL
                bw.Write(rast.MultisampleEnable ? 1 : 0);       // BOOL
                bw.Write(rast.AntialiasedLineEnable ? 1 : 0);   // BOOL
                bw.Write(rast.ForcedSampleCount);               // UINT
                bw.Write((int)rast.ConservativeRaster);         // D3D12_CONSERVATIVE_RASTERIZATION_MODE enum
            });

            // 8. DepthStencil: D3D12_DEPTH_STENCIL_DESC (disabled)
            WriteAlignedSubObject(10u, 0, () =>
            {
                var ds = new DepthStencilDescription { DepthEnable = false, DepthWriteMask = DepthWriteMask.All, StencilEnable = false };
                bw.Write(ds.DepthEnable ? 1 : 0);               // BOOL
                bw.Write((int)ds.DepthWriteMask);               // D3D12_DEPTH_WRITE_MASK enum
                bw.Write((int)ds.DepthFunc);                    // D3D12_COMPARISON_FUNC enum
                bw.Write(ds.StencilEnable ? 1 : 0);             // BOOL
                bw.Write((byte)ds.StencilReadMask);             // UINT8
                bw.Write((byte)ds.StencilWriteMask);            // UINT8
                bw.Write((byte)0); bw.Write((byte)0);           // padding
                // Front face stencil op
                bw.Write((int)ds.FrontFace.StencilFailOp);
                bw.Write((int)ds.FrontFace.StencilDepthFailOp);
                bw.Write((int)ds.FrontFace.StencilPassOp);
                bw.Write((int)ds.FrontFace.StencilFunc);
                // Back face stencil op
                bw.Write((int)ds.BackFace.StencilFailOp);
                bw.Write((int)ds.BackFace.StencilDepthFailOp);
                bw.Write((int)ds.BackFace.StencilPassOp);
                bw.Write((int)ds.BackFace.StencilFunc);
            });

            // 9. PrimitiveTopology: D3D12_PRIMITIVE_TOPOLOGY_TYPE (4 bytes, int enum)
            // D3D12_PRIMITIVE_TOPOLOGY_TYPE_MESH = 5
            WriteAlignedSubObject(13u, 4, () =>
            {
                bw.Write(5);  // D3D12_PRIMITIVE_TOPOLOGY_TYPE_MESH
            });

            // 10. RTVFormats: { UINT NumRenderTargets; DXGI_FORMAT[8] }
            WriteAlignedSubObject(14u, 0, () =>
            {
                bw.Write(1);  // NumRenderTargets = 1
                bw.Write((int)Format.R16G16B16A16_Float);  // DXGI_FORMAT = 89
                for (int i = 1; i < 8; i++) bw.Write((int)0);  // DXGI_FORMAT_UNKNOWN
            });

            // 11. SampleDesc: { UINT Count; UINT Quality }
            WriteAlignedSubObject(16u, 8, () =>
            {
                bw.Write(1);  // Count = 1
                bw.Write(0);  // Quality = 0
            });

            byte[] streamData = stream.ToArray();

            // Create PSO via ID3D12Device10::CreatePipelineState with stream desc
            IntPtr streamPtr = Marshal.AllocHGlobal(streamData.Length);
            Marshal.Copy(streamData, 0, streamPtr, streamData.Length);

            var streamDesc = new PipelineStateStreamDescription
            {
                SizeInBytes = (SharpGen.Runtime.PointerUSize)(nuint)streamData.Length,
                SubObjectStream = streamPtr,
            };

            var pso = _device.CreatePipelineState(streamDesc);
            Marshal.FreeHGlobal(streamPtr);
            return pso;
        }
        catch (Exception e)
        {
            DebugLogger.Error($"[DX12] CreateMeshShaderPSO failed: {e.Message}");
            throw;
        }
        finally
        {
            asGch.Free();
            msGch.Free();
            psGch.Free();
        }
    }

    private void LoadBloomShaders(string shaderDir, byte[] vsBytecode)
    {
        try
        {
            // Bloom extract
            string extractSource = PreprocessIncludes(File.ReadAllText(Path.Combine(shaderDir, "dx_bloom_extract.hlsl")));
            var extractBytecode = CompileShader(extractSource, "main", "dx_bloom_extract.hlsl", "ps_6_6", "ps_5_0");
            _bloomExtractPSO = _device.CreateGraphicsPipelineState(CreatePSODesc(vsBytecode, extractBytecode, Format.R16G16B16A16_Float));
            DebugLogger.Info("[DX12] Bloom extract shader loaded");

            // Bloom blur H
            string blurHSource = PreprocessIncludes(File.ReadAllText(Path.Combine(shaderDir, "dx_bloom_blur_h.hlsl")));
            var blurHBytecode = CompileShader(blurHSource, "main", "dx_bloom_blur_h.hlsl", "ps_6_6", "ps_5_0");
            _bloomBlurHPSO = _device.CreateGraphicsPipelineState(CreatePSODesc(vsBytecode, blurHBytecode, Format.R16G16B16A16_Float));
            DebugLogger.Info("[DX12] Bloom blur H shader loaded");

            // Bloom blur V
            string blurVSource = PreprocessIncludes(File.ReadAllText(Path.Combine(shaderDir, "dx_bloom_blur_v.hlsl")));
            var blurVBytecode = CompileShader(blurVSource, "main", "dx_bloom_blur_v.hlsl", "ps_6_6", "ps_5_0");
            _bloomBlurVPSO = _device.CreateGraphicsPipelineState(CreatePSODesc(vsBytecode, blurVBytecode, Format.R16G16B16A16_Float));
            DebugLogger.Info("[DX12] Bloom blur V shader loaded");

            // Bloom combine
            string combineSource = PreprocessIncludes(File.ReadAllText(Path.Combine(shaderDir, "dx_bloom_combine.hlsl")));
            var combineBytecode = CompileShader(combineSource, "main", "dx_bloom_combine.hlsl", "ps_6_6", "ps_5_0");
            _bloomCombinePSO = _device.CreateGraphicsPipelineState(CreatePSODesc(vsBytecode, combineBytecode, Format.R16G16B16A16_Float));
            DebugLogger.Info("[DX12] Bloom combine shader loaded");
        }
        catch (Exception e)
        {
            DebugLogger.Error($"[DX12] Failed to load bloom shaders: {e.Message}");
            _bloomEnabled = false;
        }
    }

    private void LoadWorkGraph()
    {
        // TODO: Re-enable after probe confirms API shapes
        /*
        string[] searchPaths = {
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "shaders"),
            Path.Combine(AppContext.BaseDirectory, "shaders"),
            @"C:\Users\htsou\CascadeProjects\RTXAudioVisualizer\shaders",
        };

        string shaderDir = "";
        foreach (var p in searchPaths)
        {
            if (Directory.Exists(p)) { shaderDir = p; break; }
        }

        string wgPath = Path.Combine(shaderDir, "wg_audio_visualizer.hlsl");
        if (!File.Exists(wgPath))
        {
            DebugLogger.Warn("[DX12Renderer] Work graph shader not found");
            return;
        }

        string source = File.ReadAllText(wgPath);
        DebugLogger.Info($"[DX12Renderer] Compiling work graph ({source.Length} bytes)...");

        // Compile with DXC as library target lib_6_8 for work graph node shaders
        IDxcUtils? utils = null;
        IDxcCompiler3? compiler = null;
        IDxcBlobEncoding? sourceBlob = null;
        IDxcOperationResult? result = null;
        try
        {
            Dxc.DxcCreateInstance(typeof(IDxcUtils).GUID, typeof(IDxcUtils).GUID, out IntPtr utilsPtr).CheckError();
            utils = (IDxcUtils)Activator.CreateInstance(typeof(IDxcUtils), true)!;
            // Use DxcCreateInstance properly
            utils.Dispose();
            Dxc.DxcCreateInstance(typeof(IDxcUtils).GUID, typeof(IDxcUtils).GUID, out utilsPtr).CheckError();
            utils = Marshal.GetObjectForIUnknown(utilsPtr) as IDxcUtils
                ?? throw new Exception("Failed to create IDxcUtils");

            Dxc.DxcCreateInstance(typeof(IDxcCompiler3).GUID, typeof(IDxcCompiler3).GUID, out IntPtr compilerPtr).CheckError();
            compiler = Marshal.GetObjectForIUnknown(compilerPtr) as IDxcCompiler3
                ?? throw new Exception("Failed to create IDxcCompiler3");

            byte[] sourceBytes = Encoding.UTF8.GetBytes(source);
            var dxcBuffer = new DxcBuffer
            {
                Ptr = Marshal.AllocHGlobal(sourceBytes.Length),
                Size = sourceBytes.Length,
                Encoding = 0,
            };
            Marshal.Copy(sourceBytes, 0, dxcBuffer.Ptr, sourceBytes.Length);

            string[] args = {
                "-E", "EntryNode",
                "-T", "lib_6_8",
                "-D", "WORK_GRAPH=1",
                "-Q", "strip_reflect",
            };

            int argCount = args.Length;
            IntPtr[] argPtrs = new IntPtr[argCount];
            for (int i = 0; i < argCount; i++)
                argPtrs[i] = Marshal.StringToHGlobalUni(args[i]);

            try
            {
                compiler.Compile(ref dxcBuffer, argPtrs, (uint)argCount, null,
                    typeof(IDxcOperationResult).GUID, out IntPtr resultPtr).CheckError();
                result = Marshal.GetObjectForIUnknown(resultPtr) as IDxcOperationResult
                    ?? throw new Exception("Failed to get compile result");
            }
            finally
            {
                for (int i = 0; i < argCount; i++)
                    Marshal.FreeHGlobal(argPtrs[i]);
            }

            result.GetStatus(out int hr);
            if (hr < 0)
            {
                result.GetErrorBuffer(out IDxcBlobEncoding? errorBlob);
                string errorMsg = errorBlob != null
                    ? Marshal.PtrToStringAnsi(errorBlob.BufferPointer, (int)errorBlob.Size)
                    ?? "Unknown compile error"
                    : "Unknown compile error";
                errorBlob?.Dispose();
                throw new Exception($"DXC compile failed: {errorMsg}");
            }

            result.GetResult(out IDxcBlob? compiledBlob);
            byte[] dxilBytes = new byte[compiledBlob.Size];
            Marshal.Copy(compiledBlob.BufferPointer, dxilBytes, 0, (int)compiledBlob.Size);
            compiledBlob.Dispose();

            DebugLogger.Info($"[DX12Renderer] Work graph compiled: {dxilBytes.Length} bytes");

            // Create global root signature for work graph
            // Work graph uses CBVs at b0, b1 and UAV at u0
            var wgRootParams = new RootParameter1[]
            {
                new(RootParameterType.ConstantBufferView, new RootDescriptor1(0, 0), ShaderVisibility.All),
                new(RootParameterType.ConstantBufferView, new RootDescriptor1(1, 0), ShaderVisibility.All),
                new(RootParameterType.UnorderedAccessView, new RootDescriptor1(0, 0), ShaderVisibility.All),
            };
            var wgRootDesc = new RootSignatureDescription1(RootSignatureFlags.None, wgRootParams);
            using var wgRootSigBlob = _device.CreateRootSignatureVersion1_1(wgRootDesc);
            _workGraphRootSig = _device.CreateRootSignature(wgRootSigBlob);

            // Build state object with work graph subobject
            var dxilLib = new DxilLibraryDescription(dxilBytes, null);
            var workGraph = new WorkGraphDescription
            {
                ProgramName = "wg_audio_visualizer",
                Flags = WorkGraphFlags.IncludeAllAvailableNodes,
            };

            var config = new StateObjectConfig(StateObjectFlags.None);

            var subObjects = new StateSubObject[]
            {
                new(StateSubObjectType.StateObjectConfig, config),
                new(StateSubObjectType.DxilLibrary, dxilLib),
                new(StateSubObjectType.GlobalRootSignature, _workGraphRootSig),
                new(StateSubObjectType.WorkGraph, workGraph),
            };

            var stateObjDesc = new StateObjectDescription
            {
                Type = StateObjectType.Executable,
                SubObjects = subObjects,
            };

            _workGraphStateObject = _device.CreateStateObject(stateObjDesc);
            DebugLogger.Info("[DX12Renderer] Work graph state object created");

            // Get program identifier
            var props = _workGraphStateObject.QueryInterface<ID3D12StateObjectProperties1>();
            _workGraphProgramId = props.GetProgramIdentifier("wg_audio_visualizer");
            props.Dispose();

            // Get backing memory requirements
            var wgProps = _workGraphStateObject.QueryInterface<ID3D12WorkGraphProperties>();
            uint wgIndex = wgProps.GetWorkGraphIndex("wg_audio_visualizer");
            var memReqs = wgProps.GetWorkGraphMemoryRequirements(wgIndex);
            wgProps.Dispose();

            _workGraphBackingMemSize = memReqs.MaxSizeInBytes;
            if (_workGraphBackingMemSize == 0)
                _workGraphBackingMemSize = 1024 * 1024; // 1MB fallback

            // Align to granularity
            if (memReqs.SizeGranularityInBytes > 0)
                _workGraphBackingMemSize = (_workGraphBackingMemSize + memReqs.SizeGranularityInBytes - 1) & ~((ulong)memReqs.SizeGranularityInBytes - 1);

            _workGraphBackingMemory = _device.CreateCommittedResource(
                HeapType.Default,
                ResourceDescription.Buffer((uint)_workGraphBackingMemSize),
                ResourceStates.Common);

            DebugLogger.Info($"[DX12Renderer] Work graph backing memory: {_workGraphBackingMemSize} bytes");
            _workGraphLoaded = true;
        }
        finally
        {
            result?.Dispose();
            sourceBlob?.Dispose();
            compiler?.Dispose();
            utils?.Dispose();
        }
        */
    }

    private void LoadCompositeShader(ReadOnlySpan<byte> vsBytecode)
    {
        string[] searchPaths = {
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "shaders"),
            Path.Combine(AppContext.BaseDirectory, "shaders"),
            @"C:\Users\htsou\CascadeProjects\RTXAudioVisualizer\shaders",
        };

        string shaderDir = "";
        foreach (var p in searchPaths)
        {
            if (Directory.Exists(p)) { shaderDir = p; break; }
        }

        string compositePath = Path.Combine(shaderDir, "dx_composite.hlsl");
        if (!File.Exists(compositePath))
        {
            DebugLogger.Warn("[DX12Renderer] Composite shader not found, using direct render");
            return;
        }

        try
        {
            string source = File.ReadAllText(compositePath);
            source = PreprocessIncludes(source);
            var psBytecode = CompileShader(source, "main", "dx_composite.hlsl", "ps_6_6", "ps_5_0");
            var psoDesc = CreatePSODesc(vsBytecode, psBytecode, Format.R8G8B8A8_UNorm);
            _compositePSO = _device.CreateGraphicsPipelineState(psoDesc);
            DebugLogger.Info("[DX12U] Composite shader loaded (DXC ps_6_6)");
        }
        catch (Exception e)
        {
            DebugLogger.Error($"[DX12U] Composite shader failed: {e.Message}");
        }
    }

    private void LoadOverlayShader(ReadOnlySpan<byte> vsBytecode)
    {
        string[] searchPaths = {
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "shaders"),
            Path.Combine(AppContext.BaseDirectory, "shaders"),
            @"C:\Users\htsou\CascadeProjects\RTXAudioVisualizer\shaders",
        };

        string shaderDir = "";
        foreach (var p in searchPaths)
        {
            if (Directory.Exists(p)) { shaderDir = p; break; }
        }

        string overlayPath = Path.Combine(shaderDir, "dx_overlay.hlsl");
        if (!File.Exists(overlayPath))
        {
            DebugLogger.Warn("[DX12Renderer] Overlay shader not found");
            return;
        }

        try
        {
            string source = File.ReadAllText(overlayPath);
            source = PreprocessIncludes(source);
            var psBytecode = CompileShader(source, "main", "dx_overlay.hlsl", "ps_6_6", "ps_5_0");
            var psoDesc = CreatePSODesc(vsBytecode, psBytecode, Format.R16G16B16A16_Float);
            _overlayPSO = _device.CreateGraphicsPipelineState(psoDesc);
            DebugLogger.Info("[DX12U] Overlay shader loaded (DXC ps_6_6)");
        }
        catch (Exception e)
        {
            DebugLogger.Error($"[DX12U] Overlay shader failed: {e.Message}");
        }
    }

    private void LoadPostFxShader(ReadOnlySpan<byte> vsBytecode)
    {
        string[] searchPaths = {
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "shaders"),
            Path.Combine(AppContext.BaseDirectory, "shaders"),
            @"C:\Users\htsou\CascadeProjects\RTXAudioVisualizer\shaders",
        };

        string shaderDir = "";
        foreach (var p in searchPaths)
        {
            if (Directory.Exists(p)) { shaderDir = p; break; }
        }

        string postfxPath = Path.Combine(shaderDir, "dx_postfx.hlsl");
        if (!File.Exists(postfxPath))
        {
            DebugLogger.Warn("[DX12Renderer] PostFX shader not found");
            return;
        }

        try
        {
            string source = File.ReadAllText(postfxPath);
            source = PreprocessIncludes(source);
            var psBytecode = CompileShader(source, "main", "dx_postfx.hlsl", "ps_6_6", "ps_5_0");
            var psoDesc = CreatePSODesc(vsBytecode, psBytecode, Format.R16G16B16A16_Float);
            _postfxPSO = _device.CreateGraphicsPipelineState(psoDesc);
            DebugLogger.Info("[DX12U] PostFX shader loaded (DXC ps_6_6)");
        }
        catch (Exception e)
        {
            DebugLogger.Error($"[DX12U] PostFX shader failed: {e.Message}");
        }
    }

    private void LoadToneMapShader(ReadOnlySpan<byte> vsBytecode)
    {
        string[] searchPaths = {
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "shaders"),
            Path.Combine(AppContext.BaseDirectory, "shaders"),
            @"C:\Users\htsou\CascadeProjects\RTXAudioVisualizer\shaders",
        };

        string shaderDir = "";
        foreach (var p in searchPaths)
        {
            if (Directory.Exists(p)) { shaderDir = p; break; }
        }

        string tonemapPath = Path.Combine(shaderDir, "dx_tonemap.hlsl");
        if (!File.Exists(tonemapPath))
        {
            DebugLogger.Warn("[DX12Renderer] Tone-map shader not found");
            return;
        }

        try
        {
            string source = File.ReadAllText(tonemapPath);
            source = PreprocessIncludes(source);
            var psBytecode = CompileShader(source, "main", "dx_tonemap.hlsl", "ps_6_6", "ps_5_0");
            var psoDesc = CreatePSODesc(vsBytecode, psBytecode, Format.R8G8B8A8_UNorm);
            _tonemapPSO = _device.CreateGraphicsPipelineState(psoDesc);
            DebugLogger.Info("[DX12U] Tone-map shader loaded (DXC ps_6_6)");
        }
        catch (Exception e)
        {
            DebugLogger.Error($"[DX12U] Tone-map shader failed: {e.Message}");
        }
    }

    private void LoadSkiaShader(ReadOnlySpan<byte> vsBytecode)
    {
        string[] searchPaths = {
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "shaders"),
            Path.Combine(AppContext.BaseDirectory, "shaders"),
            @"C:\Users\htsou\CascadeProjects\RTXAudioVisualizer\shaders",
        };

        string shaderDir = "";
        foreach (var p in searchPaths)
        {
            if (Directory.Exists(p)) { shaderDir = p; break; }
        }

        string skiaPath = Path.Combine(shaderDir, "dx_skia_composite.hlsl");
        if (!File.Exists(skiaPath))
        {
            DebugLogger.Warn("[DX12Renderer] Skia composite shader not found");
            return;
        }

        try
        {
            string source = File.ReadAllText(skiaPath);
            source = PreprocessIncludes(source);
            var psBytecode = CompileShader(source, "main", "dx_skia_composite.hlsl", "ps_6_6", "ps_5_0");

            // Create PSO with premultiplied alpha blend state
            var blendDesc = new BlendDescription
            {
                AlphaToCoverageEnable = false,
                IndependentBlendEnable = false,
            };
            blendDesc.RenderTarget[0] = new RenderTargetBlendDescription
            {
                BlendEnable = true,
                SourceBlend = Blend.One,                    // premultiplied src
                DestinationBlend = Blend.InverseSourceAlpha,
                BlendOperation = BlendOperation.Add,
                SourceBlendAlpha = Blend.One,
                DestinationBlendAlpha = Blend.InverseSourceAlpha,
                BlendOperationAlpha = BlendOperation.Add,
                RenderTargetWriteMask = ColorWriteEnable.All,
            };

            var psoDesc = new GraphicsPipelineStateDescription
            {
                RootSignature = _rootSignature,
                VertexShader = vsBytecode.ToArray(),
                PixelShader = psBytecode.ToArray(),
                InputLayout = new InputLayoutDescription(new InputElementDescription[]
                {
                    new InputElementDescription("POSITION", 0, Format.R32G32B32_Float, 0, 0, InputClassification.PerVertexData, 0),
                    new InputElementDescription("TEXCOORD", 0, Format.R32G32B32_Float, 12, 0, InputClassification.PerVertexData, 0),
                }),
                SampleMask = uint.MaxValue,
                PrimitiveTopologyType = PrimitiveTopologyType.Triangle,
                RasterizerState = RasterizerDescription.CullNone,
                BlendState = blendDesc,
                DepthStencilState = new DepthStencilDescription { DepthEnable = false, DepthWriteMask = DepthWriteMask.All, StencilEnable = false },
                RenderTargetFormats = new Format[] { Format.R8G8B8A8_UNorm },
                SampleDescription = new SampleDescription(1, 0),
                NodeMask = 0,
                CachedPSO = default,
                Flags = PipelineStateFlags.None,
            };
            _skiaPSO = _device.CreateGraphicsPipelineState(psoDesc);
            DebugLogger.Info("[DX12U] Skia composite shader loaded (DXC ps_6_6, premul alpha blend)");
        }
        catch (Exception e)
        {
            DebugLogger.Error($"[DX12U] Skia composite shader failed: {e.Message}");
        }
    }

    public void NextMode()
    {
        if (_modeNames.Count == 0) return;
        _currentMode = (_currentMode + 1) % _modeNames.Count;
        DebugLogger.Info($"[DX12Renderer] Mode: {CurrentMode}");
    }

    public void PrevMode()
    {
        if (_modeNames.Count == 0) return;
        _currentMode = (_currentMode - 1 + _modeNames.Count) % _modeNames.Count;
        DebugLogger.Info($"[DX12Renderer] Mode: {CurrentMode}");
    }

    public void SetMode(string name)
    {
        int idx = _modeNames.IndexOf(name);
        if (idx < 0)
        {
            // Try reverse lookup from display name
            foreach (var kv in _displayNames)
            {
                if (kv.Value == name) { idx = _modeNames.IndexOf(kv.Key); break; }
            }
        }
        if (idx >= 0)
        {
            _currentMode = idx;
            DebugLogger.Info($"[DX12Renderer] Mode: {CurrentMode}");
        }
    }

    public void ResetGPU()
    {
        // Reset GPU state after prolonged silence — clear frame state but keep current mode
        _firstFrame = true;
        _shouldResetGPU = false;
        DebugLogger.Info("[DX12Renderer] GPU frame state reset after silence (mode preserved)");
    }

    public void ToggleHUD()
    {
        _hudVisible = !_hudVisible;
        if (_hud != null) _hud.Visible = _hudVisible;
        DebugLogger.Info($"[DX12Renderer] HUD: {(_hudVisible ? "ON" : "OFF")}");
    }

    public void ToggleSkiaOverlay()
    {
        _skiaEnabled = !_skiaEnabled;
        DebugLogger.Info($"[DX12Renderer] SkiaSharp overlay: {(_skiaEnabled ? "ON" : "OFF")}");
    }

    public void UpdateAudioData(ref AudioUBO ubo, float[] spectrum, float[]? leftSpectrum = null, float[]? rightSpectrum = null)
    {
        _currentAudioUBO = ubo;

        if (_verbose && _frameCount % 60 == 0)
        {
            DebugLogger.Info($"[DX12Debug] UpdateAudioData: spectrum={spectrum?.Length ?? 0}, left={leftSpectrum?.Length ?? 0}, right={rightSpectrum?.Length ?? 0}");
            DebugLogger.Info($"[DX12Debug] AudioUBO: beat={ubo.Beat}, overall={ubo.Overall}, bpm={ubo.BPM}");
        }

        Marshal.StructureToPtr(ubo, _audioCBPtr, false);

        var timeCB = new TimeCB { GlobalTime = _time, DeltaTime = _deltaTime, RenderResolution = new Vector2(_width, _height) };
        Marshal.StructureToPtr(timeCB, _timeCBPtr, false);

        // Upload spectrum data to 3-row texture: row 0 = left, row 1 = center, row 2 = right
        int count = spectrum != null ? Math.Min(spectrum.Length, 1024) : 0;
        int leftCount = leftSpectrum != null ? Math.Min(leftSpectrum.Length, 1024) : count;
        int rightCount = rightSpectrum != null ? Math.Min(rightSpectrum.Length, 1024) : count;

        // Copy to 3 rows (1024 floats each = 3072 floats total)
        float[] uploadData = new float[1024 * 3];
        
        // Row 0: Left channel (or mono if not available)
        if (leftSpectrum != null)
        {
            for (int i = 0; i < leftCount; i++)
                uploadData[i] = leftSpectrum[i];
        }
        else if (spectrum != null)
        {
            for (int i = 0; i < count; i++)
                uploadData[i] = spectrum[i];
        }
        
        // Row 1: Center/mono
        if (spectrum != null)
        {
            for (int i = 0; i < count; i++)
                uploadData[1024 + i] = spectrum[i];
        }
        
        // Row 2: Right channel (or mono if not available)
        if (rightSpectrum != null)
        {
            for (int i = 0; i < rightCount; i++)
                uploadData[2048 + i] = rightSpectrum[i];
        }
        else if (spectrum != null)
        {
            for (int i = 0; i < count; i++)
                uploadData[2048 + i] = spectrum[i];
        }

        // Use SetData helper instead of manual Marshal.Copy
        _spectrumUploadBuffer.SetData(uploadData);
        _spectrumDirty = true;

        if (_verbose && _frameCount % 60 == 0)
        {
            float avgL = leftSpectrum != null ? leftSpectrum.Take(10).Average() : 0;
            float avgR = rightSpectrum != null ? rightSpectrum.Take(10).Average() : 0;
            DebugLogger.Info($"[DX12Debug] Spectrum uploaded: avgL={avgL:F3}, avgR={avgR:F3}, dirty={_spectrumDirty}");
        }
    }

    public void UpdateHUD(QuadBufferedVisuals.VisualFrame frame)
    {
        _lastFrame = frame;

        // Upload DSP data to b2 constant buffer
        Span<float> dspData = stackalloc float[16];
        dspData[0] = frame.MomentaryLUFS;
        dspData[1] = frame.ShortTermLUFS;
        dspData[2] = frame.IntegratedLUFS;
        dspData[3] = frame.THDPercentage;
        dspData[4] = frame.PhaseCorrelationDSP;
        dspData[5] = frame.PeakDbL;
        dspData[6] = frame.PeakDbR;
        dspData[7] = frame.CrestFactorDbL;
        dspData[8] = frame.DspBand0;
        dspData[9] = frame.DspBand1;
        dspData[10] = frame.DspBand2;
        dspData[11] = frame.DspBand3;
        dspData[12] = frame.DspBand4;
        dspData[13] = frame.DspBand5;
        dspData[14] = frame.DspBand6;
        dspData[15] = frame.DspBand7;
        Marshal.Copy(dspData.ToArray(), 0, _dspCBPtr, 16);
    }

    public void Render(float time)
    {
        _renderStartTicks = _renderTimer.ElapsedTicks;
        _deltaTime = time - _time;
        _time = time;

        if (_verbose && _frameCount % 60 == 0)
        {
            DebugLogger.Info($"[DX12Debug] Render frame {_frameCount}: time={time:F3}, width={_width}, height={_height}");
        }

        WaitForGpu();

        _commandAllocators[_frameIndex].Reset();
        _commandList.Reset(_commandAllocators[_frameIndex], null);

        // Copy spectrum data from upload buffer to default heap texture (3 rows)
        if (_spectrumDirty)
        {
            if (_verbose && _frameCount % 60 == 0)
                DebugLogger.Info("[DX12Debug] Copying spectrum texture (3 rows, 1024x3)");

            var srcLocation = new TextureCopyLocation(_spectrumUploadBuffer, new PlacedSubresourceFootPrint
            {
                Offset = 0,
                Footprint = new SubresourceFootPrint
                {
                    Format = Format.R32_Float,
                    Width = 1024,
                    Height = 3,
                    Depth = 1,
                    RowPitch = 1024 * 4,
                },
            });
            var dstLocation = new TextureCopyLocation(_spectrumTexture, 0);
            _commandList.CopyTextureRegion(dstLocation, 0, 0, 0, srcLocation, null);
            _commandList.ResourceBarrierTransition(_spectrumTexture, ResourceStates.CopyDest, ResourceStates.PixelShaderResource);
            _spectrumDirty = false;
        }

        _commandList.RSSetViewports(new Viewport(0, 0, _width, _height));
        _commandList.RSSetScissorRects(new Vortice.RawRect(0, 0, _width, _height));

        _commandList.SetGraphicsRootSignature(_rootSignature);
        _commandList.SetDescriptorHeaps(new[] { _cbvSrvUavHeap, _samplerHeap });

        _commandList.SetGraphicsRootConstantBufferView(0, _audioCB.GPUVirtualAddress);
        _commandList.SetGraphicsRootConstantBufferView(1, _timeCB.GPUVirtualAddress);
        _commandList.SetGraphicsRootConstantBufferView(2, _dspCB.GPUVirtualAddress);

        _commandList.IASetVertexBuffers(0, new VertexBufferView
        {
            BufferLocation = _vertexBuffer.GPUVirtualAddress,
            SizeInBytes = 4 * 5 * sizeof(float),
            StrideInBytes = 5 * sizeof(float),
        });
        _commandList.IASetIndexBuffer(new IndexBufferView
        {
            BufferLocation = _indexBuffer.GPUVirtualAddress,
            SizeInBytes = 6 * sizeof(uint),
            Format = Format.R32_UInt,
        });
        _commandList.IASetPrimitiveTopology(Vortice.Direct3D.PrimitiveTopology.TriangleStrip);

        // SRV descriptor table (root param 3): [0]=spectrum, [1]=layer0, [2]=layer1, [3]=bloom0, [4]=bloom1, [5-7]=null
        var srvGpuHandle = _cbvSrvUavHeap.GetGPUDescriptorHandleForHeapStart();
        _commandList.SetGraphicsRootDescriptorTable(3, srvGpuHandle);

        // UAV descriptor table (root param 4): [8-11]=u0-u3 (null for now, future compute use)
        var uavGpuHandle = _cbvSrvUavHeap.GetGPUDescriptorHandleForHeapStart() + (int)(_srvDescriptorSize * 8);
        _commandList.SetGraphicsRootDescriptorTable(4, uavGpuHandle);

        if (_verbose && _frameCount % 60 == 0)
            DebugLogger.Info($"[DX12Debug] Root signature set, current mode: {CurrentMode}");

        // ── Layer 0: Base mode shader → layerTex0 (R16G16B16A16_Float) ──
        var layerBeforeState = _firstFrame ? ResourceStates.Common : ResourceStates.PixelShaderResource;
        _commandList.ResourceBarrierTransition(_layerTex0,
            layerBeforeState, ResourceStates.RenderTarget);

        var layer0Rtv = _rtvHeapLayer.GetCPUDescriptorHandleForHeapStart();
        _commandList.ClearRenderTargetView(layer0Rtv, new Color4(0, 0, 0, 1));
        _commandList.OMSetRenderTargets(layer0Rtv, null);

        if (_modeNames.Count > 0)
        {
            string currentModeName = _modeNames[_currentMode];

            if (_pixelShaders.TryGetValue(currentModeName, out var modePSO))
            {
                _commandList.SetPipelineState(modePSO);
                _commandList.DrawInstanced(4, 1, 0, 0);
            }
            if (_verbose && _frameCount % 60 == 0)
                DebugLogger.Info($"[DX12Debug] Drew mode: {currentModeName}");
        }

        // ── Layer 1: Overlay shader → layerTex1 ──
        _commandList.ResourceBarrierTransition(_layerTex1,
            layerBeforeState, ResourceStates.RenderTarget);

        var layer1Rtv = _rtvHeapLayer1.GetCPUDescriptorHandleForHeapStart();
        _commandList.ClearRenderTargetView(layer1Rtv, new Color4(0, 0, 0, 1));

        if (_overlayPSO != null)
        {
            _commandList.OMSetRenderTargets(layer1Rtv, null);
            _commandList.SetPipelineState(_overlayPSO);
            _commandList.DrawInstanced(4, 1, 0, 0);
        }

        // ── Bloom pipeline (if enabled) ──
        if (_bloomEnabled && _bloomExtractPSO != null && _bloomBlurHPSO != null && _bloomBlurVPSO != null)
        {
            // Transition layerTex0: RenderTarget → PixelShaderResource (for extract)
            _commandList.ResourceBarrierTransition(_layerTex0, ResourceStates.RenderTarget, ResourceStates.PixelShaderResource);

            // Extract: layerTex0 → bloomTexture (downsampled)
            // Bind layerTex0 at t0 (descriptor offset 2)
            var extractSrvHandle = srvGpuHandle + (int)(_srvDescriptorSize * 2);
            _commandList.SetGraphicsRootDescriptorTable(3, extractSrvHandle);
            
            _commandList.ResourceBarrierTransition(_bloomTexture, ResourceStates.CopyDest, ResourceStates.RenderTarget);
            var bloomRtv0 = _bloomRtvHeap.GetCPUDescriptorHandleForHeapStart();
            _commandList.OMSetRenderTargets(bloomRtv0, null);
            _commandList.SetPipelineState(_bloomExtractPSO);
            _commandList.DrawInstanced(4, 1, 0, 0);

            // Blur H: bloomTexture → bloomTexture2
            // Bind bloomTexture at t0 (descriptor offset 4)
            var blurHSrvHandle = srvGpuHandle + (int)(_srvDescriptorSize * 4);
            _commandList.SetGraphicsRootDescriptorTable(3, blurHSrvHandle);
            
            _commandList.ResourceBarrierTransition(_bloomTexture, ResourceStates.RenderTarget, ResourceStates.PixelShaderResource);
            _commandList.ResourceBarrierTransition(_bloomTexture2, ResourceStates.CopyDest, ResourceStates.RenderTarget);
            var bloomRtv1 = _bloomRtvHeap.GetCPUDescriptorHandleForHeapStart();
            bloomRtv1.Ptr += _rtvDescriptorSize;
            _commandList.OMSetRenderTargets(bloomRtv1, null);
            _commandList.SetPipelineState(_bloomBlurHPSO);
            _commandList.DrawInstanced(4, 1, 0, 0);

            // Blur V: bloomTexture2 → bloomTexture
            // Bind bloomTexture2 at t0 (descriptor offset 5)
            var blurVSrvHandle = srvGpuHandle + (int)(_srvDescriptorSize * 5);
            _commandList.SetGraphicsRootDescriptorTable(3, blurVSrvHandle);
            
            _commandList.ResourceBarrierTransition(_bloomTexture2, ResourceStates.RenderTarget, ResourceStates.PixelShaderResource);
            _commandList.ResourceBarrierTransition(_bloomTexture, ResourceStates.PixelShaderResource, ResourceStates.RenderTarget);
            _commandList.OMSetRenderTargets(bloomRtv0, null);
            _commandList.SetPipelineState(_bloomBlurVPSO);
            _commandList.DrawInstanced(4, 1, 0, 0);

            // Transition bloomTexture: RenderTarget → PixelShaderResource (for combine)
            _commandList.ResourceBarrierTransition(_bloomTexture, ResourceStates.RenderTarget, ResourceStates.PixelShaderResource);
        }

        // ── PostFX pass: layer0 + layer1 + bloom → _postfxTex (HDR) ──
        // Transition layers: RenderTarget → PixelShaderResource
        if (!_bloomEnabled || _bloomExtractPSO == null)
        {
            _commandList.ResourceBarrierTransition(_layerTex0,
                ResourceStates.RenderTarget, ResourceStates.PixelShaderResource);
        }
        _commandList.ResourceBarrierTransition(_layerTex1,
            ResourceStates.RenderTarget, ResourceStates.PixelShaderResource);

        // Transition postfxTex: Common → RenderTarget
        var postfxBeforeState = _firstFrame ? ResourceStates.Common : ResourceStates.PixelShaderResource;
        _commandList.ResourceBarrierTransition(_postfxTex,
            postfxBeforeState, ResourceStates.RenderTarget);

        var postfxRtv = _postfxRtvHeap.GetCPUDescriptorHandleForHeapStart();
        _commandList.ClearRenderTargetView(postfxRtv, new Color4(0, 0, 0, 1));
        _commandList.OMSetRenderTargets(postfxRtv, null);

        // Bind SRV table at offset 0: t0=spectrum, t1=layer0, t2=layer1, t3=bloom0
        _commandList.SetGraphicsRootDescriptorTable(3, srvGpuHandle);

        if (_postfxPSO != null)
        {
            _commandList.SetPipelineState(_postfxPSO);
            _commandList.DrawInstanced(4, 1, 0, 0);
        }
        else if (_compositePSO != null)
        {
            // Fallback to old composite if PostFX failed to load
            _commandList.SetPipelineState(_compositePSO);
            _commandList.DrawInstanced(4, 1, 0, 0);
        }

        // ── Tone-map pass: _postfxTex → backbuffer (LDR) ──
        // Transition postfxTex: RenderTarget → PixelShaderResource
        _commandList.ResourceBarrierTransition(_postfxTex,
            ResourceStates.RenderTarget, ResourceStates.PixelShaderResource);

        // Transition back buffer: Common/Present → RenderTarget
        var beforeState = _firstFrame ? ResourceStates.Common : ResourceStates.Present;
        _commandList.ResourceBarrierTransition(_renderTargets[_frameIndex],
            beforeState, ResourceStates.RenderTarget);

        var backBufferRtv = _rtvHeap.GetCPUDescriptorHandleForHeapStart();
        backBufferRtv += (int)(_rtvDescriptorSize * _frameIndex);
        _commandList.ClearRenderTargetView(backBufferRtv, new Color4(0, 0, 0, 1));
        _commandList.OMSetRenderTargets(backBufferRtv, null);

        // Bind the complete SRV table so PostFxTex at register t6 resolves to postfxTex.
        _commandList.SetGraphicsRootDescriptorTable(3, srvGpuHandle);

        if (_tonemapPSO != null)
        {
            _commandList.SetPipelineState(_tonemapPSO);
            _commandList.DrawInstanced(4, 1, 0, 0);
        }
        else if (_compositePSO != null)
        {
            // Fallback: old composite reads t1=layer0 directly
            _commandList.SetGraphicsRootDescriptorTable(3, srvGpuHandle);
            _commandList.SetPipelineState(_compositePSO);
            _commandList.DrawInstanced(4, 1, 0, 0);
        }

        // ── SkiaSharp 2D overlay pass: alpha-blend on backbuffer ──
        if (_skiaEnabled && _skiaPSO != null && _skiaOverlay != null)
        {
            // Render 2D overlay content on CPU
            var skiaPixels = _skiaOverlay.Render(_time, ref _currentAudioUBO);

            // Copy pixel data to upload buffer
            unsafe
            {
                fixed (byte* src = skiaPixels)
                {
                    Buffer.MemoryCopy(src, (void*)_skiaUploadPtr, _skiaUploadSize, skiaPixels.Length);
                }
            }

            // Copy upload buffer → skiaTex (default heap)
            _commandList.ResourceBarrierTransition(_skiaTex, ResourceStates.PixelShaderResource, ResourceStates.CopyDest);
            var skiaSrcLoc = new TextureCopyLocation(_skiaUploadBuffer, new PlacedSubresourceFootPrint
            {
                Offset = 0,
                Footprint = new SubresourceFootPrint
                {
                    Format = Format.R8G8B8A8_UNorm,
                    Width = (uint)_width,
                    Height = (uint)_height,
                    Depth = 1,
                    RowPitch = (uint)(_width * 4),
                },
            });
            var skiaDstLoc = new TextureCopyLocation(_skiaTex, 0);
            _commandList.CopyTextureRegion(skiaDstLoc, 0, 0, 0, skiaSrcLoc, null);
            _commandList.ResourceBarrierTransition(_skiaTex, ResourceStates.CopyDest, ResourceStates.PixelShaderResource);

            // Draw overlay with alpha blending (backbuffer is already RenderTarget)
            var skiaSrvHandle = srvGpuHandle + (int)(_srvDescriptorSize * 7);
            _commandList.SetGraphicsRootDescriptorTable(3, skiaSrvHandle);
            _commandList.SetPipelineState(_skiaPSO);
            _commandList.DrawInstanced(4, 1, 0, 0);
        }

        // Draw HUD overlay
        if (_hud != null && _hudVisible)
        {
            float dt = 1.0f / 60.0f;
            string rawName = _modeNames.Count > 0 ? _modeNames[_currentMode] : "none";
            _hud.CurrentModeName = _displayNames.TryGetValue(rawName, out var displayName) ? displayName : rawName;
            _hud.CurrentModeIndex = _currentMode;
            _hud.TotalModes = _modeNames.Count;
            _hud.Render(_commandList, _lastFrame, dt);
        }

        // Transition back buffer: RenderTarget → Present
        _commandList.ResourceBarrierTransition(_renderTargets[_frameIndex],
            ResourceStates.RenderTarget, ResourceStates.Present);

        _commandList.Close();
        _commandQueue.ExecuteCommandList(_commandList);

        _swapChain.Present(1, PresentFlags.None);

        _fenceValue++;
        _commandQueue.Signal(_fence, _fenceValue);

        _frameIndex = (int)_swapChain.CurrentBackBufferIndex;
        _firstFrame = false;

        RenderLatencyMs = (float)(_renderTimer.ElapsedTicks - _renderStartTicks) / System.Diagnostics.Stopwatch.Frequency * 1000f;

        // Frame statistics
        _frameCount++;
        _totalRenderTime += RenderLatencyMs;
        _minRenderTime = Math.Min(_minRenderTime, RenderLatencyMs);
        _maxRenderTime = Math.Max(_maxRenderTime, RenderLatencyMs);

        if (_verbose && _frameCount % 60 == 0)
        {
            float avg = _totalRenderTime / _frameCount;
            DebugLogger.Info($"[DX12Debug] Frame stats: avg={avg:F2}ms, min={_minRenderTime:F2}ms, max={_maxRenderTime:F2}ms, frames={_frameCount}");
        }
    }

    // ── Unified renderer: shared texture support ──
    private ID3D12Resource? _sharedTexture;
    private ID3D12DescriptorHeap? _sharedRtvHeap;

    public void OpenSharedTexture(IntPtr sharedHandle)
    {
        _sharedTexture = _device.OpenSharedHandle<ID3D12Resource>(sharedHandle);
        _sharedRtvHeap = _device.CreateDescriptorHeap(
            new DescriptorHeapDescription(DescriptorHeapType.RenderTargetView, 1));
        _device.CreateRenderTargetView(_sharedTexture, null,
            _sharedRtvHeap.GetCPUDescriptorHandleForHeapStart());
        DebugLogger.Info("[DX12Renderer] Shared texture opened for unified rendering (fence sync)");
    }

    public void RenderToSharedTexture(float time)
    {
        if (_sharedTexture == null || _sharedRtvHeap == null) return;
        _deltaTime = time - _time;
        _time = time;
        WaitForGpu();
        _commandAllocators[_frameIndex].Reset();
        _commandList.Reset(_commandAllocators[_frameIndex], null);

        if (_spectrumDirty)
        {
            var srcLoc = new TextureCopyLocation(_spectrumUploadBuffer, new PlacedSubresourceFootPrint
            {
                Offset = 0, Footprint = new SubresourceFootPrint { Format = Format.R32_Float, Width = 1024, Height = 1, Depth = 1, RowPitch = _spectrumUploadSize }
            });
            _commandList.CopyTextureRegion(new TextureCopyLocation(_spectrumTexture, 0), 0, 0, 0, srcLoc, null);
            _commandList.ResourceBarrierTransition(_spectrumTexture, ResourceStates.CopyDest, ResourceStates.PixelShaderResource);
            _spectrumDirty = false;
        }

        _commandList.RSSetViewports(new Viewport(0, 0, _width, _height));
        _commandList.RSSetScissorRects(new Vortice.RawRect(0, 0, _width, _height));
        _commandList.SetGraphicsRootSignature(_rootSignature);
        _commandList.SetDescriptorHeaps(new[] { _cbvSrvUavHeap, _samplerHeap });
        _commandList.SetGraphicsRootConstantBufferView(0, _audioCB.GPUVirtualAddress);
        _commandList.SetGraphicsRootConstantBufferView(1, _timeCB.GPUVirtualAddress);
        _commandList.SetGraphicsRootConstantBufferView(2, _dspCB.GPUVirtualAddress);
        _commandList.IASetVertexBuffers(0, new VertexBufferView { BufferLocation = _vertexBuffer.GPUVirtualAddress, SizeInBytes = 4 * 5 * sizeof(float), StrideInBytes = 5 * sizeof(float) });
        _commandList.IASetIndexBuffer(new IndexBufferView { BufferLocation = _indexBuffer.GPUVirtualAddress, SizeInBytes = 6 * sizeof(uint), Format = Format.R32_UInt });
        _commandList.IASetPrimitiveTopology(Vortice.Direct3D.PrimitiveTopology.TriangleStrip);

        var srvGpu = _cbvSrvUavHeap.GetGPUDescriptorHandleForHeapStart();
        _commandList.SetGraphicsRootDescriptorTable(3, srvGpu);

        // Layer 0 → shared texture
        _commandList.ResourceBarrierTransition(_layerTex0, _firstFrame ? ResourceStates.Common : ResourceStates.PixelShaderResource, ResourceStates.RenderTarget);
        var layer0Rtv = _rtvHeapLayer.GetCPUDescriptorHandleForHeapStart();
        _commandList.ClearRenderTargetView(layer0Rtv, new Color4(0, 0, 0, 1));
        _commandList.OMSetRenderTargets(layer0Rtv, null);

        if (_modeNames.Count > 0 && _pixelShaders.TryGetValue(_modeNames[_currentMode], out var modePSO))
        {
            _commandList.SetPipelineState(modePSO);
            _commandList.DrawInstanced(4, 1, 0, 0);
        }

        // Copy layerTex0 → feedback texture for next frame's simulation memory
        // feedbackTex0 is bound as t5 SRV, shaders sample previous frame from it
        _commandList.ResourceBarrierTransition(_feedbackTex0,
            _firstFrame ? ResourceStates.Common : ResourceStates.PixelShaderResource,
            ResourceStates.CopyDest);
        _commandList.ResourceBarrierTransition(_layerTex0,
            ResourceStates.RenderTarget, ResourceStates.CopySource);
        _commandList.CopyResource(_feedbackTex0, _layerTex0);
        _commandList.ResourceBarrierTransition(_feedbackTex0,
            ResourceStates.CopyDest, ResourceStates.PixelShaderResource);
        _commandList.ResourceBarrierTransition(_layerTex0,
            ResourceStates.CopySource, ResourceStates.RenderTarget);

        // Layer 1: overlay
        _commandList.ResourceBarrierTransition(_layerTex1, _firstFrame ? ResourceStates.Common : ResourceStates.PixelShaderResource, ResourceStates.RenderTarget);
        var layer1Rtv = _rtvHeapLayer1.GetCPUDescriptorHandleForHeapStart();
        _commandList.ClearRenderTargetView(layer1Rtv, new Color4(0, 0, 0, 1));
        if (_overlayPSO != null)
        {
            _commandList.OMSetRenderTargets(layer1Rtv, null);
            _commandList.SetPipelineState(_overlayPSO);
            _commandList.DrawInstanced(4, 1, 0, 0);
        }

        // Composite layers → shared texture
        _commandList.ResourceBarrierTransition(_layerTex0, ResourceStates.RenderTarget, ResourceStates.PixelShaderResource);
        _commandList.ResourceBarrierTransition(_layerTex1, ResourceStates.RenderTarget, ResourceStates.PixelShaderResource);
        _commandList.ResourceBarrierTransition(_sharedTexture, ResourceStates.Common, ResourceStates.RenderTarget);

        var sharedRtv = _sharedRtvHeap.GetCPUDescriptorHandleForHeapStart();
        _commandList.ClearRenderTargetView(sharedRtv, new Color4(0, 0, 0, 1));
        _commandList.OMSetRenderTargets(sharedRtv, null);

        var layerSrv = srvGpu;
        layerSrv += (int)(_srvDescriptorSize * 2);
        _commandList.SetGraphicsRootDescriptorTable(3, layerSrv);

        if (_compositePSO != null)
        {
            _commandList.SetPipelineState(_compositePSO);
            _commandList.DrawInstanced(4, 1, 0, 0);
        }

        _commandList.ResourceBarrierTransition(_sharedTexture, ResourceStates.RenderTarget, ResourceStates.Common);
        _commandList.Close();
        _commandQueue.ExecuteCommandList(_commandList);

        _fenceValue++;
        _commandQueue.Signal(_fence, _fenceValue);
        _frameIndex = (int)(_frameIndex + 1) % FrameCount;
        _firstFrame = false;

        RenderLatencyMs = (float)(_renderTimer.ElapsedTicks - _renderStartTicks) / System.Diagnostics.Stopwatch.Frequency * 1000f;
    }

    private void WaitForGpu()
    {
        if (_fence.CompletedValue < _fenceValue)
        {
            _fence.SetEventOnCompletion(_fenceValue, _fenceEvent);
            _fenceEvent.WaitOne();
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        WaitForGpu();

        _hud?.Dispose();
        _commandList?.Dispose();
        foreach (var a in _commandAllocators) a?.Dispose();
        _fenceEvent.Dispose();

        foreach (var ps in _pixelShaders.Values) ps.Dispose();
        _compositePSO?.Dispose();
        _rootSignature?.Dispose();

        _vertexBuffer?.Dispose();
        _indexBuffer?.Dispose();
        _audioCB?.Dispose();
        _timeCB?.Dispose();
        _dspCB?.Dispose();
        _spectrumTexture?.Dispose();
        _spectrumUploadBuffer?.Dispose();

        _layerTex0?.Dispose();
        _rtvHeapLayer?.Dispose();
        _layerTex1?.Dispose();
        _rtvHeapLayer1?.Dispose();
        _overlayPSO?.Dispose();
        _postfxTex?.Dispose();
        _postfxRtvHeap?.Dispose();
        _postfxPSO?.Dispose();
        _tonemapPSO?.Dispose();
        _skiaTex?.Dispose();
        _skiaUploadBuffer?.Dispose();
        _skiaPSO?.Dispose();
        _skiaOverlay?.Dispose();
        _rtvHeap?.Dispose();
        _cbvSrvUavHeap?.Dispose();
        _samplerHeap?.Dispose();

        foreach (var rt in _renderTargets) rt?.Dispose();
        _sharedRtvHeap?.Dispose();
        _sharedTexture?.Dispose();
        _swapChain?.Dispose();
        _fence?.Dispose();
        _commandQueue?.Dispose();
        _device?.Dispose();
        _factory?.Dispose();
    }
}
