function ConvertTo-WingetSearchLines {
    param(
        [Parameter(Mandatory = $true)]
        $SearchOutput
    )

    if ($SearchOutput -is [string]) {
        return $SearchOutput -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
    }

    if ($SearchOutput -isnot [array]) {
        return @($SearchOutput | ForEach-Object { "$_".TrimEnd("`r") })
    }

    return $SearchOutput | ForEach-Object { "$_".TrimEnd("`r") }
}

function Get-WingetPackagesFromSearchOutput {
    param(
        [Parameter(Mandatory = $true)]
        $SearchOutput
    )

    $lines = ConvertTo-WingetSearchLines -SearchOutput $SearchOutput
    if (-not $lines -or $lines.Count -eq 0) {
        return @()
    }

    if ($lines | Where-Object { $_ -match 'No package found matching input criteria\.?' }) {
        return @()
    }

    # Handle "Found Name [Id]" format from exact/single result outputs.
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'Found\s+(.+?)\s+\[(.+?)\]') {
            $name = $matches[1].Trim()
            $id = $matches[2].Trim()
            $version = "Unknown"

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
            })
        }
    }

    $headerLineIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*Name\s+Id\s+Version') {
            $headerLineIndex = $i
            break
        }
    }

    if ($headerLineIndex -lt 0) {
        return @()
    }

    $headerLine = $lines[$headerLineIndex]
    $idStart = $headerLine.IndexOf("Id")
    $versionStart = $headerLine.IndexOf("Version")
    $matchStart = $headerLine.IndexOf("Match")
    $sourceStart = $headerLine.IndexOf("Source")
    $monikerStart = $headerLine.IndexOf("Moniker")

    if ($idStart -lt 0 -or $versionStart -lt 0 -or $idStart -ge $versionStart) {
        return @()
    }

    $columnCandidates = @($matchStart, $sourceStart, $monikerStart) |
        Where-Object { $_ -gt $versionStart } |
        Sort-Object
    $versionEnd = if ($columnCandidates.Count -gt 0) { $columnCandidates[0] } else { -1 }

    $packages = New-Object System.Collections.Generic.List[object]
    $seenIds = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)

    for ($i = $headerLineIndex + 1; $i -lt $lines.Count; $i++) {
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

        if ($line -match '█|▒|KB|MB|%' -or $line -match '^\s*[-=]+\s*$') {
            continue
        }

        if ($line.Length -le $versionStart) {
            continue
        }

        $name = ""
        $id = ""
        $version = ""

        # Prefer fixed-column parsing based on the header layout.
        $name = $line.Substring(0, [Math]::Min($idStart, $line.Length)).Trim()
        $idSliceLength = [Math]::Min($versionStart, $line.Length) - $idStart
        if ($idSliceLength -gt 0) {
            $id = $line.Substring($idStart, $idSliceLength).Trim()
        }

        if ($versionEnd -gt $versionStart -and $line.Length -gt $versionStart) {
            $rawVersionLength = [Math]::Min($versionEnd, $line.Length) - $versionStart
            if ($rawVersionLength -gt 0) {
                $version = $line.Substring($versionStart, $rawVersionLength).Trim()
            }
        } elseif ($line.Length -gt $versionStart) {
            $version = $line.Substring($versionStart).Trim()
            if ($version -match '\s{2,}') {
                $version = ($version -split '\s{2,}')[0].Trim()
            }
        }

        # Fall back to split parsing when long IDs overflow fixed column widths.
        if (-not $name -or -not $id -or $id -match '\s' -or -not $version -or $version -match '\s') {
            if ($line -match '^\s*(.+?)\s{2,}([^\s]+)\s+([^\s]+)(?:\s+.+)?$') {
                $name = $matches[1].Trim()
                $id = $matches[2].Trim()
                $version = $matches[3].Trim()
            }
        }

        if (-not $name -or -not $id -or $id -match '\s' -or -not $version -or $version -match '\s') {
            $parts = $line -split '\s{2,}', [System.StringSplitOptions]::RemoveEmptyEntries
            if ($parts.Count -ge 3) {
                $name = $parts[0].Trim()
                $id = $parts[1].Trim()
                $version = $parts[2].Trim()
            }
        }

        if (-not $name -or -not $id -or $id -match '\s' -or -not $version -or $version -match '\s') {
            continue
        }

        if (-not $seenIds.Add($id)) {
            continue
        }

        $packages.Add([PSCustomObject]@{
            Name = $name
            Id = $id
            Version = $version
        })
    }

    return $packages.ToArray()
}

function Select-WingetPackage {
    param(
        [Parameter(Mandatory = $true)]
        $SearchOutput
    )

    $packages = Get-WingetPackagesFromSearchOutput -SearchOutput $SearchOutput

    if (-not $packages -or $packages.Count -eq 0) {
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

    Add-Type -AssemblyName Microsoft.VisualBasic

    $title = "Wingetter - Select Package"
    $prompt = "Multiple packages found. Please select one by entering the number:`n`n"
    for ($i = 0; $i -lt $packages.Count; $i++) {
        $num = $i + 1
        $prompt += "$num. $($packages[$i].Name)`n   ID: $($packages[$i].Id)`n   Version: $($packages[$i].Version)`n`n"
    }
    $prompt += "Enter number (1-$($packages.Count)):"

    $selectedNumber = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, $title, "1")

    if ([string]::IsNullOrWhiteSpace($selectedNumber)) {
        Write-Host "No selection made. Exiting." -ForegroundColor Red
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
