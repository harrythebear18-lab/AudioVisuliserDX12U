using System;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using Vortice.Dxc;
using SharpGen.Runtime;

namespace DXRenderer;

public static class DxcProbe
{
    public static void Probe()
    {
        Console.WriteLine("=== Dxc static methods ===");
        foreach (var m in typeof(Dxc).GetMethods(BindingFlags.Public | BindingFlags.Static))
            Console.WriteLine($"  {m.ReturnType.Name} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.FullName} {p.Name}"))})");

        Console.WriteLine("=== DxcBuffer fields ===");
        foreach (var f in typeof(DxcBuffer).GetFields())
            Console.WriteLine($"  {f.FieldType.FullName} {f.Name}");

        Console.WriteLine("=== IDxcCompiler3 methods ===");
        foreach (var m in typeof(IDxcCompiler3).GetMethods())
            Console.WriteLine($"  {m.ReturnType.Name} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.FullName} {p.Name}"))})");

        Console.WriteLine("=== IDxcUtils methods ===");
        foreach (var m in typeof(IDxcUtils).GetMethods())
            Console.WriteLine($"  {m.ReturnType.Name} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.FullName} {p.Name}"))})");

        Console.WriteLine("=== IDxcOperationResult methods ===");
        foreach (var m in typeof(IDxcOperationResult).GetMethods())
            Console.WriteLine($"  {m.ReturnType.Name} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.FullName} {p.Name}"))})");

        Console.WriteLine("=== IDxcBlob methods/props ===");
        foreach (var m in typeof(IDxcBlob).GetMethods())
            Console.WriteLine($"  method: {m.ReturnType.Name} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.FullName} {p.Name}"))})");
        foreach (var p in typeof(IDxcBlob).GetProperties())
            Console.WriteLine($"  prop: {p.PropertyType.FullName} {p.Name}");

        Console.WriteLine("=== IDxcBlobEncoding methods/props ===");
        foreach (var m in typeof(IDxcBlobEncoding).GetMethods())
            Console.WriteLine($"  method: {m.ReturnType.Name} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.FullName} {p.Name}"))})");
        foreach (var p in typeof(IDxcBlobEncoding).GetProperties())
            Console.WriteLine($"  prop: {p.PropertyType.FullName} {p.Name}");

        // Dump DxcCreateInstance overloads
        Console.WriteLine("=== Dxc.DxcCreateInstance overloads ===");
        foreach (var m in typeof(Dxc).GetMethods(BindingFlags.Public | BindingFlags.Static))
            if (m.Name.Contains("CreateInstance"))
                Console.WriteLine($"  {m.ReturnType.Name} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.FullName} {p.Name}"))})");

        // Dump IDxcUtils blob creation methods
        Console.WriteLine("=== IDxcUtils blob methods ===");
        foreach (var m in typeof(IDxcUtils).GetMethods())
            if (m.Name.Contains("Blob") || m.Name.Contains("blob"))
                Console.WriteLine($"  {m.ReturnType.Name} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.FullName} {p.Name}"))})");

        // Dump IDxcBlob properties with full type names
        Console.WriteLine("=== IDxcBlob all members ===");
        foreach (var p in typeof(IDxcBlob).GetProperties())
            Console.WriteLine($"  prop: {p.PropertyType.FullName} {p.Name} (get={p.GetMethod != null}, set={p.SetMethod != null})");
        foreach (var m in typeof(IDxcBlob).GetMethods())
            Console.WriteLine($"  method: {m.ReturnType.FullName} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.FullName} {p.Name}"))})");

        // Dump IDxcBlobEncoding all members
        Console.WriteLine("=== IDxcBlobEncoding all members ===");
        foreach (var p in typeof(IDxcBlobEncoding).GetProperties())
            Console.WriteLine($"  prop: {p.PropertyType.FullName} {p.Name}");
        foreach (var m in typeof(IDxcBlobEncoding).GetMethods())
            Console.WriteLine($"  method: {m.ReturnType.FullName} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.FullName} {p.Name}"))})");

        // Dump DxcBuffer constructors
        Console.WriteLine("=== DxcBuffer constructors ===");
        foreach (var c in typeof(DxcBuffer).GetConstructors())
            Console.WriteLine($"  ({string.Join(", ", c.GetParameters().Select(p => $"{p.ParameterType.FullName} {p.Name}"))})");
    }
}
