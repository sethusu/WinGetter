<#
.SYNOPSIS
    Creates an IntuneWin package from a Winget application with registry-based detection.
.DESCRIPTION
    This script automates the process of:
    1. Searching Winget for an application
    2. Downloading the installer with proper filename
    3. Creating registry-based detection script
    4. Creating uninstall script
    5. Packaging with Content Prep Tool (intunewinapputil)
    6. Updating all metadata files
.PARAMETER AppName
    The name or ID of the application to search for in Winget (e.g., "MaximaTeam.Maxima" or "maxima")
.PARAMETER Version
    Optional. Specific version to download. If not specified, latest version will be used.
.PARAMETER OutputPath
    Optional. Base output path. Defaults to "D:\Intoon In Progress"
.PARAMETER IconPath
    Optional. Path to icon file. If not provided, will attempt to use logo.png from parent directory.
.EXAMPLE
    .\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima"
.EXAMPLE
    .\Create-IntuneWinFromWinget.ps1 -AppName "maxima" -Version "5.47.0"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$AppName,
    
    [Parameter(Mandatory=$false)]
    [string]$Version,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "D:\Intoon In Progress",
    
    [Parameter(Mandatory=$false)]
    [string]$IconPath
)

# Error handling
$ErrorActionPreference = "Stop"

# Diagnostic logging
$script:DiagnosticLogDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "Wingetter"
$script:DiagnosticLogPath = Join-Path $script:DiagnosticLogDirectory ("wingetter-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$script:SearchOutputPath = Join-Path $script:DiagnosticLogDirectory ("winget-search-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

function Initialize-DiagnosticLogging {
    try {
        if (-not (Test-Path $script:DiagnosticLogDirectory)) {
            New-Item -ItemType Directory -Path $script:DiagnosticLogDirectory -Force | Out-Null
        }

        $header = @(
            "Wingetter diagnostic log"
            "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "Computer: $env:COMPUTERNAME"
            "User: $env:USERNAME"
            "Script: $PSCommandPath"
            "AppName parameter: $AppName"
            "Version parameter: $Version"
            "OutputPath parameter: $OutputPath"
            "----------------------------------------"
        )
        $header | Set-Content -Path $script:DiagnosticLogPath -Encoding UTF8
    } catch {
        # Do not block packaging if logging setup fails.
    }
}

function Write-DiagnosticLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        Add-Content -Path $script:DiagnosticLogPath -Value "[$timestamp] [$Level] $Message"
    } catch {
        # Best effort only.
    }
}

function Save-SearchOutputDiagnostics {
    param(
        [Parameter(Mandatory=$true)]
        $SearchOutput
    )

    try {
        $lines = if ($SearchOutput -is [string]) {
            $SearchOutput -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
        } else {
            @($SearchOutput)
        }

        $diagnosticLines = @()
        $diagnosticLines += "Winget raw search output snapshot"
        $diagnosticLines += "Captured: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $diagnosticLines += "Line count: $($lines.Count)"
        $diagnosticLines += "----------------------------------------"

        for ($idx = 0; $idx -lt $lines.Count; $idx++) {
            $line = [string]$lines[$idx]
            $lineWithTabsVisible = $line -replace "`t", "<TAB>"
            $diagnosticLines += ("{0:D4}: {1}" -f ($idx + 1), $lineWithTabsVisible)
        }

        $diagnosticLines | Set-Content -Path $script:SearchOutputPath -Encoding UTF8
        Write-DiagnosticLog "Saved raw winget search output to $script:SearchOutputPath"
    } catch {
        Write-DiagnosticLog "Failed to save winget raw output snapshot: $($_.Exception.Message)" "WARN"
    }
}

Initialize-DiagnosticLogging
Write-DiagnosticLog "Diagnostic logging initialized. Log file: $script:DiagnosticLogPath"

# Function to show input dialog for Winget ID
function Get-WingetIdFromDialog {
    # Add VisualBasic assembly for InputBox
    Add-Type -AssemblyName Microsoft.VisualBasic
    
    $title = "Wingetter - Enter Winget Package ID"
    $prompt = "Enter the Winget Package ID or application name:`n`nExamples:`n  - JetBrains.WebStorm`n  - Google.Chrome`n  - MaximaTeam.Maxima`n  - webstorm`n`nYou can use the full package ID or search term."
    $defaultValue = ""
    
    $result = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, $title, $defaultValue)
    
    if ([string]::IsNullOrWhiteSpace($result)) {
        Write-Host "No Winget ID provided. Exiting." -ForegroundColor Red
        exit 1
    }
    
    return $result.Trim()
}

function Normalize-WingetPackageId {
    param([string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return ""
    }

    # Winget output can render IDs with whitespace around dots (for example: "Valve. Steam").
    $normalizedId = $Id.Trim()
    $normalizedId = $normalizedId -replace '\s*\.\s*', '.'
    $normalizedId = $normalizedId -replace '\s+', ''
    return $normalizedId
}

# Function to parse winget search results and show selection dialog
function Select-WingetPackage {
    param(
        [Parameter(Mandatory=$true)]
        $SearchOutput
    )
    
    Write-DiagnosticLog "Select-WingetPackage started. Raw SearchOutput type: $($SearchOutput.GetType().FullName)"

    # Convert to array if it's a string
    if ($SearchOutput -is [string]) {
        $SearchOutput = $SearchOutput -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
    } elseif ($SearchOutput -isnot [array]) {
        $SearchOutput = @($SearchOutput)
    }

    Write-DiagnosticLog "Select-WingetPackage received $($SearchOutput.Count) search output lines"

    function Add-PackageIfValid {
        param(
            [string]$Name,
            [string]$Id,
            [string]$Version,
            [ref]$PackageList
        )

        $nameValue = if ($Name) { $Name.Trim() } else { "" }
        $idValue = Normalize-WingetPackageId -Id $Id
        $versionValue = if ($Version) { $Version.Trim() } else { "" }

        if ($nameValue.Length -eq 0) {
            Write-DiagnosticLog "Rejected package row due to empty name. Raw values: Name='$Name' Id='$Id' Version='$Version'" "DEBUG"
            return $false
        }

        if ($idValue.Length -le 2 -or $idValue -notmatch '\.') {
            Write-DiagnosticLog "Rejected package row due to invalid package ID after normalization ('$idValue'). Raw values: Name='$Name' Id='$Id' Version='$Version'" "DEBUG"
            return $false
        }

        if ($versionValue.Length -eq 0 -or $versionValue -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]*$') {
            Write-DiagnosticLog "Rejected package row due to invalid version ('$versionValue'). Raw values: Name='$Name' Id='$Id' Version='$Version'" "DEBUG"
            return $false
        }

        $alreadyExists = $PackageList.Value | Where-Object { $_.Id -eq $idValue -and $_.Version -eq $versionValue }
        if (-not $alreadyExists) {
            $PackageList.Value += [PSCustomObject]@{
                Name = $nameValue
                Id = $idValue
                Version = $versionValue
            }
            Write-DiagnosticLog "Accepted package candidate: Name='$nameValue' Id='$idValue' Version='$versionValue'" "DEBUG"
        } else {
            Write-DiagnosticLog "Skipped duplicate package candidate: Name='$nameValue' Id='$idValue' Version='$versionValue'" "DEBUG"
        }

        return $true
    }
    
    # Parse the search results
    $packages = @()
    $inTable = $false
    $headerLineIndex = -1
    
    # Find the header line
    for ($i = 0; $i -lt $SearchOutput.Count; $i++) {
        if ($SearchOutput[$i] -match "Name\s+Id\s+Version") {
            $headerLineIndex = $i
            $inTable = $true
            break
        }
    }
    
    if ($headerLineIndex -eq -1) {
        Write-DiagnosticLog "Did not find standard table header 'Name Id Version'. Trying fallback parsers."

        # Try alternative header format
        for ($i = 0; $i -lt $SearchOutput.Count; $i++) {
            if ($SearchOutput[$i] -match "Found.*\[") {
                # Single result format: "Found PackageName [PackageId]"
                $line = $SearchOutput[$i]
                if ($line -match "Found\s+(.+?)\s+\[(.+?)\]") {
                    $name = $matches[1].Trim()
                    $id = Normalize-WingetPackageId -Id $matches[2].Trim()
                    # Try to find version in subsequent lines
                    $version = "Unknown"
                    for ($j = $i + 1; $j -lt [Math]::Min($i + 10, $SearchOutput.Count); $j++) {
                        if ($SearchOutput[$j] -match "Version:\s+(.+)") {
                            $version = $matches[1].Trim()
                            break
                        }
                    }
                    if ($id.Length -gt 2 -and $id -match '\.') {
                        $packages += [PSCustomObject]@{
                            Name = $name
                            Id = $id
                            Version = $version
                        }
                        Write-DiagnosticLog "Parsed single-result format successfully: Name='$name' Id='$id' Version='$version'"
                        return $packages[0]
                    }
                }
            }
        }
    }
    
    # Use header positions as fixed-width column boundaries when possible.
    $headerLine = if ($headerLineIndex -ge 0) { $SearchOutput[$headerLineIndex] } else { "" }
    $idColumnStart = if ($headerLineIndex -ge 0) { $headerLine.IndexOf("Id") } else { -1 }
    $versionColumnStart = if ($headerLineIndex -ge 0) { $headerLine.IndexOf("Version") } else { -1 }
    $sourceColumnStart = if ($headerLineIndex -ge 0) { $headerLine.IndexOf("Source") } else { -1 }
    $canUseFixedColumns = $idColumnStart -gt 0 -and $versionColumnStart -gt $idColumnStart
    $parseStartIndex = if ($headerLineIndex -ge 0) { $headerLineIndex + 1 } else { 0 }

    Write-DiagnosticLog "Parser configuration: headerLineIndex=$headerLineIndex parseStartIndex=$parseStartIndex canUseFixedColumns=$canUseFixedColumns idColumnStart=$idColumnStart versionColumnStart=$versionColumnStart sourceColumnStart=$sourceColumnStart"

    # Parse table rows starting after the header
    $skipNextLine = $false
    for ($i = $parseStartIndex; $i -lt $SearchOutput.Count; $i++) {
        $line = $SearchOutput[$i]
        
        # Skip separator lines (dashes) - these come right after the header
        if ($line -match "^-+$") {
            $skipNextLine = $false
            continue
        }
        
        # Skip empty lines at the start
        if ($line.Trim() -eq "" -and $packages.Count -eq 0) {
            continue
        }
        
        # If we hit an empty line after finding packages, we might be done
        if ($line.Trim() -eq "" -and $packages.Count -gt 0) {
            # Check if there are more non-empty lines after this
            $moreData = $false
            for ($j = $i + 1; $j -lt [Math]::Min($i + 3, $SearchOutput.Count); $j++) {
                if ($SearchOutput[$j].Trim() -ne "" -and $SearchOutput[$j] -notmatch "^-+$" -and $SearchOutput[$j] -notmatch "█|▒|KB|MB|%") {
                    $moreData = $true
                    break
                }
            }
            if (-not $moreData) {
                break
            }
        }
        
        # Skip lines that look like progress bars or other non-data lines
        if ($line -match "█|▒|KB|MB|%" -or ($line.Length -lt 10 -and $line.Trim() -ne "")) {
            continue
        }
        
        # Skip lines that are just dashes or special characters
        if ($line -match "^-+$" -or $line -match "^[-\s\|\\/]+$") {
            continue
        }
        
        # Strategy 1: Parse using fixed-width column positions from the header line.
        if ($canUseFixedColumns -and $line.Length -gt $versionColumnStart) {
            $nameValue = $line.Substring(0, [Math]::Min($idColumnStart, $line.Length)).Trim()

            $idLength = [Math]::Min($line.Length, $versionColumnStart) - $idColumnStart
            $idValue = if ($idLength -gt 0) {
                $line.Substring($idColumnStart, $idLength).Trim()
            } else {
                ""
            }

            $versionEnd = if ($sourceColumnStart -gt $versionColumnStart) {
                [Math]::Min($line.Length, $sourceColumnStart)
            } else {
                $line.Length
            }
            $versionLength = $versionEnd - $versionColumnStart
            $versionValue = if ($versionLength -gt 0) {
                $line.Substring($versionColumnStart, $versionLength).Trim()
            } else {
                ""
            }

            if (Add-PackageIfValid -Name $nameValue -Id $idValue -Version $versionValue -PackageList ([ref]$packages)) {
                Write-DiagnosticLog "Line $($i + 1) parsed by fixed-column strategy."
                continue
            }
        }

        # Strategy 2: regex split with support for tabs and IDs containing rendered whitespace.
        if ($line -match "^\s*(.+?)(?:\s{2,}|\t+)([A-Za-z0-9][A-Za-z0-9.\-\s]*[A-Za-z0-9])(?:\s{2,}|\t+)([0-9][0-9A-Za-z._-]*[0-9A-Za-z]|[0-9]+)") {
            if (Add-PackageIfValid -Name $matches[1] -Id $matches[2] -Version $matches[3] -PackageList ([ref]$packages)) {
                Write-DiagnosticLog "Line $($i + 1) parsed by regex strategy."
                continue
            }
        }

        # Strategy 3: generic token fallback for tab- or space-delimited output.
        $parts = $line -split '(?:\s{2,}|\t+)', [System.StringSplitOptions]::RemoveEmptyEntries
        if ($parts.Count -ge 3) {
            if (Add-PackageIfValid -Name $parts[0] -Id $parts[1] -Version $parts[2] -PackageList ([ref]$packages)) {
                Write-DiagnosticLog "Line $($i + 1) parsed by token fallback strategy."
            } else {
                Write-DiagnosticLog "Line $($i + 1) was tokenized but rejected. Tokens: $($parts -join ' | ')" "DEBUG"
            }
        }

        # Strategy 4: whitespace-token heuristic for rows that collapse to single spaces
        # or have IDs split like "Valve. Steam".
        $rawTokens = $line.Trim() -split '\s+'
        if ($rawTokens.Count -ge 3) {
            for ($tokenIndex = 1; $tokenIndex -lt $rawTokens.Count - 1; $tokenIndex++) {
                $idTokenCandidate = $rawTokens[$tokenIndex]
                $idTokenLength = 1

                # Rejoin split IDs rendered as "Valve." + "Steam"
                if ($idTokenCandidate.EndsWith(".") -and $tokenIndex + 1 -lt $rawTokens.Count) {
                    $idTokenCandidate = "$idTokenCandidate$($rawTokens[$tokenIndex + 1])"
                    $idTokenLength = 2
                }

                $versionTokenIndex = $tokenIndex + $idTokenLength
                if ($versionTokenIndex -ge $rawTokens.Count) {
                    continue
                }

                $versionTokenCandidate = $rawTokens[$versionTokenIndex]
                if ($versionTokenCandidate -notmatch '^[0-9][0-9A-Za-z._-]*$') {
                    continue
                }

                $nameTokenCount = $tokenIndex
                if ($nameTokenCount -le 0) {
                    continue
                }

                $nameTokenCandidate = ($rawTokens[0..($nameTokenCount - 1)] -join ' ')
                if (Add-PackageIfValid -Name $nameTokenCandidate -Id $idTokenCandidate -Version $versionTokenCandidate -PackageList ([ref]$packages)) {
                    Write-DiagnosticLog "Line $($i + 1) parsed by whitespace-token heuristic strategy (tokenIndex=$tokenIndex idTokenLength=$idTokenLength)."
                    break
                }
            }
        }
    }
    
    # If no packages found, return null
    if ($packages.Count -eq 0) {
        Write-DiagnosticLog "No packages parsed from search output. Refer to raw output snapshot at $script:SearchOutputPath" "WARN"
        return $null
    }

    Write-DiagnosticLog "Parsed $($packages.Count) package candidates."
    
    # If only one package, return it
    if ($packages.Count -eq 1) {
        Write-Host "`nFound 1 matching package:" -ForegroundColor Green
        Write-Host "  1. $($packages[0].Name) ($($packages[0].Id)) - Version: $($packages[0].Version)" -ForegroundColor Cyan
        Write-DiagnosticLog "Only one package candidate remained after parsing."
        return $packages[0]
    }
    
    # Display numbered list
    Write-Host "`nFound $($packages.Count) matching packages:" -ForegroundColor Green
    for ($i = 0; $i -lt $packages.Count; $i++) {
        $num = $i + 1
        Write-Host "  $num. $($packages[$i].Name) ($($packages[$i].Id)) - Version: $($packages[$i].Version)" -ForegroundColor Cyan
    }
    
    # Create selection dialog
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
    Write-DiagnosticLog "User selected package index $parsedNumber: $($selectedPackage.Id)"
    
    return $selectedPackage
}

# Prompt for AppName if not provided
if ([string]::IsNullOrWhiteSpace($AppName)) {
    Write-Host "Winget Package ID not provided. Opening input dialog..." -ForegroundColor Cyan
    Write-DiagnosticLog "AppName was not provided. Prompting user with input dialog."
    $AppName = Get-WingetIdFromDialog
    Write-Host "Using Winget ID: $AppName" -ForegroundColor Green
    Write-DiagnosticLog "User provided AppName from dialog: $AppName"
}

# Function to write colored output
function Write-Step {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host "`n[$Message]" -ForegroundColor $Color
    Write-DiagnosticLog "STEP: $Message"
}

function Write-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
    Write-DiagnosticLog "SUCCESS: $Message"
}

function Write-Error {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    Write-DiagnosticLog "ERROR: $Message" "ERROR"
}

# Function to extract icon from executable
function Extract-IconFromExe {
    param(
        [string]$ExePath,
        [string]$OutputPath
    )
    
    try {
        # Try using .NET to extract icon
        Add-Type -TypeDefinition @"
        using System;
        using System.Drawing;
        using System.Drawing.Imaging;
        using System.Runtime.InteropServices;
        public class IconExtractor {
            [DllImport("shell32.dll", CharSet = CharSet.Auto)]
            public static extern IntPtr ExtractIcon(IntPtr hInst, string lpszExeFileName, int nIconIndex);
            [DllImport("user32.dll")]
            public static extern bool DestroyIcon(IntPtr hIcon);
            
            public static bool ExtractToPng(string exePath, string outputPath) {
                try {
                    IntPtr hIcon = ExtractIcon(IntPtr.Zero, exePath, 0);
                    if (hIcon != IntPtr.Zero) {
                        Icon icon = Icon.FromHandle(hIcon);
                        using (Bitmap bmp = icon.ToBitmap()) {
                            bmp.Save(outputPath, ImageFormat.Png);
                        }
                        DestroyIcon(hIcon);
                        return true;
                    }
                } catch { }
                return false;
            }
        }
"@ -ErrorAction SilentlyContinue
        
        if ([IconExtractor]::ExtractToPng($ExePath, $OutputPath)) {
            if (Test-Path $OutputPath -and (Get-Item $OutputPath).Length -gt 0) {
                Write-Host "Extracted icon from installer executable" -ForegroundColor Green
                return $true
            }
        }
    } catch {
        # Icon extraction failed, continue
    }
    
    return $false
}

# Function to try downloading logo automatically
function Get-LogoFromWeb {
    param(
        [string]$PackageId,
        [string]$DisplayName,
        [string]$Publisher,
        [string]$Homepage,
        [string]$OutputPath,
        [string]$InstallerPath = $null
    )
    
    $urls = @()
    
    # Try JetBrains products
    if ($PackageId -like "JetBrains.*" -or $Publisher -like "*JetBrains*") {
        $productName = $PackageId -replace "JetBrains\.", ""
        $urls += @(
            "https://resources.jetbrains.com/storage/products/$($productName.ToLower())/img/meta/$($productName.ToLower())_logo_300x300.png",
            "https://www.jetbrains.com/$($productName.ToLower())/img/$($productName.ToLower())_logo_300x300.png",
            "https://resources.jetbrains.com/storage/products/$($productName.ToLower())/img/meta/$($productName.ToLower())_icon_256x256.png"
        )
    }
    
    # Extract GitHub org/repo from homepage if it's a GitHub URL
    $githubOrg = $null
    $githubRepo = $null
    if ($Homepage -match "github\.com/([^/]+)/([^/]+)") {
        $githubOrg = $matches[1]
        $githubRepo = $matches[2] -replace '/.*$', ''  # Remove any trailing path
    }
    
    # Try GitHub-based projects with multiple patterns
    if ($PackageId -like "*.*" -or $Homepage -like "*github.com*" -or $Publisher -like "*GitHub*" -or $Publisher -like "*Contributors*") {
        $parts = $PackageId -split '\.'
        $projectName = if ($parts.Count -gt 1) { $parts[-1] } else { $PackageId }
        $orgName = if ($parts.Count -gt 1) { $parts[0] } else { $projectName }
        
        # Use GitHub org/repo from homepage if available, otherwise use package ID parts
        if ($githubOrg -and $githubRepo) {
            $orgName = $githubOrg
            $projectName = $githubRepo
        }
        
        # Try extensive GitHub logo locations
        $branches = @("main", "master", "develop", "dev")
        $paths = @("logo.png", "logo.svg", "icon.png", "icon.svg", "favicon.png", "assets/logo.png", "assets/icon.png", 
                   "img/logo.png", "img/icon.png", "images/logo.png", "images/icon.png", 
                   "src/logo.png", "src/icon.png", "resources/logo.png", "resources/icon.png",
                   "$projectName.png", "$projectName.svg", "$($projectName.ToLower()).png", "$($projectName.ToLower()).svg",
                   "docs/logo.png", "docs/icon.png", "doc/logo.png", "doc/icon.png",
                   "media/logo.png", "media/icon.png", "static/logo.png", "static/icon.png",
                   "public/logo.png", "public/icon.png", "www/logo.png", "www/icon.png")
        
        foreach ($branch in $branches) {
            foreach ($path in $paths) {
                $urls += "https://raw.githubusercontent.com/$orgName/$projectName/$branch/$path"
            }
        }
        
        # Try GitHub releases/assets
        $urls += @(
            "https://github.com/$orgName/$projectName/raw/main/logo.png",
            "https://github.com/$orgName/$projectName/raw/master/logo.png",
            "https://github.com/$orgName/$projectName/blob/main/logo.png?raw=true",
            "https://github.com/$orgName/$projectName/blob/master/logo.png?raw=true"
        )
    }
    
    # Try extracting from homepage URL with extensive patterns
    if ($Homepage -and $Homepage -notlike "*github.com*") {
        $homepageBase = $Homepage.TrimEnd('/')
        $homepagePaths = @("logo.png", "logo.svg", "icon.png", "icon.svg", "favicon.png", "favicon.ico",
                          "images/logo.png", "images/icon.png", "img/logo.png", "img/icon.png",
                          "static/images/logo.png", "static/img/logo.png", "static/logo.png",
                          "assets/logo.png", "assets/icon.png", "assets/images/logo.png",
                          "media/logo.png", "media/icon.png", "resources/logo.png",
                          "www/logo.png", "www/images/logo.png", "public/logo.png",
                          "app/logo.png", "src/logo.png", "dist/logo.png")
        
        foreach ($path in $homepagePaths) {
            $urls += "$homepageBase/$path"
        }
    }
    
    # Try common package name patterns with variations
    $cleanName = $DisplayName -replace '\s+', '' -replace '[^a-zA-Z0-9]', ''
    $lowerName = $cleanName.ToLower()
    if ($cleanName) {
        $nameWithDashes = $DisplayName -replace '\s+', '-'
        $nameWithUnderscores = $DisplayName -replace '\s+', '_'
        $nameVariations = @($lowerName, $cleanName, $nameWithDashes, $nameWithUnderscores)
        foreach ($name in $nameVariations) {
            if ($name) {
                $urls += @(
                    "https://raw.githubusercontent.com/$name/$name/main/logo.png",
                    "https://raw.githubusercontent.com/$name/$name/master/logo.png",
                    "https://raw.githubusercontent.com/$name/$name/main/icon.png",
                    "https://raw.githubusercontent.com/$name/$name/master/icon.png"
                )
            }
        }
    }
    
    # Try winget manifest locations (if package is in winget-pkgs)
    if ($PackageId -like "*.*") {
        $parts = $PackageId -split '\.'
        $firstChar = $parts[0].Substring(0,1).ToLower()
        $urls += @(
            "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$firstChar/$($parts[0])/$($parts[1])/icon.png",
            "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$firstChar/$($parts[0])/$($parts[1])/logo.png"
        )
    }
    
    # Try common CDN/hosting patterns
    $cdnPatterns = @(
        "https://cdn.jsdelivr.net/gh/$orgName/$projectName@main/logo.png",
        "https://cdn.jsdelivr.net/gh/$orgName/$projectName@master/logo.png"
    )
    $urls += $cdnPatterns
    
    # Remove duplicates while preserving order
    $urls = $urls | Select-Object -Unique
    
    # Try all URLs (limit to first 50 to avoid too many attempts)
    $urlsToTry = $urls | Select-Object -First 50
    foreach ($url in $urlsToTry) {
        try {
            Write-Host "Trying to download logo from: $url" -ForegroundColor Cyan
            $response = Invoke-WebRequest -Uri $url -OutFile $OutputPath -ErrorAction Stop -TimeoutSec 8
            if (Test-Path $OutputPath) {
                $fileInfo = Get-Item $OutputPath
                # Check if it's actually an image (basic check - file size > 0)
                if ($fileInfo.Length -gt 0) {
                    # Verify it's a valid image by checking file header
                    $bytes = [System.IO.File]::ReadAllBytes($OutputPath)
                    $isImage = $false
                    if ($bytes.Length -gt 8) {
                        # PNG signature: 89 50 4E 47
                        if (($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47) -or
                            # JPEG signature: FF D8 FF
                            ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8 -and $bytes[2] -eq 0xFF) -or
                            # GIF signature: GIF
                            ($bytes[0] -eq 0x47 -and $bytes[1] -eq 0x49 -and $bytes[2] -eq 0x46)) {
                            $isImage = $true
                        }
                    }
                    
                    if ($isImage -or $OutputPath -like "*.svg") {
                        Write-Success "Downloaded logo from: $url"
                        return $true
                    } else {
                        # Not a valid image, remove it
                        Remove-Item $OutputPath -ErrorAction SilentlyContinue
                    }
                }
            }
        } catch {
            # Continue to next URL
            if (Test-Path $OutputPath) {
                Remove-Item $OutputPath -ErrorAction SilentlyContinue
            }
        }
    }
    
    # Last resort: Try to extract icon from installer if it's an EXE
    if ($InstallerPath -and (Test-Path $InstallerPath) -and $InstallerPath -like "*.exe") {
        Write-Host "Attempting to extract icon from installer executable..." -ForegroundColor Cyan
        if (Extract-IconFromExe -ExePath $InstallerPath -OutputPath $OutputPath) {
            return $true
        }
    }
    
    return $false
}

# Function to download with progress bar
function Start-WingetDownloadWithProgress {
    param(
        [string]$PackageId,
        [string]$DownloadDirectory,
        [string]$PackageName
    )
    
    Write-Host "Starting download..." -ForegroundColor Cyan
    
    # Check if --accept-package-agreements is supported
    $testCommand = winget download --help 2>&1 | Select-String -Pattern "accept-package-agreements" -Quiet
    $supportsPackageAgreements = $testCommand
    
    # Start winget download in background job
    # Use --accept-package-agreements if supported, otherwise just --accept-source-agreements
    $job = Start-Job -ScriptBlock {
        param($pkgId, $dir, $supportsPkgAgreements)
        if ($supportsPkgAgreements) {
            winget download $pkgId --exact --download-directory $dir --accept-source-agreements --accept-package-agreements 2>&1
        } else {
            winget download $pkgId --exact --download-directory $dir --accept-source-agreements 2>&1
        }
    } -ArgumentList $PackageId, $DownloadDirectory, $supportsPackageAgreements
    
    # Monitor download progress
    $previousSize = 0
    $previousTime = Get-Date
    $expectedSize = $null
    $downloadStarted = $false
    
    while ($job.State -eq "Running") {
        # Check for new or growing files in download directory
        $files = Get-ChildItem -Path $DownloadDirectory -File -ErrorAction SilentlyContinue | 
            Where-Object { 
                $_.Name -notlike "*intunewin*" -and 
                $_.Name -notlike "*ContentPrepTool*" -and 
                ($_.Extension -eq ".exe" -or $_.Extension -eq ".msi" -or $_.Extension -eq "")
            }
        
        # Try to get expected size from winget output (if available)
        $jobOutput = Receive-Job -Job $job -ErrorAction SilentlyContinue
        if ($jobOutput -and -not $expectedSize) {
            $sizeMatch = $jobOutput | Select-String -Pattern "(\d+\.?\d*)\s*(MB|GB|KB)" | Select-Object -First 1
            if ($sizeMatch) {
                $sizeValue = [double]($sizeMatch.Matches.Groups[1].Value)
                $sizeUnit = $sizeMatch.Matches.Groups[2].Value
                switch ($sizeUnit) {
                    "GB" { $expectedSize = $sizeValue * 1GB }
                    "MB" { $expectedSize = $sizeValue * 1MB }
                    "KB" { $expectedSize = $sizeValue * 1KB }
                }
            }
        }
        
        if ($files) {
            $currentFile = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $currentSize = $currentFile.Length
            $fileName = $currentFile.Name
            $downloadStarted = $true
            
            # Calculate download speed
            $currentTime = Get-Date
            $timeDiff = ($currentTime - $previousTime).TotalSeconds
            $sizeDiff = $currentSize - $previousSize
            $speedMBps = if ($timeDiff -gt 0 -and $sizeDiff -gt 0) {
                [math]::Round(($sizeDiff / 1MB) / $timeDiff, 2)
            } else {
                0
            }
            
            # Calculate progress
            if ($expectedSize -and $expectedSize -gt 0) {
                $percentComplete = [math]::Min(100, [math]::Round(($currentSize / $expectedSize) * 100, 2))
            } elseif ($currentSize -gt $previousSize) {
                # Estimate progress based on growth (if we don't know total size)
                if ($previousSize -gt 0 -and $speedMBps -gt 0) {
                    # Rough estimate: assume we're making progress
                    $percentComplete = [math]::Min(95, [math]::Round(($currentSize / ($currentSize + ($speedMBps * 1MB * 5))) * 100, 2))
                } else {
                    $percentComplete = 5
                }
            } else {
                $percentComplete = 0
            }
            
            # Format file size
            $sizeMB = [math]::Round($currentSize / 1MB, 2)
            $expectedSizeMB = if ($expectedSize) { [math]::Round($expectedSize / 1MB, 2) } else { "?" }
            
            # Calculate ETA if we have expected size and speed
            $eta = ""
            if ($expectedSize -and $expectedSize -gt 0 -and $speedMBps -gt 0) {
                $remainingMB = ($expectedSize - $currentSize) / 1MB
                $etaSeconds = [math]::Round($remainingMB / $speedMBps, 0)
                if ($etaSeconds -gt 0) {
                    $etaMinutes = [math]::Floor($etaSeconds / 60)
                    $etaSecs = $etaSeconds % 60
                    $eta = " | ETA: "
                    if ($etaMinutes -gt 0) {
                        $eta += "${etaMinutes}m "
                    }
                    $eta += "${etaSecs}s"
                }
            }
            
            # Show progress bar
            $statusMessage = "Downloading: $fileName`nSize: $sizeMB MB / $expectedSizeMB MB"
            if ($speedMBps -gt 0) {
                $statusMessage += " | Speed: $speedMBps MB/s"
            }
            if ($eta) {
                $statusMessage += $eta
            }
            Write-Progress -Activity "Downloading $PackageName" -Status $statusMessage -PercentComplete $percentComplete
            
            $previousSize = $currentSize
            $previousTime = $currentTime
        } elseif (-not $downloadStarted) {
            # No file yet, show waiting message
            Write-Progress -Activity "Downloading $PackageName" -Status "Initializing download..." -PercentComplete 0
        }
        
        Start-Sleep -Milliseconds 500
        
        # Check if job completed
        if ($job.State -ne "Running") {
            break
        }
    }
    
    # Get final job output
    $jobOutput = Receive-Job -Job $job
    Remove-Job -Job $job -Force
    
    # Clear progress bar
    Write-Progress -Activity "Downloading $PackageName" -Completed
    
    # Check exit code - jobs don't preserve exit codes well, so check output for errors
    if ($jobOutput) {
        $errorIndicators = $jobOutput | Select-String -Pattern "error|failed|exception" -CaseSensitive:$false
        if ($errorIndicators) {
            Write-Host "Winget output:" -ForegroundColor Yellow
            Write-Host $jobOutput
            throw "Winget download may have failed. Check output above."
        }
    }
    
    return $jobOutput
}

# Step 1: Search Winget for the application
Write-Step "Step 1: Searching Winget for application"
try {
    Write-Host "Diagnostic log: $script:DiagnosticLogPath" -ForegroundColor DarkGray
    Write-DiagnosticLog "Beginning Winget search for AppName='$AppName'"

    # Check if --accept-package-agreements is supported (newer Winget versions)
    $testCommand = winget search --help 2>&1 | Select-String -Pattern "accept-package-agreements" -Quiet
    $supportsPackageAgreements = $testCommand
    Write-DiagnosticLog "Winget supports --accept-package-agreements: $supportsPackageAgreements"
    
    # Search for the application (without --exact to get multiple results)
    if ($supportsPackageAgreements) {
        Write-DiagnosticLog "Running command: winget search $AppName --accept-source-agreements --accept-package-agreements"
        $searchResult = winget search $AppName --accept-source-agreements --accept-package-agreements 2>&1
    } else {
        Write-DiagnosticLog "Running command: winget search $AppName --accept-source-agreements"
        $searchResult = winget search $AppName --accept-source-agreements 2>&1
    }
    $searchExitCode = $LASTEXITCODE
    Write-DiagnosticLog "Winget search exit code: $searchExitCode"
    Save-SearchOutputDiagnostics -SearchOutput $searchResult
    
    # Check if search output appears to contain results. We intentionally use broad patterns
    # because winget output formatting can vary by locale, terminal width, and font.
    $hasResults = $searchResult | Select-String -Pattern "Name\s+Id\s+Version|Found.*\[|[A-Za-z][A-Za-z0-9-]*(?:\s*\.\s*[A-Za-z0-9][A-Za-z0-9-]*)+(?:\s{2,}|\t+)\d[0-9A-Za-z._-]*" -Quiet
    Write-DiagnosticLog "Winget search has recognizable result markers: $hasResults"
    if ($searchExitCode -ne 0) {
        # Do not fail early. Some environments return non-zero with usable output.
        if (-not $hasResults) {
            Write-Host "Note: Winget search returned exit code $searchExitCode and no obvious markers; attempting resilient parsing and fallbacks..." -ForegroundColor Yellow
            Write-DiagnosticLog "Winget search returned non-zero without obvious result markers. Proceeding with resilient parsing." "WARN"
        } else {
            Write-Host "Note: Winget returned exit code $searchExitCode but found results. Continuing..." -ForegroundColor Yellow
            Write-DiagnosticLog "Winget search returned non-zero but output appears parseable. Continuing." "WARN"
        }
    }
    
    Write-Host $searchResult
    
    # Parse search results and let user select
    $selectedPackage = Select-WingetPackage -SearchOutput $searchResult
    
    if (-not $selectedPackage) {
        # Fallback: if user input looks like a package ID, continue with exact ID flow
        # even when table parsing fails.
        if ($AppName -match '^[A-Za-z0-9][A-Za-z0-9.\-\s]*\.[A-Za-z0-9][A-Za-z0-9.\-\s]*$') {
            $normalizedFallbackId = ($AppName.Trim() -replace '\s*\.\s*', '.') -replace '\s+', ''
            $selectedPackage = [PSCustomObject]@{
                Name = $AppName.Trim()
                Id = $normalizedFallbackId
                Version = if ($Version) { $Version } else { "Unknown" }
            }
            Write-DiagnosticLog "Parser returned no result, but AppName looked like package ID. Falling back to exact ID: $normalizedFallbackId" "WARN"
            Write-Host "Parser fallback: using exact package ID '$normalizedFallbackId'" -ForegroundColor Yellow
        }
    }

    if (-not $selectedPackage) {
        Write-Host "Search output diagnostics: $script:SearchOutputPath" -ForegroundColor Yellow
        Write-DiagnosticLog "Select-WingetPackage returned no result for AppName '$AppName'." "WARN"
        throw "No packages found or could not parse search results"
    }
    
    # Use selected package ID
    $packageId = $selectedPackage.Id
    $selectedVersion = $selectedPackage.Version
    
    # If user specified a version, use it; otherwise use the version from search results
    if ($Version) {
        $foundVersion = $Version
    } else {
        $foundVersion = $selectedVersion
    }
    
    # Get app details using the selected package ID
    if ($Version) {
        if ($supportsPackageAgreements) {
            Write-DiagnosticLog "Running command: winget show $packageId --exact --version $Version --accept-source-agreements --accept-package-agreements"
            $appInfo = winget show $packageId --exact --version $Version --accept-source-agreements --accept-package-agreements 2>&1
        } else {
            Write-DiagnosticLog "Running command: winget show $packageId --exact --version $Version --accept-source-agreements"
            $appInfo = winget show $packageId --exact --version $Version --accept-source-agreements 2>&1
        }
        $showExitCode = $LASTEXITCODE
    } else {
        if ($supportsPackageAgreements) {
            Write-DiagnosticLog "Running command: winget show $packageId --exact --accept-source-agreements --accept-package-agreements"
            $appInfo = winget show $packageId --exact --accept-source-agreements --accept-package-agreements 2>&1
        } else {
            Write-DiagnosticLog "Running command: winget show $packageId --exact --accept-source-agreements"
            $appInfo = winget show $packageId --exact --accept-source-agreements 2>&1
        }
        $showExitCode = $LASTEXITCODE
    }
    Write-DiagnosticLog "Winget show exit code for '$packageId': $showExitCode"
    
    # Check if show command was successful - sometimes winget returns non-zero but still has info
    $hasAppInfo = $appInfo | Select-String -Pattern "Found.*\[|Version:\s+|Publisher:\s+" -Quiet
    $showInfoUnavailable = $false
    if ($showExitCode -ne 0) {
        # Check if we got useful output despite the error code
        if (-not $hasAppInfo) {
            Write-Host "Winget show output:" -ForegroundColor Yellow
            Write-Host $appInfo
            Write-Host "Warning: winget show returned no metadata; continuing with search-derived defaults." -ForegroundColor Yellow
            Write-DiagnosticLog "winget show failed for '$packageId' with exit code $showExitCode and no parseable metadata. Continuing with defaults." "WARN"
            $showInfoUnavailable = $true
        } else {
            Write-Host "Note: Winget returned exit code $showExitCode but found app info. Continuing..." -ForegroundColor Yellow
        }
    }
    
    if (-not $showInfoUnavailable) {
        Write-Host $appInfo
    }
    
    # Extract package details from output (in case version differs)
    $extractedPackageId = ($appInfo | Select-String -Pattern "Found (.+?) \[(.+?)\]" | ForEach-Object { $_.Matches.Groups[2].Value })
    if ($extractedPackageId) {
        $packageId = Normalize-WingetPackageId -Id $extractedPackageId
    }
    
    $extractedVersion = ($appInfo | Select-String -Pattern "Version:\s+(.+)" | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    if ($extractedVersion) {
        $foundVersion = $extractedVersion
    }
    
    if (-not $foundVersion) {
        if ($selectedVersion -and $selectedVersion -ne "Unknown") {
            $foundVersion = $selectedVersion
            Write-DiagnosticLog "Version not found from winget show output, falling back to selected search version '$foundVersion'" "WARN"
        } else {
            $foundVersion = "Unknown"
            Write-DiagnosticLog "Version not found from show/search output. Falling back to 'Unknown'." "WARN"
        }
    }
    
    if ($Version -and $foundVersion -ne $Version) {
        Write-Error "Requested version $Version does not match found version $foundVersion"
        $foundVersion = $Version
    }
    
    $displayName = ($appInfo | Select-String -Pattern "Found (.+?) \[" | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    if (-not $displayName) {
        $displayName = $selectedPackage.Name
    }
    if (-not $displayName) {
        $displayName = $packageId
    }
    
    $publisher = ($appInfo | Select-String -Pattern "Publisher:\s+(.+)" | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    if (-not $publisher) {
        $publisher = "Unknown"
    }
    
    $description = ($appInfo | Select-String -Pattern "Description:\s+(.+)" -Context 0,5 | ForEach-Object { $_.Line.Trim() })
    if (-not $description) {
        $description = "No description available"
    }
    
    $homepage = ($appInfo | Select-String -Pattern "Homepage:\s+(.+)" | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    if (-not $homepage) {
        $homepage = ""
    }
    
    Write-Success "Found: $displayName ($packageId) version $foundVersion"
    
} catch {
    Write-Error "Failed to search Winget: $_"
    Write-Host "Diagnostic log: $script:DiagnosticLogPath" -ForegroundColor Yellow
    Write-Host "Search output snapshot: $script:SearchOutputPath" -ForegroundColor Yellow
    exit 1
}

# Step 2: Create directory structure
Write-Step "Step 2: Creating directory structure"
$appDirectory = Join-Path $OutputPath $packageId
$versionDirectory = Join-Path $appDirectory $foundVersion

if (-not (Test-Path $versionDirectory)) {
    New-Item -ItemType Directory -Path $versionDirectory -Force | Out-Null
    Write-Success "Created directory: $versionDirectory"
} else {
    Write-Host "Directory already exists: $versionDirectory" -ForegroundColor Yellow
}

# Step 3: Download installer
Write-Step "Step 3: Downloading installer"
try {
    # Download with progress bar
    $downloadResult = Start-WingetDownloadWithProgress -PackageId $packageId -DownloadDirectory $versionDirectory -PackageName $displayName
    
    # Display download result summary
    if ($downloadResult) {
        $summary = $downloadResult | Select-String -Pattern "Successfully|Downloaded|Installer downloaded" | Select-Object -First 1
        if ($summary) {
            Write-Host $summary.Line -ForegroundColor Green
        }
    }
    
    # Wait a moment for file system to catch up
    Start-Sleep -Seconds 1
    
    # Find the downloaded installer file (supports .exe, .msi, .msix, .appx)
    $installerFile = Get-ChildItem -Path $versionDirectory -File -ErrorAction SilentlyContinue | 
        Where-Object { 
            ($_.Extension -eq ".exe" -or $_.Extension -eq ".msi" -or $_.Extension -eq ".msix" -or $_.Extension -eq ".appx") -and
            $_.Name -notlike "*intunewin*" -and $_.Name -notlike "*ContentPrepTool*"
        } | 
        Sort-Object LastWriteTime -Descending | 
        Select-Object -First 1
    
    if (-not $installerFile) {
        throw "Could not find downloaded installer file (.exe, .msi, .msix, or .appx)"
    }
    
    $installerFileName = $installerFile.Name
    $installerExtension = $installerFile.Extension.ToLower()
    $fileSizeMB = [math]::Round($installerFile.Length / 1MB, 2)
    Write-Success "Downloaded installer: $installerFileName ($fileSizeMB MB)"
    
    # Determine install command based on installer type
    if ($installerExtension -eq ".msi") {
        $installCommand = "msiexec /i `"$installerFileName`" /quiet /norestart"
    } elseif ($installerExtension -eq ".msix" -or $installerExtension -eq ".appx") {
        $installCommand = "Add-AppxPackage -Path `"$installerFileName`""
    } else {
        # Default to .exe with /S flag
        $installCommand = "`"$installerFileName`" /S"
    }
    
} catch {
    Write-Error "Failed to download installer: $_"
    exit 1
}

# Step 4: Get installer hash
Write-Step "Step 4: Calculating installer hash"
try {
    $installerHash = (Get-FileHash -Path $installerFile.FullName -Algorithm SHA256).Hash
    Write-Success "Installer SHA256: $installerHash"
} catch {
    Write-Error "Failed to calculate hash: $_"
    $installerHash = ""
}

# Step 5: Create registry-based detection script
Write-Step "Step 5: Creating registry-based detection script"
$detectionScript = @"
# Registry-based detection script for $displayName
# Checks for $displayName installation in Windows Uninstall registry keys

`$packageId = "$packageId"
`$version = "$foundVersion"
`$displayName = "$displayName"

# Start transcript for logging
`$logPath = "`$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\`$packageId-detection.log"
Start-Transcript -Path `$logPath -Force
Write-Host "Starting `$packageId `$version detection (Registry-based)"

# Registry paths to check
`$registryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

`$found = `$false
`$installedVersion = `$null
`$allMatchingVersions = @()

# Search for application in registry - collect ALL matching entries
foreach (`$regPath in `$registryPaths) {
    try {
        # Get all uninstall keys from this path
        `$allKeys = Get-ItemProperty `$regPath -ErrorAction SilentlyContinue
        
        if (`$allKeys) {
            # Search for application - use flexible matching
            # First try exact display name match, then partial match, then package ID match
            `$searchTerms = @(
                "*$displayName*",
                "*$($displayName.Split(' ')[0])*",  # First word of display name (e.g., "Tableau" from "Tableau Desktop")
                "*$($packageId.Split('.')[0])*"     # First part of package ID (e.g., "Tableau" from "Tableau.Desktop")
            )
            
            # Filter for matching entries
            `$uninstallKeys = `$allKeys | Where-Object {
                `$key = `$_
                `$matched = `$false
                foreach (`$term in `$searchTerms) {
                    if ((`$key.DisplayName -and `$key.DisplayName -like `$term) -or 
                        (`$key.PSChildName -and `$key.PSChildName -like `$term)) {
                        `$matched = `$true
                        break
                    }
                }
                `$matched
            }
            
            if (`$uninstallKeys) {
                foreach (`$key in `$uninstallKeys) {
                    Write-Host "Found registry key: `$(`$key.PSChildName)"
                    Write-Host "DisplayName: `$(`$key.DisplayName)"
                    Write-Host "DisplayVersion: `$(`$key.DisplayVersion)"
                    
                    # Check if this is our application - be flexible with name matching
                    # Match if DisplayName contains key words from our display name or package ID
                    `$nameMatch = `$false
                    `$displayNameWords = "$displayName" -split '\s+'
                    `$packageIdWords = "$packageId" -split '\.'
                    
                    # Check if DisplayName contains any significant word from our search terms
                    foreach (`$word in `$displayNameWords) {
                        if (`$word.Length -gt 3 -and `$key.DisplayName -and `$key.DisplayName -like "*`$word*") {
                            `$nameMatch = `$true
                            break
                        }
                    }
                    
                    # Also check package ID words
                    if (-not `$nameMatch) {
                        foreach (`$word in `$packageIdWords) {
                            if (`$word.Length -gt 3 -and `$key.DisplayName -and `$key.DisplayName -like "*`$word*") {
                                `$nameMatch = `$true
                                break
                            }
                        }
                    }
                    
                    # If name matches, add it to our collection
                    if (`$nameMatch -and `$key.DisplayName -and `$key.DisplayName -like "*$($displayName.Split(' ')[0])*") {
                        # For JetBrains products, try to extract version from DisplayName first
                        # DisplayName format: "WebStorm 2025.3.1.1" contains the marketing version
                        # DisplayVersion format: "253.29346.242" is the build number
                        `$extractedVersion = `$null
                        if (`$key.DisplayName -match "(\d+\.\d+\.\d+\.\d+)") {
                            `$extractedVersion = `$matches[1]
                            Write-Host "Extracted version from DisplayName: `$extractedVersion"
                        }
                        
                        # Use extracted version if found, otherwise use DisplayVersion
                        `$versionToUse = if (`$extractedVersion) { `$extractedVersion } else { `$key.DisplayVersion }
                        
                        if (`$versionToUse) {
                            `$allMatchingVersions += @{
                                DisplayName = `$key.DisplayName
                                DisplayVersion = `$versionToUse
                                PSChildName = `$key.PSChildName
                            }
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Host "Error checking registry path `$regPath : `$_"
        Write-Host "Error details: `$(`$_.Exception.Message)"
    }
}

# Find the highest version among all matching installations
if (`$allMatchingVersions.Count -gt 0) {
    Write-Host "Found `$(`$allMatchingVersions.Count) matching installation(s)"
    
    # Get the version - if only one, use it directly; otherwise sort
    if (`$allMatchingVersions.Count -eq 1) {
        `$highestVersion = `$allMatchingVersions[0]
        `$installedVersion = `$highestVersion['DisplayVersion']
        `$found = `$true
        Write-Host "Found version: `$installedVersion (from `$(`$highestVersion['DisplayName']))"
    } else {
        # Multiple versions - sort to find highest
        try {
            `$sortedVersions = `$allMatchingVersions | Sort-Object -Property @{
                Expression = {
                    try {
                        [version]`$_.DisplayVersion
                    } catch {
                        [version]"0.0.0"
                    }
                }
            } -Descending
            
            if (`$sortedVersions -and `$sortedVersions.Count -gt 0) {
                `$highestVersion = `$sortedVersions[0]
                `$installedVersion = `$highestVersion['DisplayVersion']
                `$found = `$true
                Write-Host "Highest version found: `$installedVersion (from `$(`$highestVersion['DisplayName']))"
            }
        } catch {
            Write-Host "Error during sorting: `$_, using first match"
            `$highestVersion = `$allMatchingVersions[0]
            `$installedVersion = `$highestVersion['DisplayVersion']
            `$found = `$true
            Write-Host "Using version: `$installedVersion (from `$(`$highestVersion['DisplayName']))"
        }
    }
}

# Verify version if found
if (`$found) {
    if (`$null -eq `$version -or `$version -eq "") {
        Write-Host "`$packageId version `$installedVersion is installed, exiting with code 0"
        Stop-Transcript
        Exit 0
    }
    
    if (`$installedVersion -eq `$version) {
        Write-Host "`$packageId version `$version is installed, exiting with code 0"
        Stop-Transcript
        Exit 0
    }
    
    # Compare versions
    try {
        `$installedVer = [version]`$installedVersion
        `$expectedVer = [version]`$version
        
        if (`$installedVer -ge `$expectedVer) {
            Write-Host "`$packageId is installed with version `$installedVersion (equal or higher than expected `$version), exit code 0"
            Stop-Transcript
            Exit 0
        }
        else {
            Write-Host "`$packageId is installed but version `$installedVersion is lower than expected `$version, exit code 1"
            Stop-Transcript
            Exit 1
        }
    }
    catch {
        # Fallback to string comparison if version parsing fails
        if (`$installedVersion -ge `$version) {
            Write-Host "`$packageId is installed with version `$installedVersion (equal or higher than expected `$version), exit code 0"
            Stop-Transcript
            Exit 0
        }
        else {
            Write-Host "`$packageId is installed but version `$installedVersion is lower than expected `$version, exit code 1"
            Stop-Transcript
            Exit 1
        }
    }
}

Write-Host "`$packageId not detected in registry, exiting with code 1"
Stop-Transcript
Exit 1
"@

$detectionScriptPath = Join-Path $versionDirectory "detection.ps1"
$detectionScript | Set-Content -Path $detectionScriptPath -Encoding UTF8
Write-Success "Created detection script: detection.ps1"

# Step 6: Create uninstall script
Write-Step "Step 6: Creating uninstall script"
$uninstallScript = @"
# Uninstall script for $displayName
# Uses registry to find and execute the uninstaller

`$packageId = "$packageId"
`$action = "uninstall"
`$displayName = "$displayName"

# Start transcript for logging
`$logPath = "`$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\`$packageId-`$action.log"
Start-Transcript -Path `$logPath -Force
Write-Host "Starting `$packageId `$action"

# Registry paths to check
`$registryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

`$uninstallString = `$null
`$quietUninstallString = `$null

# Search for application uninstall string in registry
foreach (`$regPath in `$registryPaths) {
    try {
        `$uninstallKeys = Get-ItemProperty `$regPath -ErrorAction SilentlyContinue | Where-Object {
            `$_.DisplayName -like "*$displayName*" -or 
            `$_.PSChildName -like "*$($packageId.ToLower())*" -or
            `$_.PSChildName -like "*$($packageId)*"
        }
        
        if (`$uninstallKeys) {
            foreach (`$key in `$uninstallKeys) {
                if (`$key.DisplayName -like "*$displayName*" -or `$key.DisplayName -eq `$displayName) {
                    `$uninstallString = `$key.UninstallString
                    `$quietUninstallString = `$key.QuietUninstallString
                    Write-Host "Found uninstall string: `$uninstallString"
                    break
                }
            }
            if (`$uninstallString) { break }
        }
    }
    catch {
        Write-Host "Error checking registry path `$regPath : `$_"
    }
}

if (-not `$uninstallString) {
    Write-Host "Uninstall string not found in registry for `$packageId"
    Stop-Transcript
    Exit 1
}

# Prefer quiet uninstall if available, otherwise use regular uninstall string
`$uninstallCmd = if (`$quietUninstallString) { `$quietUninstallString } else { `$uninstallString }

# For Nullsoft installers, add /S for silent uninstall if not already present
if (`$uninstallCmd -notmatch "/S" -and `$uninstallCmd -match "\.exe") {
    `$uninstallCmd = `$uninstallCmd -replace '"([^"]+\.exe)"', '"`$1" /S'
    Write-Host "Added /S flag for silent uninstall"
}

Write-Host "Executing uninstall command: `$uninstallCmd"

try {
    # Execute uninstall command
    `$process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `$uninstallCmd" -Wait -PassThru -NoNewWindow
    
    if (`$process.ExitCode -eq 0) {
        Write-Host "Package `$packageId uninstalled successfully"
        Stop-Transcript
        Exit 0
    }
    else {
        Write-Host "Uninstall returned exit code: `$(`$process.ExitCode)"
        Stop-Transcript
        Exit `$process.ExitCode
    }
}
catch {
    Write-Host "Error during uninstall: `$_"
    Stop-Transcript
    Exit 1
}
"@

$uninstallScriptPath = Join-Path $versionDirectory "uninstall.ps1"
$uninstallScript | Set-Content -Path $uninstallScriptPath -Encoding UTF8
Write-Success "Created uninstall script: uninstall.ps1"

# Step 7: Handle icon file
Write-Step "Step 7: Handling icon file"
$iconFilePath = Join-Path $versionDirectory "icon.png"
$logoFilePath = Join-Path $appDirectory "logo.png"
$logoDownloaded = $false

if ($IconPath -and (Test-Path $IconPath)) {
    Copy-Item -Path $IconPath -Destination $iconFilePath -Force
    Write-Success "Copied icon from: $IconPath"
} elseif (Test-Path $logoFilePath) {
    Copy-Item -Path $logoFilePath -Destination $iconFilePath -Force
    Write-Success "Copied logo.png from parent directory"
} else {
    # Try to download logo automatically
    Write-Host "Attempting to download logo automatically..." -ForegroundColor Cyan
    $installerFullPath = if ($installerFile) { $installerFile.FullName } else { $null }
    $logoDownloaded = Get-LogoFromWeb -PackageId $packageId -DisplayName $displayName -Publisher $publisher -Homepage $homepage -OutputPath $logoFilePath -InstallerPath $installerFullPath
    
    if ($logoDownloaded -and (Test-Path $logoFilePath)) {
        Copy-Item -Path $logoFilePath -Destination $iconFilePath -Force
        Write-Success "Downloaded and copied logo automatically"
    } else {
        Write-Host "No icon file found. You may need to add one manually." -ForegroundColor Yellow
    }
}

# Step 8: Create readme.txt
Write-Step "Step 8: Creating readme.txt"
$readmeContent = @"
Package $packageId $foundVersion from Winget

Display name: $displayName
Version: $foundVersion
Publisher: $publisher
Homepage: $homepage

Install script:
$installCommand

Uninstall script:
%windir%\sysnative\windowspowershell\v1.0\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File uninstall.ps1

Description:
$description
"@

$readmePath = Join-Path $versionDirectory "readme.txt"
$readmeContent | Set-Content -Path $readmePath -Encoding UTF8
Write-Success "Created readme.txt"

# Step 9: Create app.json
Write-Step "Step 9: Creating app.json"
$appJson = @{
    packageIdentifier = $packageId
    displayName = $displayName
    description = $description
    version = $foundVersion
    source = 2
    publisher = $publisher
    informationUrl = $homepage
    publisherUrl = $homepage
    supportUrl = $homepage
    installerType = 7
    installerUrl = ""
    hash = $installerHash
    installCommandLine = $installCommand
    uninstallCommandLine = "%windir%\\sysnative\\windowspowershell\\v1.0\\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File uninstall.ps1"
    installerFilename = $installerFileName
    installerContext = 2
    architecture = 2
}

$appJsonPath = Join-Path $versionDirectory "app.json"
$appJson | ConvertTo-Json -Depth 10 | Set-Content -Path $appJsonPath -Encoding UTF8
Write-Success "Created app.json"

# Step 10: Create win32LobApp.json with registry-based detection
Write-Step "Step 10: Creating win32LobApp.json"
$detectionScriptBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($detectionScript))

# Read icon file if it exists and convert to base64
$iconBase64 = ""
if (Test-Path $iconFilePath) {
    try {
        $iconBytes = [System.IO.File]::ReadAllBytes($iconFilePath)
        $iconBase64 = [Convert]::ToBase64String($iconBytes)
    } catch {
        Write-Host "Warning: Could not read icon file for base64 encoding" -ForegroundColor Yellow
    }
}

$win32LobAppJson = @{
    "@odata.type" = "#microsoft.graph.win32LobApp"
    description = $description
    developer = $publisher
    displayName = $displayName
    informationUrl = $homepage
    largeIcon = if ($iconBase64) {
        @{
            type = "image/png"
            value = $iconBase64
        }
    } else {
        $null
    }
    notes = "Generated by Wingetter at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [Winget|$packageId]"
    publisher = $publisher
    fileName = "$($installerFile.BaseName).intunewin"
    allowAvailableUninstall = $true
    applicableArchitectures = "x64"
    detectionRules = @(
        @{
            "@odata.type" = "#microsoft.graph.win32LobAppPowerShellScriptDetection"
            enforceSignatureCheck = $false
            runAs32Bit = $false
            scriptContent = $detectionScriptBase64
        }
    )
    displayVersion = $foundVersion
    installCommandLine = $installCommand
    installExperience = @{
        deviceRestartBehavior = "basedOnReturnCode"
        runAsAccount = "system"
    }
    minimumSupportedOperatingSystem = @{
        v10_2004 = $true
    }
    minimumSupportedWindowsRelease = "2004"
    returnCodes = @(
        @{ returnCode = 0; type = "success" }
        @{ returnCode = 1707; type = "success" }
        @{ returnCode = 3010; type = "softReboot" }
        @{ returnCode = 1641; type = "hardReboot" }
        @{ returnCode = 1618; type = "retry" }
    )
    setupFilePath = $installerFileName
    uninstallCommandLine = "%windir%\\sysnative\\windowspowershell\\v1.0\\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File uninstall.ps1"
}

# Remove null largeIcon if no icon
if (-not $iconBase64) {
    $win32LobAppJson.Remove('largeIcon')
}

$win32LobAppJsonPath = Join-Path $versionDirectory "win32LobApp.json"
$win32LobAppJson | ConvertTo-Json -Depth 10 | Set-Content -Path $win32LobAppJsonPath -Encoding UTF8
Write-Success "Created win32LobApp.json"

# Step 11: Package with Content Prep Tool
Write-Step "Step 11: Packaging with Content Prep Tool (intunewinapputil)"
$intunewinFile = $null
$intunewinCreated = $false
try {
    # Check if intunewinapputil is available
    $intunewinCmd = Get-Command intunewinapputil -ErrorAction SilentlyContinue
    if (-not $intunewinCmd) {
        throw "intunewinapputil not found. Is Content Prep Tool installed and in PATH?"
    }
    
    $outputDirectory = Split-Path $versionDirectory
    $intunewinFile = Join-Path $outputDirectory "$($installerFile.BaseName).intunewin"
    
    # Remove existing intunewin file if it exists
    if (Test-Path $intunewinFile) {
        Remove-Item -Path $intunewinFile -Force
        Write-Host "Removed existing intunewin file" -ForegroundColor Yellow
    }
    
    Write-Host "Running: intunewinapputil -c `"$versionDirectory`" -s `"$installerFileName`" -o `"$outputDirectory`" -q"
    
    & intunewinapputil -c $versionDirectory -s $installerFileName -o $outputDirectory -q
    
    if ($LASTEXITCODE -eq 0 -and (Test-Path $intunewinFile)) {
        $intunewinCreated = $true
        Write-Success "Created IntuneWin package: $intunewinFile"
        $fileInfo = Get-Item $intunewinFile
        Write-Host "File size: $([math]::Round($fileInfo.Length / 1MB, 2)) MB" -ForegroundColor Green
    } else {
        throw "Content Prep Tool failed or output file not found"
    }
    
} catch {
    Write-Error "Failed to create IntuneWin package: $_"
    Write-Host "You can manually run: intunewinapputil -c `"$versionDirectory`" -s `"$installerFileName`" -o `"$outputDirectory`" -q" -ForegroundColor Yellow
    Write-Host "Diagnostic log: $script:DiagnosticLogPath" -ForegroundColor Yellow
}

# Summary
Write-Step "Summary" "Green"
$summaryStatus = if ($intunewinCreated) {
    "Package created successfully!"
} else {
    "Package files created, but IntuneWin packaging did not complete."
}
$intunewinSummaryLine = if ($intunewinCreated) {
    "- IntuneWin Package: $intunewinFile"
} else {
    "- IntuneWin Package: (not created - see Step 11 output)"
}
$nextStepUpload = if ($intunewinCreated) {
    "3. Upload the .intunewin file to Intune"
} else {
    "3. Re-run intunewinapputil manually, then upload the .intunewin file to Intune"
}

Write-Host @"
$summaryStatus

Package Details:
- Application: $displayName
- Package ID: $packageId
- Version: $foundVersion
- Publisher: $publisher
- Installer: $installerFileName
- Output Directory: $versionDirectory
$intunewinSummaryLine

Files Created:
- detection.ps1 (Registry-based detection)
- uninstall.ps1 (Uninstall script)
- app.json (Application metadata)
- win32LobApp.json (Intune app definition)
- readme.txt (Documentation)
- icon.png (Application icon, if available)
- $installerFileName (Installer file)
$(if ($intunewinCreated) { "- $($installerFile.BaseName).intunewin (Intune package)" })

Next Steps:
1. Review the generated files in: $versionDirectory
2. Test the detection script if needed
$nextStepUpload
4. If any step fails, review diagnostic logs:
   - $script:DiagnosticLogPath
   - $script:SearchOutputPath
"@ -ForegroundColor Green
