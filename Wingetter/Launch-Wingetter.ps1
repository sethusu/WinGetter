<#
.SYNOPSIS
    Double-click / ps2exe entry point for the Wingetter GUI.
.DESCRIPTION
    Resolves the Wingetter install folder whether running as a .ps1 or as a
    compiled Wingetter.exe (ps2exe), then launches Gui\Start-WingetterGui.ps1.
    Designed to run without an elevated PowerShell session.

    When compiled with ps2exe, the GUI is started in a separate Windows
    PowerShell 5.1 process. Loading the module inside the ps2exe host breaks
    parsing of regex literals that use {n,} quantifiers (e.g. Private\Winget.ps1).
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

function Start-WingetterGuiProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppRoot,

        [Parameter(Mandatory = $true)]
        [string]$GuiScript
    )

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
        throw "Windows PowerShell not found at $windowsPowerShell"
    }

    # Separate process = real PS 5.1 parser/host (avoids ps2exe regex parse failures).
    # Hidden window style suppresses the console flash; WPF windows still appear.
    $argumentList = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-STA'
        '-WindowStyle', 'Hidden'
        '-File', $GuiScript
    )

    $process = Start-Process `
        -FilePath $windowsPowerShell `
        -ArgumentList $argumentList `
        -WorkingDirectory $AppRoot `
        -PassThru

    if (-not $process) {
        throw 'Failed to start Windows PowerShell for the Wingetter GUI.'
    }

    return $process
}

try {
    $appRoot = Get-WingetterAppRoot -Invocation $scriptInvocation
    $guiScript = Join-Path $appRoot 'Gui\Start-WingetterGui.ps1'
    $moduleManifest = Join-Path $appRoot 'Wingetter.psd1'
    $isCompiled = $scriptInvocation.MyCommand.CommandType -ne 'ExternalScript'

    if (-not (Test-Path -LiteralPath $guiScript)) {
        throw "Could not find Gui\Start-WingetterGui.ps1 next to the launcher.`nLooked in: $appRoot`n`nKeep Wingetter.exe in the same folder as Gui\, Private\, and Wingetter.psd1."
    }

    if (-not (Test-Path -LiteralPath $moduleManifest)) {
        throw "Could not find Wingetter.psd1 next to the launcher.`nLooked in: $appRoot"
    }

    Set-Location -LiteralPath $appRoot

    if ($isCompiled) {
        Start-WingetterGuiProcess -AppRoot $appRoot -GuiScript $guiScript | Out-Null
    } else {
        & $guiScript
    }
} catch {
    Show-WingetterStartupError -Message ("Wingetter failed to start:`n`n{0}" -f $_.Exception.Message)
    exit 1
}
