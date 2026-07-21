using System;
using System.Numerics;
using SkiaSharp;

namespace DXRenderer;

/// <summary>
/// 2D GPU-accelerated overlay layer using SkiaSharp.
/// Renders particles, glow, frequency meters, and text on top of the DX12 tonemapped output.
/// Audio-reactive: all elements driven by AudioUBO data.
/// Output is RGBA8 premultiplied — uploaded to DX12 texture and alpha-blended in pipeline.
/// </summary>
public class SkiaOverlay : IDisposable
{
    private readonly int _width;
    private readonly int _height;
    private SKBitmap _bitmap = null!;
    private SKCanvas _canvas = null!;
    private SKPaint _glowPaint = null!;
    private SKPaint _barPaint = null!;
    private SKPaint _textPaint = null!;
    private SKPaint _particlePaint = null!;

    private float _time;
    private float _beatPulse;
    private float _kickPulse;

    // Particle pool — simple 2D particles for beat bursts
    private const int MaxParticles = 128;
    private readonly Particle[] _particles = new Particle[MaxParticles];
    private int _particleCount;

    private struct Particle
    {
        public float X, Y;
        public float Vx, Vy;
        public float Life;
        public float MaxLife;
        public float Radius;
        public SKColor Color;
    }

    public SkiaOverlay(int width, int height)
    {
        _width = width;
        _height = height;
        Initialize();
    }

    public int Width => _width;
    public int Height => _height;

    private void Initialize()
    {
        _bitmap = new SKBitmap(_width, _height, SKColorType.Rgba8888, SKAlphaType.Premul);
        _canvas = new SKCanvas(_bitmap);

        _glowPaint = new SKPaint
        {
            IsAntialias = true,
            Style = SKPaintStyle.Fill,
        };

        _barPaint = new SKPaint
        {
            IsAntialias = true,
            Style = SKPaintStyle.Fill,
        };

        _textPaint = new SKPaint
        {
            IsAntialias = true,
            Typeface = SKTypeface.FromFamilyName("Consolas", SKFontStyleWeight.Normal, SKFontStyleWidth.Normal, SKFontStyleSlant.Upright),
            TextSize = 16,
            Color = SKColors.White.WithAlpha(180),
        };

        _particlePaint = new SKPaint
        {
            IsAntialias = true,
            Style = SKPaintStyle.Fill,
        };

        for (int i = 0; i < MaxParticles; i++)
            _particles[i] = new Particle();
    }

    /// <summary>
    /// Render one frame of 2D overlay content.
    /// Returns the pixel data for DX12 texture upload (RGBA8 premultiplied).
    /// </summary>
    public ReadOnlySpan<byte> Render(float time, ref AudioUBO audio)
    {
        _time = time;
        float dt = 1.0f / 60.0f;

        // Decay pulses
        _beatPulse = Math.Max(0, _beatPulse - dt * 4.0f);
        _kickPulse = Math.Max(0, _kickPulse - dt * 6.0f);

        // Trigger on beat/kick
        if (audio.Beat > 0.6f) _beatPulse = audio.Beat;
        if (audio.KickWeight > 0.5f) _kickPulse = audio.KickWeight;

        // Clear to transparent
        _canvas.Clear(SKColors.Transparent);

        DrawGlowHalo(ref audio);
        DrawFrequencyMeters(ref audio);
        UpdateAndDrawParticles(dt, ref audio);
        DrawBeatRing(ref audio);
        DrawTextOverlay(ref audio);

        _canvas.Flush();

        return _bitmap.GetPixelSpan();
    }

    private void DrawGlowHalo(ref AudioUBO audio)
    {
        float cx = _width * 0.5f;
        float cy = _height * 0.5f;
        float energy = audio.Overall;
        float baseRadius = Math.Min(_width, _height) * 0.15f;

        float glowRadius = baseRadius * (1.0f + energy * 0.5f + _beatPulse * 0.3f);
        var primaryColor = new SKColor(
            (byte)(audio.ColorPrimary.X * 255),
            (byte)(audio.ColorPrimary.Y * 255),
            (byte)(audio.ColorPrimary.Z * 255));

        using var glowShader = SKShader.CreateRadialGradient(
            new SKPoint(cx, cy), glowRadius,
            new[] { primaryColor.WithAlpha(60), primaryColor.WithAlpha(0) },
            new[] { 0f, 1f },
            SKShaderTileMode.Clamp);

        _glowPaint.Shader = glowShader;
        _canvas.DrawCircle(cx, cy, glowRadius, _glowPaint);
        _glowPaint.Shader = null;
    }

    private void DrawFrequencyMeters(ref AudioUBO audio)
    {
        float[] bands = { audio.Sub, audio.Bass, audio.LMid, audio.Mid, audio.HMid, audio.Pres, audio.Bril, audio.Air };
        int bandCount = bands.Length;
        float barWidth = 8;
        float barGap = 4;
        float totalWidth = bandCount * (barWidth + barGap);
        float startX = (_width - totalWidth) * 0.5f;
        float baseY = _height - 40;
        float maxHeight = 80;

        var primaryColor = new SKColor(
            (byte)(audio.ColorPrimary.X * 255),
            (byte)(audio.ColorPrimary.Y * 255),
            (byte)(audio.ColorPrimary.Z * 255));

        var secondaryColor = new SKColor(
            (byte)(audio.ColorSecondary.X * 255),
            (byte)(audio.ColorSecondary.Y * 255),
            (byte)(audio.ColorSecondary.Z * 255));

        for (int i = 0; i < bandCount; i++)
        {
            float h = Math.Clamp(bands[i] * maxHeight, 2, maxHeight);
            float x = startX + i * (barWidth + barGap);

            using var barShader = SKShader.CreateLinearGradient(
                new SKPoint(x, baseY), new SKPoint(x, baseY - h),
                new[] { primaryColor.WithAlpha(160), secondaryColor.WithAlpha(200) },
                new[] { 0f, 1f },
                SKShaderTileMode.Clamp);

            _barPaint.Shader = barShader;
            _canvas.DrawRoundRect(new SKRoundRect(new SKRect(x, baseY - h, x + barWidth, baseY), 2, 2), _barPaint);
        }
        _barPaint.Shader = null;
    }

    private void UpdateAndDrawParticles(float dt, ref AudioUBO audio)
    {
        // Spawn particles on beat
        if (audio.Beat > 0.6f && _particleCount < MaxParticles - 8)
        {
            int spawnCount = (int)(audio.Beat * 8);
            float cx = _width * 0.5f;
            float cy = _height * 0.5f;

            var color = new SKColor(
                (byte)(audio.ColorSecondary.X * 255),
                (byte)(audio.ColorSecondary.Y * 255),
                (byte)(audio.ColorSecondary.Z * 255));

            for (int i = 0; i < spawnCount && _particleCount < MaxParticles; i++)
            {
                float angle = (float)(Random.Shared.NextDouble() * Math.PI * 2);
                float speed = 50 + (float)(Random.Shared.NextDouble() * 200) * audio.Beat;
                ref var p = ref _particles[_particleCount++];
                p.X = cx;
                p.Y = cy;
                p.Vx = MathF.Cos(angle) * speed;
                p.Vy = MathF.Sin(angle) * speed;
                p.Life = 1.0f;
                p.MaxLife = 0.5f + (float)(Random.Shared.NextDouble() * 0.5f);
                p.Radius = 2 + (float)(Random.Shared.NextDouble() * 4);
                p.Color = color;
            }
        }

        // Update + draw
        for (int i = 0; i < _particleCount; i++)
        {
            ref var p = ref _particles[i];
            p.X += p.Vx * dt;
            p.Y += p.Vy * dt;
            p.Vx *= 0.96f;
            p.Vy *= 0.96f;
            p.Life -= dt / p.MaxLife;

            if (p.Life <= 0)
            {
                _particles[i] = _particles[--_particleCount];
                i--;
                continue;
            }

            float alpha = p.Life;
            float radius = p.Radius * p.Life;

            _particlePaint.Color = p.Color.WithAlpha((byte)(alpha * 200));
            _canvas.DrawCircle(p.X, p.Y, radius, _particlePaint);
        }
    }

    private void DrawBeatRing(ref AudioUBO audio)
    {
        if (_beatPulse <= 0.01f) return;

        float cx = _width * 0.5f;
        float cy = _height * 0.5f;
        float ringRadius = (1.0f - _beatPulse) * Math.Min(_width, _height) * 0.4f;

        var color = new SKColor(
            (byte)(audio.ColorPrimary.X * 255),
            (byte)(audio.ColorPrimary.Y * 255),
            (byte)(audio.ColorPrimary.Z * 255));

        _particlePaint.Color = color.WithAlpha((byte)(_beatPulse * 120));
        _particlePaint.Style = SKPaintStyle.Stroke;
        _particlePaint.StrokeWidth = 2 + _beatPulse * 3;
        _canvas.DrawCircle(cx, cy, ringRadius, _particlePaint);
        _particlePaint.Style = SKPaintStyle.Fill;
    }

    private void DrawTextOverlay(ref AudioUBO audio)
    {
        string bpmText = audio.BPM > 1 ? $"{audio.BPM:F0} BPM" : "---";
        _canvas.DrawText(bpmText, 12, 24, _textPaint);

        string energyText = $"Energy: {audio.Overall:F2}";
        _canvas.DrawText(energyText, 12, 44, _textPaint);

        string sectionText = $"Section {audio.SystemState.W:F0}";
        _canvas.DrawText(sectionText, _width - 120, 24, _textPaint);
    }

    public void Dispose()
    {
        _particlePaint?.Dispose();
        _textPaint?.Dispose();
        _barPaint?.Dispose();
        _glowPaint?.Dispose();
        _canvas?.Dispose();
        _bitmap?.Dispose();
    }
}
