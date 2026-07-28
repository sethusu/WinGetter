<#
.SYNOPSIS
    Diagnoses Wingetter launch the same way Wingetter.exe does (for local Windows terminals).
.DESCRIPTION
    Prints resolved paths, probes the GUI script, and optionally starts the GUI
    with the same EncodedCommand technique used by the compiled launcher.
.PARAMETER StartGui
    Actually start the GUI (default: only print diagnostics).
.EXAMPLE
    .\Build\Diagnose-WingetterLaunch.ps1
.EXAMPLE
    .\Build\Diagnose-WingetterLaunch.ps1 -StartGui
#>

[CmdletBinding()]
param(
    [switch]$StartGui
)

$ErrorActionPreference = 'Continue'
$wingetterRoot = Split-Path -Parent $PSScriptRoot
$guiScript = Join-Path $wingetterRoot 'Gui\Start-WingetterGui.ps1'
$manifest = Join-Path $wingetterRoot 'Wingetter.psd1'
$launcher = Join-Path $wingetterRoot 'Launch-Wingetter.ps1'
$logPath = Join-Path $env:TEMP 'Wingetter-launch.log'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

Write-Host '=== Wingetter launch diagnosis ===' -ForegroundColor Cyan
Write-Host "PSVersion: $($PSVersionTable.PSVersion)"
Write-Host "Edition:   $($PSVersionTable.PSEdition)"
Write-Host "STA:       $([System.Threading.Thread]::CurrentThread.GetApartmentState())"
Write-Host "Root:      $wingetterRoot"
Write-Host "Has space: $($wingetterRoot -match '\s')"
Write-Host "Launcher:  $launcher  exists=$([bool](Test-Path -LiteralPath $launcher))"
Write-Host "GUI:       $guiScript  exists=$([bool](Test-Path -LiteralPath $guiScript))"
Write-Host "Manifest:  $manifest  exists=$([bool](Test-Path -LiteralPath $manifest))"
Write-Host "powershell.exe: $windowsPowerShell  exists=$([bool](Test-Path -LiteralPath $windowsPowerShell))"
Write-Host "Log path:  $logPath"

Write-Host ''
Write-Host '--- Parse check: Private\Winget.ps1 ---' -ForegroundColor Cyan
$wingetScript = Join-Path $wingetterRoot 'Private\Winget.ps1'
$tokens = $null
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($wingetScript, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    Write-Host 'PARSE ERRORS:' -ForegroundColor Red
    $errors | ForEach-Object { Write-Host ("  {0}" -f $_) -ForegroundColor Red }
} else {
    Write-Host 'OK (no parse errors)' -ForegroundColor Green
}

Write-Host ''
Write-Host '--- Import module ---' -ForegroundColor Cyan
try {
    Import-Module $manifest -Force -ErrorAction Stop
    Write-Host 'Import-Module OK' -ForegroundColor Green
    Test-WingetterPrerequisites | Format-List | Out-String | Write-Host
} catch {
    Write-Host ("Import-Module FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

if (-not $StartGui) {
    Write-Host ''
    Write-Host 'Dry run only. To start the GUI:' -ForegroundColor Yellow
    Write-Host '  .\Build\Diagnose-WingetterLaunch.ps1 -StartGui'
    Write-Host 'Or run the GUI directly:'
    Write-Host "  powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$guiScript`""
    return
}

Write-Host ''
Write-Host '--- Starting GUI in-process ---' -ForegroundColor Cyan
& $guiScript
