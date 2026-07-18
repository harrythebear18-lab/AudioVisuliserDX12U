using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using StageSimWASAPI;

namespace DXRenderer;

/// <summary>
/// Brain HUD — renders brain/analyzer state as text overlay on top of the D3D11 scene.
/// Uses System.Drawing to render text to a texture, then blits with alpha blending.
/// Ported from render/brain_hud.py.
/// </summary>
public class BrainHUD : IDisposable
{
    private readonly ID3D11Device1 _device;
    private readonly ID3D11DeviceContext1 _context;
    private int _width;
    private int _height;

    private ID3D11Texture2D _hudTexture;
    private ID3D11ShaderResourceView _hudSRV;
    private ID3D11SamplerState _sampler;
    private ID3D11BlendState _blendState;
    private ID3D11Buffer _quadVB;

    private Bitmap _bitmap;
    private Graphics _gfx;
    private Font _font;
    private Font _fontSmall;

    private bool _visible = true;
    private float _updateTimer = 0f;
    private string[] _cachedLines = Array.Empty<string>();
    private Color[] _cachedColors = Array.Empty<Color>();
    private int _texHeight = 256;

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

    public BrainHUD(ID3D11Device1 device, ID3D11DeviceContext1 context, int width, int height)
    {
        _device = device;
        _context = context;
        _width = width;
        _height = height;

        // GDI+ text rendering
        _bitmap = new Bitmap(HUD_WIDTH, 256, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        _gfx = Graphics.FromImage(_bitmap);
        _gfx.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        _gfx.SmoothingMode = SmoothingMode.AntiAlias;
        _font = new Font("Consolas", 11f, FontStyle.Regular);
        _fontSmall = new Font("Consolas", 10f, FontStyle.Regular);

        // D3D11 texture for HUD (resized dynamically as needed)
        CreateHudTexture(256);

        _sampler = _device.CreateSamplerState(new SamplerDescription
        {
            Filter = Filter.MinMagLinearMipPoint,
            AddressU = TextureAddressMode.Clamp,
            AddressV = TextureAddressMode.Clamp,
            AddressW = TextureAddressMode.Clamp
        });

        // Alpha blend state for HUD overlay
        var blendDesc = new BlendDescription();
        blendDesc.RenderTarget[0] = new RenderTargetBlendDescription
        {
            BlendEnable = true,
            SourceBlend = Vortice.Direct3D11.Blend.SourceAlpha,
            DestinationBlend = Vortice.Direct3D11.Blend.InverseSourceAlpha,
            BlendOperation = Vortice.Direct3D11.BlendOperation.Add,
            SourceBlendAlpha = Vortice.Direct3D11.Blend.One,
            DestinationBlendAlpha = Vortice.Direct3D11.Blend.InverseSourceAlpha,
            BlendOperationAlpha = Vortice.Direct3D11.BlendOperation.Add,
            RenderTargetWriteMask = ColorWriteEnable.All
        };
        _blendState = _device.CreateBlendState(blendDesc);

        // Quad for HUD (top-left corner) — position in NDC + UV
        // Will be rebuilt each frame based on texture height
        float[] quadVerts = new float[20]; // 4 verts * 5 floats (pos.xy, uv.xy)
        _quadVB = _device.CreateBuffer(quadVerts, BindFlags.VertexBuffer, ResourceUsage.Dynamic, CpuAccessFlags.Write);
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

        // Status
        lineList.Add($"WASAPI Loopback: {(isSilent ? "OFF" : "ON")}");
        colorList.Add(isSilent ? red : green);

        lineList.Add($"AudioPipeline: ACTIVE (split threads)");
        colorList.Add(green);

        lineList.Add("");
        colorList.Add(white);

        // Dynamics
        lineList.Add($"Beat:{f.BeatIntensity:F3}  Trans:{f.Transient:F3}  Env:{f.Envelope:F3}");
        colorList.Add(white);

        // Bands
        lineList.Add($"Sub:{f.Band0:F3}  Bass:{f.Band1:F3}  LMid:{f.Band2:F3}");
        colorList.Add(white);
        lineList.Add($"Mid:{f.Band3:F3}  HMid:{f.Band4:F3}");
        colorList.Add(white);
        lineList.Add($"Pres:{f.Band5:F3}  Bril:{f.Band6:F3}  Air:{f.Band7:F3}");
        colorList.Add(white);

        // Overall
        lineList.Add($"Overall:{f.Overall:F3}  Silent:{(isSilent ? "Y" : "N")}  Dom:{domBand}  Beat!:{(beatDet ? "Y" : "N")}");
        colorList.Add(white);

        // Rhythm
        lineList.Add($"BPM:{f.BPM:F1}  Conf:{f.TempoConfidence:F2}  Kick:{f.KickConfidence:F2}");
        colorList.Add(white);

        // Stereo
        lineList.Add($"Stereo: L{f.LeftEnergy:F4} R{f.RightEnergy:F4}");
        colorList.Add(cyan);
        lineList.Add($"  Bal:{f.StereoBalance:F2}  W:{f.StereoWidth:F2}  Phase:{f.PhaseCorrelation:F2}");
        colorList.Add(white);

        // Advanced analysis
        lineList.Add($"Anticip:{f.BeatAnticipation:F2}  Clarity:{f.SpectralClarity:F2}  Persist:{f.MotionPersistence:F2}");
        colorList.Add(cyan);

        lineList.Add("");
        colorList.Add(dim);

        // Section + phrase
        lineList.Add($"Section:{sectionName}  Phrase:{f.PhraseBeat}/16  Eff:{f.EffectIntensity:F2}");
        colorList.Add(yellow);
        lineList.Add($"Move:{f.MovementIntensity:F2}  Hue:{f.BaseHue:F3}  Pulse:{f.ColorPulse:F2}");
        colorList.Add(cyan);

        // Colors
        lineList.Add($"Color:({f.ColorR:F2},{f.ColorG:F2},{f.ColorB:F2})  C2:({f.Color2R:F2},{f.Color2G:F2},{f.Color2B:F2})");
        colorList.Add(Color.FromArgb(
            (int)(f.ColorR * 255), (int)(f.ColorG * 255), (int)(f.ColorB * 255)));

        // Visualizer intensities
        lineList.Add($"Bright:{f.Brightness:F2}  Beam:{f.BeamIntensity:F2}  Bloom:{f.BloomIntensity:F2}");
        colorList.Add(white);
        lineList.Add($"DynLight:{f.DynamicLightIntensity:F2}  Ambient:{f.AmbientLightIntensity:F2}");
        colorList.Add(white);

        // Triggers — visualizer-native
        var triggers = new System.Collections.Generic.List<string>();
        if (f.TriggerEffectBurst > 0.5f)
        {
            string[] burstTypes = { "RADIAL", "SHOCKWAVE", "COLORWAVE", "SPARKLE" };
            string bt = f.EffectBurstType >= 0 && f.EffectBurstType < 4 ? burstTypes[f.EffectBurstType] : "?";
            triggers.Add($"BURST:{bt}({f.EffectBurstIntensity:F1})");
        }
        lineList.Add($"Triggers: {(triggers.Count > 0 ? string.Join(" ", triggers) : "-")}");
        colorList.Add(triggers.Count > 0 ? orange : dim);

        // Active flags
        lineList.Add($"Active: Dyn{f.DynamicLightsActive} Beam{f.BeamsActive} Amb{f.AmbientActive} Blm{f.BloomActive}");
        colorList.Add(dim);

        // Pipeline latency — fine-grained per-substage
        lineList.Add($"Lat Buf:{f.LatBufferDwellMs:F3} DeInt:{f.LatDeinterleaveMs:F3} FFT:{f.LatFFTComputeMs:F3} Tri:{f.LatTripleDwellMs:F3}");
        colorList.Add(dim);
        lineList.Add($"    Brain:{f.LatBrainProcessMs:F3}+{f.LatBrainUpdateMs:F3} Frm:{f.LatFrameBuildMs:F3} Rnd:{f.LatRenderMs:F3}");
        colorList.Add(dim);
        lineList.Add($"    === Total Pipeline: {f.LatTotalPipelineMs:F3}ms ===");
        colorList.Add(f.LatTotalPipelineMs > 20f ? red : f.LatTotalPipelineMs > 10f ? yellow : green);

        lines = lineList.ToArray();
        colors = colorList.ToArray();
    }

    private void RenderToTexture(string[] lines, Color[] colors)
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
            // Recreate D3D texture if needed
            if (surfH > _texHeight)
            {
                _hudSRV?.Dispose();
                _hudTexture?.Dispose();
                _texHeight = surfH;
                CreateHudTexture(_texHeight);
            }
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

        // Upload to D3D11 texture
        var box = _context.Map(_hudTexture, 0, MapMode.WriteDiscard);
        try
        {
            var bmpData = _bitmap.LockBits(
                new Rectangle(0, 0, HUD_WIDTH, _bitmap.Height),
                System.Drawing.Imaging.ImageLockMode.ReadOnly,
                System.Drawing.Imaging.PixelFormat.Format32bppArgb);

            try
            {
                int srcStride = bmpData.Stride;
                int dstStride = (int)box.RowPitch;
                int copyWidth = Math.Min(srcStride, HUD_WIDTH * 4);
                int texHeight = _bitmap.Height;

                byte[] rowData = new byte[copyWidth];
                for (int row = 0; row < texHeight; row++)
                {
                    Marshal.Copy(bmpData.Scan0 + row * srcStride, rowData, 0, copyWidth);
                    Marshal.Copy(rowData, 0, box.DataPointer + row * dstStride, copyWidth);
                }
            }
            finally
            {
                _bitmap.UnlockBits(bmpData);
            }
        }
        finally
        {
            _context.Unmap(_hudTexture, 0);
        }
    }

    private void CreateHudTexture(int height)
    {
        var texDesc = new Texture2DDescription
        {
            Width = HUD_WIDTH,
            Height = (uint)height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Dynamic,
            BindFlags = BindFlags.ShaderResource,
            CPUAccessFlags = CpuAccessFlags.Write
        };
        _hudTexture = _device.CreateTexture2D(texDesc);
        _hudSRV = _device.CreateShaderResourceView(_hudTexture);
    }

    private void UpdateQuad(int texH)
    {
        // NDC coordinates for top-left placement
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

        var box = _context.Map(_quadVB, 0, MapMode.WriteDiscard);
        Marshal.Copy(verts, 0, box.DataPointer, verts.Length);
        _context.Unmap(_quadVB, 0);
    }

    /// <summary>
    /// Render the HUD overlay. Call after composite pass, before Present.
    /// Uses the renderer's vertex shader + a simple text blit pixel shader.
    /// </summary>
    public void Render(ID3D11VertexShader vs, ID3D11InputLayout inputLayout,
                       ID3D11PixelShader textPS, ID3D11Buffer audioCB, ID3D11Buffer timeCB,
                       QuadBufferedVisuals.VisualFrame frame, float dt)
    {
        if (!_visible) return;

        // Update text every 50ms
        _updateTimer -= dt;
        if (_updateTimer <= 0 || _cachedLines.Length == 0)
        {
            _updateTimer = 0.05f;
            BuildHudText(frame, out _cachedLines, out _cachedColors);
        }

        int texH = _cachedLines.Length * LINE_HEIGHT + PADDING * 2;
        RenderToTexture(_cachedLines, _cachedColors);
        UpdateQuad(texH);

        // Set up render state for HUD blit
        _context.OMSetBlendState(_blendState);
        _context.VSSetShader(vs);
        _context.IASetInputLayout(inputLayout);
        _context.IASetVertexBuffer(0, _quadVB, (uint)(sizeof(float) * 5));
        _context.IASetPrimitiveTopology(PrimitiveTopology.TriangleStrip);
        _context.VSSetConstantBuffers(0, new[] { audioCB, timeCB });
        _context.PSSetConstantBuffers(0, new[] { audioCB, timeCB });
        _context.PSSetShader(textPS);
        _context.PSSetShaderResource(0, _hudSRV);
        _context.PSSetSampler(0, _sampler);

        _context.Draw(4, 0);

        // Unbind
        _context.PSSetShaderResource(0, null);
    }

    public void Dispose()
    {
        _font?.Dispose();
        _fontSmall?.Dispose();
        _gfx?.Dispose();
        _bitmap?.Dispose();
        _hudSRV?.Dispose();
        _hudTexture?.Dispose();
        _sampler?.Dispose();
        _blendState?.Dispose();
        _quadVB?.Dispose();
    }
}
