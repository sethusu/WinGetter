function Test-WingetSupportsPackageAgreements {
    $testCommand = winget search --help 2>&1 | Select-String -Pattern 'accept-package-agreements' -Quiet
    return [bool]$testCommand
}

function Parse-WingetSearchResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SearchOutput
    )

    if ($SearchOutput -is [string]) {
        $SearchOutput = $SearchOutput -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
    }
    elseif ($SearchOutput -isnot [array]) {
        $SearchOutput = @($SearchOutput)
    }

    $packages = @()
    $headerLineIndex = -1

    for ($i = 0; $i -lt $SearchOutput.Count; $i++) {
        if ($SearchOutput[$i] -match 'Name\s+Id\s+Version') {
            $headerLineIndex = $i
            break
        }
    }

    if ($headerLineIndex -eq -1) {
        for ($i = 0; $i -lt $SearchOutput.Count; $i++) {
            if ($SearchOutput[$i] -match 'Found.*\[') {
                $line = $SearchOutput[$i]
                if ($line -match 'Found\s+(.+?)\s+\[(.+?)\]') {
                    $name = $matches[1].Trim()
                    $id = $matches[2].Trim()
                    $version = 'Unknown'
                    for ($j = $i + 1; $j -lt [Math]::Min($i + 10, $SearchOutput.Count); $j++) {
                        if ($SearchOutput[$j] -match 'Version:\s+(.+)') {
                            $version = $matches[1].Trim()
                            break
                        }
                    }
                    return @([PSCustomObject]@{
                            Name    = $name
                            Id      = $id
                            Version = $version
                            Source  = 'winget'
                        })
                }
            }
        }
        return @()
    }

    for ($i = $headerLineIndex + 1; $i -lt $SearchOutput.Count; $i++) {
        $line = $SearchOutput[$i]

        if ($line -match '^-+$' -or $line.Trim() -eq '') {
            if ($line.Trim() -eq '' -and $packages.Count -gt 0) {
                $moreData = $false
                for ($j = $i + 1; $j -lt [Math]::Min($i + 3, $SearchOutput.Count); $j++) {
                    if ($SearchOutput[$j].Trim() -ne '' -and $SearchOutput[$j] -notmatch '^-+$' -and $SearchOutput[$j] -notmatch '█|▒|KB|MB|%') {
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

        if ($line -match '^\s*(.+?)\s{2,}([A-Za-z0-9][A-Za-z0-9.]*[A-Za-z0-9]|[A-Za-z0-9]+)\s{2,}([0-9][0-9A-Za-z.-]*[0-9A-Za-z]|[0-9]+)') {
            $name = $matches[1].Trim()
            $id = $matches[2].Trim()
            $version = $matches[3].Trim()
            if ($name.Length -gt 0 -and $id.Length -gt 2 -and $id -match '\.' -and $version.Length -gt 0) {
                $packages += [PSCustomObject]@{
                    Name    = $name
                    Id      = $id
                    Version = $version
                    Source  = 'winget'
                }
                continue
            }
        }

        $parts = $line -split '\s{2,}', [System.StringSplitOptions]::RemoveEmptyEntries
        if ($parts.Count -ge 3) {
            $name = $parts[0].Trim()
            $id = $parts[1].Trim()
            $version = $parts[2].Trim()
            if ($name.Length -gt 0 -and $id.Length -gt 2 -and $id -match '\.' -and $version.Length -gt 0 -and $version -match '^[0-9A-Za-z.-]+$') {
                $packages += [PSCustomObject]@{
                    Name    = $name
                    Id      = $id
                    Version = $version
                    Source  = 'winget'
                }
            }
        }
    }

    return $packages
}

function Search-WingetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Query,

        [scriptblock]$ProgressCallback
    )

    Write-WingetterLog -Message "Searching Winget for '$Query'..." -ProgressCallback $ProgressCallback

    $supportsPackageAgreements = Test-WingetSupportsPackageAgreements
    if ($supportsPackageAgreements) {
        $searchResult = winget search $Query --accept-source-agreements --accept-package-agreements 2>&1
    }
    else {
        $searchResult = winget search $Query --accept-source-agreements 2>&1
    }

    $searchExitCode = $LASTEXITCODE
    $hasResults = $searchResult | Select-String -Pattern 'Name\s+Id\s+Version|Found.*\[' -Quiet
    if ($searchExitCode -ne 0 -and -not $hasResults) {
        throw "Winget search failed with exit code $searchExitCode. Is Winget installed?"
    }

    $packages = Parse-WingetSearchResults -SearchOutput $searchResult
    if ($packages.Count -eq 0) {
        throw 'No packages found or could not parse search results.'
    }

    Write-WingetterLog -Message "Found $($packages.Count) matching package(s)." -Level Success -ProgressCallback $ProgressCallback
    return $packages
}

function Get-WingetAppDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,

        [string]$Version
    )

    $supportsPackageAgreements = Test-WingetSupportsPackageAgreements
    if ($Version) {
        if ($supportsPackageAgreements) {
            $appInfo = winget show $PackageId --exact --version $Version --accept-source-agreements --accept-package-agreements 2>&1
        }
        else {
            $appInfo = winget show $PackageId --exact --version $Version --accept-source-agreements 2>&1
        }
    }
    else {
        if ($supportsPackageAgreements) {
            $appInfo = winget show $PackageId --exact --accept-source-agreements --accept-package-agreements 2>&1
        }
        else {
            $appInfo = winget show $PackageId --exact --accept-source-agreements 2>&1
        }
    }

    $showExitCode = $LASTEXITCODE
    $hasAppInfo = $appInfo | Select-String -Pattern 'Found.*\[|Version:\s+|Publisher:\s+' -Quiet
    if ($showExitCode -ne 0 -and -not $hasAppInfo) {
        throw "Failed to get app information from Winget (exit code: $showExitCode)."
    }

    $extractedPackageId = ($appInfo | Select-String -Pattern 'Found (.+?) \[(.+?)\]' | ForEach-Object { $_.Matches.Groups[2].Value })
    if ($extractedPackageId) { $PackageId = $extractedPackageId }

    $foundVersion = ($appInfo | Select-String -Pattern 'Version:\s+(.+)' | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    if ($Version) { $foundVersion = $Version }
    if (-not $foundVersion) { throw 'Could not determine version from Winget output.' }

    $displayName = ($appInfo | Select-String -Pattern 'Found (.+?) \[' | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    if (-not $displayName) { $displayName = $PackageId }

    $publisher = ($appInfo | Select-String -Pattern 'Publisher:\s+(.+)' | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    if (-not $publisher) { $publisher = 'Unknown' }

    $description = ($appInfo | Select-String -Pattern 'Description:\s+(.+)' | ForEach-Object { $_.Line.Trim() })
    if (-not $description) { $description = 'No description available' }

    $homepage = ($appInfo | Select-String -Pattern 'Homepage:\s+(.+)' | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    if (-not $homepage) { $homepage = '' }

    $installerType = ($appInfo | Select-String -Pattern 'Installer Type:\s+(.+)' | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    if (-not $installerType) { $installerType = 'Unknown' }

    return [PSCustomObject]@{
        PackageId     = $PackageId
        DisplayName   = $displayName
        Version       = $foundVersion
        Publisher     = $publisher
        Description   = $description
        Homepage      = $homepage
        InstallerType = $installerType
        RawOutput     = $appInfo
    }
}

function Test-WingetterPrerequisites {
    [CmdletBinding()]
    param()

    $results = [ordered]@{}
    $allOk = $true

    try {
        $wingetVersion = winget --version 2>&1
        $results['Winget'] = @{ Ok = $true; Detail = $wingetVersion }
    }
    catch {
        $results['Winget'] = @{ Ok = $false; Detail = 'Winget is not installed or not in PATH.' }
        $allOk = $false
    }

    $intunewinCmd = Get-Command intunewinapputil -ErrorAction SilentlyContinue
    if ($intunewinCmd) {
        $results['ContentPrepTool'] = @{ Ok = $true; Detail = $intunewinCmd.Source }
    }
    else {
        $results['ContentPrepTool'] = @{ Ok = $false; Detail = 'intunewinapputil not found in PATH.' }
        $allOk = $false
    }

    return [PSCustomObject]@{
        AllOk   = $allOk
        Checks  = $results
    }
}
