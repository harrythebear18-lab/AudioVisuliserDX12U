// Stub types to replace Unity dependencies — allows full LightingBrain to compile standalone.
// These are empty shells; the brain's stage scanning logic is preserved but will find no fixtures.
// We can wire these to real outputs later.

using System;
using System.Collections.Generic;

namespace StageSimWASAPI
{
    // Unity MonoBehaviour stub
    public class MonoBehaviour { }

    // Unity Object stub
    public class UnityObject { }

    // Stubs for stage fixture types — brain references these but we don't need real impl yet
    public class TransformStub
    {
        public float[] position = new float[3];
    }

    public class MovingLight : MonoBehaviour
    {
        public TransformStub transform = new TransformStub();
    }

    public class LaserContoller : MonoBehaviour { }

    public class Blinders : MonoBehaviour { }

    // Unity Object stub with FindObjectsOfType — returns empty arrays (no stage in visualizer)
    public class Object
    {
        public static T[] FindObjectsOfType<T>() where T : class { return new T[0]; }
    }

    // Unity Time stub — brain uses Time.realtimeSinceStartup
    public static class Time
    {
        private static DateTime _start = DateTime.UtcNow;
        public static float realtimeSinceStartup => (float)(DateTime.UtcNow - _start).TotalSeconds;
        public static float deltaTime { get; set; } = 0.016f; // set by orchestrator
    }

    // Unity Debug stub
    public static class Debug
    {
        public static void Log(object msg) { Console.WriteLine(msg); }
        public static void LogWarning(object msg) { Console.WriteLine("[WARN] " + msg); }
        public static void LogError(object msg) { Console.WriteLine("[ERROR] " + msg); }
    }

    // Unity Object.FindObjectsOfType stub — returns empty arrays
    public static class UnityObjectFinder
    {
        public static T[] FindObjectsOfType<T>() where T : class { return new T[0]; }
    }

    // HarmonyLib Traverse stub — brain uses it to access private fields
    public class Traverse
    {
        public static Traverse Create(object obj) { return new Traverse(); }
        public Traverse Field(string name) { return this; }
        public T GetValue<T>() { return default; }
    }

    // WASAPIPlugin stub — brain calls WASAPIPlugin.Instance.GetStereoBalance/Width
    // Orchestrator sets these values before calling brain.Update()
    public class WASAPIPlugin
    {
        public static WASAPIPlugin Instance { get; } = new WASAPIPlugin();
        public float StereoBalance { get; set; } = 0f;
        public float StereoWidth { get; set; } = 0f;
        public float PhaseCorrelation { get; set; } = 0.5f;
        public float GetStereoBalance() => StereoBalance;
        public float GetStereoWidth() => StereoWidth;
        public float GetPhaseCorrelation() => PhaseCorrelation;
    }
}
