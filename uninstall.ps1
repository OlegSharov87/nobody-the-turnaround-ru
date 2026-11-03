<#
.SYNOPSIS
    Restores the original Nobody - The Turnaround files (removes the translation).

.PARAMETER GamePath
    Path to the game root folder. Auto-detected if omitted.

.PARAMETER BackupDir
    Restore from a specific backup folder instead of the newest one.

.PARAMETER Purge
    Delete the backup folder after a successful restore.

.PARAMETER RuntimeDir
    Runtime component folder, if it was installed somewhere else than %LOCALAPPDATA%\NobodyRU.

.PARAMETER ShortcutDir
    Shortcut folder, if the shortcut was created somewhere else than the desktop.

.EXAMPLE
    .\uninstall.ps1
.EXAMPLE
    .\uninstall.ps1 -Purge
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [string]$BackupDir,
    [switch]$Purge,
    [string]$RuntimeDir,
    [string]$ShortcutDir
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundleRel = 'Nobody_Data\StreamingAssets\aa\Windows\StandaloneWindows64'

function Write-Step([string]$T) { Write-Host "==> $T" -ForegroundColor Cyan }
function Write-Ok([string]$T)   { Write-Host "    $T" -ForegroundColor Green }
function Write-Warn2([string]$T){ Write-Host "    $T" -ForegroundColor Yellow }
function Write-Err2([string]$T) { Write-Host "    $T" -ForegroundColor Red }

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
            if ($m.Success) {
                $lib = $m.Groups[1].Value -replace '\\\\', '\'
                if ($libs -notcontains $lib) { $libs.Add($lib) }
            }
        }
    }
    return $libs
}

function Find-Game {
    foreach ($lib in (Get-SteamLibraries)) {
        $c = Join-Path $lib 'steamapps\common\Nobody - The Turnaround'
        if (Test-GameDir $c) { return $c }
    }
    foreach ($c in @('C:\Games\Nobody - The Turnaround','D:\Games\Nobody - The Turnaround',
                     'C:\Program Files (x86)\Steam\steamapps\common\Nobody - The Turnaround')) {
        if (Test-GameDir $c) { return $c }
    }
    return $null
}

function Get-Dest($Entry) {
    # Most payload files live next to the bundles; an entry with "dest" (for example
    # catalog.json, one level up) names its target relative to the bundle folder.
    if ($Entry.dest) { return [IO.Path]::GetFullPath((Join-Path $bundleDir $Entry.dest)) }
    return (Join-Path $bundleDir $Entry.file)
}

Write-Host ''
Write-Host '  Nobody - The Turnaround  |  Russian translation uninstaller' -ForegroundColor White
Write-Host '  ---------------------------------------------------------' -ForegroundColor DarkGray

Write-Step 'Looking for the game'
if ($GamePath) { $GamePath = (Resolve-Path -LiteralPath $GamePath -ErrorAction SilentlyContinue).Path }
if (-not $GamePath) { $GamePath = Find-Game }
if (-not $GamePath -or -not (Test-GameDir $GamePath)) {
    Write-Err2 'Game folder not found. Pass -GamePath "C:\path\to\Nobody - The Turnaround"'
    exit 2
}
Write-Ok "Game: $GamePath"
$bundleDir = Join-Path $GamePath $bundleRel

if (@(Get-Process -Name 'Nobody' -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Err2 'The game is running. Close it first.'
    exit 4
}

Write-Step 'Looking for backups'
# A backup folder may be partial (for example created by verify.ps1 -Fix), so the
# uninstaller merges all _RU_BACKUP_* folders, newest first, and restores every
# file exactly once from the newest backup that contains it.
if ($BackupDir) {
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        Write-Err2 "Backup folder not found: $BackupDir"
        exit 3
    }
    $backups = @(Get-Item -LiteralPath $BackupDir)
} else {
    $backups = @(Get-ChildItem -LiteralPath $bundleDir -Directory -Filter '_RU_BACKUP_*' -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending)
}
if ($backups.Count -eq 0) {
    Write-Err2 'No _RU_BACKUP_* folder found. Nothing to restore.'
    exit 3
}
Write-Ok ("Found {0} backup folder(s); newest: {1}" -f $backups.Count, (Split-Path -Leaf $backups[0].FullName))

Write-Step 'Restoring original files'
$manifestFiles = @()
$manifestFile = Join-Path $scriptDir 'payload\manifest.json'
if (Test-Path -LiteralPath $manifestFile) {
    $manifestFiles = @((Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json).files)
}
$restored = @{}
foreach ($b in $backups) {
    foreach ($f in (Get-ChildItem -LiteralPath $b.FullName -File | Where-Object { $_.Name -notlike '_backup_info.txt' })) {
        if ($restored.ContainsKey($f.Name)) { continue }
        $entry = $manifestFiles | Where-Object { $_.file -eq $f.Name } | Select-Object -First 1
        $dest = if ($entry) { Get-Dest $entry } else { Join-Path $bundleDir $f.Name }
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        $restored[$f.Name] = $true
    }
}
Write-Ok ("{0} file(s) restored" -f $restored.Count)

# Report payload files that were never backed up (cannot be restored automatically).
$manifestPath = Join-Path $scriptDir 'payload\manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    $man = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $notRestored = @($man.files | Where-Object { -not $restored.ContainsKey($_.file) })
    if ($notRestored.Count -gt 0) {
        Write-Warn2 ("{0} translated file(s) had no original backup and stay in place:" -f $notRestored.Count)
        foreach ($f in $notRestored) { Write-Warn2 ("  " + $f.file) }
        Write-Warn2 'Re-run the game through Steam "Verify integrity of game files" to restore them.'
    }
}

Write-Step 'Removing the runtime translator and its shortcut'
$rtArgs = @{ Remove = $true }
if ($RuntimeDir)  { $rtArgs.InstallDir  = $RuntimeDir }
if ($ShortcutDir) { $rtArgs.ShortcutDir = $ShortcutDir }
& (Join-Path $scriptDir 'runtime\install_runtime.ps1') @rtArgs

if ($Purge) {
    $removed = 0
    foreach ($b in $backups) {
        Remove-Item -LiteralPath $b.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $removed++
    }
    # Repair folders are created by verify.ps1 -Fix and only hold broken copies.
    foreach ($r in @(Get-ChildItem -LiteralPath $bundleDir -Directory -Filter '_RU_REPAIR_*' -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $r.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $removed++
    }
    Write-Ok ("Backup/repair folder(s) deleted: {0}" -f $removed)
}

Write-Host ''
Write-Host '  Done. The game is back to its original state.' -ForegroundColor Green
Write-Host ''
