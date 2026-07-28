<#
.SYNOPSIS
    Double-click / ps2exe entry point for the Wingetter GUI.
.DESCRIPTION
    Resolves the Wingetter install folder whether running as a .ps1 or as a
    compiled Wingetter.exe (ps2exe), then launches Gui\Start-WingetterGui.ps1.
    Designed to run without an elevated PowerShell session.
.NOTES
    Build with: .\Build\Build-WingetterExe.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Capture at script scope — $MyInvocation inside functions refers to the function.
$scriptInvocation = $MyInvocation

function Get-WingetterAppRoot {
    param($Invocation)

    # ExternalScript = running as .ps1; otherwise compiled by ps2exe.
    if ($Invocation.MyCommand.CommandType -eq 'ExternalScript') {
        $candidate = Split-Path -Parent -Path $Invocation.MyCommand.Definition
        if ($candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    # ps2exe sets $PSScriptRoot to the directory containing the .exe in current builds.
    if ($PSScriptRoot) {
        return (Resolve-Path -LiteralPath $PSScriptRoot).Path
    }

    $commandLineExe = [Environment]::GetCommandLineArgs()[0]
    if ($commandLineExe) {
        $fromArgs = Split-Path -Parent -Path $commandLineExe
        if ($fromArgs -and (Test-Path -LiteralPath $fromArgs)) {
            return (Resolve-Path -LiteralPath $fromArgs).Path
        }
    }

    try {
        $processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($processPath) {
            $fromProcess = Split-Path -Parent -Path $processPath
            if ($fromProcess -and (Test-Path -LiteralPath $fromProcess)) {
                return (Resolve-Path -LiteralPath $fromProcess).Path
            }
        }
    } catch {
        # Ignore and fall through.
    }

    return (Resolve-Path -LiteralPath (Get-Location).Path).Path
}

function Show-WingetterStartupError {
    param([string]$Message)

    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [System.Windows.MessageBox]::Show(
            $Message,
            'Wingetter',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    } catch {
        Write-Error $Message
    }
}

try {
    $appRoot = Get-WingetterAppRoot -Invocation $scriptInvocation
    $guiScript = Join-Path $appRoot 'Gui\Start-WingetterGui.ps1'
    $moduleManifest = Join-Path $appRoot 'Wingetter.psd1'

    if (-not (Test-Path -LiteralPath $guiScript)) {
        throw "Could not find Gui\Start-WingetterGui.ps1 next to the launcher.`nLooked in: $appRoot`n`nKeep Wingetter.exe in the same folder as Gui\, Private\, and Wingetter.psd1."
    }

    if (-not (Test-Path -LiteralPath $moduleManifest)) {
        throw "Could not find Wingetter.psd1 next to the launcher.`nLooked in: $appRoot"
    }

    Set-Location -LiteralPath $appRoot
    & $guiScript
} catch {
    Show-WingetterStartupError -Message ("Wingetter failed to start:`n`n{0}" -f $_.Exception.Message)
    exit 1
}
