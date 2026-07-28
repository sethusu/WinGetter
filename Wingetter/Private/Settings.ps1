function Get-WingetterSettings {
    $settingsPath = Join-Path $env:APPDATA 'Wingetter\settings.json'
    $defaults = @{
        OutputPath = Join-Path $env:USERPROFILE 'Documents\Wingetter Output'
        LastSearch = ''
        LastPackageId = ''
    }

    if (Test-Path $settingsPath) {
        try {
            $saved = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
            foreach ($key in $defaults.Keys) {
                if ($saved.PSObject.Properties.Name -contains $key -and $saved.$key) {
                    $defaults[$key] = $saved.$key
                }
            }
        } catch {
            Write-Warning "Could not read settings file. Using defaults."
        }
    }

    return [PSCustomObject]$defaults
}

function Save-WingetterSettings {
    param(
        [string]$OutputPath,
        [string]$LastSearch,
        [string]$LastPackageId
    )

    $settingsDir = Join-Path $env:APPDATA 'Wingetter'
    if (-not (Test-Path $settingsDir)) {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    }

    $settingsPath = Join-Path $settingsDir 'settings.json'
    $current = Get-WingetterSettings

    if ($PSBoundParameters.ContainsKey('OutputPath') -and $OutputPath) {
        $current.OutputPath = $OutputPath
    }
    if ($PSBoundParameters.ContainsKey('LastSearch') -and $LastSearch) {
        $current.LastSearch = $LastSearch
    }
    if ($PSBoundParameters.ContainsKey('LastPackageId') -and $LastPackageId) {
        $current.LastPackageId = $LastPackageId
    }

    $current | ConvertTo-Json | Set-Content -Path $settingsPath -Encoding UTF8
}

function Test-WingetterPrerequisites {
    $results = [ordered]@{
        WingetInstalled = $false
        WingetVersion = ''
        ContentPrepToolInstalled = $false
        ContentPrepToolPath = ''
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        Issues = @()
    }

    try {
        $wingetVersion = winget --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $results.WingetInstalled = $true
            $results.WingetVersion = ($wingetVersion | Out-String).Trim()
        } else {
            $results.Issues += 'Winget is not installed or not available on PATH.'
        }
    } catch {
        $results.Issues += "Winget check failed: $_"
    }

    $intunewinCmd = Get-Command intunewinapputil -ErrorAction SilentlyContinue
    if ($intunewinCmd) {
        $results.ContentPrepToolInstalled = $true
        $results.ContentPrepToolPath = $intunewinCmd.Source
    } else {
        $results.Issues += 'Microsoft Win32 Content Prep Tool (intunewinapputil) was not found on PATH.'
    }

    return [PSCustomObject]$results
}

$script:WingetExePath = $null
$script:WingetAgreementSupport = @{}
$script:WingetCountSupported = $null

function Get-WingetExecutable {
    if ($script:WingetExePath -and (Test-Path -LiteralPath $script:WingetExePath)) {
        return $script:WingetExePath
    }

    $candidates = [System.Collections.Generic.List[string]]::new()

    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) {
        if ($cmd.Source) { $candidates.Add([string]$cmd.Source) }
        if ($cmd.Path) { $candidates.Add([string]$cmd.Path) }
    }

    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'))

    try {
        $appx = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending |
            Select-Object -First 1
        if ($appx -and $appx.InstallLocation) {
            $candidates.Add((Join-Path $appx.InstallLocation 'winget.exe'))
        }
    } catch {
        Write-Verbose "Get-AppxPackage for DesktopAppInstaller failed: $_"
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $script:WingetExePath = $candidate
            return $script:WingetExePath
        }
    }

    # Fall back to PATH resolution; App Execution Aliases may still work interactively
    $script:WingetExePath = 'winget'
    return $script:WingetExePath
}

function Test-WingetPackageAgreementsSupported {
    param([ValidateSet('search', 'show', 'download', 'source')][string]$Command = 'search')

    if ($Command -eq 'source') {
        return $false
    }

    if ($script:WingetAgreementSupport.ContainsKey($Command)) {
        return [bool]$script:WingetAgreementSupport[$Command]
    }

    try {
        $wingetExe = Get-WingetExecutable
        $helpOutput = & $wingetExe $Command --help 2>&1 | Out-String
        # Strip UTF-16 null padding that appears when winget output is redirected
        $helpOutput = $helpOutput -replace "`0", ''
        $supported = $helpOutput -match 'accept-package-agreements'
        $script:WingetAgreementSupport[$Command] = $supported
        return $supported
    } catch {
        $script:WingetAgreementSupport[$Command] = $false
        return $false
    }
}

function Test-WingetSearchCountSupported {
    if ($null -ne $script:WingetCountSupported) {
        return [bool]$script:WingetCountSupported
    }

    try {
        $wingetExe = Get-WingetExecutable
        $helpOutput = & $wingetExe search --help 2>&1 | Out-String
        $helpOutput = $helpOutput -replace "`0", ''
        $script:WingetCountSupported = [bool]($helpOutput -match '(?i)(--count|-n,\s*--count)')
    } catch {
        $script:WingetCountSupported = $false
    }

    return [bool]$script:WingetCountSupported
}

function Invoke-WingetCli {
    param(
        [ValidateSet('search', 'show', 'download', 'source')]
        [string]$Command,
        [string[]]$Arguments = @()
    )

    $wingetExe = Get-WingetExecutable
    $supportsAgreements = Test-WingetPackageAgreementsSupported -Command $Command
    $wingetArguments = [System.Collections.Generic.List[string]]::new()
    if ($Arguments) {
        $wingetArguments.AddRange([string[]]$Arguments)
    }

    if ($Command -ne 'source') {
        if ($wingetArguments -notcontains '--accept-source-agreements') {
            $wingetArguments.Add('--accept-source-agreements')
        }
        if ($supportsAgreements -and ($wingetArguments -notcontains '--accept-package-agreements')) {
            $wingetArguments.Add('--accept-package-agreements')
        }
        if ($wingetArguments -notcontains '--disable-interactivity') {
            $wingetArguments.Add('--disable-interactivity')
        }
    }

    $previousOutputEncoding = [Console]::OutputEncoding
    $previousPreference = $OutputEncoding
    try {
        # winget often emits UTF-8; without this, redirected output becomes NUL-padded garbage
        # and table parsers return zero results (classic "VLC not found" failure mode).
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8

        $output = & $wingetExe $Command @wingetArguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $previousOutputEncoding
        $OutputEncoding = $previousPreference
    }

    return @{
        Output = $output
        ExitCode = $exitCode
        SupportsPackageAgreements = $supportsAgreements
        Executable = $wingetExe
    }
}
