function Invoke-WingetterPackaging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,
        [string]$Version,
        [string]$OutputPath = (Get-WingetterSettings).OutputPath,
        [string]$IconPath,
        [switch]$CollectIconCandidates,
        [scriptblock]$OnProgress
    )

    $totalSteps = 12
    $versionDirectory = $null
    $failureLogPath = $null
    $intunewinFile = $null

    try {
        Write-WingetterProgress -Step 1 -TotalSteps $totalSteps -StepName 'Loading package details' -Percent 5 -Message "Fetching details for $PackageId" -OnProgress $OnProgress
        $details = Get-WingetPackageDetails -PackageId $PackageId -Version $Version
        $details | Add-Member -NotePropertyName Developer -NotePropertyValue $details.Publisher -Force

        if (-not (Test-Path $OutputPath)) {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        }

        Write-WingetterProgress -Step 2 -TotalSteps $totalSteps -StepName 'Creating directories' -Percent 10 -Message 'Creating output folders' -OnProgress $OnProgress
        $appDirectory = Join-Path $OutputPath $details.PackageId
        $versionDirectory = Join-Path $appDirectory $details.Version
        $failureLogPath = Join-Path $versionDirectory 'wingetter-packaging.log'
        if (-not (Test-Path $versionDirectory)) {
            New-Item -ItemType Directory -Path $versionDirectory -Force | Out-Null
        }

        Write-WingetterProgress -Step 3 -TotalSteps $totalSteps -StepName 'Downloading installer' -Percent 15 -Message 'Starting Winget download' -OnProgress $OnProgress
        $null = Start-WingetInstallerDownload -PackageId $details.PackageId -DownloadDirectory $versionDirectory -PackageName $details.DisplayName -OnProgress $OnProgress
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

        $installerInstallCommand = Get-InstallerInstallCommand -InstallerFileName $installerFile.Name -InstallerExtension $installerFile.Extension

        Write-WingetterProgress -Step 4 -TotalSteps $totalSteps -StepName 'Calculating hash' -Percent 35 -Message $installerFile.Name -OnProgress $OnProgress
        $installerHash = (Get-FileHash -Path $installerFile.FullName -Algorithm SHA256).Hash

        Write-WingetterProgress -Step 5 -TotalSteps $totalSteps -StepName 'Generating install.ps1' -Percent 45 -OnProgress $OnProgress
        $installScript = New-WingetterInstallScript -PackageId $details.PackageId -DisplayName $details.DisplayName -Version $details.Version -InstallCommand $installerInstallCommand

        Write-WingetterProgress -Step 6 -TotalSteps $totalSteps -StepName 'Generating detection.ps1' -Percent 55 -OnProgress $OnProgress
        $detectionScript = New-WingetterDetectionScript -PackageId $details.PackageId -DisplayName $details.DisplayName -Version $details.Version

        Write-WingetterProgress -Step 7 -TotalSteps $totalSteps -StepName 'Generating uninstall.ps1' -Percent 65 -OnProgress $OnProgress
        $uninstallScript = New-WingetterUninstallScript -PackageId $details.PackageId -DisplayName $details.DisplayName

        Write-WingetterProgress -Step 8 -TotalSteps $totalSteps -StepName 'Resolving icon' -Percent 72 -OnProgress $OnProgress
        $iconFilePath = Join-Path $versionDirectory 'icon.png'
        $logoFilePath = Join-Path $appDirectory 'logo.png'
        $iconCandidates = @()
        $iconStagingDirectory = Join-Path $versionDirectory '.icon-candidates'
        $usedCustomIcon = $false

        if ($IconPath -and (Test-Path $IconPath)) {
            Set-WingetterPackageIconFiles -SourceIconPath $IconPath -LogoFilePath $logoFilePath -IconFilePath $iconFilePath
            $usedCustomIcon = $true
        } elseif (Test-Path $logoFilePath) {
            Copy-Item -Path $logoFilePath -Destination $iconFilePath -Force
        } elseif ($CollectIconCandidates) {
            $iconCandidates = @(Resolve-PackageIconCandidates -PackageId $details.PackageId -DisplayName $details.DisplayName `
                -Publisher $details.Publisher -Homepage $details.Homepage -Version $details.Version `
                -InstallerPath $installerFile.FullName -MaximumCount 3 -StagingDirectory $iconStagingDirectory -OnProgress $OnProgress)
            if ($iconCandidates.Count -gt 0) {
                Set-WingetterPackageIconFiles -SourceIconPath $iconCandidates[0].Path -LogoFilePath $logoFilePath -IconFilePath $iconFilePath
            }
        } else {
            $logoDownloaded = Get-PackageLogoFromWeb -PackageId $details.PackageId -DisplayName $details.DisplayName `
                -Publisher $details.Publisher -Homepage $details.Homepage -Version $details.Version `
                -OutputPath $logoFilePath -InstallerPath $installerFile.FullName -OnProgress $OnProgress
            if ($logoDownloaded -and (Test-Path $logoFilePath)) {
                Copy-Item -Path $logoFilePath -Destination $iconFilePath -Force
            }
        }

        Write-WingetterProgress -Step 9 -TotalSteps $totalSteps -StepName 'Writing metadata' -Percent 80 -OnProgress $OnProgress
        $metadata = New-WingetterMetadataFiles -PackageDetails $details -VersionDirectory $versionDirectory `
            -InstallerFileName $installerFile.Name -InstallerHash $installerHash `
            -InstallerInstallCommand $installerInstallCommand -DetectionScript $detectionScript `
            -InstallScript $installScript -UninstallScript $uninstallScript -IconFilePath $iconFilePath

        Write-WingetterProgress -Step 10 -TotalSteps $totalSteps -StepName 'Packaging .intunewin' -Percent 88 -OnProgress $OnProgress
        $contentPrepPath = Resolve-ContentPrepToolPath
        $packagingSucceeded = $false
        if (-not $contentPrepPath) {
            Write-WingetterLog -Message 'intunewinapputil not found. Use Install-WingetterContentPrepTool or install Microsoft Win32 Content Prep Tool and ensure it is on PATH.' -Level Warning -OnProgress $OnProgress
            Write-WingetterProgress -Step 12 -TotalSteps $totalSteps -StepName 'Complete with warnings' -Percent 100 -Message 'Metadata created, but Content Prep Tool is unavailable.' -Status Completed -OnProgress $OnProgress
        } else {
            $outputDirectory = Split-Path $versionDirectory -Parent
            $intunewinFile = Join-Path $outputDirectory $metadata.IntuneWinFileName
            if (Test-Path $intunewinFile) {
                Remove-Item -Path $intunewinFile -Force
            }

            try {
                & $contentPrepPath -c $versionDirectory -s $installerFile.Name -o $outputDirectory -q
                if ($LASTEXITCODE -eq 0 -and (Test-Path $intunewinFile)) {
                    $packagingSucceeded = $true
                    $intunewinSize = [math]::Round((Get-Item $intunewinFile).Length / 1MB, 2)
                    Write-WingetterProgress -Step 12 -TotalSteps $totalSteps -StepName 'Complete' -Percent 100 -Message "Created $intunewinFile ($intunewinSize MB)" -Status Completed -OnProgress $OnProgress
                } else {
                    throw 'Content Prep Tool failed or output file was not created.'
                }
            } catch {
                Write-WingetterLog -Message "Failed to create IntuneWin package: $_" -Level Warning -OnProgress $OnProgress
                Write-WingetterFailureLog -LogPath $failureLogPath -Step 'Packaging .intunewin' -ErrorRecord $_
                Write-WingetterProgress -Step 12 -TotalSteps $totalSteps -StepName 'Complete with warnings' -Percent 100 -Message 'Metadata created, but .intunewin packaging failed.' -Status Completed -OnProgress $OnProgress
            }
        }

        Save-WingetterSettings -OutputPath $OutputPath -LastPackageId $details.PackageId

        return [PSCustomObject]@{
            Success = $true
            PackagingSucceeded = $packagingSucceeded
            PackageId = $details.PackageId
            DisplayName = $details.DisplayName
            Version = $details.Version
            Publisher = $details.Publisher
            VersionDirectory = $versionDirectory
            IntuneWinFile = if ($packagingSucceeded) { $intunewinFile } else { $null }
            IconFile = if (Test-Path $iconFilePath) { $iconFilePath } else { $null }
            LogoFile = if (Test-Path $logoFilePath) { $logoFilePath } else { $null }
            IconCandidates = $iconCandidates
            UsedCustomIcon = $usedCustomIcon
            IconStagingDirectory = if ($iconCandidates.Count -gt 0) { $iconStagingDirectory } else { $null }
            InstallerFile = $installerFile.FullName
            Metadata = $metadata
            Details = $details
        }
    }
    catch {
        if ($versionDirectory -and -not $failureLogPath) {
            $failureLogPath = Join-Path $versionDirectory 'wingetter-packaging.log'
        }
        if ($failureLogPath) {
            if (-not (Test-Path (Split-Path $failureLogPath -Parent))) {
                New-Item -ItemType Directory -Path (Split-Path $failureLogPath -Parent) -Force | Out-Null
            }
            $failedStep = if ($_.TargetObject) { $_.TargetObject } else { 'Packaging' }
            Write-WingetterFailureLog -LogPath $failureLogPath -Step $failedStep -ErrorRecord $_
        }

        Write-WingetterProgress -Step 0 -TotalSteps $totalSteps -StepName 'Failed' -Percent 0 -Message $_.Exception.Message -Status Failed -OnProgress $OnProgress
        throw
    }
}
