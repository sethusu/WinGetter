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

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptRoot 'Modules' 'WingetSearch.psm1') -Force
Import-Module (Join-Path $scriptRoot 'Modules' 'ScriptTemplates.psm1') -Force

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

# Prompt for AppName if not provided
if ([string]::IsNullOrWhiteSpace($AppName)) {
    Write-Host "Winget Package ID not provided. Opening input dialog..." -ForegroundColor Cyan
    $AppName = Get-WingetIdFromDialog
    Write-Host "Using Winget ID: $AppName" -ForegroundColor Green
}

# Function to write colored output
function Write-Step {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host "`n[$Message]" -ForegroundColor $Color
}

function Write-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Write-WingetterError {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
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
        [string]$PackageName,
        [string]$Version
    )
    
    Write-Host "Starting download..." -ForegroundColor Cyan
    
    # Check if --accept-package-agreements is supported
    $testCommand = winget download --help 2>&1 | Select-String -Pattern "accept-package-agreements" -Quiet
    $supportsPackageAgreements = $testCommand
    
    # Start winget download in background job
    # Use --accept-package-agreements if supported, otherwise just --accept-source-agreements
    $job = Start-Job -ScriptBlock {
        param($pkgId, $dir, $supportsPkgAgreements, $pkgVersion)
        $downloadArgs = @(
            'download', $pkgId, '--exact',
            '--download-directory', $dir,
            '--disable-interactivity',
            '--accept-source-agreements'
        )
        if ($supportsPkgAgreements) {
            $downloadArgs += '--accept-package-agreements'
        }
        if ($pkgVersion) {
            $downloadArgs += @('--version', $pkgVersion)
        }
        & winget @downloadArgs 2>&1
    } -ArgumentList $PackageId, $DownloadDirectory, $supportsPackageAgreements, $Version
    
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
        $outputText = ($jobOutput | Out-String).Trim()
        $successIndicators = $outputText -match '(?i)Successfully verified|Installer downloaded|Downloaded successfully'
        $failureIndicators = $outputText -match '(?i)No applicable installer|No package found|An unexpected error|0x8'
        if ($failureIndicators -and -not $successIndicators) {
            Write-Host "Winget output:" -ForegroundColor Yellow
            Write-Host $outputText
            throw "Winget download failed. Check output above."
        }
    }
    
    return $jobOutput
}

# Step 1: Search Winget for the application
Write-Step "Step 1: Searching Winget for application"
try {
    $searchPackages = Search-WingetPackages -Query $AppName -PreferWingetSource

    if (-not $searchPackages -or $searchPackages.Count -eq 0) {
        $rawSearchOutput = Invoke-WingetSearchCommand -Query $AppName
        Write-Host "Winget search output:" -ForegroundColor Yellow
        Write-Host $rawSearchOutput
        throw "No packages found for '$AppName'. Try the exact package ID (for example Google.Chrome) or a more specific search term."
    }

    $selectedPackage = Select-WingetPackage -SearchOutput $searchPackages -Query $AppName

    if (-not $selectedPackage) {
        throw "No packages found or could not parse search results for '$AppName'"
    }

    if ($selectedPackage.TruncatedId) {
        throw "Package ID '$($selectedPackage.Id)' appears truncated. Re-run with the exact package ID or install Microsoft.WinGet.Client for structured search results."
    }

    $packageId = $selectedPackage.Id
    $selectedVersion = $selectedPackage.Version

    if ($Version) {
        $foundVersion = $Version
    } else {
        $foundVersion = $selectedVersion
    }

    $packageDetails = Get-WingetPackageDetails -PackageId $packageId -Version $Version
    if (-not $packageDetails.Package) {
        throw "Failed to get app information from Winget for package ID '$packageId'."
    }

    $showPackage = $packageDetails.Package
    $appInfoLines = @($packageDetails.RawOutput)

    Write-Host $appInfoLines

    if ($showPackage.Id) {
        $packageId = $showPackage.Id
    }

    if ($showPackage.Version -and $showPackage.Version -ne 'Unknown') {
        $foundVersion = $showPackage.Version
    }

    if (-not $foundVersion -or $foundVersion -eq 'Unknown') {
        throw "Could not determine version from Winget output"
    }

    if ($Version -and $foundVersion -ne $Version) {
        Write-WingetterError "Requested version $Version does not match found version $foundVersion"
        $foundVersion = $Version
    }

    $displayName = $showPackage.Name
    if (-not $displayName) {
        $displayName = $selectedPackage.Name
    }
    if (-not $displayName) {
        $displayName = $packageId
    }

    $publisher = ($appInfoLines | Select-String -Pattern "Publisher:\s+(.+)" | ForEach-Object { $_.Matches.Groups[1].Value.Trim() } | Select-Object -First 1)
    if (-not $publisher) {
        $publisher = "Unknown"
    }

    $description = ($appInfoLines | Select-String -Pattern "Description:\s+(.+)" | ForEach-Object { $_.Matches.Groups[1].Value.Trim() } | Select-Object -First 1)
    if (-not $description) {
        $description = "No description available"
    }

    $homepage = ($appInfoLines | Select-String -Pattern "Homepage:\s+(.+)" | ForEach-Object { $_.Matches.Groups[1].Value.Trim() } | Select-Object -First 1)
    if (-not $homepage) {
        $homepage = ""
    }

    Write-Success "Found: $displayName ($packageId) version $foundVersion"

} catch {
    Write-WingetterError "Failed to search Winget: $_"
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
    $downloadResult = Start-WingetDownloadWithProgress -PackageId $packageId -DownloadDirectory $versionDirectory -PackageName $displayName -Version $foundVersion
    
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
    Write-WingetterError "Failed to download installer: $_"
    exit 1
}

# Step 4: Get installer hash
Write-Step "Step 4: Calculating installer hash"
try {
    $installerHash = (Get-FileHash -Path $installerFile.FullName -Algorithm SHA256).Hash
    Write-Success "Installer SHA256: $installerHash"
} catch {
    Write-WingetterError "Failed to calculate hash: $_"
    $installerHash = ""
}

# Step 5: Create install, detection, and uninstall scripts
Write-Step "Step 5: Creating install, detection, and uninstall scripts"

$installerInstallCommand = $installCommand
$installScript = New-WingetterInstallScript -PackageId $packageId -DisplayName $displayName -Version $foundVersion -InstallCommand $installerInstallCommand
$detectionScript = New-WingetterDetectionScript -PackageId $packageId -DisplayName $displayName -Version $foundVersion
$uninstallScript = New-WingetterUninstallScript -PackageId $packageId -DisplayName $displayName

$installScriptPath = Join-Path $versionDirectory "install.ps1"
$detectionScriptPath = Join-Path $versionDirectory "detection.ps1"
$uninstallScriptPath = Join-Path $versionDirectory "uninstall.ps1"

$installScript | Set-Content -Path $installScriptPath -Encoding UTF8
$detectionScript | Set-Content -Path $detectionScriptPath -Encoding UTF8
$uninstallScript | Set-Content -Path $uninstallScriptPath -Encoding UTF8

$intuneInstallCommandLine = Get-WingetterIntunePowerShellCommand -ScriptFileName 'install.ps1'
$intuneUninstallCommandLine = Get-WingetterIntunePowerShellCommand -ScriptFileName 'uninstall.ps1'

Write-Success "Created install.ps1, detection.ps1, and uninstall.ps1"
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

Install command (Intune):
$intuneInstallCommandLine

Installer command (inside install.ps1):
$installerInstallCommand

Uninstall command (Intune):
$intuneUninstallCommandLine

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
    installCommandLine = $intuneInstallCommandLine
    uninstallCommandLine = $intuneUninstallCommandLine
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
    installCommandLine = $intuneInstallCommandLine
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
    uninstallCommandLine = $intuneUninstallCommandLine
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
        Write-Success "Created IntuneWin package: $intunewinFile"
        $fileInfo = Get-Item $intunewinFile
        Write-Host "File size: $([math]::Round($fileInfo.Length / 1MB, 2)) MB" -ForegroundColor Green
    } else {
        throw "Content Prep Tool failed or output file not found"
    }
    
} catch {
    Write-WingetterError "Failed to create IntuneWin package: $_"
    Write-Host "You can manually run: intunewinapputil -c `"$versionDirectory`" -s `"$installerFileName`" -o `"$outputDirectory`" -q" -ForegroundColor Yellow
}

# Summary
Write-Step "Summary" "Green"
Write-Host @"
Package created successfully!

Package Details:
- Application: $displayName
- Package ID: $packageId
- Version: $foundVersion
- Publisher: $publisher
- Installer: $installerFileName
- Output Directory: $versionDirectory
- IntuneWin Package: $intunewinFile

Files Created:
- install.ps1 (Install wrapper with logging and return codes)
- detection.ps1 (Registry-based detection)
- uninstall.ps1 (Uninstall script)
- app.json (Application metadata)
- win32LobApp.json (Intune app definition)
- readme.txt (Documentation)
- icon.png (Application icon, if available)
- $installerFileName (Installer file)
- $($installerFile.BaseName).intunewin (Intune package)

Next Steps:
1. Review the generated files in: $versionDirectory
2. Test the detection script if needed
3. Upload the .intunewin file to Intune
"@ -ForegroundColor Green
