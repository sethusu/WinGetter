<#
.SYNOPSIS
    Creates an IntuneWin package from a Winget application with registry-based detection.
.DESCRIPTION
    This script automates Winget search, download, script generation, and IntuneWin packaging.
    Use -Gui to launch the graphical interface with search dialog, progress tracking, and icon preview.
.PARAMETER AppName
    The name or ID of the application to search for in Winget.
.PARAMETER Version
    Optional. Specific version to download.
.PARAMETER OutputPath
    Optional. Base output path. Defaults to Documents\Wingetter Output.
.PARAMETER IconPath
    Optional. Path to a custom icon file.
.PARAMETER Gui
    Launch the Wingetter graphical user interface.
.EXAMPLE
    .\Create-IntuneWinFromWinget.ps1 -Gui
.EXAMPLE
    .\Create-IntuneWinFromWinget.ps1 -AppName "Google.Chrome"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AppName,

    [Parameter(Mandatory = $false)]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Join-Path $env:USERPROFILE 'Documents\Wingetter Output'),

    [Parameter(Mandatory = $false)]
    [string]$IconPath,

    [Parameter(Mandatory = $false)]
    [switch]$Gui
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot

if ($Gui) {
    $guiScript = Join-Path $scriptRoot 'Show-WingetterGui.ps1'
    if (-not (Test-Path $guiScript)) {
        Write-Error "GUI script not found: $guiScript"
        exit 1
    }
    & $guiScript
    exit $LASTEXITCODE
}

$modulePath = Join-Path $scriptRoot 'Wingetter.Core.psm1'
if (-not (Test-Path $modulePath)) {
    Write-Error "Wingetter.Core.psm1 not found at: $modulePath"
    exit 1
}
Import-Module $modulePath -Force

function Get-WingetIdFromDialog {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $result = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Enter the Winget Package ID or application name:`n`nExamples:`n  JetBrains.WebStorm`n  Google.Chrome`n  MaximaTeam.Maxima",
        'Wingetter - Enter Winget Package ID',
        ''
    )
    if ([string]::IsNullOrWhiteSpace($result)) {
        Write-Host 'No Winget ID provided. Exiting.' -ForegroundColor Red
        exit 1
    }
    return $result.Trim()
}

function Select-WingetPackageCli {
    param([array]$Packages)

    if ($Packages.Count -eq 1) {
        Write-Host "`nFound 1 matching package: $($Packages[0].Name) ($($Packages[0].Id))" -ForegroundColor Green
        return $Packages[0]
    }

    Write-Host "`nFound $($Packages.Count) matching packages:" -ForegroundColor Green
    for ($i = 0; $i -lt $Packages.Count; $i++) {
        Write-Host "  $($i + 1). $($Packages[$i].Name) ($($Packages[$i].Id)) - $($Packages[$i].Version)" -ForegroundColor Cyan
    }

    Add-Type -AssemblyName Microsoft.VisualBasic
    $prompt = "Multiple packages found. Enter the number (1-$($Packages.Count)):"
    $selectedNumber = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, 'Wingetter - Select Package', '1')

    if ([string]::IsNullOrWhiteSpace($selectedNumber)) { exit 1 }
    $parsed = 0
    if (-not [int]::TryParse($selectedNumber.Trim(), [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt $Packages.Count) {
        Write-Host "Invalid selection: $selectedNumber" -ForegroundColor Red
        exit 1
    }
    return $Packages[$parsed - 1]
}

if ([string]::IsNullOrWhiteSpace($AppName)) {
    Write-Host 'Winget Package ID not provided. Opening input dialog...' -ForegroundColor Cyan
    $AppName = Get-WingetIdFromDialog
}

Write-Host "`n[Step 1] Searching Winget for: $AppName" -ForegroundColor Cyan
try {
    $packages = Search-WingetPackage -SearchTerm $AppName -ProgressCallback {
        param($Percent, $Status, $Step)
        Write-Progress -Activity 'Wingetter' -Status $Status -PercentComplete $Percent
    }
    Write-Progress -Activity 'Wingetter' -Completed

    $selectedPackage = Select-WingetPackageCli -Packages $packages
    $packageId = $selectedPackage.Id
    $displayName = $selectedPackage.Name

    if (-not $Version -and $selectedPackage.Version -ne 'Unknown') {
        $Version = $selectedPackage.Version
    }

    Write-Host "`n[Step 2] Packaging $displayName ($packageId)" -ForegroundColor Cyan

    $result = Invoke-WingetterPackage `
        -PackageId $packageId `
        -DisplayName $displayName `
        -Version $Version `
        -OutputPath $OutputPath `
        -IconPath $IconPath `
        -ProgressCallback {
            param($Percent, $Status, $Step)
            Write-Progress -Activity "Wingetter - $Step" -Status $Status -PercentComplete $Percent
            Write-Host "[$Step] $Status" -ForegroundColor Gray
        }

    Write-Progress -Activity 'Wingetter' -Completed

    Write-Host @"

Package created successfully!

Application:  $($result.DisplayName)
Package ID:   $($result.PackageId)
Version:      $($result.Version)
Publisher:    $($result.Publisher)
Output:       $($result.VersionDirectory)
IntuneWin:    $($result.IntuneWinFile)
Log:          $($result.LogPath)

Files created:
  install.ps1, uninstall.ps1, detection.ps1
  README.md (full Intune upload reference)
  readme.txt, app.json, win32LobApp.json
  icon.png, packaging.log

"@ -ForegroundColor Green
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
