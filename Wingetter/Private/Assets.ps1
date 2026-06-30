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

function Export-IconFromExecutable {
    param(
        [string]$ExePath,
        [string]$OutputPath,
        [scriptblock]$OnProgress
    )

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
            if (Test-Path $OutputPath -and (Get-Item $OutputPath).Length -gt 0) {
                Write-WingetterLog -Message 'Extracted icon from installer executable' -Level Success -OnProgress $OnProgress
                return $true
            }
        }
    } catch {
        Write-WingetterLog -Message "Icon extraction failed: $_" -Level Warning -OnProgress $OnProgress
    }

    return $false
}

function Get-PackageLogoFromWeb {
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
            "https://www.jetbrains.com/$($productName.ToLower())/img/$($productName.ToLower())_logo_300x300.png",
            "https://resources.jetbrains.com/storage/products/$($productName.ToLower())/img/meta/$($productName.ToLower())_icon_256x256.png"
        )
    }

    $githubOrg = $null
    $githubRepo = $null
    if ($Homepage -match 'github\.com/([^/]+)/([^/]+)') {
        $githubOrg = $matches[1]
        $githubRepo = $matches[2] -replace '/.*$', ''
    }

    $orgName = $null
    $projectName = $null
    if ($PackageId -like '*.*' -or $Homepage -like '*github.com*') {
        $parts = $PackageId -split '\.'
        $projectName = if ($parts.Count -gt 1) { $parts[-1] } else { $PackageId }
        $orgName = if ($parts.Count -gt 1) { $parts[0] } else { $projectName }

        if ($githubOrg -and $githubRepo) {
            $orgName = $githubOrg
            $projectName = $githubRepo
        }

        $branches = @('main', 'master', 'develop', 'dev')
        $paths = @('logo.png', 'icon.png', 'assets/logo.png', 'assets/icon.png', 'img/logo.png', 'img/icon.png')
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
        $urls += @(
            "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$firstChar/$($parts[0])/$($parts[1])/icon.png",
            "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$firstChar/$($parts[0])/$($parts[1])/logo.png"
        )
    }

    $urls = $urls | Select-Object -Unique | Select-Object -First 50

    foreach ($url in $urls) {
        try {
            Write-WingetterLog -Message "Trying logo URL: $url" -Level Info -OnProgress $OnProgress
            Invoke-WebRequest -Uri $url -OutFile $OutputPath -ErrorAction Stop -TimeoutSec 8 | Out-Null
            if (Test-Path $OutputPath) {
                $bytes = [System.IO.File]::ReadAllBytes($OutputPath)
                $isImage = $false
                if ($bytes.Length -gt 8) {
                    $isImage = (
                        ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47) -or
                        ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8 -and $bytes[2] -eq 0xFF) -or
                        ($bytes[0] -eq 0x47 -and $bytes[1] -eq 0x49 -and $bytes[2] -eq 0x46)
                    )
                }
                if ($isImage) {
                    Write-WingetterLog -Message "Downloaded logo from $url" -Level Success -OnProgress $OnProgress
                    return $true
                }
                Remove-Item $OutputPath -ErrorAction SilentlyContinue
            }
        } catch {
            if (Test-Path $OutputPath) {
                Remove-Item $OutputPath -ErrorAction SilentlyContinue
            }
        }
    }

    if ($InstallerPath -and (Test-Path $InstallerPath) -and $InstallerPath -like '*.exe') {
        return Export-IconFromExecutable -ExePath $InstallerPath -OutputPath $OutputPath -OnProgress $OnProgress
    }

    return $false
}

function Start-WingetInstallerDownload {
    param(
        [string]$PackageId,
        [string]$DownloadDirectory,
        [string]$PackageName,
        [scriptblock]$OnProgress
    )

    $supportsAgreements = Test-WingetPackageAgreementsSupported -Command download
    $job = Start-Job -ScriptBlock {
        if ($using:supportsAgreements) {
            winget download $using:PackageId --exact --download-directory $using:DownloadDirectory --accept-source-agreements --accept-package-agreements 2>&1
        } else {
            winget download $using:PackageId --exact --download-directory $using:DownloadDirectory --accept-source-agreements 2>&1
        }
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
