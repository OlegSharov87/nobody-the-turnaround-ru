<#
.SYNOPSIS
    Builds the portable Python + Frida runtime that ships inside the release.

.DESCRIPTION
    Developer-side step, run before build_release.ps1. Downloads the official
    Python embeddable package (python.org) and the Frida wheel (PyPI), checks
    their SHA-256 against the pinned values below and unpacks them into
    runtime\python. End users therefore do not need Python installed.

.PARAMETER CacheDir
    Folder for the downloaded files. Files already present there are reused.

.EXAMPLE
    .\prepare_runtime.ps1
#>
[CmdletBinding()]
param(
    [string]$CacheDir = (Join-Path $env:TEMP 'nobody_ru_runtime_cache')
)

$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $here 'runtime\python'

$downloads = @(
    @{ Name   = 'python-3.12.10-embed-amd64.zip'
       Url    = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip'
       Sha256 = '4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3' },
    @{ Name   = 'frida-17.17.0-cp37-abi3-win_amd64.whl'
       Url    = 'https://files.pythonhosted.org/packages/cp37/f/frida/frida-17.17.0-cp37-abi3-win_amd64.whl'
       Sha256 = 'f9c3d431144d143d5eaf6830f0b85042c34517f63b2cf0e83aaa5e2ba4b636dd' }
)

New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'  # the PS 5.1 progress bar slows downloads 10x

foreach ($d in $downloads) {
    $file = Join-Path $CacheDir $d.Name
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Host "Downloading $($d.Name) ..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $d.Url -OutFile $file -UseBasicParsing
    }
    $h = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $d.Sha256) {
        throw "SHA-256 mismatch for $($d.Name): got $h, expected $($d.Sha256). Delete the file and retry."
    }
    $d.Path = $file
}

if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
New-Item -ItemType Directory -Path $target -Force | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem
Write-Host 'Unpacking Python ...' -ForegroundColor Cyan
[IO.Compression.ZipFile]::ExtractToDirectory($downloads[0].Path, $target)

# A wheel is a plain zip; unpacking it into site-packages is what pip would do.
$site = Join-Path $target 'Lib\site-packages'
New-Item -ItemType Directory -Path $site -Force | Out-Null
Write-Host 'Unpacking Frida ...' -ForegroundColor Cyan
[IO.Compression.ZipFile]::ExtractToDirectory($downloads[1].Path, $site)

# The embeddable package ignores site-packages unless it is listed in the ._pth file.
$pth = Get-ChildItem -LiteralPath $target -Filter 'python*._pth' | Select-Object -First 1
Add-Content -LiteralPath $pth.FullName -Value 'Lib\site-packages' -Encoding ASCII

$check = & (Join-Path $target 'python.exe') -c "import frida; print(frida.__version__, hasattr(frida, 'attach'))"
if ($LASTEXITCODE -ne 0 -or $check -notmatch '^17\.17\.0 True$') { throw "Runtime self-test failed: $check" }

$mb = [math]::Round(((Get-ChildItem -LiteralPath $target -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB, 1)
Write-Host "Runtime ready: $target ($mb MB, frida $check)" -ForegroundColor Green
