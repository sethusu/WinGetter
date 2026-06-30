function Start-WingetDownloadWithProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,

        [Parameter(Mandatory)]
        [string]$DownloadDirectory,

        [Parameter(Mandatory)]
        [string]$PackageName,

        [scriptblock]$ProgressCallback
    )

    Write-WingetterLog -Message "Starting download for $PackageName..." -ProgressCallback $ProgressCallback

    $supportsPackageAgreements = Test-WingetSupportsPackageAgreements
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
    $downloadStarted = $false

    while ($job.State -eq 'Running') {
        $files = Get-ChildItem -Path $DownloadDirectory -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -notlike '*intunewin*' -and
                $_.Name -notlike '*ContentPrepTool*' -and
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
            $fileName = $currentFile.Name
            $downloadStarted = $true

            $currentTime = Get-Date
            $timeDiff = ($currentTime - $previousTime).TotalSeconds
            $sizeDiff = $currentSize - $previousSize
            $speedMBps = if ($timeDiff -gt 0 -and $sizeDiff -gt 0) {
                [math]::Round(($sizeDiff / 1MB) / $timeDiff, 2)
            }
            else { 0 }

            if ($expectedSize -and $expectedSize -gt 0) {
                $percentComplete = [math]::Min(100, [math]::Round(($currentSize / $expectedSize) * 100, 2))
            }
            elseif ($currentSize -gt $previousSize) {
                $percentComplete = if ($previousSize -gt 0 -and $speedMBps -gt 0) {
                    [math]::Min(95, [math]::Round(($currentSize / ($currentSize + ($speedMBps * 1MB * 5))) * 100, 2))
                }
                else { 5 }
            }
            else { $percentComplete = 0 }

            $sizeMB = [math]::Round($currentSize / 1MB, 2)
            $expectedSizeMB = if ($expectedSize) { [math]::Round($expectedSize / 1MB, 2) } else { '?' }
            $statusMessage = "Downloading: $fileName ($sizeMB MB / $expectedSizeMB MB)"
            if ($speedMBps -gt 0) { $statusMessage += " | $speedMBps MB/s" }

            if ($ProgressCallback) {
                & $ProgressCallback @{
                    Step            = 'Download'
                    StepNumber      = 3
                    TotalSteps      = 11
                    PercentComplete = $percentComplete
                    Message         = $statusMessage
                    Level           = 'Info'
                }
            }
            else {
                Write-Progress -Activity "Downloading $PackageName" -Status $statusMessage -PercentComplete $percentComplete
            }

            $previousSize = $currentSize
            $previousTime = $currentTime
        }
        elseif (-not $downloadStarted -and $ProgressCallback) {
            & $ProgressCallback @{
                Step            = 'Download'
                StepNumber      = 3
                TotalSteps      = 11
                PercentComplete = 0
                Message         = 'Initializing download...'
                Level           = 'Info'
            }
        }

        Start-Sleep -Milliseconds 500
        if ($job.State -ne 'Running') { break }
    }

    $jobOutput = Receive-Job -Job $job
    Remove-Job -Job $job -Force
    if (-not $ProgressCallback) {
        Write-Progress -Activity "Downloading $PackageName" -Completed
    }

    if ($jobOutput) {
        $errorIndicators = $jobOutput | Select-String -Pattern 'error|failed|exception' -CaseSensitive:$false
        if ($errorIndicators) {
            throw "Winget download may have failed: $($errorIndicators | Select-Object -First 1)"
        }
    }

    return $jobOutput
}

function Get-InstallCommandForInstaller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InstallerFileName
    )

    $extension = [System.IO.Path]::GetExtension($InstallerFileName).ToLower()
    switch ($extension) {
        '.msi' { return "msiexec /i `"$InstallerFileName`" /quiet /norestart" }
        { $_ -in '.msix', '.appx' } { return "Add-AppxPackage -Path `"$InstallerFileName`"" }
        default { return "`"$InstallerFileName`" /S" }
    }
}

function Get-UninstallCommandLine {
    return '%windir%\sysnative\windowspowershell\v1.0\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File uninstall.ps1'
}

function Get-InstallPs1CommandLine {
    return '%windir%\sysnative\windowspowershell\v1.0\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File install.ps1'
}
