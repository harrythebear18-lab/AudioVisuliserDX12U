// Standalone Mathf replacement — maps Unity Mathf to System.MathF
namespace StageSimWASAPI
{
    internal static class Mathf
    {
        public static float PI => System.MathF.PI;
        public static float Max(float a, float b) => System.MathF.Max(a, b);
        public static float Min(float a, float b) => System.MathF.Min(a, b);
        public static int Max(int a, int b) => System.Math.Max(a, b);
        public static int Min(int a, int b) => System.Math.Min(a, b);
        public static float Abs(float f) => System.MathF.Abs(f);
        public static float Clamp(float v, float min, float max) => v < min ? min : (v > max ? max : v);
        public static int Clamp(int v, int min, int max) => v < min ? min : (v > max ? max : v);
        public static float Clamp01(float v) => v < 0f ? 0f : (v > 1f ? 1f : v);
        public static float Lerp(float a, float b, float t) => a + (b - a) * t;
        public static float Pow(float f, float p) => System.MathF.Pow(f, p);
        public static float Sqrt(float f) => System.MathF.Sqrt(f);
        public static float Sin(float f) => System.MathF.Sin(f);
        public static float Cos(float f) => System.MathF.Cos(f);
        public static float Exp(float f) => System.MathF.Exp(f);
        public static float Log(float f) => System.MathF.Log(f);
        public static float Round(float f) => System.MathF.Round(f);
        public static float Repeat(float t, float length) => t - length * System.MathF.Floor(t / length);
        public static int FloorToInt(float f) => (int)System.MathF.Floor(f);
        public static int RoundToInt(float f) => (int)System.MathF.Round(f);
        public static int CeilToInt(float f) => (int)System.MathF.Ceiling(f);
    }

    public struct Color32
    {
        public byte r, g, b, a;
        public Color32(byte r, byte g, byte b, byte a) { this.r = r; this.g = g; this.b = b; this.a = a; }
    }
}
