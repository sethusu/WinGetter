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

function Test-WingetPackageAgreementsSupported {
  param([ValidateSet('search', 'show', 'download')][string]$Command = 'search')

  $helpOutput = & winget $Command --help 2>&1 | Out-String
  return ($helpOutput -match 'accept-package-agreements')
}

function Invoke-WingetCli {
    param(
        [ValidateSet('search', 'show', 'download')]
        [string]$Command,
        [string[]]$Arguments = @()
    )

    $supportsAgreements = Test-WingetPackageAgreementsSupported -Command $Command
    $wingetArguments = [System.Collections.Generic.List[string]]::new()
    $wingetArguments.AddRange($Arguments)

    $wingetArguments.Add('--accept-source-agreements')
    if ($supportsAgreements) {
        $wingetArguments.Add('--accept-package-agreements')
    }

    $output = & winget $Command @wingetArguments 2>&1
    return @{
        Output = $output
        ExitCode = $LASTEXITCODE
        SupportsPackageAgreements = $supportsAgreements
    }
}
