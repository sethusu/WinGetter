function Get-ImageMimeType {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    if (-not $Bytes -or $Bytes.Length -lt 4) {
        return $null
    }

    if ($Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47) {
        return 'image/png'
    }

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8 -and $Bytes[2] -eq 0xFF) {
        return 'image/jpeg'
    }

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0x47 -and $Bytes[1] -eq 0x49 -and $Bytes[2] -eq 0x46) {
        return 'image/gif'
    }

    return $null
}

function Get-WingetDownloadArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,
        [Parameter(Mandatory = $true)]
        [string]$DownloadDirectory,
        [string]$Version,
        [string]$Source,
        [switch]$AcceptPackageAgreements
    )

    $arguments = @(
        $PackageId
        '--exact'
        '--download-directory'
        $DownloadDirectory
        '--accept-source-agreements'
    )

    if ($AcceptPackageAgreements) {
        $arguments += '--accept-package-agreements'
    }

    if ($Version) {
        $arguments += @('--version', $Version)
    }

    $resolvedSource = Resolve-WingetShowSourceArgument -Source $Source
    if ($resolvedSource) {
        $arguments += @('--source', $resolvedSource)
    }

    return $arguments
}

function Start-WingetInstallerDownload {
    param(
        [string]$PackageId,
        [string]$DownloadDirectory,
        [string]$PackageName,
        [string]$Version,
        [string]$Source,
        [scriptblock]$OnProgress
    )

    $supportsAgreements = Test-WingetPackageAgreementsSupported -Command download
    $downloadArguments = Get-WingetDownloadArguments -PackageId $PackageId -DownloadDirectory $DownloadDirectory `
        -Version $Version -Source $Source -AcceptPackageAgreements:($supportsAgreements)
    $job = Start-Job -ScriptBlock {
        winget download @using:downloadArguments 2>&1
    }

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

        $jobOutput = Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue
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
            $downloadStarted = $true
            $currentTime = Get-Date
            $timeDiff = ($currentTime - $previousTime).TotalSeconds
            $sizeDiff = $currentSize - $previousSize
            $speedMBps = if ($timeDiff -gt 0 -and $sizeDiff -gt 0) { [math]::Round(($sizeDiff / 1MB) / $timeDiff, 2) } else { 0 }

            if ($expectedSize -and $expectedSize -gt 0) {
                $percentComplete = [math]::Min(100, [math]::Round(($currentSize / $expectedSize) * 100, 2))
            } elseif ($currentSize -gt $previousSize -and $speedMBps -gt 0) {
                $percentComplete = [math]::Min(95, [math]::Round(($currentSize / ($currentSize + ($speedMBps * 1MB * 5))) * 100, 2))
            } else {
                $percentComplete = if ($downloadStarted) { 5 } else { 0 }
            }

            $sizeMB = [math]::Round($currentSize / 1MB, 2)
            $message = "Downloading $($currentFile.Name) ($sizeMB MB"
            if ($speedMBps -gt 0) { $message += ", $speedMBps MB/s" }
            $message += ')'

            Write-WingetterProgress -Step 3 -StepName 'Downloading installer' -Percent $percentComplete -Message $message -OnProgress $OnProgress
            $previousSize = $currentSize
            $previousTime = $currentTime
        } else {
            Write-WingetterProgress -Step 3 -StepName 'Downloading installer' -Percent 0 -Message 'Initializing download...' -OnProgress $OnProgress
        }

        Start-Sleep -Milliseconds 500
        if ($job.State -ne 'Running') { break }
    }

    $jobOutput = Receive-Job -Job $job -Keep
    Remove-Job -Job $job -Force

    if ($jobOutput) {
        $errorIndicators = $jobOutput | Select-String -Pattern 'error|failed|exception' -CaseSensitive:$false
        if ($errorIndicators) {
            throw "Winget download may have failed: $($jobOutput | Out-String)"
        }
    }

    return $jobOutput
}

function Get-InstallerInstallCommand {
    param(
        [string]$InstallerFileName,
        [string]$InstallerExtension
    )

    switch ($InstallerExtension.ToLower()) {
        '.msi' { return "msiexec /i `"$InstallerFileName`" /quiet /norestart" }
        '.msix' { return "Add-AppxPackage -Path `"$InstallerFileName`"" }
        '.appx' { return "Add-AppxPackage -Path `"$InstallerFileName`"" }
        default { return "`"$InstallerFileName`" /S" }
    }
}

function Get-IntuneUninstallCommandLine {
    return '%windir%\sysnative\windowspowershell\v1.0\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File uninstall.ps1'
}

function Get-IntuneInstallCommandLine {
    return '%windir%\sysnative\windowspowershell\v1.0\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File install.ps1'
}
