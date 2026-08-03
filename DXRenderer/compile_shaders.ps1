# compile_shaders.ps1 — Pre-build shader compilation
# Compiles all HLSL shaders to DXBC bytecode using DXC, embeds as .dxbc files
# Usage: powershell -File compile_shaders.ps1 -ShaderDir ..\shaders -OutDir compiled_shaders

param(
    [Parameter(Mandatory=$true)]
    [string]$ShaderDir,
    
    [Parameter(Mandatory=$true)]
    [string]$OutDir
)

# Resolve paths
$ShaderDir = Resolve-Path $ShaderDir -ErrorAction Stop
if (!(Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (New-Item -ItemType Directory -Path $OutDir -Force).FullName

# Find DXC — prefer dxc.exe (can be invoked from PowerShell), not dxcompiler.dll (DLL, not executable)
$dxcPaths = @(
    # System PATH (dxc.exe)
    (Get-Command "dxc.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
    # Vulkan SDK
    "$env:VULKAN_SDK\Bin\dxc.exe",
    # Common locations
    "C:\Program Files\DirectXShaderCompiler\bin\dxc.exe"
) | Where-Object { $_ -and (Test-Path $_ -ErrorAction SilentlyContinue) }

if (!$dxcPaths -or $dxcPaths.Count -eq 0) {
    Write-Host "[compile_shaders] DXC not found! Shaders will be compiled at runtime." -ForegroundColor Yellow
    # Create a marker file so the C# code knows to fall back to runtime compilation
    Set-Content -Path (Join-Path $OutDir "_NO_DXC.marker") -Value "DXC not available at build time"
    exit 0
}

$dxcPath = $dxcPaths[0]
Write-Host "[compile_shaders] Using DXC: $dxcPath" -ForegroundColor Green

# Function to preprocess includes (inline all #include directives)
function Preprocess-Includes {
    param([string]$Source, [string]$BaseDir, [System.Collections.Generic.HashSet[string]]$Processed = $null)
    
    if ($null -eq $Processed) { $Processed = [System.Collections.Generic.HashSet[string]]::new() }
    
    $lines = $Source -split "`r?`n"
    $result = [System.Text.StringBuilder]::new()
    
    foreach ($line in $lines) {
        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith("#include")) {
            $start = $trimmed.IndexOf('"')
            $end = $trimmed.LastIndexOf('"')
            if ($start -ge 0 -and $end -gt $start) {
                $includeRel = $trimmed.Substring($start + 1, $end - $start - 1)
                $includeFull = Join-Path $BaseDir $includeRel
                if (!(Test-Path $includeFull)) {
                    $includeFull = Join-Path $BaseDir "include" $includeRel
                }
                if (Test-Path $includeFull) {
                    $includeFull = (Resolve-Path $includeFull).Path
                    if ($Processed.Contains($includeFull)) {
                        continue  # Already inlined
                    }
                    [void]$Processed.Add($includeFull)
                    $includeSource = Get-Content $includeFull -Raw
                    $inlined = Preprocess-Includes -Source $includeSource -BaseDir $BaseDir -Processed $Processed
                    [void]$result.AppendLine($inlined)
                    continue
                }
            }
        }
        [void]$result.AppendLine($line)
    }
    
    return $result.ToString()
}

# Shader compilation arguments
$dxcArgs = @("-E", "main", "-T", "ps_6_6", "-D", "DX12U=1", "-Qstrip_reflect", "-Qstrip_debug", "-HV", "2021", "-O3")
$vsDxcArgs = @("-E", "main", "-T", "vs_6_6", "-D", "DX12U=1", "-Qstrip_reflect", "-Qstrip_debug", "-HV", "2021", "-O3")

# List all mode shaders (dx_*.hlsl) and pipeline shaders
$modeShaders = Get-ChildItem -Path $ShaderDir -Filter "dx_*.hlsl" | Where-Object { $_.Name -notmatch "_test" }
$pipelineShaders = @(
    @{Name="vs_fullscreen"; File="vs_fullscreen.hlsl"; Args=$vsDxcArgs; IsVS=$true}
)

# Also find vs_*.hlsl, cs_*.hlsl, gs_*.hlsl
$vsShaders = Get-ChildItem -Path $ShaderDir -Filter "vs_*.hlsl" -ErrorAction SilentlyContinue
$csShaders = Get-ChildItem -Path $ShaderDir -Filter "cs_*.hlsl" -ErrorAction SilentlyContinue
$gsShaders = Get-ChildItem -Path $ShaderDir -Filter "gs_*.hlsl" -ErrorAction SilentlyContinue

$compiled = 0
$failed = 0

# Compile mode pixel shaders
foreach ($shader in $modeShaders) {
    $outFile = Join-Path $OutDir ($shader.BaseName + ".dxbc")
    
    # Read and preprocess
    $source = Get-Content $shader.FullName -Raw
    $preprocessed = Preprocess-Includes -Source $source -BaseDir $ShaderDir
    
    # Write preprocessed to temp file for DXC
    $tempFile = Join-Path $env:TEMP ($shader.BaseName + "_preprocessed.hlsl")
    Set-Content -Path $tempFile -Value $preprocessed -Encoding UTF8
    
    $args = @($tempFile) + $dxcArgs + @("-Fo", $outFile)
    
    & $dxcPath @args 2>&1 | ForEach-Object { 
        if ($_ -match "error") { Write-Host "[compile_shaders] ERROR $($_)" -ForegroundColor Red }
    }
    
    if (Test-Path $outFile) {
        $size = (Get-Item $outFile).Length
        Write-Host "[compile_shaders] Compiled $($shader.Name) -> $size bytes" -ForegroundColor Green
        $compiled++
    } else {
        Write-Host "[compile_shaders] FAILED to compile $($shader.Name)" -ForegroundColor Red
        $failed++
    }
    
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
}

# Compile vertex shaders
foreach ($shader in $vsShaders) {
    $outFile = Join-Path $OutDir ($shader.BaseName + ".dxbc")
    $source = Get-Content $shader.FullName -Raw
    $preprocessed = Preprocess-Includes -Source $source -BaseDir $ShaderDir
    $tempFile = Join-Path $env:TEMP ($shader.BaseName + "_preprocessed.hlsl")
    Set-Content -Path $tempFile -Value $preprocessed -Encoding UTF8
    
    $args = @($tempFile) + $vsDxcArgs + @("-Fo", $outFile)
    & $dxcPath @args 2>&1 | ForEach-Object {
        if ($_ -match "error") { Write-Host "[compile_shaders] ERROR $($_)" -ForegroundColor Red }
    }
    
    if (Test-Path $outFile) {
        Write-Host "[compile_shaders] Compiled VS $($shader.Name)" -ForegroundColor Green
        $compiled++
    } else {
        Write-Host "[compile_shaders] FAILED to compile VS $($shader.Name)" -ForegroundColor Red
        $failed++
    }
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
}

# Compile compute shaders
foreach ($shader in $csShaders) {
    $outFile = Join-Path $OutDir ($shader.BaseName + ".dxbc")
    $source = Get-Content $shader.FullName -Raw
    $preprocessed = Preprocess-Includes -Source $source -BaseDir $ShaderDir
    $tempFile = Join-Path $env:TEMP ($shader.BaseName + "_preprocessed.hlsl")
    Set-Content -Path $tempFile -Value $preprocessed -Encoding UTF8
    
    $csArgs = @("-E", "main", "-T", "cs_6_6", "-D", "DX12U=1", "-Qstrip_reflect", "-Qstrip_debug", "-HV", "2021", "-O3")
    $args = @($tempFile) + $csArgs + @("-Fo", $outFile)
    & $dxcPath @args 2>&1 | ForEach-Object {
        if ($_ -match "error") { Write-Host "[compile_shaders] ERROR $($_)" -ForegroundColor Red }
    }
    
    if (Test-Path $outFile) {
        Write-Host "[compile_shaders] Compiled CS $($shader.Name)" -ForegroundColor Green
        $compiled++
    } else {
        Write-Host "[compile_shaders] FAILED to compile CS $($shader.Name)" -ForegroundColor Red
        $failed++
    }
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
}

# Compile geometry shaders
foreach ($shader in $gsShaders) {
    $outFile = Join-Path $OutDir ($shader.BaseName + ".dxbc")
    $source = Get-Content $shader.FullName -Raw
    $preprocessed = Preprocess-Includes -Source $source -BaseDir $ShaderDir
    $tempFile = Join-Path $env:TEMP ($shader.BaseName + "_preprocessed.hlsl")
    Set-Content -Path $tempFile -Value $preprocessed -Encoding UTF8
    
    $gsArgs = @("-E", "main", "-T", "gs_6_6", "-D", "DX12U=1", "-Qstrip_reflect", "-Qstrip_debug", "-HV", "2021", "-O3")
    $args = @($tempFile) + $gsArgs + @("-Fo", $outFile)
    & $dxcPath @args 2>&1 | ForEach-Object {
        if ($_ -match "error") { Write-Host "[compile_shaders] ERROR $($_)" -ForegroundColor Red }
    }
    
    if (Test-Path $outFile) {
        Write-Host "[compile_shaders] Compiled GS $($shader.Name)" -ForegroundColor Green
        $compiled++
    } else {
        Write-Host "[compile_shaders] FAILED to compile GS $($shader.Name)" -ForegroundColor Red
        $failed++
    }
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
}

# Also compile the work graph shader if present
$wgShader = Join-Path $ShaderDir "wg_audio_visualizer.hlsl"
if (Test-Path $wgShader) {
    $outFile = Join-Path $OutDir "wg_audio_visualizer.dxbc"
    $source = Get-Content $wgShader -Raw
    $preprocessed = Preprocess-Includes -Source $source -BaseDir $ShaderDir
    $tempFile = Join-Path $env:TEMP "wg_audio_visualizer_preprocessed.hlsl"
    Set-Content -Path $tempFile -Value $preprocessed -Encoding UTF8
    
    $wgArgs = @("-E", "main", "-T", "lib_6_6", "-D", "DX12U=1", "-Qstrip_reflect", "-Qstrip_debug", "-HV", "2021", "-O3")
    $args = @($tempFile) + $wgArgs + @("-Fo", $outFile)
    & $dxcPath @args 2>&1 | ForEach-Object {
        if ($_ -match "error") { Write-Host "[compile_shaders] ERROR $($_)" -ForegroundColor Red }
    }
    
    if (Test-Path $outFile) {
        Write-Host "[compile_shaders] Compiled WG wg_audio_visualizer.hlsl" -ForegroundColor Green
        $compiled++
    } else {
        Write-Host "[compile_shaders] FAILED to compile WG (non-fatal)" -ForegroundColor Yellow
    }
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
}

Write-Host "[compile_shaders] Done: $compiled compiled, $failed failed" -ForegroundColor Cyan

# Remove the marker if it exists (DXC was found)
$marker = Join-Path $OutDir "_NO_DXC.marker"
if (Test-Path $marker) { Remove-Item $marker -Force }

if ($failed -gt 0) {
    Write-Host "[compile_shaders] $failed shader(s) failed to compile (non-critical — compute/WG shaders may not be used)" -ForegroundColor Yellow
}

exit 0
