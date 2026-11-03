<#
.SYNOPSIS
    Nobody - The Turnaround : Russian UI translation installer.

.DESCRIPTION
    Installs the Russian translation payload (patched Unity bundles) into the game.
    Original files are backed up to a timestamped folder inside the bundle directory,
    so the process is fully reversible with uninstall.ps1.

.PARAMETER GamePath
    Path to the game root folder (the one containing Nobody.exe).
    If omitted, the installer tries Steam libraries and common locations.

.PARAMETER DryRun
    Show what would be done without changing any file.

.PARAMETER NoBackup
    Do not create a backup of the original bundles (NOT recommended).

.PARAMETER NoRuntime
    Do not install the runtime dictionary component. By default it is installed:
    it translates text the game loads at runtime (main menu, tabs, food, quests)
    and creates the desktop shortcut "Nobody (русский)" that starts the game with it.

.PARAMETER WithRuntime
    Accepted for compatibility with v1.0.0; the runtime is installed by default now.

.PARAMETER RuntimeDir
    Where to install the runtime component (default: %LOCALAPPDATA%\NobodyRU).

.PARAMETER ShortcutDir
    Where to create the shortcut (default: the desktop).

.PARAMETER Force
    Continue even if the game is currently running.

.PARAMETER IgnoreVersion
    Install even if a game bundle is neither the known original nor the translated
    version (for example, after a game update). The game may fail to start;
    keep the backup and use uninstall.ps1 to roll back.

.EXAMPLE
    .\install.ps1 -DryRun
.EXAMPLE
    .\install.ps1 -NoRuntime
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [switch]$DryRun,
    [switch]$NoBackup,
    [switch]$NoRuntime,
    [switch]$WithRuntime,
    [switch]$Force,
    [switch]$IgnoreVersion,
    [string]$RuntimeDir,
    [string]$ShortcutDir
)

$ErrorActionPreference = 'Stop'
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$payloadDir  = Join-Path $scriptDir 'payload'
$manifestPath= Join-Path $payloadDir 'manifest.json'
$bundleRel   = 'Nobody_Data\StreamingAssets\aa\Windows\StandaloneWindows64'

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host "    $Text" -ForegroundColor Yellow }
function Write-Err2([string]$Text) { Write-Host "    $Text" -ForegroundColor Red }

function Test-GameDir([string]$Dir) {
    if (-not $Dir) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Dir 'Nobody.exe'))) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Dir $bundleRel))) { return $false }
    return $true
}

function Get-SteamLibraries {
    $libs = New-Object System.Collections.Generic.List[string]
    $steam = $null
    try {
        $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
    } catch { }
    if (-not $steam) {
        foreach ($p in @('C:\Program Files (x86)\Steam', 'C:\Program Files\Steam')) {
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
    foreach ($c in @(
        'C:\Games\Nobody - The Turnaround',
        'D:\Games\Nobody - The Turnaround',
        'C:\Program Files (x86)\Steam\steamapps\common\Nobody - The Turnaround',
        'C:\Program Files\Steam\steamapps\common\Nobody - The Turnaround'
    )) {
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

function Install-Runtime {
    if ($NoRuntime) { return }
    Write-Step 'Installing the runtime dictionary and the desktop shortcut'
    $rtArgs = @{ GamePath = $GamePath }
    if ($RuntimeDir)  { $rtArgs.InstallDir  = $RuntimeDir }
    if ($ShortcutDir) { $rtArgs.ShortcutDir = $ShortcutDir }
    & (Join-Path $scriptDir 'runtime\install_runtime.ps1') @rtArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 'The runtime component was not installed. The translation in the game files'
        Write-Warn2 'works without it, but the main menu and some tabs stay in English.'
        exit 8
    }
}

function Get-GameProcess {
    try {
        return @(Get-Process -Name 'Nobody' -ErrorAction SilentlyContinue)
    } catch { return @() }
}

Write-Host ''
Write-Host '  Nobody - The Turnaround  |  Russian translation installer' -ForegroundColor White
Write-Host '  ---------------------------------------------------------------' -ForegroundColor DarkGray

# --- 1. resolve game path -------------------------------------------------
Write-Step 'Looking for the game'
if ($GamePath) {
    $GamePath = (Resolve-Path -LiteralPath $GamePath -ErrorAction SilentlyContinue).Path
}
if (-not $GamePath) { $GamePath = Find-Game }

if (-not $GamePath -or -not (Test-GameDir $GamePath)) {
    Write-Err2 'Game folder not found (Nobody.exe + Nobody_Data expected).'
    Write-Host ''
    Write-Host '  Pass the path explicitly, for example:' -ForegroundColor Yellow
    Write-Host '    .\install.ps1 -GamePath "C:\Games\Nobody - The Turnaround"' -ForegroundColor Yellow
    exit 2
}
Write-Ok "Game: $GamePath"
$bundleDir = Join-Path $GamePath $bundleRel

# --- 2. sanity checks -----------------------------------------------------
Write-Step 'Checking prerequisites'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Err2 "Payload manifest not found: $manifestPath"
    exit 3
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $manifest.files -or $manifest.files.Count -eq 0) {
    Write-Err2 'Payload manifest is empty.'
    exit 3
}
Write-Ok ("Payload v{0}: {1} bundle(s), {2:N1} MB" -f $manifest.version, $manifest.files.Count,
          (($manifest.files | Measure-Object -Property size -Sum).Sum / 1MB))

$procs = Get-GameProcess
if ($procs.Count -gt 0) {
    if ($Force) {
        Write-Warn2 'The game is running. Continuing because -Force was given.'
    } else {
        Write-Err2 'The game is running. Close it and run the installer again (or use -Force).'
        exit 4
    }
}
Write-Ok 'The game is not running'

$missing = @()
foreach ($f in $manifest.files) {
    if (-not (Test-Path -LiteralPath (Join-Path $payloadDir $f.file))) { $missing += $f.file }
}
if ($missing.Count -gt 0) {
    Write-Err2 ('Missing payload files: ' + ($missing -join ', '))
    exit 5
}
Write-Ok 'All payload files are present'

# --- 3. plan --------------------------------------------------------------
Write-Step 'Planning changes'
$toCopy = @()
$already = @()
$unknown = @()
foreach ($f in $manifest.files) {
    $dst = Get-Dest $f
    if (-not (Test-Path -LiteralPath $dst)) { $unknown += $f.file; $toCopy += $f; continue }
    $h = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLower()
    if ($h -eq $f.sha256.ToLower()) { $already += $f.file; continue }
    if ($f.orig_sha256 -and $h -ne $f.orig_sha256.ToLower()) { $unknown += $f.file }
    $toCopy += $f
}
Write-Ok ("To install: {0} file(s); already translated: {1}" -f $toCopy.Count, $already.Count)

if ($unknown.Count -gt 0) {
    Write-Warn2 ("{0} game file(s) do not match the game version this translation was made for:" -f $unknown.Count)
    foreach ($u in $unknown) { Write-Warn2 "    $u" }
    if (-not $IgnoreVersion) {
        Write-Err2 'Installation stopped: the game was probably updated, or files were modified by another mod.'
        Write-Err2 'Verify the game files in Steam and run the installer again,'
        Write-Err2 'or use -IgnoreVersion at your own risk (a backup is still created).'
        exit 7
    }
    Write-Warn2 'Continuing because -IgnoreVersion was given.'
}

if ($toCopy.Count -eq 0) {
    Write-Host ''
    Write-Host '  The translated game files are already installed.' -ForegroundColor Green
    if ($DryRun) {
        if (-not $NoRuntime) { Write-Host '    would (re)install the runtime component and the shortcut' }
        exit 0
    }
    Install-Runtime
    exit 0
}

$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $bundleDir "_RU_BACKUP_$stamp"

if ($DryRun) {
    Write-Host ''
    Write-Host '  DRY RUN - no files will be changed' -ForegroundColor Yellow
    foreach ($f in $toCopy) { Write-Host ("    would install  {0}  ({1:N1} MB)" -f $f.file, ($f.size / 1MB)) }
    if (-not $NoBackup) { Write-Host ("    would back up to {0}" -f $backupDir) }
    if (-not $NoRuntime) { Write-Host '    would install the runtime component and the desktop shortcut' }
    exit 0
}

# --- 4. backup ------------------------------------------------------------
if (-not $NoBackup) {
    Write-Step "Backing up originals to $backupDir"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $n = 0
    foreach ($f in $toCopy) {
        $dst = Get-Dest $f
        if (Test-Path -LiteralPath $dst) {
            Copy-Item -LiteralPath $dst -Destination (Join-Path $backupDir $f.file) -Force
            $n++
        }
    }
    Set-Content -LiteralPath (Join-Path $backupDir '_backup_info.txt') -Encoding UTF8 -Value @(
        "Nobody RU translation backup",
        "Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Game: $GamePath",
        "Files: $n"
    )
    Write-Ok "$n file(s) backed up"
} else {
    Write-Warn2 'Backup disabled (-NoBackup). Uninstall will not be possible for these files.'
}

# --- 5. copy payload ------------------------------------------------------
Write-Step 'Installing translation files'
$done = 0
foreach ($f in $toCopy) {
    $src = Join-Path $payloadDir $f.file
    $dst = Get-Dest $f
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $done++
    Write-Progress -Activity 'Installing translation' -Status $f.file -PercentComplete (($done / $toCopy.Count) * 100)
}
Write-Progress -Activity 'Installing translation' -Completed
Write-Ok "$done file(s) installed"

# --- 6. verify ------------------------------------------------------------
Write-Step 'Verifying installed files'
$bad = 0
foreach ($f in $toCopy) {
    $dst = Get-Dest $f
    $h = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $f.sha256.ToLower()) { Write-Err2 "hash mismatch: $($f.file)"; $bad++ }
}
if ($bad -gt 0) { Write-Err2 "$bad file(s) failed verification"; exit 6 }
Write-Ok 'All installed files match the manifest'

# --- 7. runtime dictionary + shortcut -------------------------------------
Install-Runtime

Write-Host ''
if ($NoRuntime) {
    Write-Host '  Done. Start the game as usual.' -ForegroundColor Green
} else {
    Write-Host '  Done. Start the game with the "Nobody (русский)" shortcut on the desktop.' -ForegroundColor Green
}
if (-not $NoBackup) {
    Write-Host "  To roll back:  .\uninstall.ps1 -GamePath `"$GamePath`"" -ForegroundColor DarkGray
}
Write-Host ''
