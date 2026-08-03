using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace DXRenderer;

/// <summary>
/// Pipeline validation system — independently measures frame times and cross-checks
/// against HUD-reported FPS/latency. Detects frame drops, timing discrepancies,
/// and pipeline stalls. Logs warnings when HUD values diverge from actual measurements.
/// </summary>
public class PipelineValidator
{
    private readonly Stopwatch _independentTimer = Stopwatch.StartNew();
    private long _lastFrameTicks;
    private long _frameStartTicks;

    // Rolling window of frame times (last 120 frames = ~2s at 60fps)
    private const int WINDOW_SIZE = 120;
    private readonly float[] _frameTimes = new float[WINDOW_SIZE];
    private int _frameTimeIdx;
    private int _frameTimeCount;

    // Validation results
    public float ActualAvgMs { get; private set; }
    public float ActualMinMs { get; private set; } = float.MaxValue;
    public float ActualMaxMs { get; private set; } = float.MinValue;
    public float ActualFPS { get; private set; }
    public float HudFPS { get; private set; }
    public float HudLatencyMs { get; private set; }
    public float DiscrepancyMs { get; private set; }
    public float DiscrepancyPercent { get; private set; }
    public int FrameDropCount { get; private set; }
    public int TotalFramesValidated { get; private set; }
    public int WarningCount { get; private set; }
    public bool IsValidating { get; private set; } = true;

    // Thresholds
    private const float FPS_DISCREPANCY_THRESHOLD = 0.15f;  // 15% difference = warning
    private const float FRAME_DROP_THRESHOLD_MS = 50f;      // >50ms = dropped frame
    private const float STALL_THRESHOLD_MS = 100f;          // >100ms = stall

    // Last validation summary
    public string LastSummary { get; private set; } = "";

    /// <summary>
    /// Call at the start of each frame to begin timing.
    /// </summary>
    public void BeginFrame()
    {
        _frameStartTicks = _independentTimer.ElapsedTicks;
    }

    /// <summary>
    /// Call at the end of each frame. Pass in the HUD-reported values for cross-check.
    /// </summary>
    /// <param name="hudFPS">FPS value shown on HUD</param>
    /// <param name="hudLatencyMs">Latency value shown on HUD</param>
    /// <param name="pipelineTotalMs">Total audio pipeline latency from VisualFrame</param>
    public void EndFrame(float hudFPS, float hudLatencyMs, float pipelineTotalMs = 0f)
    {
        if (!IsValidating) return;

        long nowTicks = _independentTimer.ElapsedTicks;
        float frameMs = (nowTicks - _frameStartTicks) / (float)Stopwatch.Frequency * 1000f;

        // Also measure inter-frame time (includes present wait)
        if (_lastFrameTicks > 0)
        {
            float interFrameMs = (nowTicks - _lastFrameTicks) / (float)Stopwatch.Frequency * 1000f;
            // Use inter-frame time as the "actual" frame time — more accurate than render-only
            frameMs = interFrameMs;
        }
        _lastFrameTicks = nowTicks;

        // Store in rolling window
        _frameTimes[_frameTimeIdx] = frameMs;
        _frameTimeIdx = (_frameTimeIdx + 1) % WINDOW_SIZE;
        if (_frameTimeCount < WINDOW_SIZE) _frameTimeCount++;

        // Update stats
        ActualMinMs = Math.Min(ActualMinMs, frameMs);
        ActualMaxMs = Math.Max(ActualMaxMs, frameMs);

        // Compute rolling average
        float sum = 0;
        for (int i = 0; i < _frameTimeCount; i++)
            sum += _frameTimes[i];
        ActualAvgMs = sum / Math.Max(_frameTimeCount, 1);
        ActualFPS = 1000f / Math.Max(ActualAvgMs, 0.1f);

        // Cross-check against HUD
        HudFPS = hudFPS;
        HudLatencyMs = hudLatencyMs;
        DiscrepancyMs = Math.Abs(ActualAvgMs - hudLatencyMs);
        DiscrepancyPercent = hudLatencyMs > 0.1f ? DiscrepancyMs / hudLatencyMs : 0f;

        // Detect frame drops
        if (frameMs > FRAME_DROP_THRESHOLD_MS)
        {
            FrameDropCount++;
            if (frameMs > STALL_THRESHOLD_MS)
            {
                WarningCount++;
                DebugLogger.Warn($"[PipelineValidator] STALL detected: {frameMs:F1}ms (threshold {STALL_THRESHOLD_MS}ms)");
            }
        }

        // Check HUD vs actual discrepancy (every 60 frames to avoid spam)
        TotalFramesValidated++;
        if (TotalFramesValidated % 60 == 0 && _frameTimeCount >= 30)
        {
            if (DiscrepancyPercent > FPS_DISCREPANCY_THRESHOLD)
            {
                WarningCount++;
                DebugLogger.Warn($"[PipelineValidator] HUD/Actual mismatch: HUD={hudLatencyMs:F2}ms Actual={ActualAvgMs:F2}ms ({DiscrepancyPercent*100:F1}% discrepancy)");
            }

            // Build summary
            LastSummary = $"Actual: {ActualAvgMs:F2}ms avg, {ActualMinMs:F2}min, {ActualMaxMs:F2}max, {ActualFPS:F1}fps | " +
                          $"HUD: {hudFPS:F1}fps, {hudLatencyMs:F2}ms | " +
                          $"Δ={DiscrepancyPercent*100:F1}% | " +
                          $"Drops:{FrameDropCount} Warnings:{WarningCount} | " +
                          $"Pipeline:{pipelineTotalMs:F2}ms";

            if (_frameTimeCount >= 60)
            {
                DebugLogger.Info($"[PipelineValidator] {LastSummary}");
            }
        }
    }

    /// <summary>
    /// Reset all statistics (e.g., on mode change).
    /// </summary>
    public void Reset()
    {
        Array.Clear(_frameTimes, 0, _frameTimes.Length);
        _frameTimeIdx = 0;
        _frameTimeCount = 0;
        ActualAvgMs = 0;
        ActualMinMs = float.MaxValue;
        ActualMaxMs = float.MinValue;
        ActualFPS = 0;
        FrameDropCount = 0;
        TotalFramesValidated = 0;
        WarningCount = 0;
        _lastFrameTicks = 0;
    }

    /// <summary>
    /// Get a formatted validation report for HUD display.
    /// </summary>
    public string GetHudLine()
    {
        if (!IsValidating || _frameTimeCount < 10)
            return "Validator: warming up...";

        string status = DiscrepancyPercent > FPS_DISCREPANCY_THRESHOLD ? "MISMATCH" :
                        FrameDropCount > 0 ? "DROPS" : "OK";
        return $"Validator: {ActualAvgMs:F1}ms/{ActualFPS:F0}fps Δ{DiscrepancyPercent*100:F0}% [{status}]";
    }

    /// <summary>
    /// Toggle validation on/off.
    /// </summary>
    public void Toggle()
    {
        IsValidating = !IsValidating;
        DebugLogger.Info($"[PipelineValidator] {(IsValidating ? "Enabled" : "Disabled")}");
    }
}
