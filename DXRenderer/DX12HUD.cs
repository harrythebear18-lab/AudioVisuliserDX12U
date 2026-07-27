using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D12;
using Vortice.DXGI;
using Vortice.Mathematics;
using StageSimWASAPI;
using Color = System.Drawing.Color;

namespace DXRenderer;

/// <summary>
/// Brain HUD for D3D12 — renders brain/analyzer state as text overlay.
/// Uses System.Drawing to render text to a bitmap, uploads to a D3D12 texture,
/// then draws with an alpha-blend PSO on top of the scene.
/// </summary>
public class DX12HUD : IDisposable
{
    private readonly ID3D12Device10 _device;
    private int _width;
    private int _height;

    private ID3D12Resource _hudUpload = null!;
    private ID3D12Resource _hudTexture = null!;
    private ID3D12DescriptorHeap _srvHeap = null!;
    private ID3D12PipelineState _hudPSO = null!;
    private ID3D12RootSignature _hudRootSig = null!;
    private ID3D12Resource _hudVertexBuffer = null!;
    private IntPtr _uploadPtr;

    private Bitmap _bitmap;
    private Graphics _gfx;
    private Font _font;

    private bool _visible = true;
    private float _updateTimer = 0f;
    private string[] _cachedLines = Array.Empty<string>();
    private Color[] _cachedColors = Array.Empty<Color>();
    private int _texHeight = 512;

    public string CurrentModeName { get; set; } = "";
    public int CurrentModeIndex { get; set; } = 0;
    public int TotalModes { get; set; } = 0;
    public bool VSyncEnabled { get; set; } = true;
    public float FPS { get; set; } = 0f;
    public bool VRMode { get; set; } = false;

    private static readonly string[] SectionNames = {
        "Unknown", "Intro", "Verse", "PreChorus", "Chorus",
        "BuildUp", "Drop", "Breakdown", "Bridge", "Interlude", "Outro"
    };

    private const int HUD_WIDTH = 480;
    private const int LINE_HEIGHT = 18;
    private const int PADDING = 8;

    public bool Visible
    {
        get => _visible;
        set => _visible = value;
    }

    public DX12HUD(ID3D12Device10 device, int width, int height, ReadOnlySpan<byte> vsBytecode)
    {
        _device = device;
        _width = width;
        _height = height;

        _bitmap = new Bitmap(HUD_WIDTH, _texHeight, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        _gfx = Graphics.FromImage(_bitmap);
        _gfx.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        _gfx.SmoothingMode = SmoothingMode.AntiAlias;
        _font = new Font("Consolas", 11f, FontStyle.Regular);

        Console.WriteLine("[DX12HUD] Creating texture...");
        CreateHudTexture();
        Console.WriteLine("[DX12HUD] Creating root signature...");
        CreateRootSignature();
        Console.WriteLine("[DX12HUD] Creating PSO...");
        CreatePSO(vsBytecode);
        Console.WriteLine("[DX12HUD] Done.");
    }

    private void CreateHudTexture()
    {
        // Compute aligned row pitch (D3D12 requires 256-byte alignment)
        uint alignedRowPitch = (uint)((HUD_WIDTH * 4 + 255) & ~255);
        uint uploadSize = alignedRowPitch * (uint)_texHeight;
        _hudUpload = _device.CreateCommittedResource(
            HeapType.Upload,
            ResourceDescription.Buffer(uploadSize),
            ResourceStates.GenericRead);
        unsafe { _uploadPtr = new IntPtr(_hudUpload.Map<byte>(0)); }

        // GPU texture on default heap — B8G8R8A8_UNorm matches System.Drawing BGRA layout
        _hudTexture = _device.CreateCommittedResource(
            HeapType.Default,
            ResourceDescription.Texture2D(Format.B8G8R8A8_UNorm, (uint)HUD_WIDTH, (uint)_texHeight),
            ResourceStates.PixelShaderResource);

        // SRV heap for HUD texture
        var srvDesc = new DescriptorHeapDescription(DescriptorHeapType.ConstantBufferViewShaderResourceViewUnorderedAccessView, 1)
        {
            Flags = DescriptorHeapFlags.ShaderVisible,
        };
        _srvHeap = _device.CreateDescriptorHeap(srvDesc);
        _device.CreateShaderResourceView(_hudTexture, null, _srvHeap.GetCPUDescriptorHandleForHeapStart());

        // Vertex buffer for HUD quad (updated each frame)
        float[] quadVerts = new float[20];
        _hudVertexBuffer = _device.CreateCommittedResource(
            HeapType.Upload,
            ResourceDescription.Buffer((uint)(quadVerts.Length * sizeof(float))),
            ResourceStates.GenericRead);
    }

    private void CreateRootSignature()
    {
        // Root signature: 1 descriptor table (t0 SRV) + 1 static sampler
        var ranges = new DescriptorRange1[]
        {
            new(DescriptorRangeType.ShaderResourceView, 1, 0, 0),
        };

        var rootParams = new RootParameter1[]
        {
            new(new RootDescriptorTable1(ranges), ShaderVisibility.Pixel),
        };

        var staticSamplers = new StaticSamplerDescription[]
        {
            new(0u, Filter.MinMagLinearMipPoint,
                TextureAddressMode.Clamp, TextureAddressMode.Clamp, TextureAddressMode.Clamp,
                shaderVisibility: ShaderVisibility.Pixel),
        };

        var desc = new RootSignatureDescription1(RootSignatureFlags.AllowInputAssemblerInputLayout)
        {
            Parameters = rootParams,
            StaticSamplers = staticSamplers,
        };

        _hudRootSig = _device.CreateRootSignature(desc);
    }

    private void CreatePSO(ReadOnlySpan<byte> vsBytecode)
    {
        // HUD pixel shader: sample BGRA texture, apply alpha blend
        string psSource = """
            Texture2D<float4> hudTex : register(t0);
            SamplerState hudSampler : register(s0);
            struct PSInput {
                float4 pos : SV_POSITION;
                float2 uv : TEXCOORD0;
            };
            float4 main(PSInput input) : SV_TARGET {
                float4 color = hudTex.Sample(hudSampler, input.uv);
                return color;
            }
        """;
        var psBytecode = Vortice.D3DCompiler.Compiler.Compile(psSource, "main", "hud_ps.hlsl", "ps_5_0");

        // Compile HUD's own VS with fxc vs_5_0 (avoids DXC/fxc bytecode mismatch in PSO)
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
        var hudVsBytecode = Vortice.D3DCompiler.Compiler.Compile(vsSource, "main", "hud_vs.hlsl", "vs_5_0");

        // Alpha blend description (non-premultiplied alpha)
        var blendDesc = BlendDescription.NonPremultiplied;

        var psoDesc = new GraphicsPipelineStateDescription
        {
            RootSignature = _hudRootSig,
            VertexShader = hudVsBytecode.Span.ToArray(),
            PixelShader = psBytecode.Span.ToArray(),
            InputLayout = new InputLayoutDescription(new[]
            {
                new InputElementDescription("POSITION", 0, Format.R32G32B32_Float, 0, 0),
                new InputElementDescription("TEXCOORD", 0, Format.R32G32_Float, 12, 0),
            }),
            SampleMask = uint.MaxValue,
            PrimitiveTopologyType = PrimitiveTopologyType.Triangle,
            RasterizerState = RasterizerDescription.CullNone,
            BlendState = blendDesc,
            DepthStencilState = new DepthStencilDescription { DepthEnable = false },
            RenderTargetFormats = [Format.R8G8B8A8_UNorm],
            SampleDescription = SampleDescription.Default,
        };

        try
        {
            _hudPSO = _device.CreateGraphicsPipelineState(psoDesc);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[DX12HUD] PSO creation failed: {ex.Message}");
            Console.WriteLine($"[DX12HUD] VS size: {vsBytecode.Length}, PS size: {psBytecode.Span.Length}");
            Console.WriteLine($"[DX12HUD] RootSig: {_hudRootSig != null}, Blend: {blendDesc.RenderTarget.e0.BlendEnable}");
            throw;
        }
    }

    public void Resize(int width, int height)
    {
        _width = width;
        _height = height;
    }

    private void BuildHudText(QuadBufferedVisuals.VisualFrame f, out string[] lines, out Color[] colors)
    {
        var lineList = new System.Collections.Generic.List<string>();
        var colorList = new System.Collections.Generic.List<Color>();

        string sectionName = f.Section >= 0 && f.Section < SectionNames.Length ? SectionNames[f.Section] : "?";
        bool isSilent = f.IsSilent != 0;
        bool beatDet = f.BeatDetected > 0.5f;
        int domBand = f.DominantBand;

        var green = Color.FromArgb(80, 255, 80);
        var red = Color.FromArgb(255, 80, 80);
        var white = Color.White;
        var yellow = Color.FromArgb(255, 200, 80);
        var cyan = Color.FromArgb(120, 200, 255);
        var dim = Color.FromArgb(120, 120, 120);
        var orange = Color.FromArgb(255, 140, 60);

        lineList.Add($"D3D12 Backend: {(isSilent ? "OFF" : "ON")}");
        colorList.Add(isSilent ? red : green);

        lineList.Add($"Mode [{CurrentModeIndex + 1}/{TotalModes}]: {CurrentModeName}");
        colorList.Add(cyan);

        lineList.Add($"VSync: {(VSyncEnabled ? "ON" : "OFF")}  FPS:{FPS:F0}  VR:{(VRMode ? "ON" : "OFF")}  (Y=VSync V=VR)");
        colorList.Add(VSyncEnabled ? dim : yellow);

        lineList.Add($"AudioPipeline: ACTIVE (split threads)");
        colorList.Add(green);

        lineList.Add("");
        colorList.Add(white);

        lineList.Add($"Beat:{f.BeatIntensity:F3}  Trans:{f.Transient:F3}  Env:{f.Envelope:F3}");
        colorList.Add(white);

        lineList.Add($"Sub:{f.Band0:F3}  Bass:{f.Band1:F3}  LMid:{f.Band2:F3}");
        colorList.Add(white);
        lineList.Add($"Mid:{f.Band3:F3}  HMid:{f.Band4:F3}");
        colorList.Add(white);
        lineList.Add($"Pres:{f.Band5:F3}  Bril:{f.Band6:F3}  Air:{f.Band7:F3}");
        colorList.Add(white);

        lineList.Add($"Overall:{f.Overall:F3}  Silent:{(isSilent ? "Y" : "N")}  Dom:{domBand}  Beat!:{(beatDet ? "Y" : "N")}");
        colorList.Add(white);

        lineList.Add($"BPM:{f.BPM:F1}  Conf:{f.TempoConfidence:F2}  Kick:{f.KickConfidence:F2}");
        colorList.Add(white);

        lineList.Add($"Stereo: L{f.LeftEnergy:F4} R{f.RightEnergy:F4}");
        colorList.Add(cyan);
        lineList.Add($"  Bal:{f.StereoBalance:F2}  W:{f.StereoWidth:F2}  Phase:{f.PhaseCorrelation:F2}");
        colorList.Add(white);

        lineList.Add($"Anticip:{f.BeatAnticipation:F2}  Clarity:{f.SpectralClarity:F2}  Persist:{f.MotionPersistence:F2}");
        colorList.Add(cyan);

        lineList.Add("");
        colorList.Add(dim);

        lineList.Add($"Section:{sectionName}  Phrase:{f.PhraseBeat}/16  Eff:{f.EffectIntensity:F2}");
        colorList.Add(yellow);
        lineList.Add($"Move:{f.MovementIntensity:F2}  Hue:{f.BaseHue:F3}  Pulse:{f.ColorPulse:F2}");
        colorList.Add(cyan);

        lineList.Add($"Color:({f.ColorR:F2},{f.ColorG:F2},{f.ColorB:F2})  C2:({f.Color2R:F2},{f.Color2G:F2},{f.Color2B:F2})");
        colorList.Add(Color.FromArgb(
            (int)(f.ColorR * 255), (int)(f.ColorG * 255), (int)(f.ColorB * 255)));

        lineList.Add($"Bright:{f.Brightness:F2}  Beam:{f.BeamIntensity:F2}  Bloom:{f.BloomIntensity:F2}");
        colorList.Add(white);
        lineList.Add($"DynLight:{f.DynamicLightIntensity:F2}  Ambient:{f.AmbientLightIntensity:F2}");
        colorList.Add(white);

        var triggers = new System.Collections.Generic.List<string>();
        if (f.TriggerEffectBurst > 0.5f)
        {
            string[] burstTypes = { "RADIAL", "SHOCKWAVE", "COLORWAVE", "SPARKLE" };
            string bt = f.EffectBurstType >= 0 && f.EffectBurstType < 4 ? burstTypes[f.EffectBurstType] : "?";
            triggers.Add($"BURST:{bt}({f.EffectBurstIntensity:F1})");
        }
        lineList.Add($"Triggers: {(triggers.Count > 0 ? string.Join(" ", triggers) : "-")}");
        colorList.Add(triggers.Count > 0 ? orange : dim);

        lineList.Add($"Active: Dyn{f.DynamicLightsActive} Beam{f.BeamsActive} Amb{f.AmbientActive} Blm{f.BloomActive}");
        colorList.Add(dim);

        lineList.Add($"Lat Buf:{f.LatBufferDwellMs:F3} DeInt:{f.LatDeinterleaveMs:F3} FFT:{f.LatFFTComputeMs:F3} Tri:{f.LatTripleDwellMs:F3}");
        colorList.Add(dim);
        lineList.Add($"    Brain:{f.LatBrainProcessMs:F3}+{f.LatBrainUpdateMs:F3} Frm:{f.LatFrameBuildMs:F3} Rnd:{f.LatRenderMs:F3}");
        colorList.Add(dim);
        lineList.Add($"    === Total Pipeline: {f.LatTotalPipelineMs:F3}ms ===");
        colorList.Add(f.LatTotalPipelineMs > 20f ? red : f.LatTotalPipelineMs > 10f ? yellow : green);

        // Resonance DSP — professional audio analysis
        lineList.Add("");
        colorList.Add(dim);
        lineList.Add($"── Resonance DSP ──");
        colorList.Add(cyan);
        lineList.Add($"LUFS: M={f.MomentaryLUFS:F1} S={f.ShortTermLUFS:F1} I={f.IntegratedLUFS:F1}");
        colorList.Add(f.IntegratedLUFS > -8f ? red : f.IntegratedLUFS > -14f ? yellow : green);
        lineList.Add($"THD: {f.THDPercentage:F2}%  Phase: {f.PhaseCorrelationDSP:F2}");
        colorList.Add(f.THDPercentage > 5f ? red : f.THDPercentage > 1f ? yellow : white);
        lineList.Add($"Pk L:{f.PeakDbL:F1} R:{f.PeakDbR:F1}dB  Rms L:{f.RmsDbL:F1} R:{f.RmsDbR:F1}dB");
        colorList.Add(white);
        lineList.Add($"Crest L:{f.CrestFactorDbL:F1} R:{f.CrestFactorDbR:F1}dB {(f.CrestFactorDbL < 6f ? "⚠HEADROOM" : "")}");
        colorList.Add(f.CrestFactorDbL < 6f ? red : f.CrestFactorDbL < 10f ? yellow : green);
        lineList.Add($"BQ: {f.DspBand0:F3} {f.DspBand1:F3} {f.DspBand2:F3} {f.DspBand3:F3}");
        colorList.Add(dim);
        lineList.Add($"    {f.DspBand4:F3} {f.DspBand5:F3} {f.DspBand6:F3} {f.DspBand7:F3}");
        colorList.Add(dim);

        lineList.Add("");
        colorList.Add(dim);
        lineList.Add("Keys: H=HUD  P=Overlay  M/N=Mode  B=Director");
        colorList.Add(dim);

        lines = lineList.ToArray();
        colors = colorList.ToArray();
    }

    private void RenderToBitmap(string[] lines, Color[] colors)
    {
        int surfH = lines.Length * LINE_HEIGHT + PADDING * 2;
        if (surfH > _bitmap.Height)
        {
            _bitmap.Dispose();
            _gfx.Dispose();
            _bitmap = new Bitmap(HUD_WIDTH, surfH, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            _gfx = Graphics.FromImage(_bitmap);
            _gfx.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            _gfx.SmoothingMode = SmoothingMode.AntiAlias;
        }

        _gfx.Clear(Color.FromArgb(140, 0, 0, 0));

        int y = PADDING;
        for (int i = 0; i < lines.Length; i++)
        {
            if (string.IsNullOrEmpty(lines[i]))
            {
                y += LINE_HEIGHT;
                continue;
            }
            _gfx.DrawString(lines[i], _font, new SolidBrush(colors[i]), PADDING, y);
            y += LINE_HEIGHT;
        }
    }

    /// <summary>
    /// Upload the bitmap to the D3D12 texture via upload buffer and CopyTextureRegion.
    /// </summary>
    public void UploadTexture(ID3D12GraphicsCommandList6 cmdList)
    {
        // Get footprint first to know the aligned row pitch
        var texDesc = ResourceDescription.Texture2D(Format.B8G8R8A8_UNorm, (uint)HUD_WIDTH, (uint)_texHeight);
        var layouts = new PlacedSubresourceFootPrint[1];
        var numRows = new uint[1];
        var rowSizes = new ulong[1];
        _device.GetCopyableFootprints(texDesc, 0, 1, 0, layouts, numRows, rowSizes, out _);

        uint dstRowPitch = layouts[0].Footprint.RowPitch;
        uint copyWidth = (uint)(HUD_WIDTH * 4);

        // Copy bitmap data to upload buffer using aligned row pitch
        var bmpData = _bitmap.LockBits(
            new Rectangle(0, 0, HUD_WIDTH, _bitmap.Height),
            System.Drawing.Imaging.ImageLockMode.ReadOnly,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);

        try
        {
            int srcStride = bmpData.Stride;
            int texHeight = _bitmap.Height;
            byte[] rowData = new byte[copyWidth];

            for (int row = 0; row < texHeight; row++)
            {
                Marshal.Copy(bmpData.Scan0 + row * srcStride, rowData, 0, (int)copyWidth);
                Marshal.Copy(rowData, 0, _uploadPtr + (int)(row * dstRowPitch), (int)copyWidth);
            }
        }
        finally
        {
            _bitmap.UnlockBits(bmpData);
        }

        // Transition texture: ShaderResource → CopyDest
        cmdList.ResourceBarrierTransition(_hudTexture,
            ResourceStates.PixelShaderResource, ResourceStates.CopyDest);

        // Copy from upload buffer to texture (D3D12 API: CopyTextureRegion(Dst, DstX, DstY, DstZ, Src, SrcBox))
        var dst = new TextureCopyLocation(_hudTexture, 0);
        var src = new TextureCopyLocation(_hudUpload, layouts[0]);
        cmdList.CopyTextureRegion(dst, 0, 0, 0, src, null);

        // Transition back: CopyDest → ShaderResource
        cmdList.ResourceBarrierTransition(_hudTexture,
            ResourceStates.CopyDest, ResourceStates.PixelShaderResource);
    }

    /// <summary>
    /// Render the HUD overlay. Call after scene render, before Present transition.
    /// </summary>
    public void Render(ID3D12GraphicsCommandList6 cmdList, QuadBufferedVisuals.VisualFrame frame, float dt)
    {
        if (!_visible) return;

        // Update text every 50ms
        _updateTimer -= dt;
        if (_updateTimer <= 0 || _cachedLines.Length == 0)
        {
            _updateTimer = 0.05f;
            BuildHudText(frame, out _cachedLines, out _cachedColors);
        }

        RenderToBitmap(_cachedLines, _cachedColors);
        UploadTexture(cmdList);

        // Update vertex buffer for HUD quad
        int texH = _cachedLines.Length * LINE_HEIGHT + PADDING * 2;
        float px = (float)HUD_WIDTH / _width * 2.0f;
        float py = (float)texH / _height * 2.0f;
        float x0 = -1.0f;
        float x1 = -1.0f + px;
        float y0 = 1.0f - py;
        float y1 = 1.0f;

        float[] verts = {
            x0, y0, 0,  0, 1,
            x1, y0, 0,  1, 1,
            x0, y1, 0,  0, 0,
            x1, y1, 0,  1, 0,
        };

        unsafe
        {
            void* ptr;
            _hudVertexBuffer.Map(0, null, &ptr).CheckError();
            Marshal.Copy(verts, 0, new IntPtr(ptr), verts.Length);
            _hudVertexBuffer.Unmap(0);
        }

        // Set HUD pipeline state
        cmdList.SetPipelineState(_hudPSO);
        cmdList.SetGraphicsRootSignature(_hudRootSig);
        cmdList.SetDescriptorHeaps(new[] { _srvHeap });

        cmdList.SetGraphicsRootDescriptorTable(0, _srvHeap.GetGPUDescriptorHandleForHeapStart());

        cmdList.IASetVertexBuffers(0, new VertexBufferView
        {
            BufferLocation = _hudVertexBuffer.GPUVirtualAddress,
            SizeInBytes = (uint)(verts.Length * sizeof(float)),
            StrideInBytes = 5 * sizeof(float),
        });
        cmdList.IASetPrimitiveTopology(Vortice.Direct3D.PrimitiveTopology.TriangleStrip);

        cmdList.DrawInstanced(4, 1, 0, 0);
    }

    public void Dispose()
    {
        _font?.Dispose();
        _gfx?.Dispose();
        _bitmap?.Dispose();
        _hudUpload?.Dispose();
        _hudTexture?.Dispose();
        _srvHeap?.Dispose();
        _hudPSO?.Dispose();
        _hudRootSig?.Dispose();
        _hudVertexBuffer?.Dispose();
    }
}
