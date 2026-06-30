# Wingetter - Winget search and package resolution helpers

function Test-WingetPackageId {
    <#
    .SYNOPSIS
        Returns true when the query looks like a winget package identifier.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Query
    )

    $trimmed = $Query.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $false
    }

    # Publisher.Package or Publisher.Package.SubPackage
    return $trimmed -match '^[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9][A-Za-z0-9._-]*$'
}

function ConvertFrom-WingetShowOutput {
    <#
    .SYNOPSIS
        Parses winget show output into a package object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ShowOutput
    )

    if ($null -eq $ShowOutput) {
        return $null
    }

    if ($ShowOutput -is [string]) {
        $lines = $ShowOutput -split "`r?`n" | ForEach-Object { $_.TrimEnd("`r") }
    }
    elseif ($ShowOutput -is [array]) {
        $lines = @($ShowOutput | ForEach-Object { "$_".TrimEnd("`r") })
    }
    else {
        $lines = @("$ShowOutput".TrimEnd("`r"))
    }

    $text = ($lines -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    if ($text -match '(?i)No package found|No applicable installer|Multiple packages found') {
        return $null
    }

    $package = [ordered]@{
        Name    = $null
        Id      = $null
        Version = $null
        Source  = 'winget'
    }

    foreach ($line in $lines) {
        if ($line -match '^\s*Found\s+(.+?)\s+\[(.+?)\]\s*$') {
            $package.Name = $matches[1].Trim()
            $package.Id = $matches[2].Trim()
            continue
        }

        if ($line -match '^\s*Version:\s+(.+?)\s*$') {
            $package.Version = $matches[1].Trim()
            continue
        }

        if ($line -match '^\s*Version\s+(.+?)\s*$' -and -not $package.Version) {
            $package.Version = $matches[1].Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($package.Id)) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($package.Name)) {
        $package.Name = $package.Id
    }

    if ([string]::IsNullOrWhiteSpace($package.Version)) {
        $package.Version = 'Unknown'
    }

    return [PSCustomObject]$package
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

    if ($map.Count -lt 3) {
        return $null
    }

    return $map
}

function Split-WingetTableRow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line,

        [Parameter(Mandatory = $true)]
        [hashtable]$ColumnMap
    )

    $orderedColumns = @(
        @{ Name = 'Name'; Start = $ColumnMap['Name'] }
        @{ Name = 'Id'; Start = $ColumnMap['Id'] }
        @{ Name = 'Version'; Start = $ColumnMap['Version'] }
    )

    if ($ColumnMap.Contains('Match')) {
        $orderedColumns += @{ Name = 'Match'; Start = $ColumnMap['Match'] }
    }

    if ($ColumnMap.Contains('Source')) {
        $orderedColumns += @{ Name = 'Source'; Start = $ColumnMap['Source'] }
    }

    $values = [ordered]@{}
    for ($i = 0; $i -lt $orderedColumns.Count; $i++) {
        $column = $orderedColumns[$i]
        $start = [Math]::Max(0, $column.Start)
        $end = if ($i -lt ($orderedColumns.Count - 1)) {
            $orderedColumns[$i + 1].Start - 1
        }
        else {
            $Line.Length - 1
        }

        if ($end -lt $start) {
            $end = $Line.Length - 1
        }

        $length = [Math]::Max(0, $end - $start + 1)
        if ($start -ge $Line.Length) {
            $values[$column.Name] = ''
        }
        else {
            $sliceLength = [Math]::Min($length, $Line.Length - $start)
            $values[$column.Name] = $Line.Substring($start, $sliceLength).Trim()
        }
    }

    return $values
}

function Test-WingetSearchRow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
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

    if ($Version -and $Version -notmatch '^[0-9A-Za-z.<>=\s_-]+$') {
        return $false
    }

    return $true
}

function ConvertFrom-WingetSearchOutput {
    <#
    .SYNOPSIS
        Parses winget search table/text output into package objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $SearchOutput
    )

    if ($SearchOutput -is [string]) {
        $lines = $SearchOutput -split "`r?`n" | ForEach-Object { $_.TrimEnd("`r") }
    }
    elseif ($SearchOutput -is [array]) {
        $lines = @($SearchOutput | ForEach-Object { "$_".TrimEnd("`r") })
    }
    else {
        $lines = @("$SearchOutput".TrimEnd("`r"))
    }

    $packages = [System.Collections.Generic.List[object]]::new()
    $text = ($lines -join "`n").Trim()

    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    if ($text -match '(?i)No package found matching input criteria') {
        return @()
    }

    # Single-result format sometimes returned by winget show/search edge cases
  foreach ($line in $lines) {
        if ($line -match '^\s*Found\s+(.+?)\s+\[(.+?)\]\s*$') {
            $name = $matches[1].Trim()
            $id = $matches[2].Trim()
            $version = 'Unknown'

            $lineIndex = [array]::IndexOf($lines, $line)
            for ($j = $lineIndex + 1; $j -lt [Math]::Min($lineIndex + 12, $lines.Count); $j++) {
                if ($lines[$j] -match '^\s*Version:\s+(.+?)\s*$') {
                    $version = $matches[1].Trim()
                    break
                }
            }

            $packages.Add([PSCustomObject]@{
                    Name    = $name
                    Id      = $id
                    Version = $version
                    Source  = 'winget'
                    TruncatedId = $false
                })
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
        return @()
    }

    $columnMap = Get-WingetTableColumnMap -HeaderLine $lines[$headerIndex]
    if (-not $columnMap) {
        return @()
    }

    for ($i = $headerIndex + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($packages.Count -gt 0) {
                break
            }
            continue
        }

        if ($line -match '^-+$' -or $line -match '^[-\s\|\\/]+$') {
            continue
        }

        if ($line -match '█|▒|\bKB\b|\bMB\b|%' -or ($line.Length -lt 8 -and $line.Trim() -ne '')) {
            continue
        }

        if ($line -match '(?i)^(Terms of Transaction|Sequel|Category|Pricing|Free|Paid|System Requirements|Description):') {
            break
        }

        $row = Split-WingetTableRow -Line $line -ColumnMap $columnMap
        $name = $row['Name']
        $id = $row['Id']
        $version = if ($row.Contains('Version')) { $row['Version'] } else { '' }
        $source = if ($row.Contains('Source')) { $row['Source'] } else { 'winget' }

        if (-not (Test-WingetSearchRow -Name $name -Id $id -Version $version)) {
            # Regex fallback for rows where column slicing fails
            if ($line -match '^\s*(.+?)\s{2,}([^\s]{2,}?)\s{2,}([0-9A-Za-z.<>=][0-9A-Za-z.<>=\s_-]*)') {
                $name = $matches[1].Trim()
                $id = $matches[2].Trim()
                $version = $matches[3].Trim()
                $source = 'winget'
            }
            else {
                continue
            }
        }

        if ($id -and $line -match ('(?i)' + [regex]::Escape($id) + '\s+([0-9]+(?:\.[0-9A-Za-z_-]+)+)')) {
            $version = $matches[1].Trim()
        }
        elseif ($version -match '^(Moniker|Tag|ProductCode):') {
            $version = 'Unknown'
        }
        else {
            $version = ($version -split '\s{2,}')[0].Trim()
        }

        if (-not (Test-WingetSearchRow -Name $name -Id $id -Version $version)) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($version)) {
            $version = 'Unknown'
        }

        $truncatedId = $id -match '…|\.\.\.$'
        $packages.Add([PSCustomObject]@{
                Name        = $name
                Id          = $id
                Version     = $version
                Source      = if ([string]::IsNullOrWhiteSpace($source)) { 'winget' } else { $source }
                TruncatedId = $truncatedId
            })
    }

    return @($packages)
}

function Resolve-WingetTruncatedPackage {
    <#
    .SYNOPSIS
        Resolves a truncated package ID using winget show when possible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Package,

        [scriptblock]$InvokeWingetShow = ${function:Invoke-WingetShowCommand}
    )

    if (-not $Package.TruncatedId) {
        return $Package
    }

    $resolved = & $InvokeWingetShow -PackageId $Package.Id -Exact:$false
    if ($resolved) {
        return [PSCustomObject]@{
            Name        = $resolved.Name
            Id          = $resolved.Id
            Version     = if ($Package.Version -and $Package.Version -ne 'Unknown') { $Package.Version } else { $resolved.Version }
            Source      = $Package.Source
            TruncatedId = $false
        }
    }

    $resolvedByName = & $InvokeWingetShow -PackageId $Package.Name -Exact:$false
    if ($resolvedByName) {
        return [PSCustomObject]@{
            Name        = $resolvedByName.Name
            Id          = $resolvedByName.Id
            Version     = if ($Package.Version -and $Package.Version -ne 'Unknown') { $Package.Version } else { $resolvedByName.Version }
            Source      = $Package.Source
            TruncatedId = $false
        }
    }

    return $Package
}

function Get-WingetSearchAgreementFlags {
    $supportsPackageAgreements = $false
    try {
        $helpOutput = & winget search --help 2>&1
        $supportsPackageAgreements = [bool]($helpOutput | Select-String -Pattern 'accept-package-agreements' -Quiet)
    }
    catch {
        $supportsPackageAgreements = $false
    }

    if ($supportsPackageAgreements) {
        return @('--accept-source-agreements', '--accept-package-agreements')
    }

    return @('--accept-source-agreements')
}

function Invoke-WingetShowRaw {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [string]$Version,

        [switch]$Exact
    )

    $args = @('show', $PackageId, '--disable-interactivity') + (Get-WingetSearchAgreementFlags)
    if ($Exact) {
        $args += '--exact'
    }
    if ($Version) {
        $args += @('--version', $Version)
    }

    return & winget @args 2>&1
}

function Get-WingetPackageDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [string]$Version
    )

    $rawOutput = Invoke-WingetShowRaw -PackageId $PackageId -Version $Version -Exact
    $package = ConvertFrom-WingetShowOutput -ShowOutput $rawOutput

    return [PSCustomObject]@{
        Package = $package
        RawOutput = $rawOutput
    }
}

function Invoke-WingetShowCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [string]$Version,

        [switch]$Exact
    )

    $rawOutput = Invoke-WingetShowRaw -PackageId $PackageId -Version $Version -Exact:$Exact
    return ConvertFrom-WingetShowOutput -ShowOutput $rawOutput
}


function Invoke-WingetSearchCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [switch]$Exact,

        [string]$Source
    )

    $args = @('search', $Query, '--disable-interactivity') + (Get-WingetSearchAgreementFlags)
    if ($Exact) {
        $args += '--exact'
    }
    if ($Source) {
        $args += @('--source', $Source)
    }

    $output = & winget @args 2>&1
    return $output
}

function Find-WingetPackagesFromModule {
    [CmdletBinding()]
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
        $params = @{ Name = $Query }
        if ($Exact) {
            $params['Id'] = $Query
        }

        $results = Find-WinGetPackage @params -ErrorAction Stop
        if (-not $results) {
            return @()
        }

        return @($results | ForEach-Object {
                [PSCustomObject]@{
                    Name        = $_.Name
                    Id          = $_.Id
                    Version     = if ($_.Version) { "$($_.Version)" } else { 'Unknown' }
                    Source      = if ($_.Source) { "$($_.Source)" } else { 'winget' }
                    TruncatedId = $false
                }
            })
    }
    catch {
        return $null
    }
}

function Sort-WingetPackageMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [Parameter(Mandatory = $true)]
        [array]$Packages
    )

    $normalizedQuery = $Query.Trim().ToLowerInvariant()
    $looksLikeId = Test-WingetPackageId -Query $Query

    return @($Packages | Sort-Object -Property @(
            @{
                Expression = {
                    $pkg = $_
                    $score = 0

                    if ($looksLikeId -and $pkg.Id -eq $Query) { $score += 1000 }
                    if ($pkg.Id -eq $Query) { $score += 900 }
                    if ($pkg.Id -like "*$Query*") { $score += 200 }
                    if ($pkg.Name -eq $Query) { $score += 150 }
                    if ($pkg.Name -like "*$Query*") { $score += 100 }

                    $idLower = $pkg.Id.ToLowerInvariant()
                    $nameLower = $pkg.Name.ToLowerInvariant()
                    if ($idLower -eq $normalizedQuery) { $score += 800 }
                    if ($nameLower -eq $normalizedQuery) { $score += 120 }
                    if ($idLower.StartsWith($normalizedQuery)) { $score += 80 }
                    if ($nameLower.StartsWith($normalizedQuery)) { $score += 60 }

                    if ($pkg.Source -eq 'winget') { $score += 100 }
                    if ($pkg.Source -eq 'msstore') { $score -= 40 }
                    if ($pkg.TruncatedId) { $score -= 50 }
                    if ($pkg.Version -eq 'Unknown') { $score -= 5 }

                    return $score
                }
                Descending = $true
            },
            @{
                Expression = { $_.Name }
                Descending = $false
            }
        ))
}

function Search-WingetPackages {
    <#
    .SYNOPSIS
        Searches winget using structured module output when available, otherwise CLI parsing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [switch]$PreferWingetSource
    )

    $trimmedQuery = $Query.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedQuery)) {
        return @()
    }

    $looksLikeId = Test-WingetPackageId -Query $trimmedQuery
    $packages = [System.Collections.Generic.List[object]]::new()

    if ($looksLikeId) {
        $exactShow = Invoke-WingetShowCommand -PackageId $trimmedQuery -Exact
        if ($exactShow) {
            $packages.Add([PSCustomObject]@{
                    Name        = $exactShow.Name
                    Id          = $exactShow.Id
                    Version     = $exactShow.Version
                    Source      = 'winget'
                    TruncatedId = $false
                })
        }
    }

    $moduleResults = Find-WingetPackagesFromModule -Query $trimmedQuery -Exact:($looksLikeId)
    if ($null -ne $moduleResults) {
        foreach ($pkg in $moduleResults) {
            if (-not ($packages | Where-Object { $_.Id -eq $pkg.Id })) {
                $packages.Add($pkg)
            }
        }
    }

    if ($packages.Count -eq 0) {
        $searchOutput = Invoke-WingetSearchCommand -Query $trimmedQuery
        $parsed = ConvertFrom-WingetSearchOutput -SearchOutput $searchOutput
        foreach ($pkg in $parsed) {
            if (-not ($packages | Where-Object { $_.Id -eq $pkg.Id -and $_.Name -eq $pkg.Name })) {
                $packages.Add($pkg)
            }
        }
    }

    if ($PreferWingetSource -and $packages.Count -gt 1) {
        $wingetOnly = @($packages | Where-Object { $_.Source -eq 'winget' })
        if ($wingetOnly.Count -gt 0) {
            $packages = [System.Collections.Generic.List[object]]::new()
            foreach ($pkg in $wingetOnly) { $packages.Add($pkg) }
        }
    }

    $resolved = foreach ($pkg in $packages) {
        Resolve-WingetTruncatedPackage -Package $pkg
    }

    return Sort-WingetPackageMatches -Query $trimmedQuery -Packages @($resolved)
}

function Select-WingetPackage {
    <#
    .SYNOPSIS
        Parses winget search output and optionally prompts the user to choose a package.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $SearchOutput,

        [string]$Query,

        [switch]$NoPrompt,

        [int]$DefaultSelection = 1
    )

    $packages = if ($SearchOutput -is [System.Array] -and $SearchOutput.Count -gt 0 -and $SearchOutput[0].Id) {
        @($SearchOutput)
    }
    else {
        ConvertFrom-WingetSearchOutput -SearchOutput $SearchOutput
    }

    if ($Query) {
        $packages = Sort-WingetPackageMatches -Query $Query -Packages $packages
    }

    if ($packages.Count -eq 0) {
        return $null
    }

    if ($packages.Count -eq 1) {
        Write-Host "`nFound 1 matching package:" -ForegroundColor Green
        Write-Host "  1. $($packages[0].Name) ($($packages[0].Id)) - Version: $($packages[0].Version)" -ForegroundColor Cyan
        return $packages[0]
    }

    Write-Host "`nFound $($packages.Count) matching packages:" -ForegroundColor Green
    for ($i = 0; $i -lt $packages.Count; $i++) {
        $num = $i + 1
        Write-Host "  $num. $($packages[$i].Name) ($($packages[$i].Id)) - Version: $($packages[$i].Version)" -ForegroundColor Cyan
    }

    if ($NoPrompt) {
        if ($DefaultSelection -lt 1 -or $DefaultSelection -gt $packages.Count) {
            throw "DefaultSelection must be between 1 and $($packages.Count)"
        }
        return $packages[$DefaultSelection - 1]
    }

    Add-Type -AssemblyName Microsoft.VisualBasic

    $title = 'Wingetter - Select Package'
    $prompt = "Multiple packages found. Please select one by entering the number:`n`n"
    for ($i = 0; $i -lt $packages.Count; $i++) {
        $num = $i + 1
        $prompt += "$num. $($packages[$i].Name)`n   ID: $($packages[$i].Id)`n   Version: $($packages[$i].Version)`n`n"
    }
    $prompt += "Enter number (1-$($packages.Count)):"

    $selectedNumber = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, $title, "$DefaultSelection")

    if ([string]::IsNullOrWhiteSpace($selectedNumber)) {
        Write-Host 'No selection made. Exiting.' -ForegroundColor Red
        exit 1
    }

    $parsedNumber = 0
    $isValid = [int]::TryParse($selectedNumber.Trim(), [ref]$parsedNumber)
    if (-not $isValid -or $parsedNumber -lt 1 -or $parsedNumber -gt $packages.Count) {
        Write-Host "Invalid selection: $selectedNumber. Exiting." -ForegroundColor Red
        exit 1
    }

    $selectedPackage = $packages[$parsedNumber - 1]
    Write-Host "`nSelected: $($selectedPackage.Name) ($($selectedPackage.Id))" -ForegroundColor Green

    return $selectedPackage
}

Export-ModuleMember -Function @(
    'Test-WingetPackageId',
    'ConvertFrom-WingetShowOutput',
    'ConvertFrom-WingetSearchOutput',
    'Resolve-WingetTruncatedPackage',
    'Search-WingetPackages',
    'Select-WingetPackage',
    'Sort-WingetPackageMatches',
    'Invoke-WingetShowCommand',
    'Invoke-WingetShowRaw',
    'Get-WingetPackageDetails',
    'Invoke-WingetSearchCommand'
)
