using System;
using System.Numerics;
using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;
using StageSimWASAPI;
using static Vortice.Direct3D11.D3D11;

namespace DXRenderer;

/// <summary>
/// Unified renderer that drives both DX11 and DX12 together.
/// DX12 renders compute/3D/heavy effects into a shared DXGI texture.
/// DX11 composites that with its own 2D shader passes and presents to the window.
/// Both consume the same AudioUBO from the VisualSmoother.
/// </summary>
public class UnifiedRenderer : IRenderer, IDisposable
{
    private DX11Renderer _dx11;
    private DX12Renderer? _dx12;
    private bool _dx12Available;

    // Shared texture: DX12 writes, DX11 reads (GPU handles sync via resource barriers)
    private ID3D11Texture2D? _sharedTex;
    private ID3D11ShaderResourceView? _sharedSRV;

    private int _width;
    private int _height;
    private bool _disposed;

    public string BackendName => "Unified (DX11+DX12)";
    public bool SupportsWorkGraphs => _dx12?.SupportsWorkGraphs ?? false;
    public bool ShouldResetGPU => _dx12?.ShouldResetGPU ?? false;
    public string CurrentMode => _dx11.CurrentMode;
    public int ModeCount => _dx11.ModeCount;
    public int CurrentModeIndex => _dx11.CurrentModeIndex;
    public float RenderLatencyMs { get; private set; }

    public string GetModeName(int index) => _dx11.GetModeName(index);

    private static readonly System.Diagnostics.Stopwatch _renderTimer = System.Diagnostics.Stopwatch.StartNew();
    private long _renderStartTicks;

    /// <summary>
    /// Create the unified renderer. DX11 always initializes as the presentation target.
    /// DX12 initializes as a compute/3D worker if the hardware supports it.
    /// </summary>
    public UnifiedRenderer(IntPtr hwnd, int width, int height)
    {
        _width = width;
        _height = height;

        // DX11 is always the presenter — it owns the swap chain and window
        _dx11 = new DX11Renderer(hwnd, width, height);

        // Try to create DX12 as a co-processing renderer
        try
        {
            _dx12 = new DX12Renderer(IntPtr.Zero, width, height, headless: true);
            _dx12Available = true;
            DebugLogger.Info("[UnifiedRenderer] DX12 co-processor initialized");
            SetupSharedTexture();
        }
        catch (Exception ex)
        {
            DebugLogger.Warn($"[UnifiedRenderer] DX12 unavailable, running DX11-only: {ex.Message}");
            _dx12Available = false;
        }

        DebugLogger.Info($"[UnifiedRenderer] Ready — DX11 presenter + {(_dx12Available ? "DX12 co-processor" : "no DX12")}");
    }

    /// <summary>
    /// Create a shared DXGI texture that both DX11 and DX12 can access.
    /// DX12 renders into it, DX11 samples it during compositing.
    /// GPU handles synchronization via resource barriers.
    /// </summary>
    private void SetupSharedTexture()
    {
        if (!_dx12Available) return;

        // Create shared texture on DX11 device with DX12-compatible settings
        var texDesc = new Texture2DDescription
        {
            Width = (uint)_width,
            Height = (uint)_height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm, // DX12 prefers BGRA
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.ShaderResource | BindFlags.RenderTarget,
            MiscFlags = ResourceOptionFlags.Shared, // Use Shared instead of SharedNTHandle for DX12 compatibility
        };

        _sharedTex = _dx11.Device.CreateTexture2D(texDesc);
        _sharedSRV = _dx11.Device.CreateShaderResourceView(_sharedTex);

        // Get the shared handle via IDXGIResource1
        using var dxgiResource = _sharedTex.QueryInterface<IDXGIResource1>();
        IntPtr sharedHandle = dxgiResource.CreateSharedHandle(null, Vortice.DXGI.SharedResourceFlags.Read | Vortice.DXGI.SharedResourceFlags.Write, null);

        // On DX12 side, open the shared resource
        _dx12.OpenSharedTexture(sharedHandle);

        DebugLogger.Info("[UnifiedRenderer] Shared texture ready (GPU handles sync)");
    }

    public void UpdateAudioData(ref AudioUBO ubo, float[] spectrum, float[]? leftSpectrum = null, float[]? rightSpectrum = null)
    {
        // Both renderers get the same UBO + spectrum
        _dx11.UpdateAudioData(ref ubo, spectrum, leftSpectrum, rightSpectrum);
        if (_dx12Available && _dx12 != null)
        {
            _dx12.UpdateAudioData(ref ubo, spectrum);
        }
    }

    public void UpdateHUD(QuadBufferedVisuals.VisualFrame frame)
    {
        _dx11.UpdateHUD(frame);
        if (_dx12Available && _dx12 != null)
        {
            _dx12.UpdateHUD(frame);
        }
    }

    public void Render(float time)
    {
        _renderStartTicks = _renderTimer.ElapsedTicks;

        // Phase 1: DX12 renders into shared texture
        if (_dx12Available && _dx12 != null && _sharedTex != null)
        {
            try
            {
                _dx12.RenderToSharedTexture(time);
            }
            catch (Exception ex)
            {
                DebugLogger.Warn($"[UnifiedRenderer] DX12 render failed: {ex.Message}");
            }
        }

        // Phase 2: DX11 composites base + overlay + DX12 layer → present
        try
        {
            _dx11.RenderWithSharedLayer(time, _sharedSRV, _dx12Available);
        }
        catch (Exception ex)
        {
            DebugLogger.Error($"[UnifiedRenderer] DX11 composite failed: {ex.Message}");
        }

        RenderLatencyMs = (float)(_renderTimer.ElapsedTicks - _renderStartTicks) / System.Diagnostics.Stopwatch.Frequency * 1000f;
    }

    public void NextMode()
    {
        _dx11.NextMode();
        if (_dx12Available && _dx12 != null) _dx12.SetMode(_dx11.CurrentMode);
    }
    public void PrevMode()
    {
        _dx11.PrevMode();
        if (_dx12Available && _dx12 != null) _dx12.SetMode(_dx11.CurrentMode);
    }
    public void SetMode(string name)
    {
        _dx11.SetMode(name);
        if (_dx12Available && _dx12 != null) _dx12.SetMode(name);
    }
    public void ToggleHUD() => _dx11.ToggleHUD();
    public void ToggleSkiaOverlay() => _dx12?.ToggleSkiaOverlay();
    public void ResetGPU()
    {
        _dx12?.ResetGPU();
        _dx11.ResetGPU();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        _sharedSRV?.Dispose();
        _sharedTex?.Dispose();
        _dx12?.Dispose();
        _dx11?.Dispose();
    }
}
