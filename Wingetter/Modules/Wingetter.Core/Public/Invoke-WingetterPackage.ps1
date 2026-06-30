function Invoke-WingetterPackage {
    <#
    .SYNOPSIS
        Creates an IntuneWin package from a Winget application.
    .PARAMETER PackageId
        Winget package ID (e.g. JetBrains.WebStorm).
    .PARAMETER Version
        Optional specific version to package.
    .PARAMETER OutputPath
        Base output directory.
    .PARAMETER IconPath
        Optional custom icon path.
    .PARAMETER ProgressCallback
        Scriptblock invoked with progress updates for GUI integration.
    .OUTPUTS
        PSCustomObject with packaging results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,

        [string]$Version,

        [string]$OutputPath = 'D:\Intoon In Progress',

        [string]$IconPath,

        [scriptblock]$ProgressCallback
    )

    $totalSteps = 11
    $packagingLogPath = $null
    $errorLogPath = $null
    $versionDirectory = $null

    function Write-StepProgress {
        param([string]$Name, [int]$Number, [int]$Percent = -1, [string]$Message)
        Write-WingetterLog -StepName $Name -StepNumber $Number -TotalSteps $totalSteps -PercentComplete $Percent -Message $Message -Level Step -ProgressCallback $ProgressCallback
        if ($packagingLogPath) {
            Write-WingetterFileLog -LogPath $packagingLogPath -Message "[$Name] $Message"
        }
    }

    try {
        Write-StepProgress -Name 'Prerequisites' -Number 1 -Percent 5 -Message 'Checking prerequisites...'
        $prereq = Test-WingetterPrerequisites
        if (-not $prereq.AllOk) {
            $failed = ($prereq.Checks.GetEnumerator() | Where-Object { -not $_.Value.Ok } | ForEach-Object { "$($_.Key): $($_.Value.Detail)" }) -join '; '
            throw "Prerequisites not met: $failed"
        }

        Write-StepProgress -Name 'App Details' -Number 2 -Percent 10 -Message "Fetching details for $PackageId..."
        $appDetails = Get-WingetAppDetails -PackageId $PackageId -Version $Version
        Write-WingetterLog -Message "Found $($appDetails.DisplayName) v$($appDetails.Version)" -Level Success -ProgressCallback $ProgressCallback

        Write-StepProgress -Name 'Directories' -Number 2 -Percent 15 -Message 'Creating output directories...'
        $appDirectory = Join-Path $OutputPath $appDetails.PackageId
        $versionDirectory = Join-Path $appDirectory $appDetails.Version
        New-Item -ItemType Directory -Path $versionDirectory -Force | Out-Null

        $packagingLogPath = Join-Path $versionDirectory 'packaging.log'
        $errorLogPath = Join-Path $versionDirectory 'packaging-error.log'
        Write-WingetterFileLog -LogPath $packagingLogPath -Message "Packaging started for $($appDetails.PackageId) $($appDetails.Version)"

        Write-StepProgress -Name 'Download' -Number 3 -Percent 20 -Message 'Downloading installer...'
        $null = Start-WingetDownloadWithProgress -PackageId $appDetails.PackageId -DownloadDirectory $versionDirectory -PackageName $appDetails.DisplayName -ProgressCallback $ProgressCallback
        Start-Sleep -Seconds 1

        $installerFile = Get-ChildItem -Path $versionDirectory -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -in '.exe', '.msi', '.msix', '.appx' -and
                $_.Name -notlike '*intunewin*' -and $_.Name -notlike '*ContentPrepTool*'
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if (-not $installerFile) {
            throw 'Could not find downloaded installer file (.exe, .msi, .msix, or .appx).'
        }

        $installerFileName = $installerFile.Name
        $installerBaseName = $installerFile.BaseName
        $installCommand = Get-InstallCommandForInstaller -InstallerFileName $installerFileName
        $installCommandLine = Get-InstallPs1CommandLine
        $uninstallCommandLine = Get-UninstallCommandLine

        Write-WingetterLog -Message "Downloaded $installerFileName ($([math]::Round($installerFile.Length / 1MB, 2)) MB)" -Level Success -ProgressCallback $ProgressCallback

        Write-StepProgress -Name 'Hash' -Number 4 -Percent 45 -Message 'Calculating SHA256 hash...'
        $installerHash = (Get-FileHash -Path $installerFile.FullName -Algorithm SHA256).Hash
        Write-WingetterLog -Message "SHA256: $installerHash" -Level Success -ProgressCallback $ProgressCallback

        Write-StepProgress -Name 'Scripts' -Number 5 -Percent 50 -Message 'Generating install, detection, and uninstall scripts...'
        $installScript = New-WingetterInstallScript -DisplayName $appDetails.DisplayName -PackageId $appDetails.PackageId -Version $appDetails.Version -InstallerFileName $installerFileName -InstallCommand $installCommand
        $detectionScript = New-WingetterDetectionScript -DisplayName $appDetails.DisplayName -PackageId $appDetails.PackageId -Version $appDetails.Version
        $uninstallScript = New-WingetterUninstallScript -DisplayName $appDetails.DisplayName -PackageId $appDetails.PackageId

        $installScript | Set-Content -Path (Join-Path $versionDirectory 'install.ps1') -Encoding UTF8
        $detectionScript | Set-Content -Path (Join-Path $versionDirectory 'detection.ps1') -Encoding UTF8
        $uninstallScript | Set-Content -Path (Join-Path $versionDirectory 'uninstall.ps1') -Encoding UTF8
        Write-WingetterLog -Message 'Created install.ps1, detection.ps1, uninstall.ps1' -Level Success -ProgressCallback $ProgressCallback

        Write-StepProgress -Name 'Icon' -Number 6 -Percent 60 -Message 'Resolving application icon...'
        $iconFilePath = Resolve-WingetterIcon -PackageId $appDetails.PackageId -DisplayName $appDetails.DisplayName -Publisher $appDetails.Publisher -Homepage $appDetails.Homepage -AppDirectory $appDirectory -VersionDirectory $versionDirectory -IconPath $IconPath -InstallerFullPath $installerFile.FullName -ProgressCallback $ProgressCallback

        Write-StepProgress -Name 'Metadata' -Number 7 -Percent 70 -Message 'Creating metadata files...'
        $intuneWinFileName = "$installerBaseName.intunewin"
        $win32LobAppJson = New-WingetterWin32LobAppJson -AppDetails $appDetails -InstallerFileName $installerFileName -InstallerBaseName $installerBaseName -DetectionScript $detectionScript -InstallCommandLine $installCommandLine -UninstallCommandLine $uninstallCommandLine -IconFilePath $iconFilePath
        $appJson = New-WingetterAppJson -AppDetails $appDetails -InstallerFileName $installerFileName -InstallerHash $installerHash -InstallCommandLine $installCommandLine -UninstallCommandLine $uninstallCommandLine
        $readmeMarkdown = New-WingetterReadmeMarkdown -AppDetails $appDetails -InstallerFileName $installerFileName -InstallerHash $installerHash -InstallCommandLine $installCommandLine -UninstallCommandLine $uninstallCommandLine -IntuneWinFileName $intuneWinFileName -IconPath $iconFilePath -Win32LobAppJson $win32LobAppJson

        $readmeMarkdown | Set-Content -Path (Join-Path $versionDirectory 'README.md') -Encoding UTF8
        $appJson | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $versionDirectory 'app.json') -Encoding UTF8
        $win32LobAppJson | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $versionDirectory 'win32LobApp.json') -Encoding UTF8

        # Legacy readme.txt for backward compatibility
        @"
Package $($appDetails.PackageId) $($appDetails.Version) from Winget

Display name: $($appDetails.DisplayName)
Version: $($appDetails.Version)
Publisher: $($appDetails.Publisher)
Homepage: $($appDetails.Homepage)

Install command (Intune):
$installCommandLine

Uninstall command (Intune):
$uninstallCommandLine

Raw installer command:
$installCommand

Description:
$($appDetails.Description)

See README.md for complete Intune upload reference.
"@ | Set-Content -Path (Join-Path $versionDirectory 'readme.txt') -Encoding UTF8

        Write-WingetterLog -Message 'Created README.md, app.json, win32LobApp.json' -Level Success -ProgressCallback $ProgressCallback

        Write-StepProgress -Name 'Package' -Number 8 -Percent 85 -Message 'Creating .intunewin package...'
        $intunewinFile = Invoke-IntuneWinPackage -VersionDirectory $versionDirectory -InstallerFileName $installerFileName -InstallerBaseName $installerBaseName -ProgressCallback $ProgressCallback

        Write-StepProgress -Name 'Complete' -Number $totalSteps -Percent 100 -Message 'Packaging complete!'
        Write-WingetterFileLog -LogPath $packagingLogPath -Message 'Packaging completed successfully.'

        if ($ProgressCallback) {
            & $ProgressCallback @{
                Step            = 'Complete'
                StepNumber      = $totalSteps
                TotalSteps      = $totalSteps
                PercentComplete = 100
                Message         = 'Packaging complete!'
                Level           = 'Success'
                IconPath        = $iconFilePath
                OutputDirectory = $versionDirectory
                IntuneWinFile   = $intunewinFile
            }
        }

        return [PSCustomObject]@{
            Success         = $true
            PackageId       = $appDetails.PackageId
            DisplayName     = $appDetails.DisplayName
            Version         = $appDetails.Version
            Publisher       = $appDetails.Publisher
            Description     = $appDetails.Description
            Homepage        = $appDetails.Homepage
            InstallerFile   = $installerFile.FullName
            InstallerHash   = $installerHash
            IconPath        = $iconFilePath
            OutputDirectory = $versionDirectory
            IntuneWinFile   = $intunewinFile
            PackagingLog    = $packagingLogPath
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-WingetterLog -Message $errorMessage -Level Error -ProgressCallback $ProgressCallback

        if ($errorLogPath) {
            $errorDetails = @(
                "Packaging failed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
                "Package: $PackageId",
                "Version: $Version",
                "Error: $errorMessage",
                "Stack trace:",
                $_.ScriptStackTrace
            ) -join "`n"
            $errorDetails | Set-Content -Path $errorLogPath -Encoding UTF8
            Write-WingetterFileLog -LogPath $packagingLogPath -Message "FAILED: $errorMessage" -Level Error
        }
        elseif ($versionDirectory) {
            $fallbackErrorLog = Join-Path $versionDirectory 'packaging-error.log'
            $_.Exception.Message | Set-Content -Path $fallbackErrorLog -Encoding UTF8
        }

        if ($ProgressCallback) {
            & $ProgressCallback @{
                Step            = 'Error'
                PercentComplete = -1
                Message         = $errorMessage
                Level           = 'Error'
            }
        }

        throw
    }
}
