# Wingetter.Core.ps1 - Shared packaging engine for CLI and GUI

$script:WingetterTotalSteps = 11

function Write-WingetterLog {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info',
        [scriptblock]$OnProgress
    )

    if ($OnProgress) {
        & $OnProgress @{
            Type     = 'Log'
            Level    = $Level
            Message  = $Message
        }
    }

    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        default   { 'Gray' }
    }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Send-WingetterProgress {
    param(
        [int]$StepNumber,
        [string]$Step,
        [int]$Percent = -1,
        [string]$Message = '',
        [scriptblock]$OnProgress
    )

    if ($OnProgress) {
        & $OnProgress @{
            Type        = 'Progress'
            StepNumber  = $StepNumber
            TotalSteps  = $script:WingetterTotalSteps
            Step        = $Step
            Percent     = $Percent
            Message     = $Message
        }
    }
}

function Get-WingetSupportsPackageAgreements {
    $testCommand = winget search --help 2>&1 | Select-String -Pattern 'accept-package-agreements' -Quiet
    return [bool]$testCommand
}

function ConvertFrom-WingetSearchOutput {
    param([object]$SearchOutput)

    if ($SearchOutput -is [string]) {
        $SearchOutput = $SearchOutput -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
    }
    elseif ($SearchOutput -isnot [array]) {
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

        if ($line -match '^-+$' -or ($line.Trim() -eq '' -and $packages.Count -eq 0)) { continue }

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

        if ($line -match '█|▒|KB|MB|%' -or ($line.Length -lt 10 -and $line.Trim() -ne '')) { continue }
        if ($line -match '^-+$' -or $line -match '^[-\s\|\\/]+$') { continue }

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
            if ($name.Length -gt 0 -and $id.Length -gt 2 -and $id -match '\.' -and $version.Length -gt 0 -and $version -match '^[0-9A-Za-z.-]+$') {
                $packages += [PSCustomObject]@{ Name = $name; Id = $id; Version = $version }
            }
        }
    }

    return $packages
}

function Search-WingetPackages {
    param(
        [Parameter(Mandatory)]
        [string]$SearchTerm,
        [scriptblock]$OnProgress
    )

    Send-WingetterProgress -StepNumber 0 -Step 'Search' -Percent 0 -Message "Searching Winget for '$SearchTerm'..." -OnProgress $OnProgress

    $supportsPackageAgreements = Get-WingetSupportsPackageAgreements
    if ($supportsPackageAgreements) {
        $searchResult = winget search $SearchTerm --accept-source-agreements --accept-package-agreements 2>&1
    }
    else {
        $searchResult = winget search $SearchTerm --accept-source-agreements 2>&1
    }

    $searchExitCode = $LASTEXITCODE
    $hasResults = $searchResult | Select-String -Pattern 'Name\s+Id\s+Version|Found.*\[' -Quiet
    if ($searchExitCode -ne 0 -and -not $hasResults) {
        throw "Winget search failed with exit code $searchExitCode. Is Winget installed?"
    }

    $packages = ConvertFrom-WingetSearchOutput -SearchOutput $searchResult
    if ($packages.Count -eq 0) {
        throw 'No packages found or could not parse search results.'
    }

    Write-WingetterLog -Message "Found $($packages.Count) matching package(s)." -Level Success -OnProgress $OnProgress
    return $packages
}

function Get-WingetAppDetails {
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,
        [string]$Version
    )

    $supportsPackageAgreements = Get-WingetSupportsPackageAgreements
    if ($Version) {
        if ($supportsPackageAgreements) {
            $appInfo = winget show $PackageId --exact --version $Version --accept-source-agreements --accept-package-agreements 2>&1
        }
        else {
            $appInfo = winget show $PackageId --exact --version $Version --accept-source-agreements 2>&1
        }
    }
    else {
        if ($supportsPackageAgreements) {
            $appInfo = winget show $PackageId --exact --accept-source-agreements --accept-package-agreements 2>&1
        }
        else {
            $appInfo = winget show $PackageId --exact --accept-source-agreements 2>&1
        }
    }

    $showExitCode = $LASTEXITCODE
    $hasAppInfo = $appInfo | Select-String -Pattern 'Found.*\[|Version:\s+|Publisher:\s+' -Quiet
    if ($showExitCode -ne 0 -and -not $hasAppInfo) {
        throw "Failed to get app information from Winget (exit code: $showExitCode)."
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

    $description = ($appInfo | Select-String -Pattern 'Description:\s+(.+)' -Context 0, 5 | ForEach-Object { $_.Line.Trim() })
    if (-not $description) { $description = 'No description available' }

    $homepage = ($appInfo | Select-String -Pattern 'Homepage:\s+(.+)' | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    if (-not $homepage) { $homepage = '' }

    return [PSCustomObject]@{
        PackageId     = $PackageId
        DisplayName   = $displayName
        Version       = $foundVersion
        Publisher     = $publisher
        Description   = $description
        Homepage      = $homepage
        RawAppInfo    = $appInfo
    }
}

function Extract-IconFromExe {
    param([string]$ExePath, [string]$OutputPath)

    try {
        Add-Type -TypeDefinition @"
        using System;
        using System.Drawing;
        using System.Drawing.Imaging;
        using System.Runtime.InteropServices;
        public class IconExtractor {
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

        if ([IconExtractor]::ExtractToPng($ExePath, $OutputPath)) {
            if ((Test-Path $OutputPath) -and (Get-Item $OutputPath).Length -gt 0) { return $true }
        }
    }
    catch { }

    return $false
}

function Get-LogoFromWeb {
    param(
        [string]$PackageId,
        [string]$DisplayName,
        [string]$Publisher,
        [string]$Homepage,
        [string]$OutputPath,
        [string]$InstallerPath = $null,
        [scriptblock]$OnProgress
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

        $branches = @('main', 'master')
        $paths = @('logo.png', 'icon.png', 'assets/logo.png', 'assets/icon.png', 'img/logo.png')
        foreach ($branch in $branches) {
            foreach ($path in $paths) {
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
    foreach ($url in $urls) {
        try {
            Write-WingetterLog -Message "Trying logo URL: $url" -OnProgress $OnProgress
            Invoke-WebRequest -Uri $url -OutFile $OutputPath -ErrorAction Stop -TimeoutSec 8 | Out-Null
            if (Test-Path $OutputPath) {
                $bytes = [System.IO.File]::ReadAllBytes($OutputPath)
                if ($bytes.Length -gt 8 -and (
                        ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50) -or
                        ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8)
                    )) {
                    Write-WingetterLog -Message "Downloaded logo from $url" -Level Success -OnProgress $OnProgress
                    return $true
                }
                Remove-Item $OutputPath -ErrorAction SilentlyContinue
            }
        }
        catch {
            if (Test-Path $OutputPath) { Remove-Item $OutputPath -ErrorAction SilentlyContinue }
        }
    }

    if ($InstallerPath -and (Test-Path $InstallerPath) -and $InstallerPath -like '*.exe') {
        if (Extract-IconFromExe -ExePath $InstallerPath -OutputPath $OutputPath) { return $true }
    }

    return $false
}

function Start-WingetDownloadWithProgress {
    param(
        [string]$PackageId,
        [string]$DownloadDirectory,
        [string]$PackageName,
        [scriptblock]$OnProgress
    )

    $supportsPackageAgreements = Get-WingetSupportsPackageAgreements
    $job = Start-Job -ScriptBlock {
        param($pkgId, $dir, $supportsPkgAgreements)
        if ($supportsPkgAgreements) {
            winget download $pkgId --exact --download-directory $dir --accept-source-agreements --accept-package-agreements 2>&1
        }
        else {
            winget download $pkgId --exact --download-directory $dir --accept-source-agreements 2>&1
        }
    } -ArgumentList $PackageId, $DownloadDirectory, $supportsPackageAgreements

    $previousSize = 0
    $previousTime = Get-Date
    $expectedSize = $null

    while ($job.State -eq 'Running') {
        $files = Get-ChildItem -Path $DownloadDirectory -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -notlike '*intunewin*' -and $_.Name -notlike '*ContentPrepTool*' -and
                ($_.Extension -in '.exe', '.msi', '.msix', '.appx', '')
            }

        $jobOutput = Receive-Job -Job $job -ErrorAction SilentlyContinue
        if ($jobOutput -and -not $expectedSize) {
            $sizeMatch = $jobOutput | Select-String -Pattern '(\d+\.?\d*)\s*(MB|GB|KB)' | Select-Object -First 1
            if ($sizeMatch) {
                $sizeValue = [double]($sizeMatch.Matches.Groups[1].Value)
                switch ($sizeMatch.Matches.Groups[2].Value) {
                    'GB' { $expectedSize = $sizeValue * 1GB }
                    'MB' { $expectedSize = $sizeValue * 1MB }
                    'KB' { $expectedSize = $sizeValue * 1KB }
                }
            }
        }

        if ($files) {
            $currentFile = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $currentSize = $currentFile.Length
            $percentComplete = if ($expectedSize -and $expectedSize -gt 0) {
                [math]::Min(100, [math]::Round(($currentSize / $expectedSize) * 100, 2))
            }
            else { [math]::Min(90, [math]::Round($currentSize / 1MB, 0)) }

            $sizeMB = [math]::Round($currentSize / 1MB, 2)
            Send-WingetterProgress -StepNumber 3 -Step 'Download' -Percent $percentComplete `
                -Message "Downloading $($currentFile.Name) ($sizeMB MB)..." -OnProgress $OnProgress

            $previousSize = $currentSize
            $previousTime = Get-Date
        }
        else {
            Send-WingetterProgress -StepNumber 3 -Step 'Download' -Percent 0 -Message 'Initializing download...' -OnProgress $OnProgress
        }

        Start-Sleep -Milliseconds 500
        if ($job.State -ne 'Running') { break }
    }

    $jobOutput = Receive-Job -Job $job
    Remove-Job -Job $job -Force
    if ($jobOutput) {
        $errorIndicators = $jobOutput | Select-String -Pattern 'error|failed|exception' -CaseSensitive:$false
        if ($errorIndicators) { throw "Winget download may have failed: $($jobOutput -join "`n")" }
    }

    return $jobOutput
}

function Get-WingetterInstallCommand {
    param([string]$InstallerFileName, [string]$InstallerExtension)
    switch ($InstallerExtension.ToLower()) {
        '.msi' { return "msiexec /i `"$InstallerFileName`" /quiet /norestart" }
        '.msix' { return "Add-AppxPackage -Path `"$InstallerFileName`"" }
        '.appx' { return "Add-AppxPackage -Path `"$InstallerFileName`"" }
        default { return "`"$InstallerFileName`" /S" }
    }
}

function Get-WingetterPsInvokeCommand {
    return '%windir%\sysnative\windowspowershell\v1.0\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File'
}

function New-WingetterInstallScript {
    param(
        [string]$PackageId,
        [string]$DisplayName,
        [string]$FoundVersion,
        [string]$InstallerFileName,
        [string]$RawInstallCommand
    )

    return @"
# Install script for $DisplayName
# Intune Win32 app install wrapper - runs as SYSTEM from package directory

`$ErrorActionPreference = 'Stop'
`$packageId = '$PackageId'
`$displayName = '$DisplayName'
`$expectedVersion = '$FoundVersion'
`$installerFile = '$InstallerFileName'
`$logPath = "`$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\`$packageId-install.log"

Start-Transcript -Path `$logPath -Force
Write-Host "Starting install for `$displayName (`$packageId) version `$expectedVersion"

try {
    Set-Location -Path `$PSScriptRoot -ErrorAction Stop

    if (-not (Test-Path -LiteralPath `$installerFile)) {
        throw "Installer not found: `$installerFile"
    }

    `$rawCommand = '$($RawInstallCommand -replace "'", "''")'
    Write-Host "Executing: `$rawCommand"

    if (`$rawCommand -match '^msiexec') {
        `$process = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `$rawCommand" -Wait -PassThru -NoNewWindow
    }
    elseif (`$rawCommand -match '^Add-AppxPackage') {
        Invoke-Expression `$rawCommand
        `$process = [PSCustomObject]@{ ExitCode = if (`$?) { 0 } else { 1 } }
    }
    else {
        `$process = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `$rawCommand" -Wait -PassThru -NoNewWindow
    }

    `$exitCode = `$process.ExitCode
    Write-Host "Installer exit code: `$exitCode"

    switch (`$exitCode) {
        0     { Write-Host 'Install succeeded'; Stop-Transcript; Exit 0 }
        3010  { Write-Host 'Install succeeded (reboot required)'; Stop-Transcript; Exit 3010 }
        1641  { Write-Host 'Install succeeded (hard reboot required)'; Stop-Transcript; Exit 1641 }
        1618  { Write-Host 'Another installation in progress'; Stop-Transcript; Exit 1618 }
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
        [string]$FoundVersion
    )

    $firstWord = ($DisplayName -split ' ')[0]
    $firstPackagePart = ($PackageId -split '\.')[0]

    return @"
# Registry-based detection script for $DisplayName
# Intune Win32 app detection - exit 0 if installed at expected version or higher

`$packageId = '$PackageId'
`$version = '$FoundVersion'
`$displayName = '$DisplayName'
`$logPath = "`$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\`$packageId-detection.log"

Start-Transcript -Path `$logPath -Force
Write-Host "Starting `$packageId `$version detection (Registry-based)"

`$registryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

`$found = `$false
`$installedVersion = `$null
`$allMatchingVersions = @()

foreach (`$regPath in `$registryPaths) {
    try {
        `$allKeys = Get-ItemProperty `$regPath -ErrorAction SilentlyContinue
        if (-not `$allKeys) { continue }

        `$searchTerms = @('*$displayName*', '*$firstWord*', '*$firstPackagePart*')
        `$uninstallKeys = `$allKeys | Where-Object {
            `$key = `$_
            foreach (`$term in `$searchTerms) {
                if ((`$key.DisplayName -and `$key.DisplayName -like `$term) -or (`$key.PSChildName -and `$key.PSChildName -like `$term)) {
                    return `$true
                }
            }
            `$false
        }

        foreach (`$key in `$uninstallKeys) {
            Write-Host "Found: `$(`$key.DisplayName) version `$(`$key.DisplayVersion)"
            `$extractedVersion = `$null
            if (`$key.DisplayName -match '(\d+\.\d+\.\d+\.\d+)') {
                `$extractedVersion = `$matches[1]
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
        Write-Host "Registry error on `$regPath : `$_"
    }
}

if (`$allMatchingVersions.Count -gt 0) {
    `$sorted = `$allMatchingVersions | Sort-Object -Property @{
        Expression = { try { [version]`$_.DisplayVersion } catch { [version]'0.0.0' } }
    } -Descending
    `$installedVersion = `$sorted[0].DisplayVersion
    `$found = `$true
    Write-Host "Highest installed version: `$installedVersion"
}

if (`$found) {
    if ([string]::IsNullOrWhiteSpace(`$version)) {
        Stop-Transcript; Exit 0
    }
    try {
        `$installedVer = [version]`$installedVersion
        `$expectedVer = [version]`$version
        if (`$installedVer -ge `$expectedVer) {
            Write-Host 'Detection passed'
            Stop-Transcript; Exit 0
        }
        Write-Host 'Installed version is lower than expected'
        Stop-Transcript; Exit 1
    }
    catch {
        if (`$installedVersion -ge `$version) { Stop-Transcript; Exit 0 }
        Stop-Transcript; Exit 1
    }
}

Write-Host 'Application not detected'
Stop-Transcript; Exit 1
"@
}

function New-WingetterUninstallScript {
    param(
        [string]$PackageId,
        [string]$DisplayName
    )

    return @"
# Uninstall script for $DisplayName
# Intune Win32 app uninstall - uses registry uninstall string

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
            `$_.DisplayName -like "*$DisplayName*" -or `$_.PSChildName -like "*$($PackageId.ToLower())*"
        }
        foreach (`$key in `$keys) {
            if (`$key.DisplayName -like "*$DisplayName*") {
                `$uninstallString = `$key.UninstallString
                `$quietUninstallString = `$key.QuietUninstallString
                break
            }
        }
        if (`$uninstallString) { break }
    }
    catch {
        Write-Host "Registry error: `$_"
    }
}

if (-not `$uninstallString) {
    Write-Host 'Uninstall string not found'
    Stop-Transcript; Exit 1
}

`$uninstallCmd = if (`$quietUninstallString) { `$quietUninstallString } else { `$uninstallString }
if (`$uninstallCmd -notmatch '/S' -and `$uninstallCmd -match '\.exe') {
    `$uninstallCmd = `$uninstallCmd -replace '"([^"]+\.exe)"', '"`$1" /S'
}

Write-Host "Executing: `$uninstallCmd"
try {
    `$process = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `$uninstallCmd" -Wait -PassThru -NoNewWindow
    Write-Host "Uninstall exit code: `$(`$process.ExitCode)"
    Stop-Transcript
    Exit `$process.ExitCode
}
catch {
    Write-Host "Uninstall error: `$_"
    Stop-Transcript; Exit 1
}
"@
}

function New-WingetterReadmeMarkdown {
    param(
        [hashtable]$Metadata
    )

    $psInvoke = Get-WingetterPsInvokeCommand
    $returnCodesTable = @'
| Return Code | Type | Meaning |
|-------------|------|---------|
| 0 | success | Installation/detection succeeded |
| 1707 | success | Alternate success (reboot may be needed) |
| 3010 | softReboot | Success, soft reboot required |
| 1641 | hardReboot | Success, hard reboot required |
| 1618 | retry | Another installation is in progress |
'@

    return @"
# $($Metadata.DisplayName) — Intune Win32 Package

Generated by **Wingetter** on $($Metadata.GeneratedAt).

## Application

| Field | Value |
|-------|-------|
| **Display name** | $($Metadata.DisplayName) |
| **Description** | $($Metadata.Description) |
| **Developer** | $($Metadata.Publisher) |
| **Publisher** | $($Metadata.Publisher) |
| **Display version** | ``$($Metadata.Version)`` |
| **Winget package ID** | ``$($Metadata.PackageId)`` |
| **Information URL** | $($Metadata.Homepage) |
| **Applicable architectures** | x64 |
| **Minimum Windows release** | 2004 (20H1) |

## Intune Win32 LOB App Upload

Use these values when creating the Win32 app in the Microsoft Intune admin center or via Graph API.

| Intune field | Value |
|--------------|-------|
| **Name / Display name** | $($Metadata.DisplayName) |
| **Description** | See *Application* section above |
| **Publisher** | $($Metadata.Publisher) |
| **Developer** | $($Metadata.Publisher) |
| **App version** | $($Metadata.Version) |
| **Install file** | ``$($Metadata.IntuneWinFileName)`` |
| **Setup file (in package)** | ``$($Metadata.InstallerFileName)`` |
| **Install command** | ``$psInvoke install.ps1`` |
| **Uninstall command** | ``$psInvoke uninstall.ps1`` |
| **Install behavior** | System |
| **Device restart behavior** | Based on return code |
| **Allow available uninstall** | Yes |
| **Detection rules** | PowerShell script (``detection.ps1``) |
| **Return codes** | See table below |
| **Notes** | $($Metadata.Notes) |

### Return codes

$returnCodesTable

## Installer

| Field | Value |
|-------|-------|
| **Installer file** | ``$($Metadata.InstallerFileName)`` |
| **SHA-256 hash** | ``$($Metadata.InstallerHash)`` |
| **Raw install command** | ``$($Metadata.RawInstallCommand)`` |

## Package contents

``````
$($Metadata.VersionDirectory)
├── install.ps1
├── uninstall.ps1
├── detection.ps1
├── $($Metadata.InstallerFileName)
├── icon.png
├── app.json
├── win32LobApp.json
├── README.md
├── readme.txt
└── wingetter-pack.log (on failure)
``````

## Log files (on managed devices)

| Script | Log path |
|--------|----------|
| Install | ``%ProgramData%\Microsoft\IntuneManagementExtension\Logs\$($Metadata.PackageId)-install.log`` |
| Uninstall | ``%ProgramData%\Microsoft\IntuneManagementExtension\Logs\$($Metadata.PackageId)-uninstall.log`` |
| Detection | ``%ProgramData%\Microsoft\IntuneManagementExtension\Logs\$($Metadata.PackageId)-detection.log`` |

## Upload steps

1. Upload ``$($Metadata.IntuneWinFileName)`` from ``$($Metadata.OutputDirectory)``
2. Set install/uninstall commands exactly as shown above
3. Add the PowerShell detection script from ``detection.ps1`` (or import ``win32LobApp.json`` via Graph)
4. Assign to a test group and verify install/detection/uninstall

---
*Package ID: $($Metadata.PackageId) | Version: $($Metadata.Version)*
"@
}

function Write-WingetterFailureLog {
    param(
        [string]$LogPath,
        [string]$Step,
        [object]$ErrorRecord
    )

    $content = @"
Wingetter packaging failed
==========================
Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Step: $Step

Error:
$($ErrorRecord.Exception.Message)

Stack trace:
$($ErrorRecord.ScriptStackTrace)

Full error:
$($ErrorRecord | Out-String)
"@
    $content | Set-Content -Path $LogPath -Encoding UTF8
}

function Invoke-WingetterPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,

        [string]$Version,
        [string]$DisplayName,
        [string]$OutputPath = 'D:\Intoon In Progress',
        [string]$IconPath,
        [scriptblock]$OnProgress
    )

    $versionDirectory = $null
    $currentStep = 'Initialize'

    try {
        Send-WingetterProgress -StepNumber 1 -Step 'App details' -Percent 5 -Message 'Fetching Winget metadata...' -OnProgress $OnProgress
        $currentStep = 'App details'
        $appDetails = Get-WingetAppDetails -PackageId $PackageId -Version $Version
        $packageId = $appDetails.PackageId
        $foundVersion = $appDetails.Version
        $displayName = if ($DisplayName) { $DisplayName } else { $appDetails.DisplayName }
        $publisher = $appDetails.Publisher
        $description = $appDetails.Description
        $homepage = $appDetails.Homepage

        Write-WingetterLog -Message "Packaging $displayName ($packageId) v$foundVersion" -Level Success -OnProgress $OnProgress

        Send-WingetterProgress -StepNumber 2 -Step 'Directories' -Percent 10 -Message 'Creating output directories...' -OnProgress $OnProgress
        $currentStep = 'Directories'
        $appDirectory = Join-Path $OutputPath $packageId
        $versionDirectory = Join-Path $appDirectory $foundVersion
        New-Item -ItemType Directory -Path $versionDirectory -Force | Out-Null

        Send-WingetterProgress -StepNumber 3 -Step 'Download' -Percent 15 -Message 'Downloading installer...' -OnProgress $OnProgress
        $currentStep = 'Download'
        $null = Start-WingetDownloadWithProgress -PackageId $packageId -DownloadDirectory $versionDirectory -PackageName $displayName -OnProgress $OnProgress
        Start-Sleep -Seconds 1

        $installerFile = Get-ChildItem -Path $versionDirectory -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -in '.exe', '.msi', '.msix', '.appx' -and
                $_.Name -notlike '*intunewin*' -and $_.Name -notlike '*ContentPrepTool*'
            } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if (-not $installerFile) { throw 'Could not find downloaded installer file.' }

        $installerFileName = $installerFile.Name
        $rawInstallCommand = Get-WingetterInstallCommand -InstallerFileName $installerFileName -InstallerExtension $installerFile.Extension
        $psInvoke = Get-WingetterPsInvokeCommand
        $installCommandLine = "$psInvoke install.ps1"
        $uninstallCommandLine = "$psInvoke uninstall.ps1"

        Send-WingetterProgress -StepNumber 4 -Step 'Hash' -Percent 35 -Message 'Calculating SHA-256 hash...' -OnProgress $OnProgress
        $currentStep = 'Hash'
        $installerHash = (Get-FileHash -Path $installerFile.FullName -Algorithm SHA256).Hash

        Send-WingetterProgress -StepNumber 5 -Step 'Scripts' -Percent 45 -Message 'Generating install.ps1...' -OnProgress $OnProgress
        $currentStep = 'Scripts'
        $installScript = New-WingetterInstallScript -PackageId $packageId -DisplayName $displayName -FoundVersion $foundVersion -InstallerFileName $installerFileName -RawInstallCommand $rawInstallCommand
        $installScript | Set-Content -Path (Join-Path $versionDirectory 'install.ps1') -Encoding UTF8

        Send-WingetterProgress -StepNumber 6 -Step 'Scripts' -Percent 50 -Message 'Generating detection.ps1...' -OnProgress $OnProgress
        $detectionScript = New-WingetterDetectionScript -PackageId $packageId -DisplayName $displayName -FoundVersion $foundVersion
        $detectionScript | Set-Content -Path (Join-Path $versionDirectory 'detection.ps1') -Encoding UTF8

        Send-WingetterProgress -StepNumber 7 -Step 'Scripts' -Percent 55 -Message 'Generating uninstall.ps1...' -OnProgress $OnProgress
        $uninstallScript = New-WingetterUninstallScript -PackageId $packageId -DisplayName $displayName
        $uninstallScript | Set-Content -Path (Join-Path $versionDirectory 'uninstall.ps1') -Encoding UTF8

        Send-WingetterProgress -StepNumber 8 -Step 'Icon' -Percent 60 -Message 'Resolving application icon...' -OnProgress $OnProgress
        $currentStep = 'Icon'
        $iconFilePath = Join-Path $versionDirectory 'icon.png'
        $logoFilePath = Join-Path $appDirectory 'logo.png'

        if ($IconPath -and (Test-Path $IconPath)) {
            Copy-Item -Path $IconPath -Destination $iconFilePath -Force
        }
        elseif (Test-Path $logoFilePath) {
            Copy-Item -Path $logoFilePath -Destination $iconFilePath -Force
        }
        else {
            $downloaded = Get-LogoFromWeb -PackageId $packageId -DisplayName $displayName -Publisher $publisher -Homepage $homepage -OutputPath $logoFilePath -InstallerPath $installerFile.FullName -OnProgress $OnProgress
            if ($downloaded) { Copy-Item -Path $logoFilePath -Destination $iconFilePath -Force }
        }

        if ($OnProgress -and (Test-Path $iconFilePath)) {
            & $OnProgress @{ Type = 'Icon'; Path = $iconFilePath }
        }

        Send-WingetterProgress -StepNumber 9 -Step 'Metadata' -Percent 70 -Message 'Writing metadata files...' -OnProgress $OnProgress
        $currentStep = 'Metadata'
        $outputDirectory = Split-Path $versionDirectory
        $intuneWinFileName = "$($installerFile.BaseName).intunewin"
        $notes = "Generated by Wingetter at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [Winget|$packageId]"

        $readmeTxt = @"
Package $packageId $foundVersion from Winget

Display name: $displayName
Version: $foundVersion
Publisher: $publisher
Homepage: $homepage

Install command: $installCommandLine
Uninstall command: $uninstallCommandLine

Description:
$description
"@
        $readmeTxt | Set-Content -Path (Join-Path $versionDirectory 'readme.txt') -Encoding UTF8

        $metadata = @{
            PackageId           = $packageId
            DisplayName         = $displayName
            Version             = $foundVersion
            Publisher           = $publisher
            Description         = $description
            Homepage            = $homepage
            InstallerFileName   = $installerFileName
            InstallerHash       = $installerHash
            RawInstallCommand   = $rawInstallCommand
            IntuneWinFileName   = $intuneWinFileName
            VersionDirectory    = $versionDirectory
            OutputDirectory     = $outputDirectory
            Notes               = $notes
            GeneratedAt         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }
        New-WingetterReadmeMarkdown -Metadata $metadata | Set-Content -Path (Join-Path $versionDirectory 'README.md') -Encoding UTF8

        $appJson = @{
            packageIdentifier    = $packageId
            displayName          = $displayName
            description          = $description
            version              = $foundVersion
            source               = 2
            publisher            = $publisher
            informationUrl       = $homepage
            publisherUrl         = $homepage
            supportUrl           = $homepage
            installerType        = 7
            installerUrl         = ''
            hash                 = $installerHash
            installCommandLine   = $installCommandLine
            uninstallCommandLine = $uninstallCommandLine
            installerFilename    = $installerFileName
            installerContext     = 2
            architecture         = 2
        }
        $appJson | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $versionDirectory 'app.json') -Encoding UTF8

        $detectionScriptBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Content -Path (Join-Path $versionDirectory 'detection.ps1') -Raw)))
        $iconBase64 = ''
        if (Test-Path $iconFilePath) {
            $iconBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($iconFilePath))
        }

        $win32LobAppJson = @{
            '@odata.type'                       = '#microsoft.graph.win32LobApp'
            description                         = $description
            developer                           = $publisher
            displayName                         = $displayName
            informationUrl                      = $homepage
            notes                               = $notes
            publisher                           = $publisher
            fileName                            = $intuneWinFileName
            allowAvailableUninstall             = $true
            applicableArchitectures             = 'x64'
            detectionRules                      = @(@{
                    '@odata.type'           = '#microsoft.graph.win32LobAppPowerShellScriptDetection'
                    enforceSignatureCheck   = $false
                    runAs32Bit              = $false
                    scriptContent           = $detectionScriptBase64
                })
            displayVersion                      = $foundVersion
            installCommandLine                  = $installCommandLine
            installExperience                   = @{
                deviceRestartBehavior = 'basedOnReturnCode'
                runAsAccount          = 'system'
            }
            minimumSupportedOperatingSystem     = @{ v10_2004 = $true }
            minimumSupportedWindowsRelease      = '2004'
            returnCodes                         = @(
                @{ returnCode = 0; type = 'success' }
                @{ returnCode = 1707; type = 'success' }
                @{ returnCode = 3010; type = 'softReboot' }
                @{ returnCode = 1641; type = 'hardReboot' }
                @{ returnCode = 1618; type = 'retry' }
            )
            setupFilePath                       = $installerFileName
            uninstallCommandLine                = $uninstallCommandLine
        }
        if ($iconBase64) {
            $win32LobAppJson.largeIcon = @{ type = 'image/png'; value = $iconBase64 }
        }
        $win32LobAppJson | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $versionDirectory 'win32LobApp.json') -Encoding UTF8

        Send-WingetterProgress -StepNumber 10 -Step 'Package' -Percent 85 -Message 'Running Content Prep Tool...' -OnProgress $OnProgress
        $currentStep = 'Package'
        $intunewinCmd = Get-Command intunewinapputil -ErrorAction SilentlyContinue
        if (-not $intunewinCmd) { throw 'intunewinapputil not found. Install Microsoft Win32 Content Prep Tool.' }

        $intunewinFile = Join-Path $outputDirectory $intuneWinFileName
        if (Test-Path $intunewinFile) { Remove-Item -Path $intunewinFile -Force }

        & intunewinapputil -c $versionDirectory -s $installerFileName -o $outputDirectory -q
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $intunewinFile)) {
            throw 'Content Prep Tool failed or output file not found.'
        }

        Send-WingetterProgress -StepNumber 11 -Step 'Complete' -Percent 100 -Message 'Package created successfully!' -OnProgress $OnProgress
        Write-WingetterLog -Message "Created $intunewinFile" -Level Success -OnProgress $OnProgress

        return [PSCustomObject]@{
            Success           = $true
            PackageId         = $packageId
            DisplayName       = $displayName
            Version           = $foundVersion
            Publisher         = $publisher
            VersionDirectory  = $versionDirectory
            IntuneWinFile     = $intunewinFile
            IconPath          = if (Test-Path $iconFilePath) { $iconFilePath } else { $null }
        }
    }
    catch {
        Write-WingetterLog -Message $_.Exception.Message -Level Error -OnProgress $OnProgress
        if ($versionDirectory) {
            Write-WingetterFailureLog -LogPath (Join-Path $versionDirectory 'wingetter-pack.log') -Step $currentStep -ErrorRecord $_
        }
        throw
    }
}

# Functions are exposed when this file is dot-sourced by the CLI or GUI entry points.
