<#
.SYNOPSIS
    Creates an IntuneWin package from a Winget application with registry-based detection.
.DESCRIPTION
    CLI entry point for Wingetter. For the graphical interface, run:
    .\Gui\Start-WingetterGui.ps1
.PARAMETER AppName
    The name or ID of the application to search for in Winget.
.PARAMETER Version
    Optional. Specific version to download.
.PARAMETER OutputPath
    Optional. Base output path. Defaults to the saved Wingetter settings path.
.PARAMETER IconPath
    Optional. Path to a custom PNG icon.
.PARAMETER UseGui
    Launch the graphical interface instead of running in CLI mode.
.EXAMPLE
    .\Create-IntuneWinFromWinget.ps1
.EXAMPLE
    .\Create-IntuneWinFromWinget.ps1 -AppName "Google.Chrome"
.EXAMPLE
    .\Create-IntuneWinFromWinget.ps1 -UseGui
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AppName,

    [Parameter(Mandatory = $false)]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string]$IconPath,

    [Parameter(Mandatory = $false)]
    [switch]$UseGui
)

$ErrorActionPreference = 'Stop'
$moduleRoot = $PSScriptRoot

if ($UseGui -or (-not $PSBoundParameters.ContainsKey('AppName') -and -not $AppName)) {
    & (Join-Path $moduleRoot 'Gui\Start-WingetterGui.ps1')
    return
}

Import-Module (Join-Path $moduleRoot 'Wingetter.psd1') -Force

function Get-WingetIdFromDialog {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $result = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Enter the Winget Package ID or application name:`n`nExamples:`n  JetBrains.WebStorm`n  Google.Chrome`n  MaximaTeam.Maxima",
        'Wingetter - Enter Winget Package ID',
        ''
    )
    if ([string]::IsNullOrWhiteSpace($result)) {
        throw 'No Winget ID provided.'
    }
    return $result.Trim()
}

function Select-WingetPackageFromCli {
    param([array]$Packages)

    if ($Packages.Count -eq 1) {
        $sourceLabel = if ($Packages[0].Source) { " [$($Packages[0].Source)]" } else { '' }
        Write-Host "Found 1 matching package: $($Packages[0].Name) ($($Packages[0].Id))$sourceLabel" -ForegroundColor Green
        return $Packages[0]
    }

    Write-Host "`nFound $($Packages.Count) matching packages:" -ForegroundColor Green
    for ($i = 0; $i -lt $Packages.Count; $i++) {
        $num = $i + 1
        $sourceLabel = if ($Packages[$i].Source) { " [$($Packages[$i].Source)]" } else { '' }
        Write-Host "  $num. $($Packages[$i].Name) ($($Packages[$i].Id)) - Version: $($Packages[$i].Version)$sourceLabel" -ForegroundColor Cyan
    }

    Add-Type -AssemblyName Microsoft.VisualBasic
    $prompt = "Multiple packages found. Enter the number (1-$($Packages.Count)):"
    $selectedNumber = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, 'Wingetter - Select Package', '1')
    if ([string]::IsNullOrWhiteSpace($selectedNumber)) {
        throw 'No selection made.'
    }

    $parsedNumber = 0
    if (-not [int]::TryParse($selectedNumber.Trim(), [ref]$parsedNumber) -or $parsedNumber -lt 1 -or $parsedNumber -gt $Packages.Count) {
        throw "Invalid selection: $selectedNumber"
    }

    return $Packages[$parsedNumber - 1]
}

if ([string]::IsNullOrWhiteSpace($AppName)) {
    Write-Host 'Winget Package ID not provided. Opening input dialog...' -ForegroundColor Cyan
    $AppName = Get-WingetIdFromDialog
}

if (-not $OutputPath) {
    $OutputPath = (Get-WingetterSettings).OutputPath
}

try {
    Write-Host "`n[Step 1: Searching Winget]" -ForegroundColor Cyan
    $packages = Search-WingetPackages -Query $AppName
    $selectedPackage = Select-WingetPackageFromCli -Packages $packages

    $packageVersion = $Version
    if (-not $packageVersion -and $selectedPackage.Version -and $selectedPackage.Version -ne 'Unknown') {
        $packageVersion = $selectedPackage.Version
    }

    $onProgress = {
        param($Event)
        if ($Event.Type -eq 'Progress') {
            $percent = if ($Event.Percent -ge 0) { " ($($Event.Percent)%)" } else { '' }
            $message = if ($Event.Message) { " - $($Event.Message)" } else { '' }
            Write-Host "[$($Event.StepName)]$percent$message" -ForegroundColor Cyan
        } else {
            Write-Host $Event.Message
        }
    }

    $result = Invoke-WingetterPackaging -PackageId $selectedPackage.Id -Version $packageVersion `
        -Source $selectedPackage.Source -OutputPath $OutputPath -IconPath $IconPath -OnProgress $onProgress

    if ($result.PackagingSucceeded) {
        Write-Host "`nPackage created successfully!" -ForegroundColor Green
    } else {
        Write-Host "`nPackage created with warnings (IntuneWin packaging step failed)." -ForegroundColor Yellow
    }

    $intuneWinLine = if ($result.IntuneWinFile) { $result.IntuneWinFile } else { '(not created)' }
    Write-Host @"

Package Details:
- Application: $($result.DisplayName)
- Package ID: $($result.PackageId)
- Version: $($result.Version)
- Publisher: $($result.Publisher)
- Output Directory: $($result.VersionDirectory)
- IntuneWin Package: $intuneWinLine

Files Created:
- install.ps1
- detection.ps1
- uninstall.ps1
- README.md
- readme.txt
- app.json
- win32LobApp.json
- icon.png (if available)
- wingetter-packaging.log (on failure)

Next Steps:
1. Review the generated files in: $($result.VersionDirectory)
2. Upload the .intunewin file to Intune
"@ -ForegroundColor Green
}
catch {
    Write-Host "[ERROR] $_" -ForegroundColor Red
    exit 1
}
