using System;
using System.IO;
using System.Text;

namespace DXRenderer;

/// <summary>
/// Centralized debug logging to a temp folder.
/// Mirrors messages to the console and persists them under
/// %LOCALAPPDATA%\RTXAudioVisualizer\logs\.
/// </summary>
public static class DebugLogger
{
    private static readonly string LogDir;
    private static readonly string LogFile;
    private static readonly object Lock = new();

    static DebugLogger()
    {
        LogDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "RTXAudioVisualizer",
            "logs");

        try
        {
            Directory.CreateDirectory(LogDir);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[DebugLogger] Could not create log dir: {ex.Message}");
        }

        var timestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        LogFile = Path.Combine(LogDir, $"rtx_audio_vis_{timestamp}.log");
        WriteLine($"=== RTX Audio Visualizer Log Started {DateTime.Now:O} ===");
    }

    public static string LogDirectory => LogDir;

    public static void WriteLine(string message)
    {
        var line = $"[{DateTime.Now:HH:mm:ss.fff}] {message}";
        Console.WriteLine(line);
        lock (Lock)
        {
            try
            {
                File.AppendAllText(LogFile, line + Environment.NewLine, Encoding.UTF8);
            }
            catch { /* best effort */ }
        }
    }

    public static void Info(string message) => WriteLine($"[INFO] {message}");
    public static void Warn(string message) => WriteLine($"[WARN] {message}");
    public static void Error(string message) => WriteLine($"[ERROR] {message}");

    public static void WriteCrash(Exception ex, string context = "")
    {
        var sb = new StringBuilder();
        sb.AppendLine($"=== CRASH {DateTime.Now:O} ===");
        if (!string.IsNullOrEmpty(context))
            sb.AppendLine($"Context: {context}");
        sb.AppendLine(ex.ToString());

        var crashFile = Path.Combine(LogDir, $"crash_{DateTime.Now:yyyyMMdd_HHmmss}.log");
        lock (Lock)
        {
            try
            {
                File.WriteAllText(crashFile, sb.ToString(), Encoding.UTF8);
            }
            catch { }
        }
        Error($"Crash logged to: {crashFile}");
        Error(ex.ToString());
    }
}
