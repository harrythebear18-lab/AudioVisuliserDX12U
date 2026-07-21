using System;
using System.Numerics;
using System.Runtime.InteropServices;
using StageSimWASAPI;

namespace DXRenderer;

/// <summary>
/// Abstraction layer for rendering backends (D3D11, D3D12 work graphs, etc.).
/// Both DX11Renderer and DX12Renderer implement this so Program.cs / AudioBridge
/// can swap backends without touching call sites.
/// </summary>
public interface IRenderer : IDisposable
{
    /// <summary>Human-readable backend name, e.g. "D3D11" or "D3D12 (Work Graphs)".</summary>
    string BackendName { get; }

    /// <summary>Currently active visual mode name.</summary>
    string CurrentMode { get; }

    /// <summary>Total number of loaded visual modes.</summary>
    int ModeCount { get; }

    /// <summary>Last frame render latency in milliseconds.</summary>
    float RenderLatencyMs { get; }

    /// <summary>True if the backend supports work graphs (DX12 Ultimate).</summary>
    bool SupportsWorkGraphs { get; }

    /// <summary>Advance to the next visual mode.</summary>
    void NextMode();

    /// <summary>Go to the previous visual mode.</summary>
    void PrevMode();

    /// <summary>Jump directly to a named mode, if it exists.</summary>
    void SetMode(string name);

    /// <summary>Get the name of a mode by index.</summary>
    string GetModeName(int index);

    /// <summary>Index of the current mode.</summary>
    int CurrentModeIndex { get; }

    /// <summary>Check if GPU should be reset (e.g., after prolonged silence).</summary>
    bool ShouldResetGPU { get; }

    /// <summary>Reset GPU state (called after prolonged silence).</summary>
    void ResetGPU();

    /// <summary>Toggle the brain HUD overlay on/off.</summary>
    void ToggleHUD();

    /// <summary>Toggle the SkiaSharp 2D overlay (particles/glow/meters) on/off.</summary>
    void ToggleSkiaOverlay();

    /// <summary>Update the audio constant buffer + spectrum texture from CPU data.</summary>
    /// <param name="ubo">The audio UBO struct — same layout for all backends.</param>
    /// <param name="spectrum">Up to 1024 float spectrum bins.</param>
    void UpdateAudioData(ref AudioUBO ubo, float[] spectrum, float[]? leftSpectrum = null, float[]? rightSpectrum = null);

    /// <summary>Push the latest visual frame for HUD display.</summary>
    void UpdateHUD(QuadBufferedVisuals.VisualFrame frame);

    /// <summary>Render one frame at the given absolute time.</summary>
    void Render(float time);
}

/// <summary>
/// Shared UBO layout — matches AudioBrainCB in HLSL shaders.
/// Finalized Hardware Telemetry Mirror layout.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public struct AudioUBO
{
    // BrainDynamics (16 bytes)
    public float Beat;
    public float Trans;
    public float Env;
    public float Overall;
    // FrequencySpectrum (32 bytes)
    public float Sub;
    public float Bass;
    public float LMid;
    public float Mid;
    public float HMid;
    public float Pres;
    public float Bril;
    public float Air;
    // SpatialTelemetry (24 bytes + 8 padding = 32 bytes, HLSL pads struct to 16-byte boundary)
    public Vector2 StereoLR;
    public float Balance;
    public float Width;
    public float Phase;
    public float Anticip;
    public float _pad0;
    public float _pad1;
    // PerformanceRhythm (16 bytes)
    public float BPM;
    public float Conf;
    public float KickWeight;
    public float MoveSpeed;
    // Shader Control Multipliers (80 bytes)
    public Vector4 ColorPrimary;    // xyz = RGB, w = hueBase
    public Vector4 ColorSecondary;  // xyz = RGB2, w = hueCenter
    public Vector4 ColorTertiary;   // xyz = RGB3 (blender), w = hueRange
    public Vector4 VisualModifiers;
    public Vector4 SystemState;
}

/// <summary>
/// Shared time constant buffer — matches TimeCB in HLSL shaders.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public struct TimeCB
{
    public float GlobalTime;
    public float DeltaTime;
    public Vector2 RenderResolution;
}
