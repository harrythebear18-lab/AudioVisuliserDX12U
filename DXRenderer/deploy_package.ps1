# deploy_package.ps1 — Build and package RTX Audio Visualizer for Visentrix website distribution
# Produces a self-contained zip with no .hlsl source files, no .pdb symbols
# Usage: powershell -File deploy_package.ps1

param(
    [string]$Version = "1.0.0",
    [string]$OutputDir = "dist"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $projectRoot "DXRenderer\DXRenderer.csproj"
$packageName = "RTXAudioVisualizer_v$Version"
$packageDir = Join-Path $projectRoot $OutputDir $packageName

Write-Host "[deploy] Building RTX Audio Visualizer v$Version..." -ForegroundColor Cyan

# Clean previous package
if (Test-Path $packageDir) { Remove-Item $packageDir -Recurse -Force }
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null

# Publish self-contained (includes .NET runtime, no separate install needed)
Write-Host "[deploy] Publishing self-contained build..." -ForegroundColor Yellow
$publishDir = Join-Path $projectRoot "DXRenderer\bin\Release\net10.0-windows10.0.26100.0\publish"
dotnet publish $projectPath -c Release -r win-x64 --self-contained true -o $publishDir 2>&1 | Select-String "error|warning|Build succeeded"

if (!$?) {
    Write-Host "[deploy] Build FAILED!" -ForegroundColor Red
    exit 1
}

Write-Host "[deploy] Packaging files (excluding source, symbols, shaders)..." -ForegroundColor Yellow

# Copy only the files needed to run — no .hlsl, no .pdb, no source
$allowedExtensions = @(".exe", ".dll", ".json", ".xml")
$allowedFiles = @("WASAPINative.dll")

Get-ChildItem -Path $publishDir -Recurse -File | Where-Object {
    $ext = $_.Extension.ToLower()
    $name = $_.Name
    # Include allowed extensions, exclude .pdb, .hlsl, .cs, .dxbc (already embedded)
    ($allowedExtensions -contains $ext -or $allowedFiles -contains $name) -and
    $ext -ne ".pdb" -and $ext -ne ".hlsl" -and $ext -ne ".cs" -and $ext -ne ".dxbc"
} | ForEach-Object {
    $relPath = $_.FullName.Substring($publishDir.Length + 1)
    $destPath = Join-Path $packageDir $relPath
    $destDir = Split-Path -Parent $destPath
    if (!(Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item $_.FullName $destPath -Force
}

# Copy native DLL
$nativeDll = Join-Path $projectRoot "native\WASAPINative.dll"
if (Test-Path $nativeDll) {
    Copy-Item $nativeDll $packageDir -Force
    Write-Host "[deploy] Included WASAPINative.dll" -ForegroundColor Green
}

# Copy policy documents
$policyFiles = @(
    @{Src = Join-Path $projectRoot "SOFTWARE_POLICY.md"; Dst = "SOFTWARE_POLICY.txt"},
    @{Src = Join-Path $projectRoot "MODULAR_ARCHITECTURE.md"; Dst = "ARCHITECTURE.txt"}
)

foreach ($pf in $policyFiles) {
    if (Test-Path $pf.Src) {
        Copy-Item $pf.Src (Join-Path $packageDir $pf.Dst) -Force
        Write-Host "[deploy] Included $($pf.Dst)" -ForegroundColor Green
    }
}

# Create README
$readmeContent = @"
RTX Audio Visualizer (DX12 Ultimate) v$Version
Visentrix Product

INSTALLATION:
1. Extract this zip to any folder
2. Run DXRenderer.exe
3. No additional installation required — .NET runtime is included

USAGE:
- The application captures system audio and renders real-time visualizations
- Use number keys (1-5, then Q-Z for modes 6-54) to switch visualization modes
- Press H to toggle HUD
- Press O to toggle overlay
- Press A to toggle auto-mode switching
- Press G to toggle bloom
- Press K to toggle pipeline validator
- Press ESC to exit

SYSTEM REQUIREMENTS:
- Windows 10/11 (build 26100+)
- DirectX 12 Ultimate compatible GPU (NVIDIA RTX, AMD RDNA2+, Intel Arc)
- 8GB RAM minimum
- Audio output device (for loopback capture)

LICENSE:
This software is free to use for personal, educational, and commercial purposes.
No republishing, decompiling, or reverse engineering permitted.
See SOFTWARE_POLICY.txt for full terms.

© 2026 Visentrix. All rights reserved.
"@

Set-Content -Path (Join-Path $packageDir "README.txt") -Value $readmeContent -Encoding UTF8
Write-Host "[deploy] Created README.txt" -ForegroundColor Green

# Create zip
$zipPath = Join-Path $projectRoot $OutputDir "$packageName.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $packageDir "*") -DestinationPath $zipPath -CompressionLevel Optimal

$zipSize = (Get-Item $zipPath).Length / 1MB
Write-Host "[deploy] Package created: $zipPath ($('{0:N1}' -f $zipSize) MB)" -ForegroundColor Green

# List contents summary
$fileCount = (Get-ChildItem -Path $packageDir -Recurse -File).Count
Write-Host "[deploy] Package contents: $fileCount files" -ForegroundColor Cyan
Write-Host "[deploy] Done!" -ForegroundColor Green
