<#
.SYNOPSIS
    Static validation checks for Wingetter script quality.
.DESCRIPTION
    Run this on Windows with PowerShell 5.1+ to verify the Wingetter source
    does not contain known-bad patterns that caused Intune detection failures.
#>

[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "Create-IntuneWinFromWinget.ps1")
)

$ErrorActionPreference = "Stop"
$failures = @()

function Add-Failure {
    param([string]$Message)
    $script:failures += $Message
}

if (-not (Test-Path $ScriptPath)) {
    Write-Error "Script not found: $ScriptPath"
    exit 1
}

$content = Get-Content -Path $ScriptPath -Raw

Write-Host "Validating Wingetter source: $ScriptPath" -ForegroundColor Cyan

# Detection script must sort hashtables with bracket notation
if ($content -match '\[version\]\`\$_\.DisplayVersion') {
    Add-Failure "Detection template still uses dot notation for hashtable DisplayVersion in Sort-Object."
}

if ($content -notmatch "\`$_\.\['DisplayVersion'\]") {
    Add-Failure "Detection template is missing bracket notation for hashtable DisplayVersion."
}

if ($content -notmatch 'function Get-InstalledVersionFromRegistryEntry') {
    Add-Failure "Detection template is missing Get-InstalledVersionFromRegistryEntry helper."
}

if ($content -notmatch 'function Write-Utf8NoBomFile') {
    Add-Failure "Missing Write-Utf8NoBomFile helper for Intune-safe script output."
}

if ($content -match 'function Write-Error\b') {
    Add-Failure "Custom Write-Error function shadows the built-in cmdlet."
}

if ($content -notmatch 'Start-WingetDownloadWithProgress[\s\S]*\[string\]\$Version') {
    Add-Failure "Winget download helper does not accept a Version parameter."
}

if ($content -notmatch 'Write-Utf8NoBomFile -Path \$detectionScriptPath') {
    Add-Failure "detection.ps1 is not written with UTF-8 no BOM helper."
}

if ($content -match 'DisplayName -like "\*\$\(\$displayName\.Split') {
    Add-Failure "Detection template still contains the restrictive first-word filter that breaks JetBrains matching."
}

if ($content -match 'cdn\.jsdelivr\.net/gh/\$orgName/\$projectName' -and $content -notmatch 'if \(\$orgName -and \$projectName\)') {
    Add-Failure "CDN logo URLs may be built with empty org/repo values."
}

if ($failures.Count -eq 0) {
    Write-Host "All Wingetter validation checks passed." -ForegroundColor Green
    exit 0
}

Write-Host "Wingetter validation failed:" -ForegroundColor Red
foreach ($failure in $failures) {
    Write-Host "  - $failure" -ForegroundColor Red
}
exit 1
