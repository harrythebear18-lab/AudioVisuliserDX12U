using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace DXRenderer;

/// <summary>
/// Fast pixel-level screen analysis — runs between LLM calls for quick adjustments.
/// Ported from smc-autosort's FastVision: motion detection, brightness, color variance.
/// No AI calls — pure CPU pixel math, runs in milliseconds.
/// </summary>
public class FastVisionAnalyzer
{
    private readonly IntPtr _hwnd;
    private byte[]? _prevFrame;
    private int _prevW, _prevH;

    public FastVisionAnalyzer(IntPtr hwnd)
    {
        _hwnd = hwnd;
    }

    /// <summary>
    /// Capture and analyze the current frame.
    /// Returns (brightness 0-1, motion 0-1, colorVariance 0-1).
    /// </summary>
    public (float brightness, float motion, float colorVariance) Analyze()
    {
        var rect = new NativeRect();
        if (!GetClientRect(_hwnd, ref rect))
            return (0.5f, 0f, 0.5f);

        int w = rect.Right - rect.Left;
        int h = rect.Bottom - rect.Top;
        if (w <= 0 || h <= 0) return (0.5f, 0f, 0.5f);

        // Downscale for speed — 64x36 is enough for statistics
        int dw = 64, dh = 36;

        using var bmp = new Bitmap(dw, dh, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.Low;

            var hdc = g.GetHdc();
            bool ok = PrintWindow(_hwnd, hdc, 0);
            g.ReleaseHdc(hdc);

            if (!ok)
            {
                using var screen = new Bitmap(w, h, PixelFormat.Format24bppRgb);
                using (var sg = Graphics.FromImage(screen))
                {
                    var pt = new Point(rect.Left, rect.Top);
                    ClientToScreen(_hwnd, ref pt);
                    sg.CopyFromScreen(pt.X, pt.Y, 0, 0, new Size(w, h));
                }
                g.DrawImage(screen, 0, 0, dw, dh);
            }
        }

        // Extract pixel data
        var data = bmp.LockBits(new Rectangle(0, 0, dw, dh), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        int stride = data.Stride;
        int bytes = stride * dh;
        byte[] pixels = new byte[bytes];
        Marshal.Copy(data.Scan0, pixels, 0, bytes);
        bmp.UnlockBits(data);

        // Compute brightness (luminance), color variance, and motion
        float totalLum = 0;
        float totalR = 0, totalG = 0, totalB = 0;
        float totalR2 = 0, totalG2 = 0, totalB2 = 0;
        int count = dw * dh;

        for (int y = 0; y < dh; y++)
        {
            for (int x = 0; x < dw; x++)
            {
                int idx = y * stride + x * 3;
                float r = pixels[idx + 2];
                float g = pixels[idx + 1];
                float b = pixels[idx + 0];

                totalLum += 0.299f * r + 0.587f * g + 0.114f * b;
                totalR += r; totalG += g; totalB += b;
                totalR2 += r * r; totalG2 += g * g; totalB2 += b * b;
            }
        }

        float avgLum = totalLum / count / 255f;
        float avgR = totalR / count;
        float avgG = totalG / count;
        float avgB = totalB / count;
        float varR = Math.Max(0, totalR2 / count - avgR * avgR);
        float varG = Math.Max(0, totalG2 / count - avgG * avgG);
        float varB = Math.Max(0, totalB2 / count - avgB * avgB);
        float colorVariance = Math.Clamp((float)(Math.Sqrt(varR + varG + varB) / 128f), 0f, 1f);

        // Motion: compare to previous frame
        float motion = 0f;
        if (_prevFrame != null && _prevW == dw && _prevH == dh && _prevFrame.Length == bytes)
        {
            float totalDiff = 0;
            for (int i = 0; i < bytes; i += 4) // sample every 4th byte
            {
                float diff = Math.Abs(pixels[i] - _prevFrame[i]);
                totalDiff += diff;
            }
            int samples = bytes / 4;
            motion = Math.Clamp(totalDiff / samples / 64f, 0f, 1f);
        }

        _prevFrame = pixels;
        _prevW = dw;
        _prevH = dh;

        return (avgLum, motion, colorVariance);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left, Top, Right, Bottom;
    }

    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr hWnd, ref NativeRect lpRect);

    [DllImport("user32.dll")]
    private static extern bool ClientToScreen(IntPtr hWnd, ref Point lpPoint);

    [DllImport("user32.dll")]
    private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
}
