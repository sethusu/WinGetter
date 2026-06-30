# Wingetter.Core.psm1 - Shared packaging logic for CLI and GUI

$script:WingetterLogPath = $null

function Write-WingetterLog {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"

    if ($script:WingetterLogPath) {
        Add-Content -Path $script:WingetterLogPath -Value $line -Encoding UTF8
    }

    switch ($Level) {
        'Success' { Write-Host $line -ForegroundColor Green }
        'Warning' { Write-Host $line -ForegroundColor Yellow }
        'Error'   { Write-Host $line -ForegroundColor Red }
        default   { Write-Host $line -ForegroundColor Cyan }
    }
}

function Invoke-WingetterProgress {
    param(
        [int]$Percent,
        [string]$Status,
        [string]$Step = '',
        [scriptblock]$ProgressCallback
    )

    if ($ProgressCallback) {
        & $ProgressCallback $Percent $Status $Step
    }
}

function ConvertTo-WingetterPackageList {
    param([object]$SearchOutput)

    if ($SearchOutput -is [string]) {
        $SearchOutput = $SearchOutput -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
    } elseif ($SearchOutput -isnot [array]) {
        $SearchOutput = @($SearchOutput)
    }

    $packages = @()
    $headerLineIndex = -1

    for ($i = 0; $i -lt $SearchOutput.Count; $i++) {
        if ($SearchOutput[$i] -match 'Name\s+Id\s+Version') {
            $headerLineIndex = $i
            break
        }
    }

    if ($headerLineIndex -eq -1) {
        for ($i = 0; $i -lt $SearchOutput.Count; $i++) {
            if ($SearchOutput[$i] -match 'Found.*\[') {
                $line = $SearchOutput[$i]
                if ($line -match 'Found\s+(.+?)\s+\[(.+?)\]') {
                    $name = $matches[1].Trim()
                    $id = $matches[2].Trim()
                    $version = 'Unknown'
                    for ($j = $i + 1; $j -lt [Math]::Min($i + 10, $SearchOutput.Count); $j++) {
                        if ($SearchOutput[$j] -match 'Version:\s+(.+)') {
                            $version = $matches[1].Trim()
                            break
                        }
                    }
                    return @([PSCustomObject]@{ Name = $name; Id = $id; Version = $version })
                }
            }
        }
        return @()
    }

    for ($i = $headerLineIndex + 1; $i -lt $SearchOutput.Count; $i++) {
        $line = $SearchOutput[$i]

        if ($line -match '^-+$' -or $line -match '█|▒|KB|MB|%') { continue }
        if ($line.Trim() -eq '' -and $packages.Count -gt 0) {
            $moreData = $false
            for ($j = $i + 1; $j -lt [Math]::Min($i + 3, $SearchOutput.Count); $j++) {
                if ($SearchOutput[$j].Trim() -ne '' -and $SearchOutput[$j] -notmatch '^-+$' -and $SearchOutput[$j] -notmatch '█|▒|KB|MB|%') {
                    $moreData = $true
                    break
                }
            }
            if (-not $moreData) { break }
        }
        if ($line.Trim() -eq '' -and $packages.Count -eq 0) { continue }
        if ($line -match '^[-\s\|\\/]+$') { continue }

        if ($line -match '^\s*(.+?)\s{2,}([A-Za-z0-9][A-Za-z0-9.]*[A-Za-z0-9]|[A-Za-z0-9]+)\s{2,}([0-9][0-9A-Za-z.-]*[0-9A-Za-z]|[0-9]+)') {
            $name = $matches[1].Trim()
            $id = $matches[2].Trim()
            $version = $matches[3].Trim()
            if ($name.Length -gt 0 -and $id.Length -gt 2 -and $id -match '\.' -and $version.Length -gt 0) {
                $packages += [PSCustomObject]@{ Name = $name; Id = $id; Version = $version }
                continue
            }
        }

        $parts = $line -split '\s{2,}', [System.StringSplitOptions]::RemoveEmptyEntries
        if ($parts.Count -ge 3) {
            $name = $parts[0].Trim()
            $id = $parts[1].Trim()
            $version = $parts[2].Trim()
            if ($name.Length -gt 0 -and $id.Length -gt 2 -and $id -match '\.' -and $version -match '^[0-9A-Za-z.-]+$') {
                $packages += [PSCustomObject]@{ Name = $name; Id = $id; Version = $version }
            }
        }
    }

    return $packages
}

function Search-WingetPackage {
    param(
        [Parameter(Mandatory)]
        [string]$SearchTerm,
        [scriptblock]$ProgressCallback
    )

    Invoke-WingetterProgress -Percent 5 -Status 'Searching Winget...' -Step 'Search' -ProgressCallback $ProgressCallback

    $supportsPackageAgreements = winget search --help 2>&1 | Select-String -Pattern 'accept-package-agreements' -Quiet
    if ($supportsPackageAgreements) {
        $searchResult = winget search $SearchTerm --accept-source-agreements --accept-package-agreements 2>&1
    } else {
        $searchResult = winget search $SearchTerm --accept-source-agreements 2>&1
    }

    $hasResults = $searchResult | Select-String -Pattern 'Name\s+Id\s+Version|Found.*\[' -Quiet
    if ($LASTEXITCODE -ne 0 -and -not $hasResults) {
        throw "Winget search failed. Is Winget installed? Output: $($searchResult -join "`n")"
    }

    $packages = ConvertTo-WingetterPackageList -SearchOutput $searchResult
    if ($packages.Count -eq 0) {
        throw 'No packages found for the search term.'
    }

    return $packages
}

function Get-WingetPackageDetails {
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,
        [string]$Version
    )

    $supportsPackageAgreements = winget show --help 2>&1 | Select-String -Pattern 'accept-package-agreements' -Quiet
    $args = @('show', $PackageId, '--exact', '--accept-source-agreements')
    if ($supportsPackageAgreements) { $args += '--accept-package-agreements' }
    if ($Version) { $args += @('--version', $Version) }

    $appInfo = & winget @args 2>&1
    $hasAppInfo = $appInfo | Select-String -Pattern 'Found.*\[|Version:\s+|Publisher:\s+' -Quiet
    if ($LASTEXITCODE -ne 0 -and -not $hasAppInfo) {
        throw "Failed to get app information from Winget. Output: $($appInfo -join "`n")"
    }

    $extractedPackageId = ($appInfo | Select-String -Pattern 'Found (.+?) \[(.+?)\]' | ForEach-Object { $_.Matches.Groups[2].Value })
    if ($extractedPackageId) { $PackageId = $extractedPackageId }

    $foundVersion = ($appInfo | Select-String -Pattern 'Version:\s+(.+)' | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    if ($Version) { $foundVersion = $Version }
    if (-not $foundVersion) { throw 'Could not determine version from Winget output.' }

    $displayName = ($appInfo | Select-String -Pattern 'Found (.+?) \[' | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    if (-not $displayName) { $displayName = $PackageId }

    $publisher = ($appInfo | Select-String -Pattern 'Publisher:\s+(.+)' | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    if (-not $publisher) { $publisher = 'Unknown' }

    $description = ($appInfo | Select-String -Pattern 'Description:\s+(.+)' | ForEach-Object { $_.Line -replace '^\s*Description:\s*', '' })
    if (-not $description) { $description = 'No description available.' }

    $homepage = ($appInfo | Select-String -Pattern 'Homepage:\s+(.+)' | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    if (-not $homepage) { $homepage = '' }

    [PSCustomObject]@{
        PackageId     = $PackageId
        DisplayName   = $displayName
        Version       = $foundVersion
        Publisher     = $publisher
        Description   = $description
        Homepage      = $homepage
        RawAppInfo    = ($appInfo -join "`n")
    }
}

function Extract-WingetterIconFromExe {
    param([string]$ExePath, [string]$OutputPath)

    try {
        Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public class WingetterIconExtractor {
    [DllImport("shell32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr ExtractIcon(IntPtr hInst, string lpszExeFileName, int nIconIndex);
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);
    public static bool ExtractToPng(string exePath, string outputPath) {
        try {
            IntPtr hIcon = ExtractIcon(IntPtr.Zero, exePath, 0);
            if (hIcon != IntPtr.Zero) {
                Icon icon = Icon.FromHandle(hIcon);
                using (Bitmap bmp = icon.ToBitmap()) {
                    bmp.Save(outputPath, ImageFormat.Png);
                }
                DestroyIcon(hIcon);
                return true;
            }
        } catch { }
        return false;
    }
}
"@ -ErrorAction SilentlyContinue

        if ([WingetterIconExtractor]::ExtractToPng($ExePath, $OutputPath)) {
            if ((Test-Path $OutputPath) -and (Get-Item $OutputPath).Length -gt 0) {
                return $true
            }
        }
    } catch { }

    return $false
}

function Get-WingetterLogo {
    param(
        [string]$PackageId,
        [string]$DisplayName,
        [string]$Publisher,
        [string]$Homepage,
        [string]$OutputPath,
        [string]$InstallerPath = $null,
        [scriptblock]$ProgressCallback
    )

    $urls = @()

    if ($PackageId -like 'JetBrains.*' -or $Publisher -like '*JetBrains*') {
        $productName = $PackageId -replace 'JetBrains\.', ''
        $urls += @(
            "https://resources.jetbrains.com/storage/products/$($productName.ToLower())/img/meta/$($productName.ToLower())_logo_300x300.png",
            "https://www.jetbrains.com/$($productName.ToLower())/img/$($productName.ToLower())_logo_300x300.png"
        )
    }

    $githubOrg = $null
    $githubRepo = $null
    if ($Homepage -match 'github\.com/([^/]+)/([^/]+)') {
        $githubOrg = $matches[1]
        $githubRepo = $matches[2] -replace '/.*$', ''
    }

    if ($PackageId -like '*.*' -or $Homepage -like '*github.com*') {
        $parts = $PackageId -split '\.'
        $projectName = if ($parts.Count -gt 1) { $parts[-1] } else { $PackageId }
        $orgName = if ($parts.Count -gt 1) { $parts[0] } else { $projectName }
        if ($githubOrg -and $githubRepo) { $orgName = $githubOrg; $projectName = $githubRepo }

        foreach ($branch in @('main', 'master')) {
            foreach ($path in @('logo.png', 'icon.png', 'assets/logo.png', 'img/logo.png')) {
                $urls += "https://raw.githubusercontent.com/$orgName/$projectName/$branch/$path"
            }
        }
    }

    if ($Homepage -and $Homepage -notlike '*github.com*') {
        $homepageBase = $Homepage.TrimEnd('/')
        foreach ($path in @('logo.png', 'icon.png', 'images/logo.png', 'assets/logo.png')) {
            $urls += "$homepageBase/$path"
        }
    }

    if ($PackageId -like '*.*') {
        $parts = $PackageId -split '\.'
        $firstChar = $parts[0].Substring(0, 1).ToLower()
        $urls += "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$firstChar/$($parts[0])/$($parts[1])/icon.png"
    }

    $urls = $urls | Select-Object -Unique | Select-Object -First 30
    $index = 0

    foreach ($url in $urls) {
        $index++
        Invoke-WingetterProgress -Percent ([math]::Min(90, 70 + ($index * 2))) -Status "Trying logo: $url" -Step 'Icon' -ProgressCallback $ProgressCallback
        try {
            Invoke-WebRequest -Uri $url -OutFile $OutputPath -ErrorAction Stop -TimeoutSec 8
            if (Test-Path $OutputPath) {
                $bytes = [System.IO.File]::ReadAllBytes($OutputPath)
                if ($bytes.Length -gt 8) {
                    $isImage = ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50) -or ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8)
                    if ($isImage) { return $true }
                }
                Remove-Item $OutputPath -ErrorAction SilentlyContinue
            }
        } catch {
            if (Test-Path $OutputPath) { Remove-Item $OutputPath -ErrorAction SilentlyContinue }
        }
    }

    if ($InstallerPath -and (Test-Path $InstallerPath) -and $InstallerPath -like '*.exe') {
        return (Extract-WingetterIconFromExe -ExePath $InstallerPath -OutputPath $OutputPath)
    }

    return $false
}

function Start-WingetterDownload {
    param(
        [string]$PackageId,
        [string]$DownloadDirectory,
        [string]$PackageName,
        [scriptblock]$ProgressCallback
    )

    $supportsPackageAgreements = winget download --help 2>&1 | Select-String -Pattern 'accept-package-agreements' -Quiet

    $job = Start-Job -ScriptBlock {
        param($pkgId, $dir, $supportsPkgAgreements)
        if ($supportsPkgAgreements) {
            winget download $pkgId --exact --download-directory $dir --accept-source-agreements --accept-package-agreements 2>&1
        } else {
            winget download $pkgId --exact --download-directory $dir --accept-source-agreements 2>&1
        }
    } -ArgumentList $PackageId, $DownloadDirectory, $supportsPackageAgreements

    $previousSize = 0
    $expectedSize = $null

    while ($job.State -eq 'Running') {
        $files = Get-ChildItem -Path $DownloadDirectory -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.exe', '.msi', '.msix', '.appx', '' -and $_.Name -notlike '*intunewin*' }

        if ($files) {
            $currentFile = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $currentSize = $currentFile.Length
            $percent = if ($expectedSize -and $expectedSize -gt 0) {
                [math]::Min(99, [math]::Round(($currentSize / $expectedSize) * 100))
            } elseif ($currentSize -gt $previousSize) {
                [math]::Min(95, [math]::Round($currentSize / 1MB))
            } else { 5 }

            $sizeMB = [math]::Round($currentSize / 1MB, 2)
            Invoke-WingetterProgress -Percent $percent -Status "Downloading $PackageName ($sizeMB MB)" -Step 'Download' -ProgressCallback $ProgressCallback
            $previousSize = $currentSize
        } else {
            Invoke-WingetterProgress -Percent 10 -Status 'Initializing download...' -Step 'Download' -ProgressCallback $ProgressCallback
        }

        Start-Sleep -Milliseconds 500
    }

    $jobOutput = Receive-Job -Job $job
    Remove-Job -Job $job -Force
    Invoke-WingetterProgress -Percent 100 -Status 'Download complete' -Step 'Download' -ProgressCallback $ProgressCallback

    if ($jobOutput) {
        $errorIndicators = $jobOutput | Select-String -Pattern 'error|failed|exception' -CaseSensitive:$false
        if ($errorIndicators) {
            throw "Winget download may have failed: $($jobOutput -join "`n")"
        }
    }

    return $jobOutput
}

function New-WingetterInstallScript {
    param(
        [string]$PackageId,
        [string]$DisplayName,
        [string]$Version,
        [string]$InstallCommand,
        [string]$InstallerFileName
    )

    @"
# Install script for $DisplayName
# Intune Win32 app install script - runs as SYSTEM from package content folder

`$ErrorActionPreference = 'Continue'
`$packageId = '$PackageId'
`$displayName = '$DisplayName'
`$expectedVersion = '$Version'
`$logPath = "`$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\`$packageId-install.log"

Start-Transcript -Path `$logPath -Force
Write-Host "Starting install for `$displayName (`$packageId) version `$expectedVersion"

try {
    Set-Location -Path `$PSScriptRoot
    Write-Host "Working directory: `$(Get-Location)"

    `$installerPath = Join-Path `$PSScriptRoot '$InstallerFileName'
    if (-not (Test-Path `$installerPath)) {
        Write-Host "Installer not found: `$installerPath"
        Stop-Transcript
        Exit 1
    }

    `$installCommand = '$($InstallCommand -replace "'", "''")'
    Write-Host "Executing: `$installCommand"

    `$process = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `$installCommand" -Wait -PassThru -NoNewWindow
    `$exitCode = `$process.ExitCode
    Write-Host "Install completed with exit code: `$exitCode"

  # Intune success / reboot return codes
    switch (`$exitCode) {
        0     { Write-Host 'Install succeeded'; Stop-Transcript; Exit 0 }
        1707  { Write-Host 'Install succeeded (1707)'; Stop-Transcript; Exit 0 }
        3010  { Write-Host 'Install succeeded, soft reboot required (3010)'; Stop-Transcript; Exit 3010 }
        1641  { Write-Host 'Install succeeded, hard reboot required (1641)'; Stop-Transcript; Exit 1641 }
        1618  { Write-Host 'Another installation in progress (1618)'; Stop-Transcript; Exit 1618 }
        default { Write-Host "Install failed with exit code `$exitCode"; Stop-Transcript; Exit `$exitCode }
    }
}
catch {
    Write-Host "Install error: `$_"
    Stop-Transcript
    Exit 1
}
"@
}

function New-WingetterDetectionScript {
    param(
        [string]$PackageId,
        [string]$DisplayName,
        [string]$Version
    )

    $firstWord = ($DisplayName -split '\s+')[0]
    $firstPackagePart = ($PackageId -split '\.')[0]

    @"
# Registry-based detection script for $DisplayName
`$packageId = '$PackageId'
`$version = '$Version'
`$displayName = '$DisplayName'
`$logPath = "`$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\`$packageId-detection.log"

Start-Transcript -Path `$logPath -Force
Write-Host "Starting `$packageId `$version detection"

`$registryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

`$allMatchingVersions = @()

foreach (`$regPath in `$registryPaths) {
    try {
        `$allKeys = Get-ItemProperty `$regPath -ErrorAction SilentlyContinue
        if (-not `$allKeys) { continue }

        `$searchTerms = @('*$DisplayName*', '*$firstWord*', '*$firstPackagePart*')
        `$uninstallKeys = `$allKeys | Where-Object {
            `$key = `$_
            foreach (`$term in `$searchTerms) {
                if ((`$key.DisplayName -and `$key.DisplayName -like `$term) -or (`$key.PSChildName -like `$term)) { return `$true }
            }
            `$false
        }

        foreach (`$key in `$uninstallKeys) {
            if (-not `$key.DisplayName -or `$key.DisplayName -notlike '*$firstWord*') { continue }

            `$extractedVersion = `$null
            if (`$key.DisplayName -match '(\d+\.\d+\.\d+\.\d+)') {
                `$extractedVersion = `$matches[1]
            }
            `$versionToUse = if (`$extractedVersion) { `$extractedVersion } else { `$key.DisplayVersion }
            if (`$versionToUse) {
                `$allMatchingVersions += @{ DisplayName = `$key.DisplayName; DisplayVersion = `$versionToUse }
            }
        }
    }
    catch {
        Write-Host "Registry check error on `$regPath : `$_"
    }
}

if (`$allMatchingVersions.Count -eq 0) {
    Write-Host 'Application not detected'
    Stop-Transcript
    Exit 1
}

`$installedVersion = if (`$allMatchingVersions.Count -eq 1) {
    `$allMatchingVersions[0].DisplayVersion
} else {
    (`$allMatchingVersions | Sort-Object { try { [version]`$_.DisplayVersion } catch { [version]'0.0.0' } } -Descending)[0].DisplayVersion
}

Write-Host "Detected version: `$installedVersion"

if ([string]::IsNullOrWhiteSpace(`$version)) {
    Stop-Transcript
    Exit 0
}

try {
    if ([version]`$installedVersion -ge [version]`$version) {
        Stop-Transcript
        Exit 0
    }
}
catch {
    if (`$installedVersion -ge `$version) { Stop-Transcript; Exit 0 }
}

Stop-Transcript
Exit 1
"@
}

function New-WingetterUninstallScript {
    param(
        [string]$PackageId,
        [string]$DisplayName
    )

    @"
# Uninstall script for $DisplayName
`$packageId = '$PackageId'
`$displayName = '$DisplayName'
`$logPath = "`$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\`$packageId-uninstall.log"

Start-Transcript -Path `$logPath -Force
Write-Host "Starting uninstall for `$displayName"

`$registryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

`$uninstallString = `$null
`$quietUninstallString = `$null

foreach (`$regPath in `$registryPaths) {
    try {
        `$uninstallKeys = Get-ItemProperty `$regPath -ErrorAction SilentlyContinue | Where-Object {
            `$_.DisplayName -like "*$DisplayName*" -or `$_.PSChildName -like "*$($PackageId.ToLower())*"
        }
        foreach (`$key in `$uninstallKeys) {
            if (`$key.DisplayName -like "*$DisplayName*") {
                `$uninstallString = `$key.UninstallString
                `$quietUninstallString = `$key.QuietUninstallString
                break
            }
        }
        if (`$uninstallString) { break }
    }
    catch { Write-Host "Registry error: `$_" }
}

if (-not `$uninstallString) {
    Write-Host 'Uninstall string not found'
    Stop-Transcript
    Exit 1
}

`$uninstallCmd = if (`$quietUninstallString) { `$quietUninstallString } else { `$uninstallString }
if (`$uninstallCmd -notmatch '/S' -and `$uninstallCmd -match '\.exe') {
    `$uninstallCmd = `$uninstallCmd -replace '"([^"]+\.exe)"', '"`$1" /S'
}

Write-Host "Executing: `$uninstallCmd"
try {
    `$process = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `$uninstallCmd" -Wait -PassThru -NoNewWindow
    Stop-Transcript
    Exit `$process.ExitCode
}
catch {
    Write-Host "Uninstall error: `$_"
    Stop-Transcript
    Exit 1
}
"@
}

function New-WingetterReadmeMarkdown {
    param(
        [hashtable]$Metadata
    )

    $returnCodesTable = @'
| Return Code | Type | Meaning |
|-------------|------|---------|
| 0 | success | Installation succeeded |
| 1707 | success | Installation succeeded (alternate) |
| 3010 | softReboot | Success, restart required (soft) |
| 1641 | hardReboot | Success, restart required (hard) |
| 1618 | retry | Another installation in progress |
'@

    @"
# $($Metadata.DisplayName)

> Generated by **Wingetter** on $($Metadata.GeneratedAt)

## Application Description

$($Metadata.Description)

## Intune Win32 App Upload Reference

Use this section when creating the app in the Microsoft Intune admin center.

### General Information

| Field | Value |
|-------|-------|
| **Display name** | $($Metadata.DisplayName) |
| **Description** | See [Application Description](#application-description) above |
| **Publisher** | $($Metadata.Publisher) |
| **Developer** | $($Metadata.Publisher) |
| **Version** | $($Metadata.Version) |
| **Information URL** | $($Metadata.Homepage) |
| **Winget Package ID** | ``$($Metadata.PackageId)`` |
| **Notes** | $($Metadata.Notes) |

### Program

| Field | Value |
|-------|-------|
| **Install command** | ``$($Metadata.InstallCommand)`` |
| **Uninstall command** | ``$($Metadata.UninstallCommand)`` |
| **Install behavior** | System |
| **Device restart behavior** | Based on return code |
| **Setup file** | ``$($Metadata.InstallerFileName)`` |
| **IntuneWin file** | ``$($Metadata.IntuneWinFileName)`` |
| **Installer SHA256** | ``$($Metadata.InstallerHash)`` |
| **Applicable architectures** | x64 |
| **Minimum OS** | Windows 10 2004 (20H1) |

### Detection

| Field | Value |
|-------|-------|
| **Detection type** | PowerShell script |
| **Script file** | ``detection.ps1`` |
| **Run as 32-bit** | No |
| **Enforce signature check** | No |
| **Detection logic** | Registry-based version check for $($Metadata.DisplayName) |

### Return Codes

$returnCodesTable

### Additional Settings

| Field | Value |
|-------|-------|
| **Allow available uninstall** | Yes |
| **Install script** | ``install.ps1`` (wraps install command with logging) |
| **Uninstall script** | ``uninstall.ps1`` |
| **Icon file** | ``icon.png`` $(if ($Metadata.HasIcon) { '(included)' } else { '(not available)' }) |

## Package Contents

``````
$($Metadata.OutputDirectory)/
├── install.ps1
├── uninstall.ps1
├── detection.ps1
├── README.md
├── readme.txt
├── app.json
├── win32LobApp.json
├── icon.png
├── $($Metadata.InstallerFileName)
├── packaging.log
└── ../$($Metadata.IntuneWinFileName)
``````

## Deployment Notes

1. Upload ``$($Metadata.IntuneWinFileName)`` to Intune as a **Windows app (Win32)**.
2. Use the **Install command** and **Uninstall command** from the Program table above, or reference the generated ``install.ps1`` / ``uninstall.ps1`` scripts.
3. Paste the contents of ``detection.ps1`` into the PowerShell detection rule, or use ``win32LobApp.json`` with Microsoft Graph.
4. Review ``packaging.log`` if packaging failed.

## Winget Source Details

``````text
$($Metadata.RawAppInfo)
``````
"@
}

function Invoke-WingetterPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,
        [string]$Version,
        [string]$DisplayName,
        [string]$OutputPath = "$env:USERPROFILE\Documents\Wingetter Output",
        [string]$IconPath,
        [scriptblock]$ProgressCallback
    )

    $script:WingetterLogPath = $null
    $versionDirectory = $null
    $intunewinFile = $null

    try {
        Invoke-WingetterProgress -Percent 0 -Status 'Starting packaging...' -Step 'Init' -ProgressCallback $ProgressCallback
        Write-WingetterLog "Starting package for $PackageId"

        $details = Get-WingetPackageDetails -PackageId $PackageId -Version $Version
        $packageId = $details.PackageId
        $foundVersion = $details.Version
        if (-not $DisplayName) { $DisplayName = $details.DisplayName }
        $publisher = $details.Publisher
        $description = $details.Description
        $homepage = $details.Homepage

        Invoke-WingetterProgress -Percent 10 -Status "Preparing $DisplayName $foundVersion" -Step 'Prepare' -ProgressCallback $ProgressCallback

        $appDirectory = Join-Path $OutputPath $packageId
        $versionDirectory = Join-Path $appDirectory $foundVersion
        New-Item -ItemType Directory -Path $versionDirectory -Force | Out-Null

        $script:WingetterLogPath = Join-Path $versionDirectory 'packaging.log'
        if (Test-Path $script:WingetterLogPath) { Remove-Item $script:WingetterLogPath -Force }
        Write-WingetterLog "Output directory: $versionDirectory"

        Invoke-WingetterProgress -Percent 15 -Status 'Downloading installer...' -Step 'Download' -ProgressCallback $ProgressCallback
        Start-WingetterDownload -PackageId $packageId -DownloadDirectory $versionDirectory -PackageName $DisplayName -ProgressCallback $ProgressCallback | Out-Null
        Start-Sleep -Seconds 1

        $installerFile = Get-ChildItem -Path $versionDirectory -File |
            Where-Object { $_.Extension -in '.exe', '.msi', '.msix', '.appx' -and $_.Name -notlike '*intunewin*' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if (-not $installerFile) { throw 'Could not find downloaded installer file.' }

        $installerFileName = $installerFile.Name
        $installerExtension = $installerFile.Extension.ToLower()

        if ($installerExtension -eq '.msi') {
            $installCommand = "msiexec /i `"$installerFileName`" /quiet /norestart"
        } elseif ($installerExtension -in '.msix', '.appx') {
            $installCommand = "Add-AppxPackage -Path `"$installerFileName`""
        } else {
            $installCommand = "`"$installerFileName`" /S"
        }

        $installPs1Command = "%windir%\sysnative\windowspowershell\v1.0\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File install.ps1"
        $uninstallCommand = "%windir%\sysnative\windowspowershell\v1.0\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File uninstall.ps1"

        Invoke-WingetterProgress -Percent 45 -Status 'Calculating installer hash...' -Step 'Hash' -ProgressCallback $ProgressCallback
        $installerHash = (Get-FileHash -Path $installerFile.FullName -Algorithm SHA256).Hash
        Write-WingetterLog "Installer hash: $installerHash"

        Invoke-WingetterProgress -Percent 50 -Status 'Creating PowerShell scripts...' -Step 'Scripts' -ProgressCallback $ProgressCallback

        $installScript = New-WingetterInstallScript -PackageId $packageId -DisplayName $DisplayName -Version $foundVersion -InstallCommand $installCommand -InstallerFileName $installerFileName
        $installScript | Set-Content -Path (Join-Path $versionDirectory 'install.ps1') -Encoding UTF8

        $detectionScript = New-WingetterDetectionScript -PackageId $packageId -DisplayName $DisplayName -Version $foundVersion
        $detectionScript | Set-Content -Path (Join-Path $versionDirectory 'detection.ps1') -Encoding UTF8

        $uninstallScript = New-WingetterUninstallScript -PackageId $packageId -DisplayName $DisplayName
        $uninstallScript | Set-Content -Path (Join-Path $versionDirectory 'uninstall.ps1') -Encoding UTF8

        Write-WingetterLog 'Created install.ps1, detection.ps1, uninstall.ps1'

        Invoke-WingetterProgress -Percent 60 -Status 'Fetching application icon...' -Step 'Icon' -ProgressCallback $ProgressCallback
        $iconFilePath = Join-Path $versionDirectory 'icon.png'
        $logoFilePath = Join-Path $appDirectory 'logo.png'
        $hasIcon = $false

        if ($IconPath -and (Test-Path $IconPath)) {
            Copy-Item -Path $IconPath -Destination $iconFilePath -Force
            $hasIcon = $true
        } elseif (Test-Path $logoFilePath) {
            Copy-Item -Path $logoFilePath -Destination $iconFilePath -Force
            $hasIcon = $true
        } else {
            $hasIcon = Get-WingetterLogo -PackageId $packageId -DisplayName $DisplayName -Publisher $publisher -Homepage $homepage -OutputPath $logoFilePath -InstallerPath $installerFile.FullName -ProgressCallback $ProgressCallback
            if ($hasIcon) { Copy-Item -Path $logoFilePath -Destination $iconFilePath -Force }
        }

        Invoke-WingetterProgress -Percent 75 -Status 'Creating metadata files...' -Step 'Metadata' -ProgressCallback $ProgressCallback

        $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $intunewinFileName = "$($installerFile.BaseName).intunewin"
        $notes = "Generated by Wingetter at $generatedAt [Winget|$packageId]"

        $readmeTxt = @"
Package $packageId $foundVersion from Winget

Display name: $DisplayName
Version: $foundVersion
Publisher: $publisher
Homepage: $homepage

Install command:
$installPs1Command

Uninstall command:
$uninstallCommand

Description:
$description
"@
        $readmeTxt | Set-Content -Path (Join-Path $versionDirectory 'readme.txt') -Encoding UTF8

        $appJson = @{
            packageIdentifier = $packageId
            displayName = $DisplayName
            description = $description
            version = $foundVersion
            source = 2
            publisher = $publisher
            informationUrl = $homepage
            publisherUrl = $homepage
            supportUrl = $homepage
            installerType = 7
            installerUrl = ''
            hash = $installerHash
            installCommandLine = $installPs1Command
            uninstallCommandLine = $uninstallCommand
            installerFilename = $installerFileName
            installerContext = 2
            architecture = 2
        }
        $appJson | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $versionDirectory 'app.json') -Encoding UTF8

        $detectionScriptBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($detectionScript))
        $iconBase64 = ''
        if ($hasIcon -and (Test-Path $iconFilePath)) {
            $iconBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($iconFilePath))
        }

        $win32LobAppJson = @{
            '@odata.type' = '#microsoft.graph.win32LobApp'
            description = $description
            developer = $publisher
            displayName = $DisplayName
            informationUrl = $homepage
            notes = $notes
            publisher = $publisher
            fileName = $intunewinFileName
            allowAvailableUninstall = $true
            applicableArchitectures = 'x64'
            detectionRules = @(@{
                '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptDetection'
                enforceSignatureCheck = $false
                runAs32Bit = $false
                scriptContent = $detectionScriptBase64
            })
            displayVersion = $foundVersion
            installCommandLine = $installPs1Command
            installExperience = @{
                deviceRestartBehavior = 'basedOnReturnCode'
                runAsAccount = 'system'
            }
            minimumSupportedOperatingSystem = @{ v10_2004 = $true }
            minimumSupportedWindowsRelease = '2004'
            returnCodes = @(
                @{ returnCode = 0; type = 'success' }
                @{ returnCode = 1707; type = 'success' }
                @{ returnCode = 3010; type = 'softReboot' }
                @{ returnCode = 1641; type = 'hardReboot' }
                @{ returnCode = 1618; type = 'retry' }
            )
            setupFilePath = $installerFileName
            uninstallCommandLine = $uninstallCommand
        }
        if ($iconBase64) {
            $win32LobAppJson.largeIcon = @{ type = 'image/png'; value = $iconBase64 }
        }
        $win32LobAppJson | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $versionDirectory 'win32LobApp.json') -Encoding UTF8

        $readmeMd = New-WingetterReadmeMarkdown -Metadata @{
            DisplayName = $DisplayName
            Description = $description
            Publisher = $publisher
            Version = $foundVersion
            Homepage = $homepage
            PackageId = $packageId
            Notes = $notes
            InstallCommand = $installPs1Command
            UninstallCommand = $uninstallCommand
            InstallerFileName = $installerFileName
            IntuneWinFileName = $intunewinFileName
            InstallerHash = $installerHash
            HasIcon = $hasIcon
            OutputDirectory = $versionDirectory
            GeneratedAt = $generatedAt
            RawAppInfo = $details.RawAppInfo
        }
        $readmeMd | Set-Content -Path (Join-Path $versionDirectory 'README.md') -Encoding UTF8

        Invoke-WingetterProgress -Percent 85 -Status 'Creating IntuneWin package...' -Step 'Package' -ProgressCallback $ProgressCallback

        $intunewinCmd = Get-Command intunewinapputil -ErrorAction SilentlyContinue
        if (-not $intunewinCmd) { throw 'intunewinapputil not found. Install Microsoft Win32 Content Prep Tool.' }

        $outputDirectory = Split-Path $versionDirectory
        $intunewinFile = Join-Path $outputDirectory $intunewinFileName
        if (Test-Path $intunewinFile) { Remove-Item -Path $intunewinFile -Force }

        & intunewinapputil -c $versionDirectory -s $installerFileName -o $outputDirectory -q
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $intunewinFile)) {
            throw 'Content Prep Tool failed or output file not found.'
        }

        Write-WingetterLog "Created IntuneWin: $intunewinFile" -Level Success
        Invoke-WingetterProgress -Percent 100 -Status 'Package complete!' -Step 'Complete' -ProgressCallback $ProgressCallback

        return [PSCustomObject]@{
            Success = $true
            PackageId = $packageId
            DisplayName = $DisplayName
            Version = $foundVersion
            Publisher = $publisher
            VersionDirectory = $versionDirectory
            IntuneWinFile = $intunewinFile
            IconPath = if ($hasIcon) { $iconFilePath } else { $null }
            InstallerFile = $installerFile.FullName
            LogPath = $script:WingetterLogPath
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-WingetterLog $errorMessage -Level Error

        if ($versionDirectory -and -not $script:WingetterLogPath) {
            $script:WingetterLogPath = Join-Path $versionDirectory 'packaging.log'
            Write-WingetterLog $errorMessage -Level Error
        }

        if ($versionDirectory) {
            $failureLog = Join-Path $versionDirectory 'packaging-failure.log'
            @"
Wingetter Packaging Failure
Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Package: $PackageId
Error: $errorMessage

Stack Trace:
$($_.ScriptStackTrace)
"@ | Set-Content -Path $failureLog -Encoding UTF8
        }

        Invoke-WingetterProgress -Percent 0 -Status "Failed: $errorMessage" -Step 'Error' -ProgressCallback $ProgressCallback
        throw
    }
}

Export-ModuleMember -Function @(
    'Search-WingetPackage',
    'Get-WingetPackageDetails',
    'ConvertTo-WingetterPackageList',
    'Invoke-WingetterPackage',
    'Get-WingetterLogo',
    'Write-WingetterLog'
)
