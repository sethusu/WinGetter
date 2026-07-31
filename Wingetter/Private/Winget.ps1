# PowerShell 5.1 reads BOM-less scripts as the system ANSI code page. Keep this file
# ASCII-safe (or UTF-8 with BOM) so glyphs like U+2592 (UTF-8 ... 0x92) are not
# misread as curly quotes that terminate strings and break regex quantifiers ({2,}).
$script:WingetEllipsisChar = [char]0x2026
$script:WingetProgressLinePattern = '[{0}{1}]|\bKB\b|\bMB\b|%' -f [char]0x2588, [char]0x2592

function Test-WingetTruncatedId {
    param(
        [AllowEmptyString()]
        [string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $false
    }

    return ($Id.IndexOf($script:WingetEllipsisChar) -ge 0) -or ($Id -match '\.\.\.$')
}

function ConvertTo-WingetOutputLines {
    param($Output)

    if ($null -eq $Output) {
        return @()
    }

    $normalize = {
        param($Value)
        # winget redirected stdout is frequently UTF-16 interpreted as a narrow encoding,
        # which inserts a NUL between every character. Strip those so table headers match.
        $text = "$Value" -replace "`0", ''
        return $text.TrimEnd("`r")
    }

    if ($Output -is [string]) {
        return @($Output -split "`r?`n" | ForEach-Object { & $normalize $_ })
    }
    if ($Output -is [array]) {
        return @($Output | ForEach-Object { & $normalize $_ })
    }
    return @(& $normalize $Output)
}

function Test-WingetPackageId {
    param(
        [AllowEmptyString()]
        [string]$Query
    )

    $trimmed = if ($null -eq $Query) { '' } else { $Query.Trim() }
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $false
    }

    # Publisher.Package style identifiers used by the community winget repository
    return $trimmed -match '^[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9][A-Za-z0-9._-]*$'
}

function Normalize-WingetPackageId {
    param(
        [AllowEmptyString()]
        [string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return ''
    }

    $normalizedId = $Id.Trim()
    $normalizedId = $normalizedId -replace '\s*\.\s*', '.'
    $normalizedId = $normalizedId -replace '\s+', ''
    return $normalizedId
}

function Get-WingetTableColumnMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HeaderLine
    )

    $columns = @('Name', 'Id', 'Version', 'Match', 'Source')
    $map = [ordered]@{}

    foreach ($column in $columns) {
        $index = $HeaderLine.IndexOf($column, [System.StringComparison]::Ordinal)
        if ($index -ge 0) {
            $map[$column] = $index
        }
    }

    if (-not $map.Contains('Name') -or -not $map.Contains('Id') -or -not $map.Contains('Version')) {
        return $null
    }

    return $map
}

function Split-WingetTableRow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line,

        [Parameter(Mandatory = $true)]
        $ColumnMap
    )

    $orderedColumns = @(
        @{ Name = 'Name'; Start = [int]$ColumnMap['Name'] }
        @{ Name = 'Id'; Start = [int]$ColumnMap['Id'] }
        @{ Name = 'Version'; Start = [int]$ColumnMap['Version'] }
    )

    if ($ColumnMap.Contains('Match')) {
        $orderedColumns += @{ Name = 'Match'; Start = [int]$ColumnMap['Match'] }
    }
    if ($ColumnMap.Contains('Source')) {
        $orderedColumns += @{ Name = 'Source'; Start = [int]$ColumnMap['Source'] }
    }

    $values = [ordered]@{}
    for ($i = 0; $i -lt $orderedColumns.Count; $i++) {
        $column = $orderedColumns[$i]
        $start = [Math]::Max(0, $column.Start)
        $end = if ($i -lt ($orderedColumns.Count - 1)) {
            $orderedColumns[$i + 1].Start - 1
        } else {
            $Line.Length - 1
        }

        if ($end -lt $start) {
            $end = $Line.Length - 1
        }

        if ($start -ge $Line.Length) {
            $values[$column.Name] = ''
            continue
        }

        $length = [Math]::Max(0, $end - $start + 1)
        $sliceLength = [Math]::Min($length, $Line.Length - $start)
        $values[$column.Name] = $Line.Substring($start, $sliceLength).Trim()
    }

    return $values
}

function Test-WingetSearchRow {
    param(
        [string]$Name,
        [string]$Id,
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Id)) {
        return $false
    }

    if ($Name -match '^(Name|Found|Terms|Search|No package)' -or $Id -match '^(Id|Found)$') {
        return $false
    }

    if ($Version -match '^(Version|Match|Source)$') {
        return $false
    }

    if ($Id.Length -lt 2) {
        return $false
    }

    # Accept dotted community IDs and undotted MS Store product IDs (e.g. XP89DCGQ3K6VLD),
    # including truncated winget table IDs that contain an ellipsis glyph.
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -and -not (Test-WingetTruncatedId -Id $Id)) {
        return $false
    }

    if ($Version -and $Version -notmatch '^[0-9A-Za-z.<>=\s_-]+$') {
        return $false
    }

    return $true
}

function New-WingetPackageResult {
    param(
        [string]$Name,
        [string]$Id,
        [string]$Version = 'Unknown',
        [string]$Source = '',
        [bool]$TruncatedId = $false
    )

    return [PSCustomObject]@{
        Name        = $Name
        Id          = $Id
        Version     = if ([string]::IsNullOrWhiteSpace($Version)) { 'Unknown' } else { $Version }
        Source      = if ($null -eq $Source) { '' } else { $Source }
        TruncatedId = $TruncatedId
    }
}

function Get-WingetSourceFromSearchLine {
    param(
        [string]$Line,
        [string]$ParsedSource = '',
        [string]$DefaultSource = ''
    )

    # Column slicing often bleeds Match text into Source when Version is long.
    # Prefer a clean trailing token (winget / msstore / custom source name).
    if ($Line -match '\s([A-Za-z][A-Za-z0-9._-]*)\s*$') {
        $tail = $matches[1]
        if ($tail -notmatch '^(?i)(Moniker|Tag|ProductCode|Version|Match|Source|Name|Id)$' -and $tail -notmatch '^[0-9]') {
            if ([string]::IsNullOrWhiteSpace($ParsedSource) -or $ParsedSource -match '[:\s]' -or $ParsedSource.Length -gt 32) {
                return $tail
            }
        }
    }

    if ($ParsedSource -and $ParsedSource -notmatch '[:\s]' -and $ParsedSource.Length -le 32) {
        return $ParsedSource.Trim()
    }

    return $DefaultSource
}

function Parse-WingetSearchResults {
    param(
        [Parameter(Mandatory = $true)]
        $SearchOutput,

        [string]$DefaultSource = ''
    )

    $lines = ConvertTo-WingetOutputLines -Output $SearchOutput
    $packages = [System.Collections.Generic.List[object]]::new()
    $text = ($lines -join "`n").Trim()

    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    if ($text -match '(?i)No package found matching input criteria') {
        return @()
    }

    foreach ($line in $lines) {
        if ($line -match '^\s*Found\s+(.+?)\s+\[(.+?)\]\s*$') {
            $name = $matches[1].Trim()
            $id = Normalize-WingetPackageId -Id $matches[2].Trim()
            $version = 'Unknown'
            $lineIndex = [array]::IndexOf($lines, $line)
            for ($j = $lineIndex + 1; $j -lt [Math]::Min($lineIndex + 12, $lines.Count); $j++) {
                if ($lines[$j] -match '^\s*Version:\s+(.+?)\s*$') {
                    $version = $matches[1].Trim()
                    break
                }
            }

            $packages.Add((New-WingetPackageResult -Name $name -Id $id -Version $version -Source $DefaultSource -TruncatedId:$false))
            return @($packages)
        }
    }

    $headerIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'Name\s+Id\s+Version') {
            $headerIndex = $i
            break
        }
    }

    if ($headerIndex -lt 0) {
        # Header missing (encoding damage or atypical output). Fall back to loose row parsing
        # so substring matches like `winget search vlc` still surface VideoLAN.VLC.
        return @(Parse-WingetSearchResultsLoose -Lines $lines -DefaultSource $DefaultSource)
    }

    $columnMap = Get-WingetTableColumnMap -HeaderLine $lines[$headerIndex]
    if (-not $columnMap) {
        return @()
    }

    for ($i = $headerIndex + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($packages.Count -gt 0) { break }
            continue
        }

        if ($line -match '^-+$' -or $line -match '^[-\s\|\\/]+$') {
            continue
        }

        if ($line -match $script:WingetProgressLinePattern -or ($line.Length -lt 8 -and $line.Trim() -ne '')) {
            continue
        }

        if ($line -match '(?i)^(Terms of Transaction|Sequel|Category|Pricing|Free|Paid|System Requirements|Description):') {
            break
        }

        $row = Split-WingetTableRow -Line $line -ColumnMap $columnMap
        $name = $row['Name']
        $id = Normalize-WingetPackageId -Id $row['Id']
        $version = if ($row.Contains('Version')) { $row['Version'] } else { '' }
        $parsedSource = if ($row.Contains('Source')) { $row['Source'] } else { '' }
        $source = Get-WingetSourceFromSearchLine -Line $line -ParsedSource $parsedSource -DefaultSource $DefaultSource

        if (-not (Test-WingetSearchRow -Name $name -Id $id -Version $version)) {
            # Fallback for misaligned columns: Name / Id / Version with 2+ spaces
            if ($line -match '^\s*(.+?)\s{2,}([^\s]{2,}?)\s{2,}([0-9A-Za-z.<>=][0-9A-Za-z.<>=\s_-]*)') {
                $name = $matches[1].Trim()
                $id = Normalize-WingetPackageId -Id $matches[2].Trim()
                $version = $matches[3].Trim()
                $source = Get-WingetSourceFromSearchLine -Line $line -ParsedSource $source -DefaultSource $DefaultSource
            } else {
                continue
            }
        }

        # Recover full version when column width truncates/overflows (common with Match column)
        if ($id -and $line -match ('(?i)' + [regex]::Escape($id) + '\s+([0-9]+(?:\.[0-9A-Za-z_-]+)+)')) {
            $version = $matches[1].Trim()
        } elseif ($version -match '^(Moniker|Tag|ProductCode):') {
            $version = 'Unknown'
        } else {
            $version = ($version -split '\s{2,}')[0].Trim()
            # Strip trailing match labels that spilled into Version
            if ($version -match '^(?<ver>[0-9][0-9A-Za-z.-]*)\s+(Moniker|Tag|ProductCode):') {
                $version = $matches['ver']
            }
        }

        if (-not (Test-WingetSearchRow -Name $name -Id $id -Version $version)) {
            continue
        }

        $truncatedId = Test-WingetTruncatedId -Id $id
        $packages.Add((New-WingetPackageResult -Name $name -Id $id -Version $version -Source $source -TruncatedId:$truncatedId))
    }

    return @($packages)
}

function Parse-WingetSourceList {
    param(
        [Parameter(Mandatory = $true)]
        $SourceOutput
    )

    $lines = ConvertTo-WingetOutputLines -Output $SourceOutput
    $sources = [System.Collections.Generic.List[string]]::new()
    $headerIndex = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*Name\s+Argument' -or $lines[$i] -match '^\s*Name\s+') {
            $headerIndex = $i
            break
        }
    }

    $start = if ($headerIndex -ge 0) { $headerIndex + 1 } else { 0 }
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^-+$') {
            continue
        }

        # Typical: "winget    https://cdn.winget.microsoft.com/cache"
        # Also accept "msstore   ..." and custom enterprise sources
        if ($line -match '^(?i)(Name|Argument)\b') {
            continue
        }

        $name = ($line -split '\s+', 2)[0].Trim()
        if ($name -and $name -notmatch '^(?i)(Name|Argument)$' -and $name -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            if (-not ($sources -contains $name)) {
                $sources.Add($name)
            }
        }
    }

    return @($sources)
}

function Get-WingetConfiguredSources {
    [CmdletBinding()]
    param()

    try {
        $result = Invoke-WingetCli -Command source -Arguments @('list')
        $sources = Parse-WingetSourceList -SourceOutput $result.Output
        if ($sources.Count -gt 0) {
            return $sources
        }
    } catch {
        Write-Verbose "Unable to list winget sources: $_"
    }

    # Sensible defaults when source list parsing fails
    return @('winget', 'msstore')
}

function Sort-WingetPackageMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Packages
    )

    if ($Packages.Count -eq 0) {
        return @()
    }

    $normalizedQuery = $Query.Trim().ToLowerInvariant()
    $looksLikeId = Test-WingetPackageId -Query $Query

    return @($Packages | Sort-Object -Property @(
            @{
                Expression = {
                    $pkg = $_
                    $score = 0
                    $idLower = "$($pkg.Id)".ToLowerInvariant()
                    $nameLower = "$($pkg.Name)".ToLowerInvariant()

                    if ($looksLikeId -and $pkg.Id -eq $Query) { $score += 1000 }
                    if ($pkg.Id -eq $Query) { $score += 900 }
                    if ($idLower -eq $normalizedQuery) { $score += 800 }
                    if ($idLower.StartsWith($normalizedQuery)) { $score += 80 }
                    if ($pkg.Id -like "*$Query*") { $score += 200 }
                    if ($nameLower -eq $normalizedQuery) { $score += 150 }
                    if ($nameLower.StartsWith($normalizedQuery)) { $score += 60 }
                    if ($pkg.Name -like "*$Query*") { $score += 100 }

                    # Prefer community winget packages for Intune packaging, but keep all sources
                    if ("$($pkg.Source)" -eq 'winget') { $score += 40 }
                    if ("$($pkg.Source)" -eq 'msstore') { $score -= 10 }
                    if ($pkg.TruncatedId) { $score -= 50 }
                    if ($pkg.Version -eq 'Unknown') { $score -= 5 }

                    return $score
                }
                Descending = $true
            },
            @{ Expression = { $_.Source }; Descending = $false },
            @{ Expression = { $_.Name }; Descending = $false }
        ))
}

function Find-WingetPackagesFromModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [switch]$Exact
    )

    if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
        return $null
    }

    try {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop

        # Match winget CLI search semantics: Query does case-insensitive substring
        # matching across name/id/moniker (and related fields). -Name alone is too narrow
        # and can miss packages like VLC that match via moniker/command.
        if ($Exact) {
            $results = Find-WinGetPackage -Id $Query -ErrorAction Stop
        } else {
            $results = Find-WinGetPackage -Query $Query -ErrorAction Stop
        }

        if (-not $results) {
            return @()
        }

        return @($results | ForEach-Object {
                New-WingetPackageResult `
                    -Name $_.Name `
                    -Id $_.Id `
                    -Version $(if ($_.Version) { "$($_.Version)" } else { 'Unknown' }) `
                    -Source $(if ($_.Source) { "$($_.Source)" } else { '' }) `
                    -TruncatedId:$false
            })
    } catch {
        return $null
    }
}

function Resolve-WingetTruncatedPackage {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Package
    )

    if (-not $Package.TruncatedId) {
        return $Package
    }

    $candidates = @($Package.Id, $Package.Name) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    foreach ($candidate in $candidates) {
        try {
            $showArguments = @($candidate)
            if ($Package.Source) {
                $showArguments += @('--source', $Package.Source)
            }
            $result = Invoke-WingetCli -Command show -Arguments $showArguments
            $details = ConvertFrom-WingetShowFoundLine -ShowOutput $result.Output
            if ($details) {
                return New-WingetPackageResult `
                    -Name $details.Name `
                    -Id $details.Id `
                    -Version $(if ($Package.Version -and $Package.Version -ne 'Unknown') { $Package.Version } else { $details.Version }) `
                    -Source $(if ($Package.Source) { $Package.Source } else { $details.Source }) `
                    -TruncatedId:$false
            }
        } catch {
            Write-Verbose "Could not resolve truncated package '$candidate': $_"
        }
    }

    return $Package
}

function ConvertFrom-WingetShowFoundLine {
    param($ShowOutput)

    $lines = ConvertTo-WingetOutputLines -Output $ShowOutput
    $text = ($lines -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    if ($text -match '(?i)No package found|No applicable installer|Multiple packages found') {
        return $null
    }

    $name = $null
    $id = $null
    $version = 'Unknown'
    $source = ''

    foreach ($line in $lines) {
        if ($line -match '^\s*Found\s+(.+?)\s+\[(.+?)\]\s*$') {
            $name = $matches[1].Trim()
            $id = Normalize-WingetPackageId -Id $matches[2].Trim()
            continue
        }
        if ($line -match '^\s*Version:\s+(.+?)\s*$') {
            $version = $matches[1].Trim()
            continue
        }
        if ($line -match '^\s*Source:\s+(.+?)\s*$') {
            $source = $matches[1].Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($id)) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $id
    }

    return New-WingetPackageResult -Name $name -Id $id -Version $version -Source $source -TruncatedId:$false
}

function Add-WingetPackageUnique {
    param(
        [System.Collections.Generic.List[object]]$Target,
        [pscustomobject]$Package
    )

    if (-not $Package -or [string]::IsNullOrWhiteSpace($Package.Id)) {
        return
    }

    $existing = $Target | Where-Object {
        $_.Id -eq $Package.Id -and (
            [string]::IsNullOrWhiteSpace($Package.Source) -or
            [string]::IsNullOrWhiteSpace($_.Source) -or
            $_.Source -eq $Package.Source
        )
    } | Select-Object -First 1

    if ($existing) {
        if ([string]::IsNullOrWhiteSpace($existing.Source) -and $Package.Source) {
            $existing.Source = $Package.Source
        }
        if (($existing.Version -eq 'Unknown' -or [string]::IsNullOrWhiteSpace($existing.Version)) -and $Package.Version -and $Package.Version -ne 'Unknown') {
            $existing.Version = $Package.Version
        }
        return
    }

    $Target.Add($Package)
}

function Parse-WingetSearchResultsLoose {
    param(
        [string[]]$Lines,
        [string]$DefaultSource = ''
    )

    $packages = [System.Collections.Generic.List[object]]::new()

    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '(?i)No package found matching input criteria') { return @() }
        if ($line -match $script:WingetProgressLinePattern) { continue }
        if ($line -match '^\s*Name\s+Id\s+Version') { continue }
        if ($line -match '^-+$') { continue }

        # Publisher.Package Id with a version somewhere after it
        if ($line -match '(?i)\b([A-Za-z0-9][A-Za-z0-9_-]*\.[A-Za-z0-9][A-Za-z0-9._-]*)\b.*?\b(\d+(?:\.\d+[0-9A-Za-z_-]*)+)\b') {
            $id = Normalize-WingetPackageId -Id $matches[1]
            $version = $matches[2]
            $name = $line.Substring(0, $line.IndexOf($matches[1])).Trim()
            if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }
            $source = Get-WingetSourceFromSearchLine -Line $line -DefaultSource $DefaultSource
            if (Test-WingetSearchRow -Name $name -Id $id -Version $version) {
                $packages.Add((New-WingetPackageResult -Name $name -Id $id -Version $version -Source $source -TruncatedId:(Test-WingetTruncatedId -Id $id)))
            }
            continue
        }

        # MS Store style product codes
        if ($line -match '(?i)\b(XP[A-Z0-9]{12,}|9[A-Z0-9]{12,})\b') {
            $id = $matches[1]
            $name = $line.Substring(0, $line.IndexOf($id)).Trim()
            if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }
            $version = 'Unknown'
            if ($line -match '\b(\d+(?:\.\d+[0-9A-Za-z_-]*)+)\b') {
                $version = $matches[1]
            }
            $source = Get-WingetSourceFromSearchLine -Line $line -DefaultSource $(if ($DefaultSource) { $DefaultSource } else { 'msstore' })
            $packages.Add((New-WingetPackageResult -Name $name -Id $id -Version $version -Source $source -TruncatedId:$false))
        }
    }

    return @($packages)
}

function Search-WingetPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [int]$MaxResultsPerSource = 50
    )

    $trimmedQuery = $Query.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedQuery)) {
        return @()
    }

    $packages = [System.Collections.Generic.List[object]]::new()
    $looksLikeId = Test-WingetPackageId -Query $trimmedQuery
    $errors = [System.Collections.Generic.List[string]]::new()

    # Exact package ID resolution first (fast path for Publisher.Package queries)
    if ($looksLikeId) {
        try {
            $showResult = Invoke-WingetCli -Command show -Arguments @($trimmedQuery, '--exact')
            $exactPackage = ConvertFrom-WingetShowFoundLine -ShowOutput $showResult.Output
            if ($exactPackage) {
                Add-WingetPackageUnique -Target $packages -Package $exactPackage
            }
        } catch {
            Write-Verbose "Exact show lookup failed for '$trimmedQuery': $_"
        }
    }

    # Prefer structured WinGet PowerShell module when present (Query ~= winget search)
    $moduleResults = Find-WingetPackagesFromModule -Query $trimmedQuery -Exact:($looksLikeId)
    if ($null -ne $moduleResults) {
        foreach ($pkg in $moduleResults) {
            Add-WingetPackageUnique -Target $packages -Package $pkg
        }
    }

    $countArgs = @()
    if ($MaxResultsPerSource -gt 0 -and (Test-WingetSearchCountSupported)) {
        $countArgs = @('--count', "$MaxResultsPerSource")
    }

    # 1) Unscoped search first -- same as typing `winget search VLC` in a terminal.
    #    Winget substring-matches name, id, moniker, tags, and commands across all sources.
    try {
        $result = Invoke-WingetCli -Command search -Arguments (@($trimmedQuery) + $countArgs)
        $parsed = Parse-WingetSearchResults -SearchOutput $result.Output
        foreach ($pkg in $parsed) {
            Add-WingetPackageUnique -Target $packages -Package $pkg
        }
        if ($result.ExitCode -ne 0 -and $parsed.Count -eq 0 -and $packages.Count -eq 0) {
            $errors.Add("unscoped search exit $($result.ExitCode)")
        }
    } catch {
        $errors.Add("unscoped search: $($_.Exception.Message)")
    }

    # 2) Also search each configured repository so custom/enterprise sources are covered
    #    even when the default aggregate query is incomplete.
    $sources = @(Get-WingetConfiguredSources)
    foreach ($source in $sources) {
        if ([string]::IsNullOrWhiteSpace($source)) { continue }

        $searchArgs = @($trimmedQuery) + $countArgs + @('--source', $source)
        try {
            $result = Invoke-WingetCli -Command search -Arguments $searchArgs
            $parsed = Parse-WingetSearchResults -SearchOutput $result.Output -DefaultSource $source
            foreach ($pkg in $parsed) {
                if ([string]::IsNullOrWhiteSpace($pkg.Source)) {
                    $pkg.Source = $source
                }
                Add-WingetPackageUnique -Target $packages -Package $pkg
            }

            if ($result.ExitCode -ne 0 -and $parsed.Count -eq 0) {
                $errors.Add("source '$source' exit $($result.ExitCode)")
            }
        } catch {
            $errors.Add("source '$source': $($_.Exception.Message)")
        }
    }

    if ($packages.Count -eq 0 -and $errors.Count -gt 0) {
        throw "Winget search failed for '$trimmedQuery' ($($errors -join '; '))."
    }

    $resolved = foreach ($pkg in $packages) {
        Resolve-WingetTruncatedPackage -Package $pkg
    }

    return Sort-WingetPackageMatches -Query $trimmedQuery -Packages @($resolved)
}

function Get-WingetPackageDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,
        [string]$Version,
        [string]$Source
    )

    $showArguments = @($PackageId, '--exact')
    if ($Version) {
        $showArguments += @('--version', $Version)
    }
    if ($Source) {
        $showArguments += @('--source', $Source)
    }

    $result = Invoke-WingetCli -Command show -Arguments $showArguments
    $appInfo = $result.Output
    $hasAppInfo = $appInfo | Select-String -Pattern 'Found.*\[|Version:\s+|Publisher:\s+' -Quiet

    if ($result.ExitCode -ne 0 -and -not $hasAppInfo) {
        throw "Failed to get app information from Winget (exit code: $($result.ExitCode))."
    }

    $lines = ConvertTo-WingetOutputLines -Output $appInfo
    $text = $lines -join "`n"

    $packageId = if ($text -match 'Found .+? \[(.+?)\]') { Normalize-WingetPackageId -Id $matches[1].Trim() } else { $PackageId }
    $displayName = if ($text -match 'Found (.+?) \[') { $matches[1].Trim() } else { $PackageId }
    $foundVersion = if ($text -match 'Version:\s+(.+)') { ($text | Select-String -Pattern 'Version:\s+(.+)' | Select-Object -First 1).Matches.Groups[1].Value.Trim() } else { $Version }
    $publisher = if ($text -match 'Publisher:\s+(.+)') { ($text | Select-String -Pattern 'Publisher:\s+(.+)' | Select-Object -First 1).Matches.Groups[1].Value.Trim() } else { 'Unknown' }
    $homepage = if ($text -match 'Homepage:\s+(.+)') { ($text | Select-String -Pattern 'Homepage:\s+(.+)' | Select-Object -First 1).Matches.Groups[1].Value.Trim() } else { '' }
    $packageSource = if ($text -match 'Source:\s+(.+)') { ($text | Select-String -Pattern 'Source:\s+(.+)' | Select-Object -First 1).Matches.Groups[1].Value.Trim() } else { $Source }

    $description = 'No description available'
    $descriptionLine = $lines | Where-Object { $_ -match '^Description:\s+' } | Select-Object -First 1
    if ($descriptionLine) {
        $description = ($descriptionLine -replace '^Description:\s+', '').Trim()
        $lineIndex = [array]::IndexOf($lines, $descriptionLine)
        if ($lineIndex -ge 0) {
            $extraLines = @()
            for ($i = $lineIndex + 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^(Version|Publisher|Homepage|Installer|License|Tags|Moniker|Source):') { break }
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
        Source = $packageSource
        RawOutput = $appInfo
    }
}
