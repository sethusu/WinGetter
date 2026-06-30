function New-WingetterInstallScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter(Mandatory)]
        [string]$PackageId,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$InstallerFileName,

        [Parameter(Mandatory)]
        [string]$InstallCommand
    )

    $extension = [System.IO.Path]::GetExtension($InstallerFileName).ToLower()
    $isMsi = $extension -eq '.msi'
    $isAppx = $extension -in '.msix', '.appx'

    return @"
# Install script for $DisplayName
# Intune Win32 app install script - runs in SYSTEM context
# Package: $PackageId | Version: $Version

`$ErrorActionPreference = 'Stop'
`$packageId = '$PackageId'
`$version = '$Version'
`$displayName = '$DisplayName'
`$installerFile = '$InstallerFileName'
`$logPath = "`$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\`$packageId-install.log"

Start-Transcript -Path `$logPath -Force
Write-Host "Starting install for `$displayName (`$packageId `$version)"

try {
    `$scriptDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
    Set-Location -Path `$scriptDir

    if (-not (Test-Path `$installerFile)) {
        Write-Host "Installer not found: `$installerFile"
        Stop-Transcript
        Exit 1
    }

$(if ($isAppx) {
@"
    Add-AppxPackage -Path `$installerFile -ErrorAction Stop
    Write-Host "Appx package installed successfully."
    Stop-Transcript
    Exit 0
"@
} elseif ($isMsi) {
@"
    `$arguments = @('/i', `$installerFile, '/quiet', '/norestart', '/l*v', "`$env:TEMP\`$packageId-msi-install.log")
    `$process = Start-Process -FilePath 'msiexec.exe' -ArgumentList `$arguments -Wait -PassThru -NoNewWindow
    Write-Host "msiexec exit code: `$(`$process.ExitCode)"
    Stop-Transcript
    Exit `$process.ExitCode
"@
} else {
@"
    `$process = Start-Process -FilePath `$installerFile -ArgumentList '/S' -Wait -PassThru -NoNewWindow
    Write-Host "Installer exit code: `$(`$process.ExitCode)"

    switch (`$process.ExitCode) {
        0     { Stop-Transcript; Exit 0 }
        3010  { Write-Host 'Soft reboot required (3010).'; Stop-Transcript; Exit 3010 }
        1641  { Write-Host 'Hard reboot required (1641).'; Stop-Transcript; Exit 1641 }
        default { Stop-Transcript; Exit `$process.ExitCode }
    }
"@
})
}
catch {
    Write-Host "Install failed: `$_"
    Stop-Transcript
    Exit 1
}
"@
}

function New-WingetterDetectionScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter(Mandatory)]
        [string]$PackageId,

        [Parameter(Mandatory)]
        [string]$Version
    )

    $firstWord = ($DisplayName -split '\s+')[0]
    $packagePrefix = ($PackageId -split '\.')[0]

    return @"
# Registry-based detection script for $DisplayName
# Intune Win32 app detection - runs in SYSTEM context
# Returns exit 0 when installed at or above expected version

`$ErrorActionPreference = 'Continue'
`$packageId = '$PackageId'
`$version = '$Version'
`$displayName = '$DisplayName'
`$logPath = "`$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\`$packageId-detection.log"

Start-Transcript -Path `$logPath -Force
Write-Host "Starting detection for `$packageId `$version"

`$registryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

`$allMatchingVersions = @()
`$searchTerms = @('*$displayName*', '*$firstWord*', '*$packagePrefix*')

foreach (`$regPath in `$registryPaths) {
    try {
        `$allKeys = Get-ItemProperty `$regPath -ErrorAction SilentlyContinue
        if (-not `$allKeys) { continue }

        `$uninstallKeys = `$allKeys | Where-Object {
            `$key = `$_
            foreach (`$term in `$searchTerms) {
                if ((`$key.DisplayName -and `$key.DisplayName -like `$term) -or
                    (`$key.PSChildName -and `$key.PSChildName -like `$term)) {
                    return `$true
                }
            }
            `$false
        }

        foreach (`$key in `$uninstallKeys) {
            if (-not `$key.DisplayName -or `$key.DisplayName -notlike '*$firstWord*') { continue }

            Write-Host "Found: `$(`$key.DisplayName) | Version: `$(`$key.DisplayVersion)"

            `$extractedVersion = `$null
            if (`$key.DisplayName -match '(\d+\.\d+\.\d+\.\d+)') {
                `$extractedVersion = `$matches[1]
                Write-Host "Extracted marketing version from DisplayName: `$extractedVersion"
            }

            `$versionToUse = if (`$extractedVersion) { `$extractedVersion } else { `$key.DisplayVersion }
            if (`$versionToUse) {
                `$allMatchingVersions += @{
                    DisplayName    = `$key.DisplayName
                    DisplayVersion = `$versionToUse
                }
            }
        }
    }
    catch {
        Write-Host "Error checking `$regPath : `$_"
    }
}

if (`$allMatchingVersions.Count -eq 0) {
    Write-Host "`$packageId not detected in registry."
    Stop-Transcript
    Exit 1
}

`$sorted = `$allMatchingVersions | Sort-Object {
    try { [version]`$_.DisplayVersion } catch { [version]'0.0.0' }
} -Descending

`$installedVersion = `$sorted[0].DisplayVersion
Write-Host "Highest detected version: `$installedVersion"

if ([string]::IsNullOrWhiteSpace(`$version)) {
    Stop-Transcript
    Exit 0
}

try {
    `$installedVer = [version]`$installedVersion
    `$expectedVer = [version]`$version
    if (`$installedVer -ge `$expectedVer) {
        Write-Host "Installed version meets or exceeds expected version."
        Stop-Transcript
        Exit 0
    }
    Write-Host "Installed version `$installedVersion is lower than expected `$version."
    Stop-Transcript
    Exit 1
}
catch {
    if (`$installedVersion -ge `$version) {
        Stop-Transcript
        Exit 0
    }
    Stop-Transcript
    Exit 1
}
"@
}

function New-WingetterUninstallScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter(Mandatory)]
        [string]$PackageId
    )

    return @"
# Uninstall script for $DisplayName
# Intune Win32 app uninstall - runs in SYSTEM context

`$ErrorActionPreference = 'Stop'
`$packageId = '$PackageId'
`$displayName = '$DisplayName'
`$logPath = "`$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\`$packageId-uninstall.log"

Start-Transcript -Path `$logPath -Force
Write-Host "Starting uninstall for `$displayName (`$packageId)"

`$registryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

`$uninstallString = `$null
`$quietUninstallString = `$null

foreach (`$regPath in `$registryPaths) {
    try {
        `$keys = Get-ItemProperty `$regPath -ErrorAction SilentlyContinue | Where-Object {
            `$_.DisplayName -like "*$displayName*" -or
            `$_.PSChildName -like "*$($PackageId.ToLower())*"
        }
        foreach (`$key in `$keys) {
            if (`$key.DisplayName -like "*$displayName*") {
                `$uninstallString = `$key.UninstallString
                `$quietUninstallString = `$key.QuietUninstallString
                Write-Host "Found uninstall string: `$uninstallString"
                break
            }
        }
        if (`$uninstallString) { break }
    }
    catch {
        Write-Host "Error checking `$regPath : `$_"
    }
}

if (-not `$uninstallString) {
    Write-Host "Uninstall string not found for `$packageId"
    Stop-Transcript
    Exit 1
}

`$uninstallCmd = if (`$quietUninstallString) { `$quietUninstallString } else { `$uninstallString }
if (`$uninstallCmd -notmatch '/S' -and `$uninstallCmd -match '\.exe') {
    `$uninstallCmd = `$uninstallCmd -replace '"([^"]+\.exe)"', '"`$1" /S'
    Write-Host 'Added /S flag for silent uninstall.'
}

Write-Host "Executing: `$uninstallCmd"
try {
    `$process = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `$uninstallCmd" -Wait -PassThru -NoNewWindow
    Write-Host "Uninstall exit code: `$(`$process.ExitCode)"
    Stop-Transcript
    Exit `$process.ExitCode
}
catch {
    Write-Host "Uninstall failed: `$_"
    Stop-Transcript
    Exit 1
}
"@
}
