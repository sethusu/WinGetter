function Get-WingetterDefaultBaseOutputPath {
    # Default base is a folder named after the app (Wingetter), not a generic "Output" suffix.
    $homeDir = if ($env:USERPROFILE) {
        $env:USERPROFILE
    } elseif ($env:HOME) {
        $env:HOME
    } else {
        [Environment]::GetFolderPath('UserProfile')
    }
    if (-not $homeDir) {
        $homeDir = [System.IO.Path]::GetTempPath()
    }
    return (Join-Path $homeDir 'Documents\Wingetter')
}

function Get-WingetterBaseOutputPath {
    param(
        [string]$Path,
        [string]$PackageId
    )

    if (-not $Path) {
        return Get-WingetterDefaultBaseOutputPath
    }

    if ($PackageId -and ((Split-Path -Path $Path -Leaf) -eq $PackageId)) {
        $parent = Split-Path -Path $Path -Parent
        if ($parent) {
            return $parent
        }
    }

    return $Path
}

function Get-WingetterAppOutputPath {
    param(
        [string]$BasePath,
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    $base = if ($BasePath) { $BasePath } else { Get-WingetterDefaultBaseOutputPath }
    # If the caller already passed the app-named folder, keep it.
    if ((Split-Path -Path $base -Leaf) -eq $PackageId) {
        return $base
    }

    return (Join-Path $base $PackageId)
}

function Get-WingetterSettings {
    $settingsPath = Join-Path $env:APPDATA 'Wingetter\settings.json'
    $defaults = @{
        OutputPath = Get-WingetterDefaultBaseOutputPath
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

    # Migrate the old portable default so existing installs land under Documents\Wingetter\{App}.
    $legacyDefault = Join-Path (Split-Path (Get-WingetterDefaultBaseOutputPath) -Parent) 'Wingetter Output'
    if ($defaults.OutputPath -eq $legacyDefault) {
        $defaults.OutputPath = Get-WingetterDefaultBaseOutputPath
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
        # Persist the base folder; per-app paths are derived as {base}\{PackageId}.
        $current.OutputPath = Get-WingetterBaseOutputPath -Path $OutputPath -PackageId $LastPackageId
    }
    if ($PSBoundParameters.ContainsKey('LastSearch') -and $LastSearch) {
        $current.LastSearch = $LastSearch
    }
    if ($PSBoundParameters.ContainsKey('LastPackageId') -and $LastPackageId) {
        $current.LastPackageId = $LastPackageId
    }

    $current | ConvertTo-Json | Set-Content -Path $settingsPath -Encoding UTF8
}

function Update-WingetterSessionPath {
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($machinePath, $userPath) | Where-Object { $_ }
    if ($parts.Count -gt 0) {
        $env:Path = ($parts -join ';')
    }
}

function Resolve-ContentPrepToolPath {
    Update-WingetterSessionPath

    $commandNames = @('intunewinapputil', 'IntuneWinAppUtil')
    foreach ($name in $commandNames) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) {
            return [string]$cmd.Source
        }
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\IntuneWinAppUtil.exe'))
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\intunewinapputil.exe'))

    $programFilesX86 = ${env:ProgramFiles(x86)}
    if ($programFilesX86) {
        $candidates.Add((Join-Path $programFilesX86 'Microsoft Win32 Content Prep Tool\IntuneWinAppUtil.exe'))
    }
    if ($env:ProgramFiles) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Microsoft Win32 Content Prep Tool\IntuneWinAppUtil.exe'))
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return $null
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
        $wingetExe = Get-WingetExecutable
        $wingetVersion = & $wingetExe --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $results.WingetInstalled = $true
            $results.WingetVersion = ($wingetVersion | Out-String).Trim() -replace "`0", ''
        } else {
            $results.Issues += 'Winget is not installed or not available on PATH.'
        }
    } catch {
        $results.Issues += "Winget check failed: $_"
    }

    $contentPrepPath = Resolve-ContentPrepToolPath
    if ($contentPrepPath) {
        $results.ContentPrepToolInstalled = $true
        $results.ContentPrepToolPath = $contentPrepPath
    } else {
        $results.Issues += 'Microsoft Win32 Content Prep Tool (intunewinapputil) was not found on PATH.'
    }

    return [PSCustomObject]$results
}

function Install-WingetterContentPrepTool {
    <#
    .SYNOPSIS
        Installs the Microsoft Win32 Content Prep Tool via winget.
    .DESCRIPTION
        Runs `winget install --exact --id Microsoft.Win32ContentPrepTool` non-interactively,
        refreshes the session PATH, and re-checks whether intunewinapputil is available.
    .PARAMETER PackageId
        Winget package ID. Defaults to Microsoft.Win32ContentPrepTool.
    .PARAMETER Force
        Pass --force to winget install.
    .EXAMPLE
        Install-WingetterContentPrepTool
    #>
    [CmdletBinding()]
    param(
        [string]$PackageId = 'Microsoft.Win32ContentPrepTool',
        [switch]$Force
    )

    $alreadyPresent = Resolve-ContentPrepToolPath
    if ($alreadyPresent -and -not $Force) {
        return [PSCustomObject]@{
            Succeeded = $true
            AlreadyInstalled = $true
            ExitCode = 0
            PackageId = $PackageId
            ContentPrepToolPath = $alreadyPresent
            Output = "Content Prep Tool is already available at $alreadyPresent"
            Prerequisites = Test-WingetterPrerequisites
        }
    }

    $wingetExe = $null
    try {
        $wingetExe = Get-WingetExecutable
        $null = & $wingetExe --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw 'Winget returned a non-zero exit code.'
        }
    } catch {
        throw "Winget is required to install the Content Prep Tool. $_"
    }

    $wingetArguments = [System.Collections.Generic.List[string]]::new()
    $wingetArguments.AddRange([string[]]@(
        'install'
        '--exact'
        '--id'
        $PackageId
        '--accept-source-agreements'
        '--accept-package-agreements'
        '--disable-interactivity'
    ))
    if ($Force) {
        $wingetArguments.Add('--force')
    }

    $previousOutputEncoding = [Console]::OutputEncoding
    $previousPreference = $OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
        $output = & $wingetExe @wingetArguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $previousOutputEncoding
        $OutputEncoding = $previousPreference
    }

    $outputText = (($output | Out-String) -replace "`0", '').Trim()
    # 0 = success; -1978335189 / 0x8A15002B = no applicable upgrade / already installed
    $alreadyInstalledExit = -1978335189
    $succeeded = ($exitCode -eq 0 -or $exitCode -eq $alreadyInstalledExit)

    Update-WingetterSessionPath
    $contentPrepPath = Resolve-ContentPrepToolPath
    if ($contentPrepPath) {
        $succeeded = $true
    }

    $prereqs = Test-WingetterPrerequisites
    if (-not $succeeded) {
        $message = if ($outputText) { $outputText } else { "winget install failed with exit code $exitCode" }
        throw "Failed to install Content Prep Tool ($PackageId). $message"
    }

    return [PSCustomObject]@{
        Succeeded = $true
        AlreadyInstalled = ($exitCode -eq $alreadyInstalledExit -or [bool]$alreadyPresent)
        ExitCode = $exitCode
        PackageId = $PackageId
        ContentPrepToolPath = $contentPrepPath
        Output = $outputText
        Prerequisites = $prereqs
    }
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
