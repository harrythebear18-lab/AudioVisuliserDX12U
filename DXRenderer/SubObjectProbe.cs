using System;
using System.Linq;
using System.Reflection;
using Vortice.Direct3D12;

namespace DXRenderer;

public static class SubObjectProbe
{
    public static void Probe()
    {
        var t = typeof(StateSubObject);
        Console.WriteLine($"=== StateSubObject (IsClass={t.IsClass}, IsStruct={t.IsValueType}) ===");
        
        Console.WriteLine("Constructors:");
        foreach (var c in t.GetConstructors())
        {
            var p = c.GetParameters();
            Console.WriteLine($"  ({string.Join(", ", p.Select(x => $"{x.ParameterType.Name} {x.Name}"))})");
        }

        Console.WriteLine("Fields:");
        foreach (var f in t.GetFields())
            Console.WriteLine($"  {f.FieldType.Name} {f.Name}");

        Console.WriteLine("Properties:");
        foreach (var p in t.GetProperties())
            Console.WriteLine($"  {p.PropertyType.Name} {p.Name}");

        // Also check StateObjectDescription
        var t2 = typeof(StateObjectDescription);
        Console.WriteLine($"=== StateObjectDescription (IsClass={t2.IsClass}, IsStruct={t2.IsValueType}) ===");
        Console.WriteLine("Constructors:");
        foreach (var c in t2.GetConstructors())
        {
            var p = c.GetParameters();
            Console.WriteLine($"  ({string.Join(", ", p.Select(x => $"{x.ParameterType.Name} {x.Name}"))})");
        }

        // Check DxcBuffer
        var t3 = typeof(Vortice.Dxc.DxcBuffer);
        Console.WriteLine($"=== DxcBuffer ===");
        foreach (var f in t3.GetFields())
            Console.WriteLine($"  {f.FieldType.Name} {f.Name}");

        // Check IDxcCompiler3.Compile
        var t4 = typeof(Vortice.Dxc.IDxcCompiler3);
        Console.WriteLine($"=== IDxcCompiler3 methods ===");
        foreach (var m in t4.GetMethods())
            Console.WriteLine($"  {m.ReturnType.Name} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.Name} {p.Name}"))})");

        // Check IDxcOperationResult
        var t5 = typeof(Vortice.Dxc.IDxcOperationResult);
        Console.WriteLine($"=== IDxcOperationResult methods ===");
        foreach (var m in t5.GetMethods())
            Console.WriteLine($"  {m.ReturnType.Name} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.Name} {p.Name}"))})");

        // Check IStateSubObjectDescription
        var t7 = typeof(IStateSubObjectDescription);
        Console.WriteLine($"=== IStateSubObjectDescription ===");
        Console.WriteLine($"  IsInterface={t7.IsInterface}");
        foreach (var p in t7.GetProperties())
            Console.WriteLine($"  prop: {p.PropertyType.Name} {p.Name}");

        // Check which types implement IStateSubObjectDescription
        var asm = typeof(StateSubObject).Assembly;
        var module = asm.GetModules()[0];
        Type[]? allTypes = null;
        try { allTypes = module.GetTypes(); }
        catch (ReflectionTypeLoadException ex) { allTypes = ex.Types.Where(t => t != null).ToArray(); }
        Console.WriteLine("=== Types implementing IStateSubObjectDescription ===");
        if (allTypes != null)
        {
            foreach (var tt in allTypes)
            {
                try
                {
                    if (typeof(IStateSubObjectDescription).IsAssignableFrom(tt) && tt != typeof(IStateSubObjectDescription))
                        Console.WriteLine($"  {tt.FullName} (IsClass={tt.IsClass}, IsStruct={tt.IsValueType})");
                }
                catch { }
            }
        }

        // Check DxcBuffer fields with types
        Console.WriteLine("=== DxcBuffer fields with types ===");
        foreach (var f in typeof(Vortice.Dxc.DxcBuffer).GetFields())
            Console.WriteLine($"  {f.FieldType.FullName} {f.Name}");

        // Check IDxcCompiler3.Compile with full param types
        Console.WriteLine("=== IDxcCompiler3.Compile ===");
        foreach (var m in typeof(Vortice.Dxc.IDxcCompiler3).GetMethods())
            if (m.Name == "Compile")
                Console.WriteLine($"  {m.ReturnType.Name} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.FullName} {p.Name}"))})");

        // Check IDxcOperationResult methods with full types
        Console.WriteLine("=== IDxcOperationResult methods ===");
        foreach (var m in typeof(Vortice.Dxc.IDxcOperationResult).GetMethods())
            Console.WriteLine($"  {m.ReturnType.Name} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.FullName} {p.Name}"))})");

        // Check IDxcBlob methods with full types
        Console.WriteLine("=== IDxcBlob methods ===");
        foreach (var m in typeof(Vortice.Dxc.IDxcBlob).GetMethods())
            Console.WriteLine($"  {m.ReturnType.Name} {m.Name}({string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.FullName} {p.Name}"))})");
        foreach (var p in typeof(Vortice.Dxc.IDxcBlob).GetProperties())
            Console.WriteLine($"  prop: {p.PropertyType.FullName} {p.Name}");
    }
}
