using System;
using System.Numerics;
using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;
using Vortice.D3DCompiler;
using StageSimWASAPI;
using static Vortice.Direct3D11.D3D11;

namespace DXRenderer;

public class DX11Renderer : IRenderer
{
    private ID3D11Device1 _device;
    private ID3D11DeviceContext1 _context;
    private IDXGISwapChain1 _swapChain;
    private ID3D11RenderTargetView _rtv;
    private ID3D11Texture2D _depthStencil;
    private ID3D11DepthStencilView _dsv;

    private ID3D11Buffer _quadVB;
    private ID3D11InputLayout _inputLayout;
    private ID3D11VertexShader _vs;

    private ID3D11Buffer _audioCB;
    private ID3D11Buffer _timeCB;

    private Dictionary<string, ID3D11PixelShader> _pixelShaders = new();
    private Dictionary<string, ID3D11PixelShader> _bgShaders = new();   // background pass
    private Dictionary<string, ID3D11PixelShader> _fxShaders = new();   // effects pass
    private List<string> _modeNames = new();
    private int _currentMode = 0;

    private ID3D11ShaderResourceView _spectrumSRV;
    private ID3D11Texture2D _spectrumTexture;

    private ID3D11SamplerState _sampler;
    private ID3D11BlendState _blendState;
    private ID3D11BlendState _additiveBlendState;
    private ID3D11DepthStencilState _depthState;
    private ID3D11DepthStencilState _depthState3D;
    private ID3D11RasterizerState _rasterizer;

    // Multi-layer rendering — intermediate render targets for compositing
    private ID3D11Texture2D _layerTex0;  // base layer (main shader)
    private ID3D11RenderTargetView _layerRTV0;
    private ID3D11ShaderResourceView _layerSRV0;
    private ID3D11Texture2D _layerTex1;  // overlay layer (beams, particles)
    private ID3D11RenderTargetView _layerRTV1;
    private ID3D11ShaderResourceView _layerSRV1;

    // Overlay + post-process shaders
    private ID3D11PixelShader _overlayPS;   // beam/particle overlay
    private ID3D11PixelShader _compositePS;  // final composite + flash/strobe/bloom
    private ID3D11PixelShader _hudPS;        // HUD text blit
    private ID3D11PixelShader? _particleRenderPS;  // renders compute-shader particles

    // Brain HUD overlay
    private BrainHUD? _hud;

    // ── Compute shader pipeline ──
    private ID3D11ComputeShader? _particleCS;
    private ID3D11Buffer? _particleBufferA;     // ping-pong particle buffers
    private ID3D11Buffer? _particleBufferB;
    private ID3D11UnorderedAccessView? _particleUAV_A;
    private ID3D11UnorderedAccessView? _particleUAV_B;
    private ID3D11ShaderResourceView? _particleSRV_A;
    private ID3D11ShaderResourceView? _particleSRV_B;
    private ID3D11Buffer? _aliveCountBuffer;
    private ID3D11UnorderedAccessView? _aliveCountUAV;
    private ID3D11Buffer? _particleCB;
    private bool _useComputeParticles;
    private int _particleFrame;
    private AudioUBO _lastUBO;

    // ── 3D mesh rendering pipeline (for volumetric mode) ──
    private ID3D11Buffer? _sphereVB;
    private ID3D11Buffer? _sphereIB;
    private ID3D11VertexShader? _meshVS;
    private ID3D11PixelShader? _meshPS;
    private ID3D11InputLayout? _meshLayout;
    private int _sphereIndexCount;
    private ID3D11Buffer? _meshCB;

    // ── Particle vortex pipeline ──
    private ID3D11VertexShader? _particleVS;
    private ID3D11PixelShader? _particlePS;
    private ID3D11GeometryShader? _particleGS;
    private ID3D11ComputeShader? _vortexCS;

    // ── Bloom / post-FX render targets (downsampled) ──
    private ID3D11Texture2D? _bloomTexHalf;     // half-res bright pass
    private ID3D11RenderTargetView? _bloomRTVHalf;
    private ID3D11ShaderResourceView? _bloomSRVHalf;
    private ID3D11Texture2D? _bloomTexQuarter;  // quarter-res blurred
    private ID3D11RenderTargetView? _bloomRTVQuarter;
    private ID3D11ShaderResourceView? _bloomSRVQuarter;
    private ID3D11PixelShader? _bloomBrightPS;  // extract bright pixels
    private ID3D11PixelShader? _bloomBlurHPS;   // horizontal blur
    private ID3D11PixelShader? _bloomBlurVPS;   // vertical blur
    private ID3D11PixelShader? _bloomCombinePS; // additive bloom onto scene

    // ── Additional render layers for multilayered modes ──
    private ID3D11Texture2D? _layerTex2;        // FX layer (bloom input)
    private ID3D11RenderTargetView? _layerRTV2;
    private ID3D11ShaderResourceView? _layerSRV2;

    private const int MAX_PARTICLES = 65536;

    private int _width;
    private int _height;
    private float _time;
    private bool _disposed;

    public string BackendName => "D3D11";
    public bool SupportsWorkGraphs => false;
    public bool ShouldResetGPU => false;
    public ID3D11Device1 Device => _device;
    public ID3D11DeviceContext1 Context => _context;

    public DX11Renderer(IntPtr hwnd, int width, int height)
    {
        _width = width;
        _height = height;
        Initialize(hwnd);
    }

    private void Initialize(IntPtr hwnd)
    {
        FeatureLevel[] featureLevels = [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0];

        if (D3D11CreateDevice(
            IntPtr.Zero,
            DriverType.Hardware,
            DeviceCreationFlags.None,
            featureLevels,
            out ID3D11Device tempDevice,
            out FeatureLevel featureLevel,
            out ID3D11DeviceContext tempContext
        ).Failure)
        {
            D3D11CreateDevice(
                IntPtr.Zero,
                DriverType.Warp,
                DeviceCreationFlags.None,
                featureLevels,
                out tempDevice,
                out featureLevel,
                out tempContext
            ).CheckError();
        }

        _device = tempDevice.QueryInterface<ID3D11Device1>();
        _context = tempContext.QueryInterface<ID3D11DeviceContext1>();
        tempDevice.Dispose();
        tempContext.Dispose();

        // Swap chain
        using var dxgiDevice = _device.QueryInterface<IDXGIDevice>();
        using var adapter = dxgiDevice.GetParent<IDXGIAdapter>();
        using var factory = adapter.GetParent<IDXGIFactory2>();

        var swapChainDesc = new SwapChainDescription1
        {
            Width = (uint)_width,
            Height = (uint)_height,
            Format = Format.R8G8B8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            BufferUsage = Usage.RenderTargetOutput,
            BufferCount = 2,
            SwapEffect = SwapEffect.FlipDiscard,
            Scaling = Scaling.None,
            AlphaMode = AlphaMode.Ignore,
        };

        _swapChain = factory.CreateSwapChainForHwnd(_device, hwnd, swapChainDesc);

        // Render target
        using var backBuffer = _swapChain.GetBuffer<ID3D11Texture2D>(0);
        _rtv = _device.CreateRenderTargetView(backBuffer);

        // Depth stencil
        var depthDesc = new Texture2DDescription
        {
            Width = (uint)_width,
            Height = (uint)_height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.D32_Float,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.DepthStencil
        };
        _depthStencil = _device.CreateTexture2D(depthDesc);
        _dsv = _device.CreateDepthStencilView(_depthStencil);

        // Fullscreen quad
        float[] quadVerts = {
            -1, -1, 0,  0, 0,
             1, -1, 0,  1, 0,
            -1,  1, 0,  0, 1,
             1,  1, 0,  1, 1,
        };
        _quadVB = _device.CreateBuffer(quadVerts, BindFlags.VertexBuffer);

        // Vertex shader
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
        var vsBytecode = Compiler.Compile(vsSource, "main", "vs.hlsl", "vs_5_0");
        _vs = _device.CreateVertexShader(vsBytecode.Span);

        var inputElements = new[]
        {
            new InputElementDescription("POSITION", 0, Format.R32G32B32_Float, 0, 0),
            new InputElementDescription("TEXCOORD", 0, Format.R32G32_Float, 12, 0)
        };
        _inputLayout = _device.CreateInputLayout(inputElements, vsBytecode.Span);

        // Constant buffers
        _audioCB = _device.CreateBuffer(
            (uint)Marshal.SizeOf<AudioUBO>(),
            BindFlags.ConstantBuffer,
            ResourceUsage.Dynamic,
            CpuAccessFlags.Write
        );

        _timeCB = _device.CreateBuffer(
            (uint)Marshal.SizeOf<TimeCB>(),
            BindFlags.ConstantBuffer,
            ResourceUsage.Dynamic,
            CpuAccessFlags.Write
        );

        // Spectrum texture
        var texDesc = new Texture2DDescription
        {
            Width = 1024,
            Height = 2,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.R32_Float,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Dynamic,
            BindFlags = BindFlags.ShaderResource,
            CPUAccessFlags = CpuAccessFlags.Write
        };
        _spectrumTexture = _device.CreateTexture2D(texDesc);
        _spectrumSRV = _device.CreateShaderResourceView(_spectrumTexture);

        // Sampler
        _sampler = _device.CreateSamplerState(new SamplerDescription
        {
            Filter = Filter.MinMagLinearMipPoint,
            AddressU = TextureAddressMode.Clamp,
            AddressV = TextureAddressMode.Clamp,
            AddressW = TextureAddressMode.Clamp
        });

        // Blend state (opaque — no blending for fullscreen pass)
        var blendDesc = new BlendDescription();
        blendDesc.RenderTarget[0] = new RenderTargetBlendDescription
        {
            BlendEnable = false,
            SourceBlend = Blend.One,
            DestinationBlend = Blend.Zero,
            BlendOperation = BlendOperation.Add,
            SourceBlendAlpha = Blend.One,
            DestinationBlendAlpha = Blend.Zero,
            BlendOperationAlpha = BlendOperation.Add,
            RenderTargetWriteMask = ColorWriteEnable.All
        };
        _blendState = _device.CreateBlendState(blendDesc);

        // Additive blend state for overlay layers (beams, particles, bloom)
        var additiveDesc = new BlendDescription();
        additiveDesc.RenderTarget[0] = new RenderTargetBlendDescription
        {
            BlendEnable = true,
            SourceBlend = Blend.One,
            DestinationBlend = Blend.One,
            BlendOperation = BlendOperation.Add,
            SourceBlendAlpha = Blend.One,
            DestinationBlendAlpha = Blend.One,
            BlendOperationAlpha = BlendOperation.Add,
            RenderTargetWriteMask = ColorWriteEnable.All
        };
        _additiveBlendState = _device.CreateBlendState(additiveDesc);

        // Intermediate render targets for multi-layer compositing
        var layerDesc = new Texture2DDescription
        {
            Width = (uint)_width,
            Height = (uint)_height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.R16G16B16A16_Float,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.RenderTarget | BindFlags.ShaderResource
        };
        _layerTex0 = _device.CreateTexture2D(layerDesc);
        _layerRTV0 = _device.CreateRenderTargetView(_layerTex0);
        _layerSRV0 = _device.CreateShaderResourceView(_layerTex0);

        _layerTex1 = _device.CreateTexture2D(layerDesc);
        _layerRTV1 = _device.CreateRenderTargetView(_layerTex1);
        _layerSRV1 = _device.CreateShaderResourceView(_layerTex1);

        // Layer 2 — FX/bloom input layer
        _layerTex2 = _device.CreateTexture2D(layerDesc);
        _layerRTV2 = _device.CreateRenderTargetView(_layerTex2);
        _layerSRV2 = _device.CreateShaderResourceView(_layerTex2);

        // Bloom render targets — half and quarter res
        var bloomHalfDesc = new Texture2DDescription
        {
            Width = (uint)(_width / 2),
            Height = (uint)(_height / 2),
            MipLevels = 1, ArraySize = 1,
            Format = Format.R16G16B16A16_Float,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.RenderTarget | BindFlags.ShaderResource
        };
        _bloomTexHalf = _device.CreateTexture2D(bloomHalfDesc);
        _bloomRTVHalf = _device.CreateRenderTargetView(_bloomTexHalf);
        _bloomSRVHalf = _device.CreateShaderResourceView(_bloomTexHalf);

        var bloomQuarterDesc = bloomHalfDesc;
        bloomQuarterDesc.Width = (uint)(_width / 4);
        bloomQuarterDesc.Height = (uint)(_height / 4);
        _bloomTexQuarter = _device.CreateTexture2D(bloomQuarterDesc);
        _bloomRTVQuarter = _device.CreateRenderTargetView(_bloomTexQuarter);
        _bloomSRVQuarter = _device.CreateShaderResourceView(_bloomTexQuarter);

        // ── Compute shader particle buffers ──
        // Particle struct: 3x float4 = 48 bytes (pos.xyz+size, vel.xyz+energy, data.life+maxLife+hue+bandIdx)
        int particleStride = 48;
        var particleBufDesc = new BufferDescription
        {
            ByteWidth = (uint)(MAX_PARTICLES * particleStride),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.UnorderedAccess | BindFlags.ShaderResource,
            MiscFlags = ResourceOptionFlags.BufferStructured,
            StructureByteStride = (uint)particleStride
        };
        _particleBufferA = _device.CreateBuffer(particleBufDesc);
        _particleBufferB = _device.CreateBuffer(particleBufDesc);

        // Zero-initialize particle buffer A (life=0 triggers respawn in CS on first dispatch)
        var zeroData = new byte[MAX_PARTICLES * particleStride];
        _context.UpdateSubresource(zeroData, _particleBufferA, 0);

        var uavDesc = new UnorderedAccessViewDescription
        {
            Format = Vortice.DXGI.Format.Unknown,
            ViewDimension = UnorderedAccessViewDimension.Buffer,
            Buffer = { FirstElement = 0, NumElements = MAX_PARTICLES, Flags = BufferUnorderedAccessViewFlags.None }
        };
        _particleUAV_A = _device.CreateUnorderedAccessView(_particleBufferA, uavDesc);
        _particleUAV_B = _device.CreateUnorderedAccessView(_particleBufferB, uavDesc);

        var srvDesc = new ShaderResourceViewDescription
        {
            Format = Vortice.DXGI.Format.Unknown,
            ViewDimension = ShaderResourceViewDimension.Buffer,
            Buffer = { FirstElement = 0, NumElements = MAX_PARTICLES }
        };
        _particleSRV_A = _device.CreateShaderResourceView(_particleBufferA, srvDesc);
        _particleSRV_B = _device.CreateShaderResourceView(_particleBufferB, srvDesc);

        // Alive count buffer (atomic counter)
        var aliveDesc = new BufferDescription
        {
            ByteWidth = 16,
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.UnorderedAccess,
            MiscFlags = ResourceOptionFlags.BufferAllowRawViews
        };
        _aliveCountBuffer = _device.CreateBuffer(aliveDesc);
        var aliveUavDesc = new UnorderedAccessViewDescription
        {
            Format = Vortice.DXGI.Format.R32_Typeless,
            ViewDimension = UnorderedAccessViewDimension.Buffer,
            Buffer = { FirstElement = 0, NumElements = 4, Flags = BufferUnorderedAccessViewFlags.Raw }
        };
        _aliveCountUAV = _device.CreateUnorderedAccessView(_aliveCountBuffer, aliveUavDesc);

        // Particle constant buffer
        _particleCB = _device.CreateBuffer(16, BindFlags.ConstantBuffer, ResourceUsage.Dynamic, CpuAccessFlags.Write);

        // ── 3D mesh pipeline: generate UV sphere ──
        GenerateSphere(64, 32);

        // Mesh constant buffer (3x float4x4 + float4 MeshParams = 208 bytes)
        _meshCB = _device.CreateBuffer(208, BindFlags.ConstantBuffer, ResourceUsage.Dynamic, CpuAccessFlags.Write);

        // 3D depth stencil state — depth testing ON for mesh rendering
        _depthState3D = _device.CreateDepthStencilState(new DepthStencilDescription
        {
            DepthEnable = true,
            DepthWriteMask = DepthWriteMask.All,
            DepthFunc = ComparisonFunction.Less,
            StencilEnable = false
        });

        _depthState = _device.CreateDepthStencilState(new DepthStencilDescription
        {
            DepthEnable = false,
            DepthWriteMask = DepthWriteMask.Zero
        });

        _rasterizer = _device.CreateRasterizerState(new RasterizerDescription
        {
            FillMode = FillMode.Solid,
            CullMode = CullMode.None
        });

        LoadShaders();

        DebugLogger.Info($"[DX11Renderer] Initialized: {_width}x{_height}, {_modeNames.Count} modes, FL={featureLevel}");
    }

    // Generate a UV sphere mesh with position, normal, uv (8 floats per vertex = 32 bytes)
    private void GenerateSphere(int segments, int rings)
    {
        int vertexCount = (segments + 1) * (rings + 1);
        int indexCount = segments * rings * 6;

        var vertices = new float[vertexCount * 8];
        var indices = new uint[indexCount];

        int vi = 0;
        for (int ring = 0; ring <= rings; ring++)
        {
            float phi = (float)Math.PI * ring / rings;  // 0..PI (top to bottom)
            float y = (float)Math.Cos(phi);
            float ringRadius = (float)Math.Sin(phi);

            for (int seg = 0; seg <= segments; seg++)
            {
                float theta = 2.0f * (float)Math.PI * seg / segments;  // 0..2PI
                float x = ringRadius * (float)Math.Cos(theta);
                float z = ringRadius * (float)Math.Sin(theta);

                // Position
                vertices[vi++] = x;
                vertices[vi++] = y;
                vertices[vi++] = z;
                // Normal (same as position for unit sphere)
                vertices[vi++] = x;
                vertices[vi++] = y;
                vertices[vi++] = z;
                // UV
                vertices[vi++] = (float)seg / segments;
                vertices[vi++] = (float)ring / rings;
            }
        }

        int ii = 0;
        for (int ring = 0; ring < rings; ring++)
        {
            for (int seg = 0; seg < segments; seg++)
            {
                uint a = (uint)(ring * (segments + 1) + seg);
                uint b = (uint)(ring * (segments + 1) + seg + 1);
                uint c = (uint)((ring + 1) * (segments + 1) + seg);
                uint d = (uint)((ring + 1) * (segments + 1) + seg + 1);

                indices[ii++] = a; indices[ii++] = c; indices[ii++] = b;
                indices[ii++] = b; indices[ii++] = c; indices[ii++] = d;
            }
        }

        _sphereIndexCount = indexCount;

        var vbDesc = new BufferDescription
        {
            ByteWidth = (uint)(vertices.Length * 4),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.VertexBuffer
        };
        var vbData = GCHandle.Alloc(vertices, GCHandleType.Pinned);
        try {
            _sphereVB = _device.CreateBuffer(vbDesc, new SubresourceData(vbData.AddrOfPinnedObject()));
        } finally { vbData.Free(); }

        var ibDesc = new BufferDescription
        {
            ByteWidth = (uint)(indices.Length * 4),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.IndexBuffer
        };
        var ibData = GCHandle.Alloc(indices, GCHandleType.Pinned);
        try {
            _sphereIB = _device.CreateBuffer(ibDesc, new SubresourceData(ibData.AddrOfPinnedObject()));
        } finally { ibData.Free(); }

        DebugLogger.Info($"[DX11Renderer] Sphere mesh: {vertexCount} verts, {indexCount} indices");
    }

    private void LoadShaders()
    {
        // Try multiple candidate locations
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
            if (Directory.Exists(p))
            {
                shaderDir = p;
                break;
            }
        }

        if (string.IsNullOrEmpty(shaderDir))
        {
            DebugLogger.Error($"[DX11Renderer] Shader directory not found! Tried: {string.Join(", ", searchPaths)}");
            return;
        }

        DebugLogger.Info($"[DX11Renderer] Shader dir: {shaderDir}");

        string[] modes = {
            "quantum_bars",       // 0. Quantum Bars
            "spectrum_3d",        // 1. Spectrum 3D (keep)
            "plasma_field",      // 2. Plasma Field
            "neon_pulse",        // 3. Neon Pulse
            "particle_flow",     // 4. Particle Flow
            "waveform",          // 5. Waveform
            "sphere",            // 6. Sphere
            "aurora",            // 7. Aurora Borealis
            "dna_helix",         // 8. DNA Helix
            "heartbeat",         // 9. Heartbeat
            "rtx_mesh",          // 10. RTX Mesh
            "ray_marched",       // 11. Ray Marched
            "volumetric_clouds", // 12. Volumetric Clouds
            "fractal_dimensions",// 13. Fractal Dimensions
            "neural_network",    // 14. Neural Network
            "quantum_field",     // 15. Quantum Field
            "holographic",       // 16. Holographic
            "particle_storm",    // 17. Particle Storm
            "wave_tessellation", // 18. Wave Pool + Tessellation (keep)
            "audio_tessellation",// 19. Audio Tessellation
            "compute_shaders",   // 20. Compute Shaders
            "rtx_reflections",   // 21. RTX Reflections
        };

        foreach (var mode in modes)
        {
            string hlslFile = Path.Combine(shaderDir, $"dx_{mode}.hlsl");
            if (!File.Exists(hlslFile))
            {
                DebugLogger.Warn($"[DX11Renderer] Shader not found: {hlslFile}");
                continue;
            }

            try
            {
                string source = File.ReadAllText(hlslFile);
                DebugLogger.Info($"[DX11Renderer] Compiling {mode} ({source.Length} bytes)...");
                var bytecode = Compiler.Compile(source, "main", $"dx_{mode}.hlsl", "ps_5_0");
                var ps = _device.CreatePixelShader(bytecode.Span);
                _pixelShaders[mode] = ps;
                _modeNames.Add(mode);
                DebugLogger.Info($"[DX11Renderer] Loaded: {mode}");

                // Try loading background pass shader (dx_mode_bg.hlsl)
                string bgFile = Path.Combine(shaderDir, $"dx_{mode}_bg.hlsl");
                if (File.Exists(bgFile))
                {
                    try
                    {
                        string bgSource = File.ReadAllText(bgFile);
                        var bgBytecode = Compiler.Compile(bgSource, "main", $"dx_{mode}_bg.hlsl", "ps_5_0");
                        _bgShaders[mode] = _device.CreatePixelShader(bgBytecode.Span);
                        DebugLogger.Info($"[DX11Renderer] Loaded BG pass: {mode}_bg");
                    }
                    catch (Exception e) { DebugLogger.Warn($"[DX11Renderer] BG shader failed for {mode}: {e.Message}"); }
                }

                // Try loading FX pass shader (dx_mode_fx.hlsl)
                string fxFile = Path.Combine(shaderDir, $"dx_{mode}_fx.hlsl");
                if (File.Exists(fxFile))
                {
                    try
                    {
                        string fxSource = File.ReadAllText(fxFile);
                        var fxBytecode = Compiler.Compile(fxSource, "main", $"dx_{mode}_fx.hlsl", "ps_5_0");
                        _fxShaders[mode] = _device.CreatePixelShader(fxBytecode.Span);
                        DebugLogger.Info($"[DX11Renderer] Loaded FX pass: {mode}_fx");
                    }
                    catch (Exception e) { DebugLogger.Warn($"[DX11Renderer] FX shader failed for {mode}: {e.Message}"); }
                }
            }
            catch (Exception e)
            {
                string errMsg = $"[DX11Renderer] Failed to load {mode}: {e.Message}";
                DebugLogger.Error(errMsg);
                File.AppendAllText(Path.Combine(DebugLogger.LogDirectory, "shader_errors.log"), errMsg + "\n" + e.StackTrace + "\n");
            }
        }

        // Load overlay + composite + HUD shaders for multi-layer rendering
        TryLoadShader(shaderDir, "dx_overlay", out _overlayPS);
        TryLoadShader(shaderDir, "dx_composite", out _compositePS);
        TryLoadShader(shaderDir, "dx_hud", out _hudPS);
        TryLoadShader(shaderDir, "dx_particle_render", out _particleRenderPS);

        // Load bloom post-FX shaders
        TryLoadShader(shaderDir, "dx_bloom_bright", out _bloomBrightPS);
        TryLoadShader(shaderDir, "dx_bloom_blur_h", out _bloomBlurHPS);
        TryLoadShader(shaderDir, "dx_bloom_blur_v", out _bloomBlurVPS);
        TryLoadShader(shaderDir, "dx_bloom_combine", out _bloomCombinePS);

        // Load compute shader for GPU particle simulation
        string csFile = Path.Combine(shaderDir, "cs_particle_sim.hlsl");
        if (File.Exists(csFile))
        {
            try
            {
                string csSource = File.ReadAllText(csFile);
                var csBytecode = Compiler.Compile(csSource, "CSMain", "cs_particle_sim.hlsl", "cs_5_0");
                _particleCS = _device.CreateComputeShader(csBytecode.Span);
                _useComputeParticles = true;
                DebugLogger.Info("[DX11Renderer] Compute shader loaded: cs_particle_sim");
            }
            catch (Exception e)
            {
                DebugLogger.Warn($"[DX11Renderer] Compute shader failed (non-fatal): {e.Message}");
                _useComputeParticles = false;
            }
        }

        // Load 3D mesh shaders (vertex + pixel) for volumetric mode
        string vsMeshFile = Path.Combine(shaderDir, "vs_mesh.hlsl");
        if (File.Exists(vsMeshFile))
        {
            try
            {
                string vsSource = File.ReadAllText(vsMeshFile);
                var vsBytecode = Compiler.Compile(vsSource, "main", "vs_mesh.hlsl", "vs_5_0");
                _meshVS = _device.CreateVertexShader(vsBytecode.Span);

                var meshInputElements = new[]
                {
                    new InputElementDescription("POSITION", 0, Format.R32G32B32_Float, 0, 0),
                    new InputElementDescription("NORMAL", 0, Format.R32G32B32_Float, 12, 0),
                    new InputElementDescription("TEXCOORD", 0, Format.R32G32_Float, 24, 0)
                };
                _meshLayout = _device.CreateInputLayout(meshInputElements, vsBytecode.Span);
                DebugLogger.Info("[DX11Renderer] Mesh vertex shader loaded: vs_mesh");
            }
            catch (Exception e)
            {
                DebugLogger.Warn($"[DX11Renderer] Mesh VS failed: {e.Message}");
            }
        }

        TryLoadShader(shaderDir, "dx_volumetric_mesh", out _meshPS);
        if (_meshPS != null)
            DebugLogger.Info("[DX11Renderer] Mesh pixel shader loaded: dx_volumetric_mesh");

        // Load particle vortex compute shader
        string vortexCSFile = Path.Combine(shaderDir, "cs_particle_vortex.hlsl");
        if (File.Exists(vortexCSFile))
        {
            try
            {
                string csSource = File.ReadAllText(vortexCSFile);
                var csBytecode = Compiler.Compile(csSource, "CSMain", "cs_particle_vortex.hlsl", "cs_5_0");
                _vortexCS = _device.CreateComputeShader(csBytecode.Span);
                DebugLogger.Info("[DX11Renderer] Vortex compute shader loaded: cs_particle_vortex");
            }
            catch (Exception e)
            {
                DebugLogger.Warn($"[DX11Renderer] Vortex CS failed: {e.Message}");
            }
        }

        // Load particle vortex vertex shader (no input layout — uses SV_VertexID)
        string pvsFile = Path.Combine(shaderDir, "vs_particle_vortex.hlsl");
        if (File.Exists(pvsFile))
        {
            try
            {
                string vsSource = File.ReadAllText(pvsFile);
                var vsBytecode = Compiler.Compile(vsSource, "main", "vs_particle_vortex.hlsl", "vs_5_0");
                _particleVS = _device.CreateVertexShader(vsBytecode.Span);
                DebugLogger.Info("[DX11Renderer] Particle VS loaded: vs_particle_vortex");
            }
            catch (Exception e)
            {
                DebugLogger.Warn($"[DX11Renderer] Particle VS failed: {e.Message}");
            }
        }

        TryLoadShader(shaderDir, "dx_particle_vortex", out _particlePS);
        if (_particlePS != null)
            DebugLogger.Info("[DX11Renderer] Particle PS loaded: dx_particle_vortex");

        // Load particle geometry shader (expands points to quads)
        string pgsFile = Path.Combine(shaderDir, "gs_particle_vortex.hlsl");
        if (File.Exists(pgsFile))
        {
            try
            {
                string gsSource = File.ReadAllText(pgsFile);
                var gsBytecode = Compiler.Compile(gsSource, "main", "gs_particle_vortex.hlsl", "gs_5_0");
                _particleGS = _device.CreateGeometryShader(gsBytecode.Span);
                DebugLogger.Info("[DX11Renderer] Particle GS loaded: gs_particle_vortex");
            }
            catch (Exception e)
            {
                DebugLogger.Warn($"[DX11Renderer] Particle GS failed: {e.Message}");
            }
        }

        // Create brain HUD if HUD shader loaded
        if (_hudPS != null)
        {
            _hud = new BrainHUD(_device, _context, _width, _height);
            DebugLogger.Info("[DX11Renderer] Brain HUD initialized");
        }

        DebugLogger.Info($"[DX11Renderer] Total modes loaded: {_modeNames.Count}, overlay={(_overlayPS != null)}, composite={(_compositePS != null)}, hud={(_hudPS != null)}");
    }

    // ── Compute shader dispatch — GPU particle simulation ──
    private void DispatchComputeParticles(float dt)
    {
        if (!_useComputeParticles || _particleCS == null) return;

        _particleFrame++;
        uint seed = (uint)(_particleFrame * 19937 + 314159);

        // Update particle CB via Map/Unmap
        var cbBox = _context.Map(_particleCB, 0, MapMode.WriteDiscard);
        Marshal.Copy(new float[] { MAX_PARTICLES, dt, (float)seed, 0f }, 0, cbBox.DataPointer, 4);
        _context.Unmap(_particleCB, 0);

        // Bind compute shader
        _context.CSSetShader(_particleCS);
        _context.CSSetConstantBuffers(0, new[] { _audioCB, _timeCB, _particleCB });
        _context.CSSetShaderResources(0, new[] { _spectrumSRV });
        _context.CSSetSampler(0, _sampler);

        // Ping-pong: read from A, write to B
        _context.CSSetUnorderedAccessViews(0, new[] { _particleUAV_A, _aliveCountUAV }, new uint[] { unchecked((uint)-1), unchecked((uint)-1) });

        // Dispatch: 65536 particles / 64 threads = 1024 groups
        _context.Dispatch(1024, 1, 1);

        // Unbind UAVs
        _context.CSSetUnorderedAccessViews(0, new ID3D11UnorderedAccessView[] { null, null }, new uint[] { unchecked((uint)-1), unchecked((uint)-1) });
        _context.CSSetShaderResources(0, new ID3D11ShaderResourceView[] { null });
        _context.CSSetShader(null);

        // No swap — compute shader does in-place update on u0, so UAV_A/SRV_A always has latest data
    }

    // ── Vortex compute shader dispatch ──
    private void DispatchVortexParticles(float dt)
    {
        if (_vortexCS == null) return;

        _particleFrame++;
        uint seed = (uint)(_particleFrame * 19937 + 314159);

        var cbBox = _context.Map(_particleCB, 0, MapMode.WriteDiscard);
        Marshal.Copy(new float[] { MAX_PARTICLES, dt, (float)seed, 0f }, 0, cbBox.DataPointer, 4);
        _context.Unmap(_particleCB, 0);

        _context.CSSetShader(_vortexCS);
        _context.CSSetConstantBuffers(0, new[] { _audioCB, _timeCB, _particleCB });
        _context.CSSetShaderResources(0, new[] { _spectrumSRV });
        _context.CSSetSampler(0, _sampler);
        _context.CSSetUnorderedAccessViews(0, new[] { _particleUAV_A, _aliveCountUAV }, new uint[] { unchecked((uint)-1), unchecked((uint)-1) });

        _context.Dispatch(1024, 1, 1);

        _context.CSSetUnorderedAccessViews(0, new ID3D11UnorderedAccessView[] { null, null }, new uint[] { unchecked((uint)-1), unchecked((uint)-1) });
        _context.CSSetShaderResources(0, new ID3D11ShaderResourceView[] { null });
        _context.CSSetShader(null);
    }

    // ── Bloom post-FX chain: bright pass → blur H → blur V → combine ──
    private void RenderBloomPass()
    {
        if (_bloomBrightPS == null || _bloomBlurHPS == null || _bloomBlurVPS == null || _bloomCombinePS == null)
            return;

        // Pass 1: Bright pass — extract bright pixels from layer0 into half-res bloom target
        _context.RSSetViewport(0, 0, _width / 2, _height / 2);
        _context.ClearRenderTargetView(_bloomRTVHalf, new Color4(0, 0, 0, 1));
        _context.OMSetRenderTargets(_bloomRTVHalf, null);
        _context.OMSetBlendState(_blendState);
        _context.PSSetShaderResource(0, _layerSRV0);
        _context.PSSetShader(_bloomBrightPS);
        _context.Draw(4, 0);

        // Pass 2: Horizontal blur — half-res → quarter-res
        _context.RSSetViewport(0, 0, _width / 4, _height / 4);
        _context.ClearRenderTargetView(_bloomRTVQuarter, new Color4(0, 0, 0, 1));
        _context.OMSetRenderTargets(_bloomRTVQuarter, null);
        _context.PSSetShaderResource(0, _bloomSRVHalf);
        _context.PSSetShader(_bloomBlurHPS);
        _context.Draw(4, 0);

        // Pass 3: Vertical blur — quarter-res → half-res (back)
        _context.RSSetViewport(0, 0, _width / 2, _height / 2);
        _context.ClearRenderTargetView(_bloomRTVHalf, new Color4(0, 0, 0, 1));
        _context.OMSetRenderTargets(_bloomRTVHalf, null);
        _context.PSSetShaderResource(0, _bloomSRVQuarter);
        _context.PSSetShader(_bloomBlurVPS);
        _context.Draw(4, 0);

        // Restore full-res viewport
        _context.RSSetViewport(0, 0, _width, _height);

        // Unbind SRVs
        _context.PSSetShaderResource(0, null);
    }

    private void TryLoadShader(string dir, string name, out ID3D11PixelShader ps)
    {
        ps = null;
        string path = Path.Combine(dir, $"{name}.hlsl");
        if (!File.Exists(path))
        {
            DebugLogger.Warn($"[DX11Renderer] Optional shader not found: {name}");
            return;
        }
        try
        {
            string source = File.ReadAllText(path);
            var bytecode = Compiler.Compile(source, "main", $"{name}.hlsl", "ps_5_0");
            ps = _device.CreatePixelShader(bytecode.Span);
            DebugLogger.Info($"[DX11Renderer] Loaded: {name}");
        }
        catch (Exception e)
        {
            DebugLogger.Error($"[DX11Renderer] Failed to load {name}: {e.Message}");
        }
    }

    public string CurrentMode => _modeNames.Count > 0 ? _modeNames[_currentMode] : "";
    public int ModeCount => _modeNames.Count;
    public int CurrentModeIndex => _currentMode;

    public string GetModeName(int index)
    {
        if (index < 0 || index >= _modeNames.Count) return "";
        return _modeNames[index];
    }

    public void NextMode()
    {
        _currentMode = (_currentMode + 1) % _modeNames.Count;
        DebugLogger.Info($"[DX11Renderer] Mode: {CurrentMode}");
    }

    public void PrevMode()
    {
        _currentMode = (_currentMode - 1 + _modeNames.Count) % _modeNames.Count;
        DebugLogger.Info($"[DX11Renderer] Mode: {CurrentMode}");
    }

    public void SetMode(string name)
    {
        int idx = _modeNames.IndexOf(name);
        if (idx >= 0)
        {
            _currentMode = idx;
            DebugLogger.Info($"[DX11Renderer] Mode: {CurrentMode}");
        }
    }

    public void ResetGPU()
    {
        // DX11 doesn't need GPU reset - no-op
        _currentMode = 0;
    }

    public void UpdateAudioData(ref AudioUBO ubo, float[] spectrum, float[]? leftSpectrum = null, float[]? rightSpectrum = null)
    {
        _lastUBO = ubo;
        // Map audio CB
        var box = _context.Map(_audioCB, 0, MapMode.WriteDiscard);
        Marshal.StructureToPtr(ubo, box.DataPointer, false);
        _context.Unmap(_audioCB, 0);

        // Map time CB
        var timeBox = _context.Map(_timeCB, 0, MapMode.WriteDiscard);
        var timeCB = new TimeCB { GlobalTime = _time, DeltaTime = 0.016f, RenderResolution = new Vector2(_width, _height) };
        Marshal.StructureToPtr(timeCB, timeBox.DataPointer, false);
        _context.Unmap(_timeCB, 0);

        // Map spectrum texture (2 rows: row 0 = L, row 1 = R)
        var specBox = _context.Map(_spectrumTexture, 0, MapMode.WriteDiscard);
        int copyLen = Math.Min(spectrum.Length, 1024);
        // Row 0: L spectrum (or mono if no L/R)
        if (leftSpectrum != null)
            Marshal.Copy(leftSpectrum, 0, specBox.DataPointer, Math.Min(leftSpectrum.Length, 1024));
        else
            Marshal.Copy(spectrum, 0, specBox.DataPointer, copyLen);
        // Row 1: R spectrum (or mono if no L/R)
        if (rightSpectrum != null)
            Marshal.Copy(rightSpectrum, 0, specBox.DataPointer + 1024 * 4, Math.Min(rightSpectrum.Length, 1024));
        else
            Marshal.Copy(spectrum, 0, specBox.DataPointer + 1024 * 4, copyLen);
        _context.Unmap(_spectrumTexture, 0);
    }

    private int _frameCount = 0;
    private static readonly System.Diagnostics.Stopwatch _renderTimer = System.Diagnostics.Stopwatch.StartNew();
    private long _renderStartTicks;
    public float RenderLatencyMs { get; private set; }

    // Update mesh constant buffer with camera matrices + audio displacement params
    private void UpdateMeshCB()
    {
        // Orbit camera
        float camAngle = _time * 0.15f;
        float camDist = 3.5f;
        Vector3 camPos = new((float)(Math.Sin(camAngle) * camDist), 0.5f, (float)(Math.Cos(camAngle) * camDist));
        Vector3 camTarget = new(0, 0, 0);
        Vector3 camUp = new(0, 1, 0);

        // View matrix
        var view = Matrix4x4.CreateLookAt(camPos, camTarget, camUp);
        // Projection matrix
        float fov = (float)(Math.PI / 4.0);
        float aspect = (float)_width / _height;
        var proj = Matrix4x4.CreatePerspectiveFieldOfView(fov, aspect, 0.1f, 100.0f);
        // Model matrix (identity — sphere is already at origin)
        var model = Matrix4x4.Identity;

        // Audio params for displacement
        float bass = (_lastUBO.Bass + _lastUBO.LMid) * 0.5f;
        float mid = (_lastUBO.Mid + _lastUBO.HMid) * 0.5f;
        float treble = (_lastUBO.Pres + _lastUBO.Air) * 0.5f;
        float beat = _lastUBO.Beat;

        // Pack into 208 bytes: 3x float4x4 (192) + float4 MeshParams (16)
        var cbData = new float[48];
        // View (row-major -> column-major transpose)
        cbData[0] = view.M11; cbData[1] = view.M21; cbData[2] = view.M31; cbData[3] = view.M41;
        cbData[4] = view.M12; cbData[5] = view.M22; cbData[6] = view.M32; cbData[7] = view.M42;
        cbData[8] = view.M13; cbData[9] = view.M23; cbData[10] = view.M33; cbData[11] = view.M43;
        cbData[12] = view.M14; cbData[13] = view.M24; cbData[14] = view.M34; cbData[15] = view.M44;
        // Proj
        cbData[16] = proj.M11; cbData[17] = proj.M21; cbData[18] = proj.M31; cbData[19] = proj.M41;
        cbData[20] = proj.M12; cbData[21] = proj.M22; cbData[22] = proj.M32; cbData[23] = proj.M42;
        cbData[24] = proj.M13; cbData[25] = proj.M23; cbData[26] = proj.M33; cbData[27] = proj.M43;
        cbData[28] = proj.M14; cbData[29] = proj.M24; cbData[30] = proj.M34; cbData[31] = proj.M44;
        // Model
        cbData[32] = model.M11; cbData[33] = model.M21; cbData[34] = model.M31; cbData[35] = model.M41;
        cbData[36] = model.M12; cbData[37] = model.M22; cbData[38] = model.M32; cbData[39] = model.M42;
        cbData[40] = model.M13; cbData[41] = model.M23; cbData[42] = model.M33; cbData[43] = model.M43;
        cbData[44] = model.M14; cbData[45] = model.M24; cbData[46] = model.M34; cbData[47] = model.M44;

        // Append MeshParams to the float array
        var fullData = new float[52];
        Array.Copy(cbData, fullData, 48);
        fullData[48] = bass;
        fullData[49] = mid;
        fullData[50] = treble;
        fullData[51] = beat;

        var box = _context.Map(_meshCB, 0, MapMode.WriteDiscard);
        Marshal.Copy(fullData, 0, box.DataPointer, 52);
        _context.Unmap(_meshCB, 0);
    }

    public void Render(float time)
    {
        _renderStartTicks = _renderTimer.ElapsedTicks;
        _time = time;
        _frameCount++;

        if (_frameCount % 120 == 0)
            DebugLogger.Info($"[DX11Renderer] Frame {_frameCount}, mode={CurrentMode}, modes={_modeNames.Count}");

        // Common setup
        _context.RSSetViewport(0, 0, _width, _height);
        _context.RSSetState(_rasterizer);
        _context.OMSetDepthStencilState(_depthState, 0);
        _context.VSSetShader(_vs);
        _context.IASetInputLayout(_inputLayout);
        _context.IASetVertexBuffer(0, _quadVB, (uint)(sizeof(float) * 5));
        _context.IASetPrimitiveTopology(PrimitiveTopology.TriangleStrip);
        _context.VSSetConstantBuffers(0, new[] { _audioCB, _timeCB });
        _context.PSSetConstantBuffers(0, new[] { _audioCB, _timeCB });
        _context.PSSetSampler(0, _sampler);

        // ── Compute pass: GPU particle simulation (before rendering) ──
        string preModeName = _modeNames.Count > 0 ? _modeNames[_currentMode] : "";
        if (preModeName == "particle_vortex" && _vortexCS != null)
            DispatchVortexParticles(0.016f);
        else if (preModeName != "volumetric")
            DispatchComputeParticles(0.016f);

        string currentModeName = _modeNames.Count > 0 ? _modeNames[_currentMode] : "";
        ID3D11PixelShader? bgPS = null;
        ID3D11PixelShader? fxPS = null;
        bool hasBg = currentModeName != "" && _bgShaders.TryGetValue(currentModeName, out bgPS);
        bool hasFx = currentModeName != "" && _fxShaders.TryGetValue(currentModeName, out fxPS);

        // ── Pass 1: Background layer → layerTex2 (atmosphere, depth, environment) ──
        _context.ClearRenderTargetView(_layerRTV2, new Color4(0f, 0f, 0f, 1f));
        if (hasBg && bgPS != null)
        {
            _context.OMSetRenderTargets(_layerRTV2, null);
            _context.OMSetBlendState(_blendState);
            _context.PSSetShaderResource(0, _spectrumSRV);
            _context.PSSetShader(bgPS);
            _context.Draw(4, 0);
        }

        // ── Pass 2: Main layer → layerTex0 (primary visual content) ──
        _context.ClearRenderTargetView(_layerRTV0, new Color4(0f, 0f, 0f, 1f));

        _context.OMSetRenderTargets(_layerRTV0, null);
        _context.OMSetBlendState(_blendState);
        _context.PSSetShaderResource(0, _spectrumSRV);
        if (hasBg && _layerSRV2 != null)
            _context.PSSetShaderResource(1, _layerSRV2);
        if (_useComputeParticles && _particleSRV_A != null)
            _context.PSSetShaderResource(2, _particleSRV_A);

        ID3D11PixelShader? basePS = null;
        if (_modeNames.Count > 0 && _pixelShaders.TryGetValue(currentModeName, out basePS))
        {
            _context.PSSetShader(basePS);
            _context.Draw(4, 0);
        }

        // Unbind SRVs from main pass
        _context.PSSetShaderResource(1, null);
        _context.PSSetShaderResource(2, null);

        // ── Bloom post-FX chain: bright pass → blur H → blur V ──
        RenderBloomPass();

        // ── Pass 3: FX layer → layerTex1 (particles, effects, overlays specific to mode) ──
        _context.ClearRenderTargetView(_layerRTV1, new Color4(0f, 0f, 0f, 1f));
        if (hasFx && fxPS != null)
        {
            _context.OMSetRenderTargets(_layerRTV1, null);
            _context.OMSetBlendState(_additiveBlendState);
            _context.PSSetShaderResource(0, _spectrumSRV);
            // Feed main layer as t1 so FX can react to what's already rendered
            _context.PSSetShaderResource(1, _layerSRV0);
            // Bind compute particle buffer as t2
            if (_useComputeParticles && _particleSRV_A != null)
                _context.PSSetShaderResource(2, _particleSRV_A);
            _context.PSSetShader(fxPS);
            _context.Draw(4, 0);
            _context.PSSetShaderResource(1, null);
            _context.PSSetShaderResource(2, null);
        }
        else if (_overlayPS != null)
        {
            // Fall back to global overlay shader for modes without custom FX
            // (skipped for liquid_metal — overlay haze/bloom causes white-out)
            _context.OMSetRenderTargets(_layerRTV1, null);
            _context.OMSetBlendState(_blendState);
            _context.PSSetShaderResource(0, _spectrumSRV);
            _context.PSSetShader(_overlayPS);
            _context.Draw(4, 0);
        }

        // ── Pass 4: Composite — BG + main + FX + bloom → backbuffer ──
        _context.ClearRenderTargetView(_rtv, new Color4(0f, 0f, 0f, 1f));
        _context.OMSetRenderTargets(_rtv, null);
        _context.OMSetBlendState(_blendState);

        // Bind all layer textures + bloom as SRVs
        _context.PSSetShaderResource(0, _layerSRV0);   // main
        _context.PSSetShaderResource(1, _layerSRV1);   // FX/overlay
        if (hasBg && _layerSRV2 != null)
            _context.PSSetShaderResource(2, _layerSRV2);  // background
        else
            _context.PSSetShaderResource(2, null);  // no BG — unbind to avoid stale data
        if (_bloomSRVHalf != null)
            _context.PSSetShaderResource(3, _bloomSRVHalf);  // bloom

        if (_compositePS != null)
        {
            _context.PSSetShader(_compositePS);
        }
        _context.Draw(4, 0);

        // Unbind all SRVs before HUD
        _context.PSSetShaderResource(0, null);
        _context.PSSetShaderResource(1, null);
        _context.PSSetShaderResource(2, null);
        _context.PSSetShaderResource(3, null);

        // ── HUD overlay (brain state text) ──
        if (_hud != null && _hudPS != null)
        {
            _hud.Render(_vs, _inputLayout, _hudPS, _audioCB, _timeCB, _lastFrame, 0.016f);
        }

        _swapChain.Present(1, PresentFlags.None);
        RenderLatencyMs = (float)(_renderTimer.ElapsedTicks - _renderStartTicks) / System.Diagnostics.Stopwatch.Frequency * 1000f;
    }

    private QuadBufferedVisuals.VisualFrame _lastFrame;

    /// <summary>
    /// Update the HUD with the latest visual frame data.
    /// Called by AudioBridge before Render.
    /// </summary>
    public void UpdateHUD(QuadBufferedVisuals.VisualFrame frame)
    {
        _lastFrame = frame;
    }

    public void ToggleHUD()
    {
        if (_hud != null)
            _hud.Visible = !_hud.Visible;
    }

    public void ToggleSkiaOverlay()
    {
        // SkiaSharp overlay is DX12-only — no-op for DX11
    }

    /// <summary>
    /// Render with an additional shared texture layer from DX12 co-processor.
    /// The sharedSRV is sampled as a third composite layer (t2).
    /// </summary>
    public void RenderWithSharedLayer(float time, ID3D11ShaderResourceView? sharedSRV, bool dx12Active)
    {
        _renderStartTicks = _renderTimer.ElapsedTicks;
        _time = time;
        _frameCount++;

        if (_frameCount % 120 == 0)
            DebugLogger.Info($"[DX11Renderer] Frame {_frameCount}, mode={CurrentMode}, modes={_modeNames.Count}, dx12layer={(dx12Active ? "ON" : "OFF")}");

        _context.RSSetViewport(0, 0, _width, _height);
        _context.RSSetState(_rasterizer);
        _context.OMSetDepthStencilState(_depthState, 0);
        _context.VSSetShader(_vs);
        _context.IASetInputLayout(_inputLayout);
        _context.IASetVertexBuffer(0, _quadVB, (uint)(sizeof(float) * 5));
        _context.IASetPrimitiveTopology(PrimitiveTopology.TriangleStrip);
        _context.VSSetConstantBuffers(0, new[] { _audioCB, _timeCB });
        _context.PSSetConstantBuffers(0, new[] { _audioCB, _timeCB });
        _context.PSSetSampler(0, _sampler);

        // ── Layer 0: Base shader → intermediate texture ──
        _context.ClearRenderTargetView(_layerRTV0, new Color4(0f, 0f, 0f, 1f));
        _context.OMSetRenderTargets(_layerRTV0, null);
        _context.OMSetBlendState(_blendState);
        _context.PSSetShaderResource(0, _spectrumSRV);

        ID3D11PixelShader? basePS = null;
        if (_modeNames.Count > 0 && _pixelShaders.TryGetValue(_modeNames[_currentMode], out basePS))
        {
            _context.PSSetShader(basePS);
            _context.Draw(4, 0);
        }

        // ── Layer 1: Overlay (beams, particles) → intermediate texture ──
        _context.ClearRenderTargetView(_layerRTV1, new Color4(0f, 0f, 0f, 1f));
        if (_overlayPS != null)
        {
            _context.OMSetRenderTargets(_layerRTV1, null);
            _context.OMSetBlendState(_blendState);
            _context.PSSetShaderResource(0, _spectrumSRV);
            _context.PSSetShader(_overlayPS);
            _context.Draw(4, 0);
        }

        // ── Composite: base + overlay + DX12 shared layer → backbuffer ──
        _context.ClearRenderTargetView(_rtv, new Color4(0f, 0f, 0f, 1f));
        _context.OMSetRenderTargets(_rtv, null);
        _context.OMSetBlendState(_blendState);

        _context.PSSetShaderResource(0, _layerSRV0);
        _context.PSSetShaderResource(1, _layerSRV1);
        _context.PSSetShaderResource(2, sharedSRV);  // DX12 compute/3D output

        if (_compositePS != null)
        {
            _context.PSSetShader(_compositePS);
        }
        _context.Draw(4, 0);

        // Unbind SRVs before HUD
        _context.PSSetShaderResource(0, null);
        _context.PSSetShaderResource(1, null);
        _context.PSSetShaderResource(2, null);

        // ── HUD overlay ──
        if (_hud != null && _hudPS != null)
        {
            _hud.Render(_vs, _inputLayout, _hudPS, _audioCB, _timeCB, _lastFrame, 0.016f);
        }

        _swapChain.Present(1, PresentFlags.None);
        RenderLatencyMs = (float)(_renderTimer.ElapsedTicks - _renderStartTicks) / System.Diagnostics.Stopwatch.Frequency * 1000f;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        _sampler?.Dispose();
        _blendState?.Dispose();
        _additiveBlendState?.Dispose();
        _depthState?.Dispose();
        _rasterizer?.Dispose();
        _spectrumSRV?.Dispose();
        _spectrumTexture?.Dispose();
        _layerSRV0?.Dispose();
        _layerRTV0?.Dispose();
        _layerTex0?.Dispose();
        _layerSRV1?.Dispose();
        _layerRTV1?.Dispose();
        _layerTex1?.Dispose();
        _layerSRV2?.Dispose();
        _layerRTV2?.Dispose();
        _layerTex2?.Dispose();
        _bloomSRVHalf?.Dispose();
        _bloomRTVHalf?.Dispose();
        _bloomTexHalf?.Dispose();
        _bloomSRVQuarter?.Dispose();
        _bloomRTVQuarter?.Dispose();
        _bloomTexQuarter?.Dispose();
        _bloomBrightPS?.Dispose();
        _bloomBlurHPS?.Dispose();
        _bloomBlurVPS?.Dispose();
        _bloomCombinePS?.Dispose();
        _particleCS?.Dispose();
        _particleUAV_A?.Dispose();
        _particleUAV_B?.Dispose();
        _particleSRV_A?.Dispose();
        _particleSRV_B?.Dispose();
        _particleBufferA?.Dispose();
        _particleBufferB?.Dispose();
        _aliveCountUAV?.Dispose();
        _aliveCountBuffer?.Dispose();
        _particleCB?.Dispose();
        _overlayPS?.Dispose();
        _compositePS?.Dispose();
        _hudPS?.Dispose();
        _hud?.Dispose();
        _timeCB?.Dispose();
        _audioCB?.Dispose();
        _inputLayout?.Dispose();
        _vs?.Dispose();
        _quadVB?.Dispose();
        foreach (var ps in _pixelShaders.Values) ps.Dispose();
        _dsv?.Dispose();
        _depthStencil?.Dispose();
        _rtv?.Dispose();
        _swapChain?.Dispose();
        _context?.Dispose();
        _device?.Dispose();
    }
}
