using System;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Threading;
using StageSimWASAPI;

namespace DXRenderer;

/// <summary>
/// Audio bridge — consumes visual frames from the orchestrator's quad buffer.
/// The orchestrator runs its own split threads (audio compute + visual generation).
/// This bridge just reads the latest finished frame for GPU rendering.
/// No Python, no WebSocket, no stage fixtures — pure C# visualizer path.
/// </summary>
public class AudioBridge : IDisposable
{
    private AudioPipelineOrchestrator _orchestrator;
    private QuadBufferedVisuals.VisualFrame _latestVisual;
    private float[] _spectrum = new float[1024];
    private float[] _peakSpectrum = new float[1024];  // visual decay peaks
    private float[] _peakVelocity = new float[1024];  // fall speed per bin
    private double _lastPeakUpdate;
    private float[] _leftSpectrum = new float[1024];
    private float[] _rightSpectrum = new float[1024];
    private readonly object _lock = new();

    // Public access to analyzer for brain integration
    public AudioAnalyzer Analyzer => _orchestrator.Analyzer;

    public AudioBridge()
    {
        _orchestrator = new AudioPipelineOrchestrator(2048);  // 2048 = 23Hz/bin, good band resolution
    }

    public void Start()
    {
        if (!_orchestrator.Start())
        {
            Console.WriteLine("[AudioBridge] Failed to start audio pipeline");
            return;
        }
        Console.WriteLine($"[AudioBridge] Pipeline running at {_orchestrator.SampleRate}Hz");
        Console.WriteLine("[AudioBridge] Split threads active — consuming quad buffer");
    }

    /// <summary>
    /// Consume latest visual frame from quad buffer.
    /// Called by render loop — non-blocking, returns latest or last-known frame.
    /// </summary>
    public void PollFrame()
    {
        try
        {
            if (_orchestrator.Visuals != null && _orchestrator.Visuals.TryConsume(out var vf, out var spec))
            {
                lock (_lock)
                {
                    _latestVisual = vf;
                    int bins = Math.Min(spec.Length, 1024);
                    Array.Copy(spec, _spectrum, bins);
                }
            }
        }
        catch (Exception e)
        {
            Console.WriteLine($"[AudioBridge] Poll error: {e.Message}");
        }
    }

    /// <summary>
    /// Returns the latest raw visual frame. No smoothing/decay — that lives on the visual side.
    /// </summary>
    public QuadBufferedVisuals.VisualFrame GetLatestFrame()
    {
        lock (_lock) { return _latestVisual; }
    }

    public float[] GetSpectrum()
    {
        lock (_lock)
        {
            // Per-bin visual peak decay: bars jump up instantly, fall with gravity
            double now = System.Diagnostics.Stopwatch.GetTimestamp()
                / (double)System.Diagnostics.Stopwatch.Frequency;
            float dt = _lastPeakUpdate > 0 ? (float)(now - _lastPeakUpdate) : 0.016f;
            _lastPeakUpdate = now;
            dt = Math.Min(dt, 0.05f);  // clamp to 50ms

            // Visual decay: bars fall smoothly after peaks, matching pipeline latency
            float gravity = 15.0f;

            for (int i = 0; i < _spectrum.Length; i++)
            {
                float target = _spectrum[i];
                if (target >= _peakSpectrum[i])
                {
                    // New peak — jump up instantly, reset velocity
                    _peakSpectrum[i] = target;
                    _peakVelocity[i] = 0f;
                }
                else
                {
                    // Below peak — accelerate downward
                    _peakVelocity[i] -= gravity * dt;
                    _peakSpectrum[i] += _peakVelocity[i] * dt;
                    if (_peakSpectrum[i] < target)
                    {
                        _peakSpectrum[i] = target;
                        _peakVelocity[i] = 0f;
                    }
                }
            }

            return (float[])_peakSpectrum.Clone();
        }
    }

    public float[] GetLeftSpectrum()
    {
        var lr = _orchestrator.GetLeftSpectrum();
        if (lr != null) Array.Copy(lr, _leftSpectrum, Math.Min(lr.Length, 1024));
        return _leftSpectrum;
    }

    public float[] GetRightSpectrum()
    {
        var rr = _orchestrator.GetRightSpectrum();
        if (rr != null) Array.Copy(rr, _rightSpectrum, Math.Min(rr.Length, 1024));
        return _rightSpectrum;
    }

    public void Stop()
    {
        _orchestrator?.Stop();
    }

    public void Dispose()
    {
        Stop();
    }
}
