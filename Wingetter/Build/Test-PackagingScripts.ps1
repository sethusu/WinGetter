<#
.SYNOPSIS
    Lightweight checks for the ps2exe launcher and build script (safe on non-Windows).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = @()

function Test-ScriptParses {
    param([string]$Path)
    $errors = $null
    $tokens = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        return ($errors | ForEach-Object { $_.ToString() }) -join '; '
    }
    return $null
}

$required = @(
    (Join-Path $root 'Launch-Wingetter.ps1')
    (Join-Path $root 'Start-Wingetter.cmd')
    (Join-Path $PSScriptRoot 'Build-WingetterExe.ps1')
    (Join-Path $root 'Gui\Start-WingetterGui.ps1')
    (Join-Path $root 'Wingetter.psd1')
)

foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path)) {
        $failures += "Missing required file: $path"
    }
}

foreach ($script in @(
        (Join-Path $root 'Launch-Wingetter.ps1')
        (Join-Path $PSScriptRoot 'Build-WingetterExe.ps1')
    )) {
    if (Test-Path -LiteralPath $script) {
        $parseError = Test-ScriptParses -Path $script
        if ($parseError) {
            $failures += "Parse error in ${script}: $parseError"
        }
    }
}

$launcher = Get-Content -LiteralPath (Join-Path $root 'Launch-Wingetter.ps1') -Raw
foreach ($needle in @(
        'Get-WingetterAppRoot'
        'Start-WingetterGui.ps1'
        'Show-WingetterStartupError'
        'Start-WingetterGuiProcess'
        'WindowsPowerShell\v1.0\powershell.exe'
        'isCompiled'
    )) {
    if ($launcher -notmatch [regex]::Escape($needle)) {
        $failures += "Launch-Wingetter.ps1 missing expected content: $needle"
    }
}

$build = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Build-WingetterExe.ps1') -Raw
foreach ($needle in @('Invoke-ps2exe', '-noConsole', 'Wingetter.exe', 'Launch-Wingetter.ps1')) {
    if ($build -notmatch [regex]::Escape($needle)) {
        $failures += "Build-WingetterExe.ps1 missing expected content: $needle"
    }
}

$cmd = Get-Content -LiteralPath (Join-Path $root 'Start-Wingetter.cmd') -Raw
if ($cmd -notmatch 'Launch-Wingetter\.ps1') {
    $failures += 'Start-Wingetter.cmd does not reference Launch-Wingetter.ps1'
}
if ($cmd -notmatch 'ExecutionPolicy Bypass') {
    $failures += 'Start-Wingetter.cmd should use ExecutionPolicy Bypass'
}

if ($failures.Count -gt 0) {
    Write-Host 'Packaging checks FAILED:' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'Packaging checks passed.' -ForegroundColor Green
