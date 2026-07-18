using System;
using System.Collections.Generic;
using System.Numerics;

namespace DXRenderer;

/// <summary>
/// Resource handle used by the render graph.
/// Backends translate these into actual textures/buffers.
/// </summary>
public enum RenderGraphResource
{
    Backbuffer,
    SceneColor,
    SceneDepth,
    ParticleColor,
    BeamColor,
    Bloom0,
    Bloom1,
    Composite,
    Overlay,
}

/// <summary>
/// Blend mode between graph passes.
/// </summary>
public enum BlendMode
{
    Replace,
    Add,
    Screen,
    Multiply,
    Lerp,
}

/// <summary>
/// One render-graph node. Concrete backends supply the execution logic
/// by matching the node type; this class just describes the pass.
/// </summary>
public abstract class RenderPassNode
{
    public string Name { get; set; } = "";
    public RenderGraphResource? ColorTarget { get; set; }
    public RenderGraphResource? DepthTarget { get; set; }
    public List<RenderGraphResource> Inputs { get; } = new();
    public BlendMode Blend { get; set; } = BlendMode.Replace;
    public float BlendWeight { get; set; } = 1.0f;
}

/// <summary>
/// Fullscreen pixel-shader pass (the existing dx_*.hlsl modes).
/// </summary>
public class FullscreenPassNode : RenderPassNode
{
    public string ShaderName { get; set; } = "test";
}

/// <summary>
/// Compute-driven particle simulation + render pass.
/// Simulates N particles in a vortex force field, then renders them
/// as additive streaks/beams into the color target.
/// </summary>
public class ParticlePassNode : RenderPassNode
{
    public int ParticleCount { get; set; } = 65536;
    public float VortexStrength { get; set; } = 1.0f;
    public float ParticleSize { get; set; } = 1.0f;
    public float Turbulence { get; set; } = 0.5f;
}

/// <summary>
/// Additive volumetric beam/laser pass.
/// Renders audio-reactive light beams that react to stereo width and kick.
/// </summary>
public class BeamPassNode : RenderPassNode
{
    public int BeamCount { get; set; } = 32;
    public float BeamThickness { get; set; } = 0.02f;
    public float PulseSpeed { get; set; } = 1.0f;
}

/// <summary>
/// Post-process pass: bloom, tone mapping, vignette, etc.
/// </summary>
public class PostProcessPassNode : RenderPassNode
{
    public string Kernel { get; set; } = "bloom"; // bloom, dof, tonemap
}

/// <summary>
/// A render graph: an ordered list of passes plus shared resource description.
/// The VisualDirectorBot composes this each frame; backends execute it.
/// </summary>
public class RenderGraph
{
    public List<RenderPassNode> Passes { get; } = new();

    /// <summary>
    /// Performance parameters fed into AudioUBO/TimeCB to modulate visuals.
    /// </summary>
    public float Intensity { get; set; } = 1.0f;
    public float Pulse { get; set; } = 0.0f;
    public float Accent { get; set; } = 0.0f;
    public float ColorShift { get; set; } = 0.0f;
    public float Speed { get; set; } = 1.0f;
    public float Zoom { get; set; } = 1.0f;
    public float Feedback { get; set; } = 0.0f;

    public void Clear() => Passes.Clear();

    public void AddPass(RenderPassNode node) => Passes.Add(node);
}
