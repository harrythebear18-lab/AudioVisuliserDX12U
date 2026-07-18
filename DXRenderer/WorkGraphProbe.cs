// Probe: inspect work graph type members
using System;
using System.Linq;
using System.Reflection;
using Vortice.Direct3D12;

namespace DXRenderer;

public static class WorkGraphProbe
{
    public static void Probe()
    {
        var wgType = typeof(WorkGraphDescription);
        Console.WriteLine("=== WorkGraphDescription ===");
        foreach (var f in wgType.GetFields())
            Console.WriteLine($"  field: {f.FieldType.Name} {f.Name}");

        var spType = typeof(SetProgramDescription);
        Console.WriteLine("=== SetProgramDescription ===");
        foreach (var f in spType.GetFields())
            Console.WriteLine($"  field: {f.FieldType.Name} {f.Name}");

        var ncType = typeof(NodeCpuInput);
        Console.WriteLine("=== NodeCpuInput ===");
        foreach (var f in ncType.GetFields())
            Console.WriteLine($"  field: {f.FieldType.Name} {f.Name}");

        var dgType = typeof(DispatchGraphDescription);
        Console.WriteLine("=== DispatchGraphDescription ===");
        foreach (var f in dgType.GetFields())
            Console.WriteLine($"  field: {f.FieldType.Name} {f.Name}");

        var cmdListType = typeof(ID3D12GraphicsCommandList6);
        Console.WriteLine("=== ID3D12GraphicsCommandList6 methods (Program/Graph) ===");
        foreach (var m in cmdListType.GetMethods())
            if (m.Name.Contains("Program") || m.Name.Contains("Graph") || m.Name.Contains("Dispatch"))
                Console.WriteLine($"  .{m.Name}({string.Join(", ", m.GetParameters().Select(p => p.ParameterType.Name))})");

        // Check ID3D12GraphicsCommandList10
        Console.WriteLine("=== ID3D12GraphicsCommandList10 ===");
        var cl10Type = typeof(Vortice.Direct3D12.ID3D12GraphicsCommandList10);
        foreach (var m in cl10Type.GetMethods())
            Console.WriteLine($"  .{m.Name}({string.Join(", ", m.GetParameters().Select(p => p.ParameterType.Name))})");

        // Search all types for SetProgram/DispatchGraph
        Console.WriteLine("=== Searching all types for SetProgram/DispatchGraph ===");
        var asm = typeof(ID3D12Device).Assembly;
        var module = asm.GetModules()[0];
        int found = 0;
        Type[]? allTypes = null;
        try { allTypes = module.GetTypes(); }
        catch (ReflectionTypeLoadException ex) { allTypes = ex.Types.Where(t => t != null).ToArray(); }
        if (allTypes != null)
        {
            foreach (var t in allTypes)
            {
                try
                {
                    foreach (var m in t.GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance))
                    {
                        if (m.Name == "SetProgram" || m.Name == "DispatchGraph")
                        {
                            Console.WriteLine($"  {t.FullName}.{m.Name}({string.Join(", ", m.GetParameters().Select(p => p.ParameterType.Name))})");
                            found++;
                        }
                    }
                }
                catch { }
            }
        }
        if (found == 0)
            Console.WriteLine("  NOT FOUND in managed wrappers — need COM interop via native vtable");

        var swgType = typeof(SetWorkGraphDescription);
        Console.WriteLine("=== SetWorkGraphDescription ===");
        foreach (var f in swgType.GetFields())
            Console.WriteLine($"  field: {f.FieldType.Name} {f.Name}");

        // ProgramIdentifier
        Console.WriteLine("=== ProgramIdentifier ===");
        foreach (var f in typeof(ProgramIdentifier).GetFields())
            Console.WriteLine($"  field: {f.FieldType.Name} {f.Name}");
        foreach (var p in typeof(ProgramIdentifier).GetProperties())
            Console.WriteLine($"  prop: {p.PropertyType.Name} {p.Name}");

        // GpuVirtualAddressRange
        Console.WriteLine("=== GpuVirtualAddressRange ===");
        foreach (var f in typeof(GpuVirtualAddressRange).GetFields())
            Console.WriteLine($"  field: {f.FieldType.Name} {f.Name}");
        foreach (var p in typeof(GpuVirtualAddressRange).GetProperties())
            Console.WriteLine($"  prop: {p.PropertyType.Name} {p.Name}");

        // GpuVirtualAddressRangeAndStride
        Console.WriteLine("=== GpuVirtualAddressRangeAndStride ===");
        foreach (var f in typeof(GpuVirtualAddressRangeAndStride).GetFields())
            Console.WriteLine($"  field: {f.FieldType.Name} {f.Name}");
        foreach (var p in typeof(GpuVirtualAddressRangeAndStride).GetProperties())
            Console.WriteLine($"  prop: {p.PropertyType.Name} {p.Name}");

        // WorkGraphMemoryRequirements
        Console.WriteLine("=== WorkGraphMemoryRequirements ===");
        foreach (var f in typeof(WorkGraphMemoryRequirements).GetFields())
            Console.WriteLine($"  field: {f.FieldType.Name} {f.Name}");
        foreach (var p in typeof(WorkGraphMemoryRequirements).GetProperties())
            Console.WriteLine($"  prop: {p.PropertyType.Name} {p.Name}");

        // ID3D12WorkGraphProperties methods
        var wgpType = typeof(ID3D12WorkGraphProperties);
        Console.WriteLine("=== ID3D12WorkGraphProperties ===");
        foreach (var m in wgpType.GetMethods())
            Console.WriteLine($"  .{m.Name}({string.Join(", ", m.GetParameters().Select(p => p.ParameterType.Name))})");

        Console.WriteLine("=== WorkGraphFlags ===");
        foreach (var v in Enum.GetNames(typeof(WorkGraphFlags)))
            Console.WriteLine($"  {v}");

        Console.WriteLine("=== SetWorkGraphFlags ===");
        foreach (var v in Enum.GetNames(typeof(SetWorkGraphFlags)))
            Console.WriteLine($"  {v}");

        Console.WriteLine("=== ProgramType ===");
        foreach (var v in Enum.GetNames(typeof(ProgramType)))
            Console.WriteLine($"  {v}");

        Console.WriteLine("=== DispatchMode ===");
        foreach (var v in Enum.GetNames(typeof(DispatchMode)))
            Console.WriteLine($"  {v}");

        Console.WriteLine("=== StateSubObjectType ===");
        foreach (var v in Enum.GetNames(typeof(StateSubObjectType)))
            Console.WriteLine($"  {v}");

        var sopType = typeof(ID3D12StateObjectProperties1);
        Console.WriteLine("=== ID3D12StateObjectProperties1 ===");
        foreach (var m in sopType.GetMethods())
            Console.WriteLine($"  .{m.Name}({string.Join(", ", m.GetParameters().Select(p => p.ParameterType.Name))})");
    }
}
