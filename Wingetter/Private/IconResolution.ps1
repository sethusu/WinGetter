function Get-WingetterWebUserAgent {
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Wingetter/1.0'
}

function Get-SiteRootIconUrls {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return @() }

    try {
        $uri = [Uri]$Url
        $root = "$($uri.Scheme)://$($uri.Host)"
        return @(
            "$root/favicon.ico"
            "$root/favicon.png"
            "$root/apple-touch-icon.png"
        )
    } catch {
        return @()
    }
}

function Initialize-WingetterWebClient {
    if ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12 -eq 0) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    $client = New-Object System.Net.WebClient
    $client.Headers.Add('User-Agent', (Get-WingetterWebUserAgent))
    return $client
}

function Get-WingetterWebString {
    param([string]$Url)

    try {
        $client = Initialize-WingetterWebClient
        return $client.DownloadString($Url)
    } catch {
        return $null
    }
}

function Get-WingetterDomainFromUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }

    try {
        $hostName = ([Uri]$Url).Host
        if ($hostName -like 'www.*') {
            $hostName = $hostName.Substring(4)
        }
        return $hostName
    } catch {
        return $null
    }
}

function Get-IconBytesFromUrl {
    param(
        [string]$Url,
        [int]$TimeoutSec = 15
    )

    $tempFile = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.icon')
    try {
        $client = Initialize-WingetterWebClient
        $client.DownloadFile($Url, $tempFile)

        if (-not (Test-Path $tempFile)) { return $null }
        $bytes = [System.IO.File]::ReadAllBytes($tempFile)
        if ($bytes.Length -lt 4) { return $null }
        return $bytes
    } catch {
        return $null
    } finally {
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

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
            $iconStream = [System.IO.File]::OpenRead($tempFile)
            try {
                $icon = New-Object System.Drawing.Icon($iconStream, 256, 256)
                $bitmap = $icon.ToBitmap()
                $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $icon.Dispose()
                $bitmap.Dispose()
                return (Test-Path $OutputPath)
            } catch {
                $iconStream.Dispose()
                $iconStream = [System.IO.File]::OpenRead($tempFile)
                $icon = New-Object System.Drawing.Icon($iconStream)
                $bitmap = $icon.ToBitmap()
                $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $icon.Dispose()
                $bitmap.Dispose()
                return (Test-Path $OutputPath)
            } finally {
                if ($iconStream) { $iconStream.Dispose() }
            }
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
        $bytes = Get-IconBytesFromUrl -Url $Url
        if (-not $bytes) {
            throw 'Download returned no data'
        }

        if (Save-BytesAsPngIcon -Bytes $bytes -OutputPath $OutputPath) {
            if (Test-SavedIconQuality -OutputPath $OutputPath) {
                Write-WingetterLog -Message "Downloaded icon from $Url" -Level Success -OnProgress $OnProgress
                return $true
            }

            Write-WingetterLog -Message "Rejected low-quality icon from $Url" -Level Warning -OnProgress $OnProgress
        }
    } catch {
        Write-WingetterLog -Message "Icon URL failed ($Url): $($_.Exception.Message)" -Level Warning -OnProgress $OnProgress
    }

    if (Test-Path $OutputPath) {
        Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
    }
    return $false
}

function Test-SavedIconQuality {
    param(
        [string]$OutputPath,
        [int]$MinimumSize = 48
    )

    if (-not (Test-Path $OutputPath)) { return $false }

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $image = [System.Drawing.Image]::FromFile($OutputPath)
        try {
            return ($image.Width -ge $MinimumSize -and $image.Height -ge $MinimumSize)
        } finally {
            $image.Dispose()
        }
    } catch {
        return $false
    }
}

function Test-IsRejectedIconUrl {
    param(
        [string]$Url,
        [string]$PackageId,
        [string]$Homepage
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return $true }

    $allowGithub = ($PackageId -like 'Git.*' -or $Homepage -like '*github.com*')
    if (-not $allowGithub -and $Url -match '(?i)github\.com|githubusercontent\.com|githubassets\.com|github\.io') {
        return $true
    }

    if ($Url -match '(?i)duckduckgo\.com/favicon|google\.com/s2/favicons|opengraph\.githubassets\.com') {
        return $true
    }

    return $false
}

function Get-IconUrlPriorityScore {
    param(
        [string]$Url,
        [string]$DisplayName,
        [string]$PackageId,
        [ValidateSet('Known', 'Wikimedia', 'Clearbit', 'WingetShow', 'WingetManifest', 'WebSearch', 'Homepage', 'Heuristic', 'Favicon')]
        [string]$Source
    )

    $score = switch ($Source) {
        'Known' { 1000 }
        'Wikimedia' { 920 }
        'Clearbit' { 880 }
        'WingetShow' { 860 }
        'WingetManifest' { 820 }
        'WebSearch' { 780 }
        'Homepage' { 640 }
        'Heuristic' { 220 }
        'Favicon' { 120 }
        default { 0 }
    }

    if ($Url -match '\.png($|\?)') { $score += 90 }
    if ($Url -match '\.(jpg|jpeg)($|\?)') { $score += 70 }
    if ($Url -match '(?i)(logo|brand|app[-_]?icon)') { $score += 45 }
    if ($Url -match '(?i)favicon') { $score -= 60 }
    if ($Url -match '\.ico($|\?)') { $score -= 40 }
    if ($Url -match '\.svg($|\?)') { $score -= 25 }
    if ($Url -match 'upload\.wikimedia\.org') { $score += 55 }
    if ($Url -match 'logo\.clearbit\.com') { $score += 50 }

    $appToken = ($PackageId -split '\.')[-1]
    if ($DisplayName -and $Url -match [regex]::Escape($DisplayName)) { $score += 35 }
    if ($appToken -and $Url -match "(?i)$([regex]::Escape($appToken))") { $score += 25 }

    return $score
}

function Add-WingetterIconCandidates {
    param(
        [System.Collections.ArrayList]$Candidates,
        [string[]]$Urls,
        [string]$Source,
        [string]$DisplayName,
        [string]$PackageId,
        [string]$Homepage
    )

    foreach ($url in ($Urls | Where-Object { $_ })) {
        if (Test-IsRejectedIconUrl -Url $url -PackageId $PackageId -Homepage $Homepage) {
            continue
        }

        $score = Get-IconUrlPriorityScore -Url $url -DisplayName $DisplayName -PackageId $PackageId -Source $Source
        $existing = $Candidates | Where-Object { $_.Url -eq $url } | Select-Object -First 1
        if ($existing -and $existing.Score -ge $score) {
            continue
        }
        if ($existing) {
            [void]$Candidates.Remove($existing)
        }

        [void]$Candidates.Add([pscustomobject]@{
            Url = $url
            Score = $score
            Source = $Source
        })
    }
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
            $yaml = Get-WingetterWebString -Url $manifestUrl
            if (-not $yaml) { continue }
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
    $urls += Get-SiteRootIconUrls -Url $Homepage
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
        $html = Get-WingetterWebString -Url $Homepage
        if (-not $html) { return ($urls | Select-Object -Unique) }

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
                'https://upload.wikimedia.org/wikipedia/commons/thumb/8/83/Steam_icon_logo.svg/330px-Steam_icon_logo.svg.png'
                'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Steam_2016_logo_black.svg/512px-Steam_2016_logo_black.svg.png'
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

    if ($githubOrg -and $githubRepo) {
        foreach ($branch in @('main', 'master')) {
            foreach ($path in @('logo.png', 'icon.png', 'assets/logo.png', 'assets/icon.png', 'img/logo.png', 'img/icon.png', 'docs/logo.png')) {
                $urls += "https://raw.githubusercontent.com/$githubOrg/$githubRepo/$branch/$path"
            }
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

function Get-IconUrlsFromWikimedia {
    param(
        [string]$DisplayName,
        [string]$PackageId
    )

    $urls = @()
    $appName = if ($DisplayName) { $DisplayName.Trim() } else { ($PackageId -split '\.')[-1] }
    if ([string]::IsNullOrWhiteSpace($appName)) { return @() }

    $queries = @(
        "$appName logo"
        "$appName icon"
        "$appName software logo"
    )

    foreach ($query in ($queries | Select-Object -Unique)) {
        try {
            $encodedQuery = [Uri]::EscapeDataString($query)
            $apiUrl = "https://commons.wikimedia.org/w/api.php?action=query&generator=search&gsrsearch=$encodedQuery&gsrnamespace=6&gsrlimit=10&prop=imageinfo&iiprop=url&iiurlwidth=512&format=json"
            $jsonText = Get-WingetterWebString -Url $apiUrl
            if (-not $jsonText) { continue }

            $data = $jsonText | ConvertFrom-Json
            if (-not $data.query -or -not $data.query.pages) { continue }

            foreach ($pageProperty in $data.query.pages.PSObject.Properties) {
                $page = $pageProperty.Value
                if (-not $page.imageinfo) { continue }

                $title = [string]$page.title
                $titleLower = $title.ToLower()
                $appLower = $appName.ToLower()

                if ($titleLower -notmatch 'logo|icon' -and $titleLower -notmatch [regex]::Escape($appLower)) {
                    continue
                }

                if ($appName.Length -le 5 -and $titleLower -notmatch '(?i)\bicon\b|\blogo\b') {
                    continue
                }

                $imageInfo = $page.imageinfo[0]
                $imageUrl = $null

                if ($title -match '\.svg$' -and $imageInfo.thumburl) {
                    $imageUrl = $imageInfo.thumburl
                } elseif ($imageInfo.url -match '\.(png|jpg|jpeg)($|\?)') {
                    $imageUrl = $imageInfo.url
                } elseif ($imageInfo.thumburl -match '\.(png|jpg|jpeg)($|\?)') {
                    $imageUrl = $imageInfo.thumburl
                }

                if ($imageUrl) {
                    $urls += $imageUrl
                }
            }
        } catch {
            Write-Verbose "Wikimedia icon search failed for '$query': $_"
        }
    }

    return $urls | Select-Object -Unique
}

function Get-IconUrlsFromClearbit {
    param(
        [string]$Homepage,
        [string]$PublisherUrl = $null
    )

    $urls = @()
    foreach ($site in @($Homepage, $PublisherUrl)) {
        $domain = Get-WingetterDomainFromUrl -Url $site
        if ($domain -and $domain -notlike 'github.com' -and $domain -notlike 'raw.githubusercontent.com') {
            $urls += "https://logo.clearbit.com/$domain"
        }
    }

    return $urls | Select-Object -Unique
}

function Get-IconUrlsFromWebSearch {
    param(
        [string]$DisplayName,
        [string]$PackageId,
        [string]$Publisher
    )

    $urls = @()
    $appName = if ($DisplayName) { $DisplayName.Trim() } else { ($PackageId -split '\.')[-1] }
    if ([string]::IsNullOrWhiteSpace($appName)) { return @() }

    $publisherText = if ($Publisher) { $Publisher.Trim() } else { '' }
    $searchTerms = @(
        "$appName $publisherText logo png"
        "$appName app icon png"
        "$appName logo transparent png"
    )

    foreach ($term in ($searchTerms | Select-Object -Unique)) {
        try {
            $encodedQuery = [Uri]::EscapeDataString($term)
            $searchUrl = "https://www.bing.com/images/search?q=$encodedQuery&first=1&form=HDRSC2"
            $html = Get-WingetterWebString -Url $searchUrl
            if (-not $html) { continue }

            foreach ($pattern in @(
                '(?i)murl&quot;:&quot;(https?://[^&]+?\.(?:png|jpg|jpeg))'
                '(?i)"murl":"(https?://[^"]+?\.(?:png|jpg|jpeg))"'
                '(?i)turl&quot;:&quot;(https?://[^&]+?\.(?:png|jpg|jpeg))'
            )) {
                foreach ($match in [regex]::Matches($html, $pattern)) {
                    $urls += $match.Groups[1].Value
                }
            }

            foreach ($match in [regex]::Matches($html, '(?i)(https?://[^\s"<>]+\.png)')) {
                if ($match.Value -match '(?i)logo|icon|brand|app') {
                    $urls += $match.Value
                }
            }
        } catch {
            Write-Verbose "Web image search failed for '$term': $_"
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

    $candidateList = [System.Collections.ArrayList]@()

    Add-WingetterIconCandidates -Candidates $candidateList -Urls (Get-KnownPackageIconUrls -PackageId $PackageId -Publisher $Publisher -Homepage $Homepage) `
        -Source 'Known' -DisplayName $DisplayName -PackageId $PackageId -Homepage $Homepage
    Add-WingetterIconCandidates -Candidates $candidateList -Urls (Get-IconUrlsFromWikimedia -DisplayName $DisplayName -PackageId $PackageId) `
        -Source 'Wikimedia' -DisplayName $DisplayName -PackageId $PackageId -Homepage $Homepage
    Add-WingetterIconCandidates -Candidates $candidateList -Urls (Get-IconUrlsFromClearbit -Homepage $Homepage) `
        -Source 'Clearbit' -DisplayName $DisplayName -PackageId $PackageId -Homepage $Homepage
    Add-WingetterIconCandidates -Candidates $candidateList -Urls (Get-IconUrlsFromWingetShow -PackageId $PackageId -Version $Version) `
        -Source 'WingetShow' -DisplayName $DisplayName -PackageId $PackageId -Homepage $Homepage
    Add-WingetterIconCandidates -Candidates $candidateList -Urls (Get-IconUrlsFromWingetManifest -PackageId $PackageId -Version $Version) `
        -Source 'WingetManifest' -DisplayName $DisplayName -PackageId $PackageId -Homepage $Homepage
    Add-WingetterIconCandidates -Candidates $candidateList -Urls (Get-IconUrlsFromWebSearch -DisplayName $DisplayName -PackageId $PackageId -Publisher $Publisher) `
        -Source 'WebSearch' -DisplayName $DisplayName -PackageId $PackageId -Homepage $Homepage

    if ($Homepage) {
        Add-WingetterIconCandidates -Candidates $candidateList -Urls (Get-IconUrlsFromHomepage -Homepage $Homepage) `
            -Source 'Homepage' -DisplayName $DisplayName -PackageId $PackageId -Homepage $Homepage
        Add-WingetterIconCandidates -Candidates $candidateList -Urls (Get-SiteRootIconUrls -Url $Homepage) `
            -Source 'Favicon' -DisplayName $DisplayName -PackageId $PackageId -Homepage $Homepage
    }

    Add-WingetterIconCandidates -Candidates $candidateList -Urls (Get-HeuristicIconUrls -PackageId $PackageId -DisplayName $DisplayName -Publisher $Publisher -Homepage $Homepage) `
        -Source 'Heuristic' -DisplayName $DisplayName -PackageId $PackageId -Homepage $Homepage

    $sortedCandidates = $candidateList | Sort-Object -Property Score -Descending

    Write-WingetterLog -Message "Resolved $($sortedCandidates.Count) icon candidate URL(s) for $PackageId" -Level Info -OnProgress $OnProgress

    foreach ($candidate in $sortedCandidates) {
        Write-WingetterLog -Message "Icon candidate [$($candidate.Source) score=$($candidate.Score)]: $($candidate.Url)" -Level Info -OnProgress $OnProgress
        if (Save-PackageIconFromUrl -Url $candidate.Url -OutputPath $OutputPath -OnProgress $OnProgress) {
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
