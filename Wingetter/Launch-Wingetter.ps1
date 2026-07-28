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

    The child process is started with -EncodedCommand so paths that contain
    spaces (e.g. D:\Intoon In Progress\...) are not mangled by Start-Process
    -ArgumentList quoting.
.NOTES
    Build with: .\Build\Build-WingetterExe.ps1
    Startup log: %TEMP%\Wingetter-launch.log
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

function Write-WingetterLaunchLog {
    param(
        [string]$LogPath,
        [string]$Message
    )

    $line = '{0:yyyy-MM-dd HH:mm:ss.fff}  {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Start-WingetterGuiProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppRoot,

        [Parameter(Mandatory = $true)]
        [string]$GuiScript,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
        throw "Windows PowerShell not found at $windowsPowerShell"
    }

    # Escape single quotes for embedding inside a single-quoted PowerShell literal.
    $appRootLiteral = $AppRoot.Replace("'", "''")
    $guiScriptLiteral = $GuiScript.Replace("'", "''")
    $logPathLiteral = $LogPath.Replace("'", "''")

    # Child script: run GUI; on failure write log + MessageBox (console may be hidden).
    $childScript = @"
`$ErrorActionPreference = 'Stop'
`$wingetterLog = '$logPathLiteral'
function Write-WingetterChildLog([string]`$Message) {
    Add-Content -LiteralPath `$wingetterLog -Value (('{0:yyyy-MM-dd HH:mm:ss.fff}  CHILD  {1}' -f (Get-Date), `$Message)) -Encoding UTF8
}
try {
    Write-WingetterChildLog 'Starting GUI'
    Write-WingetterChildLog ("AppRoot=$AppRoot")
    Write-WingetterChildLog ("GuiScript=$GuiScript")
    Set-Location -LiteralPath '$appRootLiteral'
    & '$guiScriptLiteral'
    Write-WingetterChildLog 'GUI exited normally'
} catch {
    Write-WingetterChildLog ('ERROR: ' + `$_.Exception.Message)
    Write-WingetterChildLog (`$_.ScriptStackTrace)
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [System.Windows.MessageBox]::Show(
            ('Wingetter GUI failed to start:`n`n' + `$_.Exception.Message + '`n`nSee log:`n' + `$wingetterLog),
            'Wingetter',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    } catch { }
    exit 1
}
"@

    # -EncodedCommand avoids Start-Process ArgumentList quoting bugs with spaces in paths.
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))

    Write-WingetterLaunchLog -LogPath $LogPath -Message "powershell=$windowsPowerShell"
    Write-WingetterLaunchLog -LogPath $LogPath -Message "appRoot=$AppRoot"
    Write-WingetterLaunchLog -LogPath $LogPath -Message "guiScript=$GuiScript"
    Write-WingetterLaunchLog -LogPath $LogPath -Message 'Starting child via -EncodedCommand'

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $windowsPowerShell
    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -EncodedCommand $encodedCommand"
    $startInfo.WorkingDirectory = $AppRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Failed to start Windows PowerShell for the Wingetter GUI.'
    }

    Write-WingetterLaunchLog -LogPath $LogPath -Message ("childPid={0}" -f $process.Id)

    # If the child dies immediately, surface the failure instead of a silent flash.
    if ($process.WaitForExit(4000)) {
        $exitCode = $process.ExitCode
        Write-WingetterLaunchLog -LogPath $LogPath -Message ("childExitedEarly exitCode={0}" -f $exitCode)
        $tail = ''
        if (Test-Path -LiteralPath $LogPath) {
            $tail = (Get-Content -LiteralPath $LogPath -Tail 20) -join "`n"
        }
        throw "Wingetter GUI process exited immediately (exit code $exitCode).`n`nLog: $LogPath`n`n$tail"
    }

    Write-WingetterLaunchLog -LogPath $LogPath -Message 'child still running after 4s — launch looks healthy'
    return $process
}

try {
    $logPath = Join-Path $env:TEMP 'Wingetter-launch.log'
    '' | Set-Content -LiteralPath $logPath -Encoding UTF8

    $appRoot = Get-WingetterAppRoot -Invocation $scriptInvocation
    $guiScript = Join-Path $appRoot 'Gui\Start-WingetterGui.ps1'
    $moduleManifest = Join-Path $appRoot 'Wingetter.psd1'
    $isCompiled = $scriptInvocation.MyCommand.CommandType -ne 'ExternalScript'

    Write-WingetterLaunchLog -LogPath $logPath -Message ("isCompiled={0}" -f $isCompiled)
    Write-WingetterLaunchLog -LogPath $logPath -Message ("appRoot={0}" -f $appRoot)

    if (-not (Test-Path -LiteralPath $guiScript)) {
        throw "Could not find Gui\Start-WingetterGui.ps1 next to the launcher.`nLooked in: $appRoot`n`nKeep Wingetter.exe in the same folder as Gui\, Private\, and Wingetter.psd1."
    }

    if (-not (Test-Path -LiteralPath $moduleManifest)) {
        throw "Could not find Wingetter.psd1 next to the launcher.`nLooked in: $appRoot"
    }

    Set-Location -LiteralPath $appRoot

    if ($isCompiled) {
        Start-WingetterGuiProcess -AppRoot $appRoot -GuiScript $guiScript -LogPath $logPath | Out-Null
    } else {
        Write-WingetterLaunchLog -LogPath $logPath -Message 'Running GUI in-process (not compiled)'
        & $guiScript
    }
} catch {
    $message = "Wingetter failed to start:`n`n{0}" -f $_.Exception.Message
    if ($logPath) {
        try { Write-WingetterLaunchLog -LogPath $logPath -Message ("FATAL: " + $_.Exception.Message) } catch { }
        $message += "`n`nLog: $logPath"
    }
    Show-WingetterStartupError -Message $message
    exit 1
}
