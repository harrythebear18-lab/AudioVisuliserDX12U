using System;
using StageSimWASAPI;

namespace DXRenderer;

/// <summary>
/// Abstraction for a single graphics API backend (DX11, DX12, OpenGL, Vulkan).
/// Each backend renders its layer(s) into a shared texture.
/// The UnifiedCompositor (DX11 presenter) blends all backend outputs.
/// </summary>
public interface IGraphicsBackend : IDisposable
{
    /// <summary>API name: "D3D11", "D3D12", "OpenGL", "Vulkan"</summary>
    string ApiName { get; }

    /// <summary>True if this backend is initialized and ready to render.</summary>
    bool IsAvailable { get; }

    /// <summary>True if this backend supports compute shaders / work graphs.</summary>
    bool SupportsCompute { get; }

    /// <summary>Update audio data (UBO + spectrum) on this backend.</summary>
    void UpdateAudioData(ref AudioUBO ubo, float[] spectrum);

    /// <summary>Update HUD frame data on this backend.</summary>
    void UpdateHUD(QuadBufferedVisuals.VisualFrame frame);

    /// <summary>
    /// Render one frame into the shared texture.
    /// The backend must acquire the keyed mutex, render, then release it.
    /// </summary>
    void RenderToSharedTexture(float time);

    /// <summary>
    /// Open a shared DXGI texture created by the compositor.
    /// The backend stores the handle for rendering.
    /// </summary>
    void OpenSharedTexture(IntPtr sharedHandle, out object? keyedMutex);
}
