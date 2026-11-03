<#
.SYNOPSIS
    Builds a distributable ZIP of the translation installer.

.DESCRIPTION
    Collects the installer scripts, payload and runtime files into a staging
    folder, removes machine-specific artifacts (.venv, logs, pid markers) and
    produces 05_release\Nobody_RU_v<version>.zip with a SHA-256 checksum file.

.EXAMPLE
    .\build_release.ps1
#>
[CmdletBinding()]
param(
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$version = (Get-Content -LiteralPath (Join-Path $here 'VERSION') -Raw).Trim()
if (-not $OutDir) { $OutDir = Join-Path $root '05_release' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$stage = Join-Path $env:TEMP ("nobody_ru_stage_" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Write-Host "Staging $version ..." -ForegroundColor Cyan
$excludeDirs  = @('.venv', '__pycache__')
$excludeFiles = @('_watcher_safe.log', '_watcher.log', '_patched_pid.txt', '*.bak')

function Copy-Tree([string]$Src, [string]$Dst) {
    New-Item -ItemType Directory -Path $Dst -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Src -Force) {
        if ($item.PSIsContainer) {
            if ($excludeDirs -contains $item.Name) { continue }
            Copy-Tree $item.FullName (Join-Path $Dst $item.Name)
        } else {
            $skip = $false
            foreach ($pat in $excludeFiles) { if ($item.Name -like $pat) { $skip = $true; break } }
            if (-not $skip) { Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Dst $item.Name) -Force }
        }
    }
}

Copy-Tree $here $stage

$zip = Join-Path $OutDir ("Nobody_RU_v{0}.zip" -f $version)
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Write-Host 'Compressing ...' -ForegroundColor Cyan
# Compress-Archive and ZipFile.CreateFromDirectory on .NET Framework write entry
# names with backslashes, which is not spec-compliant (Linux/macOS extractors then
# create files literally named "payload\x.bundle"). Write entries explicitly with
# forward slashes instead.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-ZipFromDirectory([string]$SourceDir, [string]$ZipPath) {
    $baseLen = $SourceDir.TrimEnd('\').Length + 1
    $fs = [IO.File]::Open($ZipPath, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite)
    try {
        $archive = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in (Get-ChildItem -LiteralPath $SourceDir -Recurse -File -Force)) {
                $rel = $file.FullName.Substring($baseLen).Replace('\', '/')
                $entry = $archive.CreateEntry($rel, [IO.Compression.CompressionLevel]::Optimal)
                $out = $entry.Open()
                try {
                    $in = [IO.File]::OpenRead($file.FullName)
                    try { $in.CopyTo($out) } finally { $in.Dispose() }
                } finally { $out.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $fs.Dispose() }
}

New-ZipFromDirectory $stage $zip
Remove-Item -LiteralPath $stage -Recurse -Force

$sizeMb = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)
$hash   = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
Set-Content -LiteralPath ($zip + '.sha256') -Encoding ASCII -Value "$hash  $(Split-Path -Leaf $zip)"

Write-Host ''
Write-Host "Built: $zip" -ForegroundColor Green
Write-Host "Size : $sizeMb MB" -ForegroundColor Green
Write-Host "SHA256: $hash" -ForegroundColor DarkGray
