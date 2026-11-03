<#
.SYNOPSIS
    Installs the runtime dictionary component of the Nobody RU translation.

.DESCRIPTION
    Part of the in-game text (main menu, tabs, food, quests, stats) is not stored in
    bundles but comes from an encrypted dictionary loaded at runtime. This component
    replaces those strings in the game's memory (via Frida) while the game runs.

    Everything needed ships with the package (portable Python + Frida), nothing is
    downloaded and Python does not have to be installed. The component is copied to
    %LOCALAPPDATA%\NobodyRU and a desktop shortcut "Nobody (русский)" is created.
    The shortcut starts the game together with the translator; the translator exits
    when the game closes. No autostart entry, no background process.

.PARAMETER GamePath
    Game root folder (contains Nobody.exe). Required unless -Remove is used.

.PARAMETER Remove
    Remove the component, its shortcut and the v1.0.0 autostart entry.

.PARAMETER InstallDir
    Where to put the component. Default: %LOCALAPPDATA%\NobodyRU.

.PARAMETER ShortcutDir
    Where to create the shortcut. Default: the user's desktop.
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [switch]$Remove,
    [string]$InstallDir  = (Join-Path $env:LOCALAPPDATA 'NobodyRU'),
    [string]$ShortcutDir = [Environment]::GetFolderPath('Desktop')
)

$ErrorActionPreference = 'Stop'
$here         = Split-Path -Parent $MyInvocation.MyCommand.Path
$shortcutPath = Join-Path $ShortcutDir 'Nobody (русский).lnk'
$legacyVbs    = Join-Path ([Environment]::GetFolderPath('Startup')) 'NobodyRU-watcher.vbs'
$files        = @('nobody_translator_safe_watcher.pyw', 'cn_ru_glossary.json')

function Stop-Translator {
    # Only processes started from our own install folder.
    $marker = $InstallDir.ToLower()
    $k = 0
    try {
        foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue)) {
            if ($p.ExecutablePath -and $p.ExecutablePath.ToLower().StartsWith($marker)) {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $k++
            }
        }
    } catch { }
    if ($k -gt 0) { Start-Sleep -Milliseconds 500 }
    return $k
}

function Remove-Legacy {
    if (Test-Path -LiteralPath $legacyVbs) {
        Remove-Item -LiteralPath $legacyVbs -Force
        Write-Host '    v1.0.0 autostart entry removed' -ForegroundColor Green
    }
}

if ($Remove) {
    $n = Stop-Translator
    if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
    if (Test-Path -LiteralPath $InstallDir)   { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
    Remove-Legacy
    Write-Host "Runtime component removed (stopped $n process(es))." -ForegroundColor Green
    exit 0
}

$gameExe = if ($GamePath) { Join-Path $GamePath 'Nobody.exe' } else { $null }
if (-not $gameExe -or -not (Test-Path -LiteralPath $gameExe)) {
    Write-Host 'Pass the game folder: install_runtime.ps1 -GamePath "C:\...\Nobody - The Turnaround"' -ForegroundColor Red
    exit 2
}
$srcPython = Join-Path $here 'python'
if (-not (Test-Path -LiteralPath (Join-Path $srcPython 'pythonw.exe'))) {
    Write-Host 'The package is incomplete: runtime\python is missing. Download the release ZIP again.' -ForegroundColor Red
    exit 3
}

Write-Host "==> Copying the translator to $InstallDir" -ForegroundColor Cyan
Stop-Translator | Out-Null
if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item -LiteralPath $srcPython -Destination (Join-Path $InstallDir 'python') -Recurse
foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $here $f) -Destination $InstallDir }

$py = Join-Path $InstallDir 'python\python.exe'
$check = & $py -c "import frida; print('ok')" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Self-test failed: $check" -ForegroundColor Red
    Write-Host 'An antivirus may have blocked frida. See README, section "Antivirus".' -ForegroundColor Yellow
    exit 4
}

Write-Host '==> Creating the shortcut' -ForegroundColor Cyan
New-Item -ItemType Directory -Path $ShortcutDir -Force | Out-Null
$sh  = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut($shortcutPath)
$lnk.TargetPath       = Join-Path $InstallDir 'python\pythonw.exe'
$lnk.Arguments        = ('"{0}" --launch "{1}"' -f (Join-Path $InstallDir $files[0]), $gameExe)
$lnk.WorkingDirectory = $InstallDir
$lnk.IconLocation     = "$gameExe,0"
$lnk.Description      = 'Nobody - The Turnaround with the Russian translation'
$lnk.Save()
Write-Host "    $shortcutPath" -ForegroundColor Green

Remove-Legacy

Write-Host ''
Write-Host 'Runtime component installed. Start the game with the "Nobody (русский)"' -ForegroundColor Green
Write-Host 'shortcut on the desktop; the translator closes together with the game.' -ForegroundColor Green
Write-Host "Log: $(Join-Path $InstallDir '_watcher_safe.log')" -ForegroundColor DarkGray
