<#
.SYNOPSIS
    Creates an IntuneWin package from a Winget application with registry-based detection.
.DESCRIPTION
  Launches the Wingetter GUI when run without parameters. Use -NoGui for command-line
  packaging, or pass -AppName to package directly without the graphical interface.
.PARAMETER AppName
    The name or ID of the application to search for in Winget.
.PARAMETER Version
    Optional specific version to download.
.PARAMETER OutputPath
    Base output path. Defaults to "D:\Intoon In Progress".
.PARAMETER IconPath
    Optional path to a custom icon file (PNG recommended).
.PARAMETER NoGui
    Skip the GUI and run in console mode. Implied when -AppName is provided.
.EXAMPLE
    .\Create-IntuneWinFromWinget.ps1
.EXAMPLE
    .\Create-IntuneWinFromWinget.ps1 -AppName "JetBrains.WebStorm"
.EXAMPLE
    .\Create-IntuneWinFromWinget.ps1 -AppName "Google.Chrome" -OutputPath "C:\IntunePackages"
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

    [Parameter(Mandatory = $false)]
    [switch]$NoGui
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Wingetter.Core.ps1')

if (-not $NoGui -and [string]::IsNullOrWhiteSpace($AppName)) {
    & (Join-Path $scriptRoot 'Start-WingetterGui.ps1')
    return
}

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "`n[$Message]" -ForegroundColor $Color
}

function Select-WingetPackageCli {
    param([array]$Packages)

    if ($Packages.Count -eq 0) { return $null }

    if ($Packages.Count -eq 1) {
        Write-Host "`nFound 1 matching package:" -ForegroundColor Green
        Write-Host "  1. $($Packages[0].Name) ($($Packages[0].Id)) - Version: $($Packages[0].Version)" -ForegroundColor Cyan
        return $Packages[0]
    }

    Write-Host "`nFound $($Packages.Count) matching packages:" -ForegroundColor Green
    for ($i = 0; $i -lt $Packages.Count; $i++) {
        $num = $i + 1
        Write-Host "  $num. $($Packages[$i].Name) ($($Packages[$i].Id)) - Version: $($Packages[$i].Version)" -ForegroundColor Cyan
    }

    Add-Type -AssemblyName Microsoft.VisualBasic
    $prompt = "Multiple packages found. Enter number (1-$($Packages.Count)):"
    $selectedNumber = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, 'Wingetter - Select Package', '1')
    if ([string]::IsNullOrWhiteSpace($selectedNumber)) { throw 'No selection made.' }

    $parsedNumber = 0
    if (-not [int]::TryParse($selectedNumber.Trim(), [ref]$parsedNumber) -or $parsedNumber -lt 1 -or $parsedNumber -gt $Packages.Count) {
        throw "Invalid selection: $selectedNumber"
    }

    return $Packages[$parsedNumber - 1]
}

if ([string]::IsNullOrWhiteSpace($AppName)) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $AppName = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Enter the Winget Package ID or search term:',
        'Wingetter - Enter Winget Package ID',
        ''
    )
    if ([string]::IsNullOrWhiteSpace($AppName)) {
        Write-Host 'No Winget ID provided. Exiting.' -ForegroundColor Red
        exit 1
    }
    $AppName = $AppName.Trim()
}

$onProgress = {
    param($evt)
    if ($evt.Type -eq 'Log') {
        $color = switch ($evt.Level) {
            'Success' { 'Green' }
            'Warning' { 'Yellow' }
            'Error'   { 'Red' }
            default   { 'Gray' }
        }
        Write-Host "[$($evt.Level)] $($evt.Message)" -ForegroundColor $color
    }
    elseif ($evt.Type -eq 'Progress') {
        if ($evt.Percent -ge 0) {
            Write-Progress -Activity $evt.Step -Status $evt.Message -PercentComplete $evt.Percent
        }
        else {
            Write-Host "[$($evt.Step)] $($evt.Message)" -ForegroundColor Cyan
        }
    }
}

try {
    Write-Step 'Step 1: Searching Winget for application'
    $packages = Search-WingetPackages -SearchTerm $AppName -OnProgress $onProgress

    $exactMatch = $packages | Where-Object { $_.Id -eq $AppName } | Select-Object -First 1
    $selectedPackage = if ($exactMatch) {
        $exactMatch
    }
    else {
        Select-WingetPackageCli -Packages $packages
    }

    $packageId = $selectedPackage.Id
    $versionToUse = if ($Version) { $Version } else { $selectedPackage.Version }

    Write-Host "Selected: $($selectedPackage.Name) ($packageId)" -ForegroundColor Green

    $result = Invoke-WingetterPackage -PackageId $packageId -Version $versionToUse -OutputPath $OutputPath -IconPath $IconPath -OnProgress $onProgress

    Write-Progress -Activity 'Wingetter' -Completed
    Write-Step 'Summary' 'Green'
    Write-Host @"
Package created successfully!

Application: $($result.DisplayName)
Package ID:  $($result.PackageId)
Version:     $($result.Version)
Publisher:   $($result.Publisher)
Output:      $($result.VersionDirectory)
IntuneWin:   $($result.IntuneWinFile)

Files created:
- install.ps1, uninstall.ps1, detection.ps1
- README.md (Intune upload reference)
- app.json, win32LobApp.json
- wingetter-pack.log (written on failure)
"@ -ForegroundColor Green
}
catch {
    Write-Progress -Activity 'Wingetter' -Completed
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
