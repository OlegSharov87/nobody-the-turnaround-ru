<#
.SYNOPSIS
    Checks whether the Russian translation is correctly installed.

.PARAMETER GamePath
    Path to the game root folder. Auto-detected if omitted.

.PARAMETER Fix
    Re-copy any file that does not match the payload manifest.

.EXAMPLE
    .\verify.ps1
.EXAMPLE
    .\verify.ps1 -Fix
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [switch]$Fix
)

$ErrorActionPreference = 'Stop'
$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$payloadDir   = Join-Path $scriptDir 'payload'
$manifestPath = Join-Path $payloadDir 'manifest.json'
$bundleRel    = 'Nobody_Data\StreamingAssets\aa\Windows\StandaloneWindows64'

function Test-GameDir([string]$Dir) {
    if (-not $Dir) { return $false }
    return ((Test-Path -LiteralPath (Join-Path $Dir 'Nobody.exe')) -and
            (Test-Path -LiteralPath (Join-Path $Dir $bundleRel)))
}

function Get-SteamLibraries {
    $libs = New-Object System.Collections.Generic.List[string]
    $steam = $null
    try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath } catch { }
    if (-not $steam) {
        foreach ($p in @('C:\Program Files (x86)\Steam','C:\Program Files\Steam')) {
            if (Test-Path -LiteralPath $p) { $steam = $p; break }
        }
    }
    if (-not $steam) { return $libs }
    $libs.Add($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        foreach ($line in Get-Content -LiteralPath $vdf -Encoding UTF8) {
            $m = [regex]::Match($line, '"path"\s+"([^"]+)"')
            if ($m.Success) { $libs.Add(($m.Groups[1].Value -replace '\\\\','\')) }
        }
    }
    return $libs
}

if (-not $GamePath) {
    foreach ($lib in (Get-SteamLibraries)) {
        $c = Join-Path $lib 'steamapps\common\Nobody - The Turnaround'
        if (Test-GameDir $c) { $GamePath = $c; break }
    }
}
if (-not $GamePath) {
    foreach ($c in @('C:\Games\Nobody - The Turnaround','D:\Games\Nobody - The Turnaround')) {
        if (Test-GameDir $c) { $GamePath = $c; break }
    }
}
if (-not $GamePath -or -not (Test-GameDir $GamePath)) {
    Write-Host 'Game folder not found. Pass -GamePath "..."' -ForegroundColor Red
    exit 2
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$bundleDir = Join-Path $GamePath $bundleRel

Write-Host ''
Write-Host "Game: $GamePath" -ForegroundColor White
Write-Host "Payload: v$($manifest.version), $($manifest.files.Count) file(s)" -ForegroundColor DarkGray
Write-Host ''

function Get-Dest($Entry) {
    # Most payload files live next to the bundles; an entry with "dest" (for example
    # catalog.json, one level up) names its target relative to the bundle folder.
    if ($Entry.dest) { return [IO.Path]::GetFullPath((Join-Path $bundleDir $Entry.dest)) }
    return (Join-Path $bundleDir $Entry.file)
}

$ok = 0; $mismatch = @(); $absent = @()
foreach ($f in $manifest.files) {
    $dst = Get-Dest $f
    if (-not (Test-Path -LiteralPath $dst)) { $absent += $f.file; continue }
    $h = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLower()
    if ($h -eq $f.sha256.ToLower()) { $ok++ } else { $mismatch += $f.file }
}

Write-Host ("Installed and correct : {0}" -f $ok) -ForegroundColor Green
if ($mismatch.Count) { Write-Host ("Different             : {0}" -f $mismatch.Count) -ForegroundColor Yellow }
if ($absent.Count)   { Write-Host ("Missing               : {0}" -f $absent.Count) -ForegroundColor Red }

foreach ($n in $mismatch) { Write-Host "  differs: $n" -ForegroundColor Yellow }
foreach ($n in $absent)   { Write-Host "  missing: $n" -ForegroundColor Red }

if ($Fix -and ($mismatch.Count + $absent.Count) -gt 0) {
    if (@(Get-Process -Name 'Nobody' -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Host ''
        Write-Host 'The game is running. Close it before repairing.' -ForegroundColor Red
        exit 4
    }
    Write-Host ''
    Write-Host 'Repairing...' -ForegroundColor Cyan
    # Repair backups are kept apart from _RU_BACKUP_* on purpose: they contain the
    # broken/translated file, not the original, so uninstall must never use them.
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $bundleDir "_RU_REPAIR_$stamp"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($n in ($mismatch + $absent)) {
        $dst = Get-Dest ($manifest.files | Where-Object { $_.file -eq $n } | Select-Object -First 1)
        if (Test-Path -LiteralPath $dst) { Copy-Item -LiteralPath $dst -Destination (Join-Path $backup $n) -Force }
        Copy-Item -LiteralPath (Join-Path $payloadDir $n) -Destination $dst -Force
    }
    Write-Host ("Repaired {0} file(s). Backup: {1}" -f ($mismatch.Count + $absent.Count), $backup) -ForegroundColor Green
    exit 0
}

if (($mismatch.Count + $absent.Count) -eq 0) {
    Write-Host ''
    Write-Host 'The translation is installed correctly.' -ForegroundColor Green
    exit 0
}
Write-Host ''
Write-Host 'Run with -Fix to repair, or re-run install.ps1.' -ForegroundColor Yellow
exit 1
