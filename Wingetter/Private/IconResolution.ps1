function Resolve-AbsoluteUrl {
    param(
        [string]$BaseUrl,
        [string]$RelativeUrl
    )

    if ([string]::IsNullOrWhiteSpace($RelativeUrl)) { return $null }
    if ($RelativeUrl -match '^https?://') { return $RelativeUrl }
    if ($RelativeUrl -match '^//') { return "https:$RelativeUrl" }

    try {
        return [Uri]::new([Uri]$BaseUrl, $RelativeUrl).AbsoluteUri
    } catch {
        return $null
    }
}

function Test-ImageBytes {
    param([byte[]]$Bytes)

    if (-not $Bytes -or $Bytes.Length -lt 4) { return $false }

    if ($Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47) { return $true }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8 -and $Bytes[2] -eq 0xFF) { return $true }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0x47 -and $Bytes[1] -eq 0x49 -and $Bytes[2] -eq 0x46) { return $true }
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0x00 -and $Bytes[1] -eq 0x00 -and $Bytes[2] -eq 0x01 -and $Bytes[3] -eq 0x00) { return $true }

    return $false
}

function Save-BytesAsPngIcon {
    param(
        [byte[]]$Bytes,
        [string]$OutputPath
    )

    if (-not (Test-ImageBytes -Bytes $Bytes)) {
        return $false
    }

    $tempFile = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.img')
    try {
        [System.IO.File]::WriteAllBytes($tempFile, $Bytes)

        if ($Bytes[0] -eq 0x00 -and $Bytes[1] -eq 0x00) {
            Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            $icon = New-Object System.Drawing.Icon($tempFile)
            $bitmap = $icon.ToBitmap()
            $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $icon.Dispose()
            $bitmap.Dispose()
            return (Test-Path $OutputPath)
        }

        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $stream = New-Object System.IO.MemoryStream(,$Bytes)
        try {
            $image = [System.Drawing.Image]::FromStream($stream)
            $image.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $image.Dispose()
            return (Test-Path $OutputPath)
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $false
    } finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    }
}

function Save-PackageIconFromUrl {
    param(
        [string]$Url,
        [string]$OutputPath,
        [scriptblock]$OnProgress
    )

    try {
        Write-WingetterLog -Message "Trying icon URL: $Url" -Level Info -OnProgress $OnProgress
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop
        $bytes = $response.Content
        if ($bytes -is [string]) {
            $bytes = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes($bytes)
        }

        if (Save-BytesAsPngIcon -Bytes $bytes -OutputPath $OutputPath) {
            Write-WingetterLog -Message "Downloaded icon from $Url" -Level Success -OnProgress $OnProgress
            return $true
        }
    } catch {
        Write-WingetterLog -Message "Icon URL failed ($Url): $($_.Exception.Message)" -Level Warning -OnProgress $OnProgress
    }

    if (Test-Path $OutputPath) {
        Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
    }
    return $false
}

function Get-IconUrlsFromWingetShow {
    param(
        [string]$PackageId,
        [string]$Version
    )

    $urls = @()
    try {
        $showArguments = @($PackageId, '--exact')
        if ($Version) { $showArguments += @('--version', $Version) }
        $result = Invoke-WingetCli -Command show -Arguments $showArguments
        $text = ($result.Output | Out-String)

        foreach ($match in [regex]::Matches($text, '(?i)(IconUrl|Icon URL|Icon):\s*(https?://\S+)')) {
            $urls += $match.Groups[2].Value.Trim()
        }
        foreach ($match in [regex]::Matches($text, '(?i)(https?://[^\s"]+\.(?:png|jpg|jpeg|ico|webp))')) {
            if ($match.Value -match '(?i)icon|logo|favicon') {
                $urls += $match.Value.Trim()
            }
        }
    } catch {
        Write-Verbose "Could not parse winget show icon metadata: $_"
    }

    return $urls | Select-Object -Unique
}

function Get-IconUrlsFromWingetManifest {
    param(
        [string]$PackageId,
        [string]$Version
    )

    if ($PackageId -notmatch '^(.+)\.(.+)$') { return @() }

    $publisher = $matches[1]
    $app = $matches[2]
    $firstChar = $publisher.Substring(0, 1).ToLower()
    $basePath = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$firstChar/$publisher/$app"

    $manifestPaths = @()
    if ($Version) {
        $manifestPaths += "$basePath/$Version/$PackageId.locale.en-US.yaml"
        $manifestPaths += "$basePath/$Version/$PackageId.yaml"
    }

    $urls = @()
    foreach ($manifestUrl in $manifestPaths) {
        try {
            $yaml = (Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing -TimeoutSec 10).Content
            if ($yaml -match '(?m)^PackageUrl:\s*(.+)$') {
                $packageUrl = $matches[1].Trim()
                $urls += Get-IconUrlsFromHomepage -Homepage $packageUrl
            }
            if ($yaml -match '(?m)^PublisherUrl:\s*(.+)$') {
                $urls += Get-IconUrlsFromHomepage -Homepage $matches[1].Trim()
            }
            foreach ($match in [regex]::Matches($yaml, '(?m)^\s*IconUrl:\s*(https?://\S+)')) {
                $urls += $match.Groups[1].Value.Trim()
            }
        } catch {
            Write-Verbose "Manifest not available at $manifestUrl"
        }
    }

    return $urls | Select-Object -Unique
}

function Get-IconUrlsFromHomepage {
    param([string]$Homepage)

    if ([string]::IsNullOrWhiteSpace($Homepage)) { return @() }

    $urls = @()
    $base = $Homepage.TrimEnd('/')

    $urls += @(
        "$base/apple-touch-icon.png"
        "$base/apple-touch-icon-precomposed.png"
        "$base/favicon.ico"
        "$base/favicon.png"
        "$base/assets/favicon.ico"
        "$base/assets/favicon.png"
        "$base/images/favicon.ico"
        "$base/images/favicon.png"
    )

    try {
        $response = Invoke-WebRequest -Uri $Homepage -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop
        $html = $response.Content

        foreach ($pattern in @(
            '(?i)<link[^>]+rel=["'']apple-touch-icon[^>]+href=["'']([^"'']+)["'']'
            '(?i)<link[^>]+href=["'']([^"'']+)["''][^>]+rel=["'']apple-touch-icon'
            '(?i)<link[^>]+rel=["''](?:shortcut )?icon[^>]+href=["'']([^"'']+)["'']'
            '(?i)<link[^>]+href=["'']([^"'']+)["''][^>]+rel=["''](?:shortcut )?icon'
            '(?i)<meta[^>]+property=["'']og:image["''][^>]+content=["'']([^"'']+)["'']'
            '(?i)<meta[^>]+content=["'']([^"'']+)["''][^>]+property=["'']og:image'
        )) {
            foreach ($match in [regex]::Matches($html, $pattern)) {
                $resolved = Resolve-AbsoluteUrl -BaseUrl $Homepage -RelativeUrl $match.Groups[1].Value.Trim()
                if ($resolved) { $urls += $resolved }
            }
        }
    } catch {
        Write-Verbose "Could not parse homepage icons from $Homepage : $_"
    }

    return $urls | Select-Object -Unique
}

function Get-KnownPackageIconUrls {
    param(
        [string]$PackageId,
        [string]$Publisher,
        [string]$Homepage
    )

    $urls = @()

    switch -Wildcard ($PackageId) {
        'Valve.Steam' {
            $urls += @(
                'https://store.steampowered.com/favicon.ico'
            )
        }
        'Google.Chrome' { $urls += @('https://www.google.com/chrome/static/images/chrome-logo-m100.svg', 'https://www.google.com/chrome/static/images/chrome-logo.svg', 'https://www.google.com/favicon.ico') }
        'Microsoft.*' {
            $urls += @(
                'https://www.microsoft.com/favicon.ico'
                'https://c.s-microsoft.com/favicon.ico'
            )
        }
        'JetBrains.*' {
            $productName = $PackageId -replace 'JetBrains\.', ''
            $lower = $productName.ToLower()
            $urls += @(
                "https://resources.jetbrains.com/storage/products/$lower/img/meta/${lower}_icon_256x256.png"
                "https://resources.jetbrains.com/storage/products/$lower/img/meta/${lower}_logo_300x300.png"
            )
        }
        'Mozilla.Firefox' { $urls += 'https://www.mozilla.org/media/img/favicons/firefox/favicon-196x196.png' }
        '7zip.*' { $urls += 'https://www.7-zip.org/favicon.ico' }
        'Discord.Discord' { $urls += 'https://discord.com/assets/favicon.ico' }
        'Spotify.Spotify' { $urls += 'https://open.spotifycdn.com/cdn/images/favicon32.b64ccf03.png' }
        'VideoLAN.VLC' { $urls += 'https://www.videolan.org/favicon.ico' }
        'Git.Git' { $urls += 'https://git-scm.com/favicon.ico' }
    }

    if ($Publisher -like '*Valve*') {
        $urls += 'https://store.steampowered.com/favicon.ico'
    }

    if ($Homepage) {
        try {
            $domain = ([Uri]$Homepage).Host
            if ($domain) {
                $urls += "https://$domain/favicon.ico"
            }
        } catch { }
    }

    return $urls | Select-Object -Unique
}

function Get-HeuristicIconUrls {
    param(
        [string]$PackageId,
        [string]$DisplayName,
        [string]$Publisher,
        [string]$Homepage
    )

    $urls = @()
    $githubOrg = $null
    $githubRepo = $null

    if ($Homepage -match 'github\.com/([^/]+)/([^/]+)') {
        $githubOrg = $matches[1]
        $githubRepo = ($matches[2] -replace '/.*$', '')
    }

    if ($PackageId -like '*.*') {
        $parts = $PackageId -split '\.'
        $publisherPart = $parts[0]
        $appPart = $parts[1]
        $firstChar = $publisherPart.Substring(0, 1).ToLower()
        $urls += @(
            "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$firstChar/$publisherPart/$appPart/icon.png"
            "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$firstChar/$publisherPart/$appPart/logo.png"
        )
    }

    $orgName = if ($githubOrg) { $githubOrg } else { ($PackageId -split '\.')[0] }
    $projectName = if ($githubRepo) { $githubRepo } else { ($PackageId -split '\.')[-1] }
    foreach ($branch in @('main', 'master')) {
        foreach ($path in @('logo.png', 'icon.png', 'assets/logo.png', 'assets/icon.png', 'img/logo.png', 'img/icon.png', 'docs/logo.png')) {
            $urls += "https://raw.githubusercontent.com/$orgName/$projectName/$branch/$path"
        }
    }

    if ($Homepage -and $Homepage -notlike '*github.com*') {
        $homepageBase = $Homepage.TrimEnd('/')
        foreach ($path in @('logo.png', 'icon.png', 'images/logo.png', 'assets/logo.png', 'static/logo.png')) {
            $urls += "$homepageBase/$path"
        }
    }

    return $urls | Select-Object -Unique
}

function Export-BestIconFromExecutable {
    param(
        [string]$ExePath,
        [string]$OutputPath,
        [scriptblock]$OnProgress
    )

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        $associated = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
        if ($associated) {
            $bitmap = $associated.ToBitmap()
            $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $associated.Dispose()
            $bitmap.Dispose()
            if ((Test-Path $OutputPath) -and (Get-Item $OutputPath).Length -gt 0) {
                Write-WingetterLog -Message 'Extracted associated icon from installer executable' -Level Success -OnProgress $OnProgress
                return $true
            }
        }
    } catch {
        Write-Verbose "Associated icon extraction failed: $_"
    }

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
                for (int index = 0; index < 8; index++) {
                    IntPtr hIcon = ExtractIcon(IntPtr.Zero, exePath, index);
                    if (hIcon == IntPtr.Zero) { continue; }
                    try {
                        Icon icon = Icon.FromHandle(hIcon);
                        using (Bitmap bmp = icon.ToBitmap()) {
                            if (bmp.Width >= 32 && bmp.Height >= 32) {
                                bmp.Save(outputPath, ImageFormat.Png);
                                return true;
                            }
                        }
                    } finally {
                        DestroyIcon(hIcon);
                    }
                }
                return false;
            }
        }
"@ -ErrorAction SilentlyContinue

        if ([WingetterIconExtractor]::ExtractToPng($ExePath, $OutputPath)) {
            if (Test-Path $OutputPath -and (Get-Item $OutputPath).Length -gt 0) {
                Write-WingetterLog -Message 'Extracted shell icon from installer executable' -Level Success -OnProgress $OnProgress
                return $true
            }
        }
    } catch {
        Write-WingetterLog -Message "Icon extraction failed: $_" -Level Warning -OnProgress $OnProgress
    }

    return $false
}

function Resolve-PackageIcon {
    param(
        [string]$PackageId,
        [string]$DisplayName,
        [string]$Publisher,
        [string]$Homepage,
        [string]$Version,
        [string]$OutputPath,
        [string]$InstallerPath = $null,
        [scriptblock]$OnProgress
    )

    $candidateUrls = @()
    $candidateUrls += Get-IconUrlsFromWingetShow -PackageId $PackageId -Version $Version
    $candidateUrls += Get-IconUrlsFromWingetManifest -PackageId $PackageId -Version $Version
    $candidateUrls += Get-IconUrlsFromHomepage -Homepage $Homepage
    $candidateUrls += Get-KnownPackageIconUrls -PackageId $PackageId -Publisher $Publisher -Homepage $Homepage
    $candidateUrls += Get-HeuristicIconUrls -PackageId $PackageId -DisplayName $DisplayName -Publisher $Publisher -Homepage $Homepage

    $candidateUrls = $candidateUrls | Where-Object { $_ -and $_ -match '^https?://' } | Select-Object -Unique

    Write-WingetterLog -Message "Resolved $($candidateUrls.Count) icon candidate URL(s) for $PackageId" -Level Info -OnProgress $OnProgress

    foreach ($url in $candidateUrls) {
        if (Save-PackageIconFromUrl -Url $url -OutputPath $OutputPath -OnProgress $OnProgress) {
            return $true
        }
    }

    if ($InstallerPath -and (Test-Path $InstallerPath) -and $InstallerPath -like '*.exe') {
        return Export-BestIconFromExecutable -ExePath $InstallerPath -OutputPath $OutputPath -OnProgress $OnProgress
    }

    Write-WingetterLog -Message "No icon could be resolved for $PackageId" -Level Warning -OnProgress $OnProgress
    return $false
}

function Get-PackageLogoFromWeb {
    param(
        [string]$PackageId,
        [string]$DisplayName,
        [string]$Publisher,
        [string]$Homepage,
        [string]$OutputPath,
        [string]$Version,
        [string]$InstallerPath = $null,
        [scriptblock]$OnProgress
    )

    return Resolve-PackageIcon -PackageId $PackageId -DisplayName $DisplayName -Publisher $Publisher `
        -Homepage $Homepage -Version $Version -OutputPath $OutputPath -InstallerPath $InstallerPath -OnProgress $OnProgress
}
