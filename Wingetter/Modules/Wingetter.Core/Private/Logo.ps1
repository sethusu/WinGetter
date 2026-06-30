function Extract-IconFromExe {
    [CmdletBinding()]
    param(
        [string]$ExePath,
        [string]$OutputPath,
        [scriptblock]$ProgressCallback
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
            if ((Test-Path $OutputPath) -and (Get-Item $OutputPath).Length -gt 0) {
                Write-WingetterLog -Message 'Extracted icon from installer executable.' -Level Success -ProgressCallback $ProgressCallback
                return $true
            }
        }
    }
    catch {
        # Continue without icon
    }

    return $false
}

function Get-LogoFromWeb {
    [CmdletBinding()]
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
        if ($githubOrg -and $githubRepo) {
            $orgName = $githubOrg
            $projectName = $githubRepo
        }

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

    $urls = $urls | Select-Object -Unique
    foreach ($url in ($urls | Select-Object -First 30)) {
        try {
            Write-WingetterLog -Message "Trying logo URL: $url" -ProgressCallback $ProgressCallback
            Invoke-WebRequest -Uri $url -OutFile $OutputPath -ErrorAction Stop -TimeoutSec 8
            if (Test-Path $OutputPath) {
                $bytes = [System.IO.File]::ReadAllBytes($OutputPath)
                $isImage = $bytes.Length -gt 8 -and (
                    ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50) -or
                    ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) -or
                    ($bytes[0] -eq 0x47 -and $bytes[1] -eq 0x49)
                )
                if ($isImage) {
                    Write-WingetterLog -Message "Downloaded logo from $url" -Level Success -ProgressCallback $ProgressCallback
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
        return Extract-IconFromExe -ExePath $InstallerPath -OutputPath $OutputPath -ProgressCallback $ProgressCallback
    }

    return $false
}

function Resolve-WingetterIcon {
    [CmdletBinding()]
    param(
        [string]$PackageId,
        [string]$DisplayName,
        [string]$Publisher,
        [string]$Homepage,
        [string]$AppDirectory,
        [string]$VersionDirectory,
        [string]$IconPath,
        [string]$InstallerFullPath,
        [scriptblock]$ProgressCallback
    )

    $iconFilePath = Join-Path $VersionDirectory 'icon.png'
    $logoFilePath = Join-Path $AppDirectory 'logo.png'

    if ($IconPath -and (Test-Path $IconPath)) {
        Copy-Item -Path $IconPath -Destination $iconFilePath -Force
        Write-WingetterLog -Message "Copied icon from $IconPath" -Level Success -ProgressCallback $ProgressCallback
    }
    elseif (Test-Path $logoFilePath) {
        Copy-Item -Path $logoFilePath -Destination $iconFilePath -Force
        Write-WingetterLog -Message 'Copied logo.png from parent directory.' -Level Success -ProgressCallback $ProgressCallback
    }
    else {
        $downloaded = Get-LogoFromWeb -PackageId $PackageId -DisplayName $DisplayName -Publisher $Publisher -Homepage $Homepage -OutputPath $logoFilePath -InstallerPath $InstallerFullPath -ProgressCallback $ProgressCallback
        if ($downloaded -and (Test-Path $logoFilePath)) {
            Copy-Item -Path $logoFilePath -Destination $iconFilePath -Force
            Write-WingetterLog -Message 'Downloaded and copied application icon.' -Level Success -ProgressCallback $ProgressCallback
        }
        else {
            Write-WingetterLog -Message 'No icon file found. Package will be created without icon.' -Level Warning -ProgressCallback $ProgressCallback
        }
    }

    if (Test-Path $iconFilePath) {
        return $iconFilePath
    }
    return $null
}
