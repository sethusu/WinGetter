<#
.SYNOPSIS
    Builds a double-clickable Wingetter.exe with ps2exe and stages a distributable folder.
.DESCRIPTION
    Installs the ps2exe PowerShell Gallery module if needed, copies Wingetter runtime
    files into dist\Wingetter, and compiles Launch-Wingetter.ps1 to Wingetter.exe
    (no console window). Run this on Windows with PowerShell 5.1+.

    The resulting folder can be zipped and shared. End users double-click Wingetter.exe
    — no elevated PowerShell session required.
.PARAMETER OutputRoot
    Root folder for the staged build. Defaults to <repo>\dist.
.PARAMETER SkipZip
    Do not create Wingetter-portable.zip next to the staged folder.
.PARAMETER ForceReinstallPs2Exe
    Reinstall the ps2exe module even if it is already present.
.EXAMPLE
    .\Build\Build-WingetterExe.ps1
.EXAMPLE
    .\Build\Build-WingetterExe.ps1 -SkipZip
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputRoot,

    [Parameter(Mandatory = $false)]
    [switch]$SkipZip,

    [Parameter(Mandatory = $false)]
    [switch]$ForceReinstallPs2Exe
)

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'Build-WingetterExe.ps1 must be run on Windows (ps2exe requires Windows PowerShell / .NET Framework).'
}

$wingetterRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $wingetterRoot
$launcherScript = Join-Path $wingetterRoot 'Launch-Wingetter.ps1'
$manifestPath = Join-Path $wingetterRoot 'Wingetter.psd1'

if (-not (Test-Path -LiteralPath $launcherScript)) {
    throw "Launcher not found: $launcherScript"
}

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Module manifest not found: $manifestPath"
}

$manifestData = Import-PowerShellDataFile -LiteralPath $manifestPath
$version = [string]$manifestData.ModuleVersion
if ([string]::IsNullOrWhiteSpace($version)) {
    $version = '0.0.0'
}
# File version wants four parts (e.g. 2.2.0.0).
$versionParts = @($version.Split('.'))
while ($versionParts.Count -lt 4) { $versionParts += '0' }
$fileVersion = ($versionParts[0..3] -join '.')

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $repoRoot 'dist'
}

$stageDir = Join-Path $OutputRoot 'Wingetter'
$exePath = Join-Path $stageDir 'Wingetter.exe'
$zipPath = Join-Path $OutputRoot 'Wingetter-portable.zip'

Write-Host "Wingetter ps2exe build" -ForegroundColor Cyan
Write-Host "  Version : $version ($fileVersion)"
Write-Host "  Source  : $wingetterRoot"
Write-Host "  Output  : $stageDir"

function Install-Ps2ExeModule {
    param([switch]$Force)

    $existing = Get-Module -ListAvailable -Name ps2exe | Select-Object -First 1
    if ($existing -and -not $Force) {
        Write-Host "Using ps2exe $($existing.Version) from $($existing.ModuleBase)" -ForegroundColor DarkGray
        Import-Module ps2exe -Force
        return
    }

    Write-Host 'Installing ps2exe from the PowerShell Gallery (CurrentUser)...' -ForegroundColor Yellow
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck
    Import-Module ps2exe -Force
}

Install-Ps2ExeModule -Force:$ForceReinstallPs2Exe

if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    throw 'Invoke-ps2exe was not found after importing the ps2exe module.'
}

if (Test-Path -LiteralPath $stageDir) {
    Write-Host "Cleaning previous stage: $stageDir" -ForegroundColor DarkGray
    Remove-Item -LiteralPath $stageDir -Recurse -Force
}

New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

$copyItems = @(
    'Gui'
    'Private'
    'Wingetter.psd1'
    'Wingetter.psm1'
    'Create-IntuneWinFromWinget.ps1'
    'Launch-Wingetter.ps1'
    'Start-Wingetter.cmd'
    'README.md'
    'CHANGELOG.md'
)

foreach ($item in $copyItems) {
    $source = Join-Path $wingetterRoot $item
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Warning "Skipping missing item: $item"
        continue
    }
    $destination = Join-Path $stageDir $item
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}

Write-Host "Compiling $launcherScript -> $exePath" -ForegroundColor Cyan

# -noConsole: Windows GUI subsystem (no flash console). STA is used for WinExe hosts.
# Omit -requireAdmin so the exe runs without UAC elevation.
Invoke-ps2exe `
    -inputFile $launcherScript `
    -outputFile $exePath `
    -noConsole `
    -noOutput `
    -noError `
    -title 'Wingetter' `
    -description 'Create Intune Win32 packages from Winget applications' `
    -company 'Wingetter' `
    -product 'Wingetter' `
    -copyright 'Wingetter' `
    -version $fileVersion

if (-not (Test-Path -LiteralPath $exePath)) {
    throw "ps2exe completed but Wingetter.exe was not created at $exePath"
}

# Leave Launch-Wingetter.ps1 in the stage for debugging; the exe is the primary entry point.
$readmeLines = @(
    '# Wingetter portable'
    ''
    "Version: $version"
    ''
    '## Run'
    ''
    '1. Double-click **Wingetter.exe** (no admin PowerShell required).'
    '2. Keep this folder intact — `Wingetter.exe` must stay next to `Gui\`, `Private\`, and `Wingetter.psd1`.'
    '3. The exe starts the GUI via Windows PowerShell 5.1 in a separate process.'
    '4. If antivirus blocks the exe, use `Start-Wingetter.cmd` or `Launch-Wingetter.ps1` instead.'
    ''
    '## Requirements'
    ''
    '- Windows 10/11 with PowerShell 5.1+'
    '- Winget (`winget --version`)'
    '- Microsoft Win32 Content Prep Tool (`intunewinapputil`) — install from the GUI if missing'
    ''
    '## CLI'
    ''
    '```powershell'
    '.\Create-IntuneWinFromWinget.ps1 -AppName "Google.Chrome"'
    '```'
    ''
)

Set-Content -LiteralPath (Join-Path $stageDir 'START-HERE.md') -Value $readmeLines -Encoding UTF8

if (-not $SkipZip) {
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Write-Host "Creating zip: $zipPath" -ForegroundColor Cyan
    Compress-Archive -Path $stageDir -DestinationPath $zipPath -Force
}

Write-Host ''
Write-Host 'Build complete.' -ForegroundColor Green
Write-Host "  Folder : $stageDir"
Write-Host "  Exe    : $exePath"
if (-not $SkipZip) {
    Write-Host "  Zip    : $zipPath"
}
Write-Host ''
Write-Host 'Share the Wingetter folder (or zip). End users double-click Wingetter.exe.' -ForegroundColor Green
