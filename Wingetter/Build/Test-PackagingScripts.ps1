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
    (Join-Path $root 'Gui\Wingetter.SandboxTestDialog.xaml')
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
        'EncodedCommand'
        'Wingetter-launch.log'
        'CreateNoWindow'
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

# PowerShell 5.1 reads BOM-less scripts using the ANSI code page. UTF-8 bytes such as
# 0x92/0x94 then become curly quotes and terminate strings early (breaking \s{2,} regexes).
$utf8Bom = [byte[]](0xEF, 0xBB, 0xBF)
$privateDir = Join-Path $root 'Private'
foreach ($scriptPath in Get-ChildItem -LiteralPath $privateDir -Filter '*.ps1' -File) {
    $bytes = [System.IO.File]::ReadAllBytes($scriptPath.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq $utf8Bom[0] -and $bytes[1] -eq $utf8Bom[1] -and $bytes[2] -eq $utf8Bom[2])
    if ($hasBom) {
        continue
    }

    $offset = 0
    while ($offset -lt $bytes.Length) {
        $b = $bytes[$offset]
        if ($b -lt 0x80) {
            $offset++
            continue
        }

        if ($b -ge 0xF0) { $seqLen = 4 }
        elseif ($b -ge 0xE0) { $seqLen = 3 }
        elseif ($b -ge 0xC0) { $seqLen = 2 }
        else {
            $failures += "$($scriptPath.Name) contains invalid UTF-8 continuation at offset $offset"
            break
        }

        if (($offset + $seqLen) -gt $bytes.Length) {
            $failures += "$($scriptPath.Name) contains truncated UTF-8 sequence at offset $offset"
            break
        }

        $sequence = $bytes[$offset..($offset + $seqLen - 1)]
        foreach ($quoteRisk in 0x91, 0x92, 0x93, 0x94) {
            if ($sequence -contains [byte]$quoteRisk) {
                $failures += "$($scriptPath.Name) is UTF-8 without BOM and contains byte 0x$([Convert]::ToString($quoteRisk, 16)) inside a multi-byte character. Windows PowerShell 5.1 may misread that as a curly quote and break parsing. Use ASCII or save with a UTF-8 BOM."
                break
            }
        }

        # Also flag any non-ASCII in BOM-less Private scripts -- keep the distributed module ASCII-safe.
        $failures += "$($scriptPath.Name) contains non-ASCII bytes without a UTF-8 BOM (offset $offset). Windows PowerShell 5.1 may mis-parse the file; use ASCII or add a UTF-8 BOM."
        break
    }
}

$wingetScript = Get-Content -LiteralPath (Join-Path $privateDir 'Winget.ps1') -Raw
foreach ($needle in @(
        'WingetProgressLinePattern'
        'Test-WingetTruncatedId'
        'WingetEllipsisChar'
    )) {
    if ($wingetScript -notmatch [regex]::Escape($needle)) {
        $failures += "Private\Winget.ps1 missing expected content: $needle"
    }
}

$gui = Get-Content -LiteralPath (Join-Path $root 'Gui\Start-WingetterGui.ps1') -Raw
foreach ($needle in @(
        'TestSandboxButton'
        'Show-WingetterSandboxTestDialog'
        'Invoke-WingetterSandboxTestFromUi'
        'Test-WingetterWindowsSandbox'
        'CopyReportButton'
        'Write-WingetterSandboxTestReport'
        'Resolve-WingetterSandboxStepStatus'
    )) {
    if ($gui -notmatch [regex]::Escape($needle)) {
        $failures += "Gui\Start-WingetterGui.ps1 missing expected content: $needle"
    }
}

$sandboxScript = Get-Content -LiteralPath (Join-Path $privateDir 'Sandbox.ps1') -Raw
foreach ($needle in @(
        'Test-WingetterWindowsSandbox'
        'Install-WingetterWindowsSandbox'
        'Start-WingetterSandboxSession'
        'Complete-WingetterSandboxTest'
        'Containers-DisposableClientVM'
        'install.ps1'
        'detection.ps1'
        'uninstall.ps1'
        'Copy-PackageStepLogs'
        'sandbox-test-report'
        'sandbox-failure.log'
        'Save-DesktopScreenshot'
        'ui-activity.json'
        'Resolve-WingetterSandboxStepStatus'
        'WingetterStep-'
        'Windows PowerShell transcript end'
        'process.Refresh'
        'status.ndjson'
        'Ignoring Inno extractor window'
        'STEP_DONE'
    )) {
    if ($sandboxScript -notmatch [regex]::Escape($needle)) {
        $failures += "Private\Sandbox.ps1 missing expected content: $needle"
    }
}

$silentScript = Join-Path $privateDir 'SilentInstall.ps1'
if (-not (Test-Path -LiteralPath $silentScript)) {
    $failures += 'Missing required file: Private\SilentInstall.ps1'
} else {
    $silentText = Get-Content -LiteralPath $silentScript -Raw
    foreach ($needle in @(
            'Get-WingetterSilentInstallPlan'
            '/VERYSILENT'
            '/LANG=english'
            'Test-WingetterSilentSwitchAdequacy'
        )) {
        if ($silentText -notmatch [regex]::Escape($needle)) {
            $failures += "Private\SilentInstall.ps1 missing expected content: $needle"
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'Packaging checks FAILED:' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'Packaging checks passed.' -ForegroundColor Green
