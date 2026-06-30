<#
.SYNOPSIS
    Creates an IntuneWin package from a Winget application with registry-based detection.
.DESCRIPTION
    This script automates the process of creating Intune Win32 packages from Winget.
    For a graphical experience with search, radio-button selection, live progress,
    and icon preview, run Start-WingetterGui.ps1 instead.

    This CLI wrapper supports the same parameters as before and uses the Wingetter.Core module.
.PARAMETER AppName
    The name or ID of the application to search for in Winget.
.PARAMETER Version
    Optional. Specific version to download.
.PARAMETER OutputPath
    Optional. Base output path. Defaults to "D:\Intoon In Progress"
.PARAMETER IconPath
    Optional. Path to icon file.
.PARAMETER UseGui
    Launch the graphical interface instead of CLI mode.
.EXAMPLE
    .\Create-IntuneWinFromWinget.ps1
.EXAMPLE
    .\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima"
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
    [string]$OutputPath = 'D:\Intoon In Progress',

    [Parameter(Mandatory = $false)]
    [string]$IconPath,

    [switch]$UseGui
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $scriptRoot 'Modules\Wingetter.Core\Wingetter.Core.psm1'

if ($UseGui) {
    $guiPath = Join-Path $scriptRoot 'Start-WingetterGui.ps1'
    & $guiPath
    return
}

if (-not (Test-Path $modulePath)) {
    Write-Error "Wingetter.Core module not found at: $modulePath"
    exit 1
}

Import-Module $modulePath -Force

function Get-WingetIdFromDialog {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $title = 'Wingetter - Enter Winget Package ID'
    $prompt = @"
Enter the Winget Package ID or application name:

Examples:
  - JetBrains.WebStorm
  - Google.Chrome
  - MaximaTeam.Maxima

You can use the full package ID or search term.
"@
    $result = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, $title, '')
    if ([string]::IsNullOrWhiteSpace($result)) {
        Write-Host 'No Winget ID provided. Exiting.' -ForegroundColor Red
        exit 1
    }
    return $result.Trim()
}

function Select-WingetPackageInteractive {
    param($Packages)

    if ($Packages.Count -eq 0) {
        throw 'No packages found.'
    }
    if ($Packages.Count -eq 1) {
        Write-Host "`nFound 1 matching package:" -ForegroundColor Green
        Write-Host "  $($Packages[0].Name) ($($Packages[0].Id)) - v$($Packages[0].Version)" -ForegroundColor Cyan
        return $Packages[0]
    }

    Write-Host "`nFound $($Packages.Count) matching packages:" -ForegroundColor Green
    for ($i = 0; $i -lt $Packages.Count; $i++) {
        Write-Host "  $($i + 1). $($Packages[$i].Name) ($($Packages[$i].Id)) - v$($Packages[$i].Version)" -ForegroundColor Cyan
    }

    Add-Type -AssemblyName Microsoft.VisualBasic
    $prompt = "Multiple packages found. Enter the number (1-$($Packages.Count)):`n`n"
    for ($i = 0; $i -lt $Packages.Count; $i++) {
        $prompt += "$($i + 1). $($Packages[$i].Name) ($($Packages[$i].Id))`n"
    }
    $selectedNumber = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, 'Wingetter - Select Package', '1')
    if ([string]::IsNullOrWhiteSpace($selectedNumber)) {
        Write-Host 'No selection made. Exiting.' -ForegroundColor Red
        exit 1
    }

    $parsedNumber = 0
    if (-not [int]::TryParse($selectedNumber.Trim(), [ref]$parsedNumber) -or $parsedNumber -lt 1 -or $parsedNumber -gt $Packages.Count) {
        Write-Host "Invalid selection: $selectedNumber. Exiting." -ForegroundColor Red
        exit 1
    }

    return $Packages[$parsedNumber - 1]
}

if ([string]::IsNullOrWhiteSpace($AppName)) {
    Write-Host 'Winget Package ID not provided. Opening input dialog...' -ForegroundColor Cyan
    Write-Host 'Tip: Run with -UseGui for the full graphical interface.' -ForegroundColor DarkGray
    $AppName = Get-WingetIdFromDialog
}

Write-Host "Using search term: $AppName" -ForegroundColor Green

try {
    $packages = Search-WingetPackage -Query $AppName
    $selectedPackage = Select-WingetPackageInteractive -Packages $packages

    $packageVersion = if ($Version) { $Version } else { $selectedPackage.Version }

    $result = Invoke-WingetterPackage -PackageId $selectedPackage.Id -Version $packageVersion -OutputPath $OutputPath -IconPath $IconPath

    Write-Host @"

Package created successfully!

Application: $($result.DisplayName)
Package ID:  $($result.PackageId)
Version:     $($result.Version)
Publisher:   $($result.Publisher)
Output:      $($result.OutputDirectory)
IntuneWin:   $($result.IntuneWinFile)

Files created:
  - install.ps1, detection.ps1, uninstall.ps1
  - README.md (full Intune upload reference)
  - app.json, win32LobApp.json
  - packaging.log (and packaging-error.log on failure)

Next steps:
  1. Review README.md for all Intune upload fields
  2. Upload the .intunewin file to Intune
  3. Use install.ps1 / uninstall.ps1 / detection.ps1 command lines from win32LobApp.json
"@ -ForegroundColor Green
}
catch {
    Write-Host "[ERROR] $_" -ForegroundColor Red
    exit 1
}
