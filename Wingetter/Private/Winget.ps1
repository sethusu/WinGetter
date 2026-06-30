function ConvertTo-WingetOutputLines {
    param($Output)

    if ($Output -is [string]) {
        return $Output -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
    }
    if ($Output -is [array]) {
        return @($Output | ForEach-Object { "$_".TrimEnd("`r") })
    }
    return @("$Output".TrimEnd("`r"))
}

function Parse-WingetSearchResults {
    param(
        [Parameter(Mandatory = $true)]
        $SearchOutput
    )

    $lines = ConvertTo-WingetOutputLines -Output $SearchOutput
    $packages = @()
    $headerLineIndex = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'Name\s+Id\s+Version') {
            $headerLineIndex = $i
            break
        }
    }

    if ($headerLineIndex -eq -1) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'Found\s+(.+?)\s+\[(.+?)\]') {
                $name = $matches[1].Trim()
                $id = $matches[2].Trim()
                $version = 'Unknown'
                for ($j = $i + 1; $j -lt [Math]::Min($i + 10, $lines.Count); $j++) {
                    if ($lines[$j] -match 'Version:\s+(.+)') {
                        $version = $matches[1].Trim()
                        break
                    }
                }
                return @([PSCustomObject]@{
                    Name = $name
                    Id = $id
                    Version = $version
                    Source = ''
                })
            }
        }
        return @()
    }

    for ($i = $headerLineIndex + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($line -match '^-+$' -or $line.Trim() -eq '') {
            if ($packages.Count -gt 0) {
                $moreData = $false
                for ($j = $i + 1; $j -lt [Math]::Min($i + 3, $lines.Count); $j++) {
                    if ($lines[$j].Trim() -ne '' -and $lines[$j] -notmatch '^-+$' -and $lines[$j] -notmatch '█|▒|KB|MB|%') {
                        $moreData = $true
                        break
                    }
                }
                if (-not $moreData) { break }
            }
            continue
        }

        if ($line -match '█|▒|KB|MB|%' -or ($line.Length -lt 10 -and $line.Trim() -ne '')) {
            continue
        }

        if ($line -match "^\s*(.+?)\s{2,}([A-Za-z0-9][A-Za-z0-9.]*[A-Za-z0-9]|[A-Za-z0-9]+)\s{2,}([0-9][0-9A-Za-z.-]*[0-9A-Za-z]|[0-9]+)") {
            $name = $matches[1].Trim()
            $id = $matches[2].Trim()
            $version = $matches[3].Trim()
            $source = ''
            if ($line -match '\s{2,}([A-Za-z]+)\s*$') {
                $source = $matches[1].Trim()
            }

            if ($name -and $id -match '\.' -and $version) {
                $packages += [PSCustomObject]@{
                    Name = $name
                    Id = $id
                    Version = $version
                    Source = $source
                }
                continue
            }
        }

        $parts = $line -split '\s{2,}', [System.StringSplitOptions]::RemoveEmptyEntries
        if ($parts.Count -ge 3) {
            $name = $parts[0].Trim()
            $id = $parts[1].Trim()
            $version = $parts[2].Trim()
            $source = if ($parts.Count -ge 5) { $parts[4].Trim() } else { '' }

            if ($name -and $id -match '\.' -and $version -match '^[0-9A-Za-z.-]+$') {
                $packages += [PSCustomObject]@{
                    Name = $name
                    Id = $id
                    Version = $version
                    Source = $source
                }
            }
        }
    }

    return $packages
}

function Search-WingetPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $result = Invoke-WingetCli -Command search -Arguments @($Query)
    $packages = Parse-WingetSearchResults -SearchOutput $result.Output
    $hasResults = $packages.Count -gt 0

    if ($result.ExitCode -ne 0 -and -not $hasResults) {
        throw "Winget search failed with exit code $($result.ExitCode). Output: $($result.Output | Out-String)"
    }

    return $packages
}

function Get-WingetPackageDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,
        [string]$Version
    )

    $showArguments = @($PackageId, '--exact')
    if ($Version) {
        $showArguments += @('--version', $Version)
    }

    $result = Invoke-WingetCli -Command show -Arguments $showArguments
    $appInfo = $result.Output
    $hasAppInfo = $appInfo | Select-String -Pattern 'Found.*\[|Version:\s+|Publisher:\s+' -Quiet

    if ($result.ExitCode -ne 0 -and -not $hasAppInfo) {
        throw "Failed to get app information from Winget (exit code: $($result.ExitCode))."
    }

    $lines = ConvertTo-WingetOutputLines -Output $appInfo
    $text = $lines -join "`n"

    $packageId = if ($text -match 'Found .+? \[(.+?)\]') { $matches[1].Trim() } else { $PackageId }
    $displayName = if ($text -match 'Found (.+?) \[') { $matches[1].Trim() } else { $PackageId }
    $foundVersion = if ($text -match 'Version:\s+(.+)') { ($text | Select-String -Pattern 'Version:\s+(.+)' | Select-Object -First 1).Matches.Groups[1].Value.Trim() } else { $Version }
    $publisher = if ($text -match 'Publisher:\s+(.+)') { ($text | Select-String -Pattern 'Publisher:\s+(.+)' | Select-Object -First 1).Matches.Groups[1].Value.Trim() } else { 'Unknown' }
    $homepage = if ($text -match 'Homepage:\s+(.+)') { ($text | Select-String -Pattern 'Homepage:\s+(.+)' | Select-Object -First 1).Matches.Groups[1].Value.Trim() } else { '' }

    $description = 'No description available'
    $descriptionLine = $lines | Where-Object { $_ -match '^Description:\s+' } | Select-Object -First 1
    if ($descriptionLine) {
        $description = ($descriptionLine -replace '^Description:\s+', '').Trim()
        $lineIndex = [array]::IndexOf($lines, $descriptionLine)
        if ($lineIndex -ge 0) {
            $extraLines = @()
            for ($i = $lineIndex + 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^(Version|Publisher|Homepage|Installer|License|Tags|Moniker):') { break }
                if ($lines[$i].Trim()) { $extraLines += $lines[$i].Trim() }
            }
            if ($extraLines.Count -gt 0) {
                $description = ($description + ' ' + ($extraLines -join ' ')).Trim()
            }
        }
    }

    $installerType = ''
    if ($text -match 'Installer Type:\s+(.+)') {
        $installerType = ($text | Select-String -Pattern 'Installer Type:\s+(.+)' | Select-Object -First 1).Matches.Groups[1].Value.Trim()
    }

    if (-not $foundVersion) {
        throw 'Could not determine version from Winget output.'
    }

    if ($Version -and $foundVersion -ne $Version) {
        $foundVersion = $Version
    }

    return [PSCustomObject]@{
        PackageId = $packageId
        DisplayName = $displayName
        Version = $foundVersion
        Publisher = $publisher
        Description = $description
        Homepage = $homepage
        InstallerType = $installerType
        RawOutput = $appInfo
    }
}
