<#
.SYNOPSIS
    Creates Intune Win32 packages from Winget with an enhanced GUI.
.DESCRIPTION
    Interactive mode includes:
      - Search dialog with radio-button package selection
      - Output destination picker
      - Icon picker + icon preview
      - Optional Markdown app notes/description override
      - Live run progress window
    Output includes:
      - install.ps1 / uninstall.ps1 / detection.ps1
      - app.json / win32LobApp.json
      - README.md with Intune upload field reference
      - run-failure.log on failed execution
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AppName,

    [Parameter(Mandatory = $false)]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "D:\Intoon In Progress",

    [Parameter(Mandatory = $false)]
    [string]$IconPath,

    [Parameter(Mandatory = $false)]
    [string]$DescriptionMarkdown,

    [Parameter(Mandatory = $false)]
    [switch]$NoGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n[$Message]" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function ConvertTo-NormalizedArray {
    param([Parameter(Mandatory = $true)] $InputValue)
    if ($InputValue -is [string]) {
        return ($InputValue -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    }
    if ($InputValue -is [System.Array]) {
        return $InputValue
    }
    return @($InputValue)
}

function Test-WingetSupportsPackageAgreement {
    $help = winget --help 2>&1
    return ($help | Select-String -Pattern "accept-package-agreements" -Quiet)
}

function Invoke-Winget {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = & winget @Arguments 2>&1
    return [PSCustomObject]@{
        Output = (ConvertTo-NormalizedArray -InputValue $output)
        ExitCode = $LASTEXITCODE
    }
}

function Parse-WingetSearchResults {
    param([Parameter(Mandatory = $true)]$SearchOutput)

    $lines = ConvertTo-NormalizedArray -InputValue $SearchOutput
    $packages = @()

    foreach ($line in $lines) {
        if ($line -match "^\s*(.+?)\s{2,}([A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+)\s{2,}([^\s]+)") {
            $packages += [PSCustomObject]@{
                Name = $matches[1].Trim()
                Id = $matches[2].Trim()
                Version = $matches[3].Trim()
            }
        }
    }

    if ($packages.Count -eq 0) {
        foreach ($line in $lines) {
            if ($line -match "Found\s+(.+?)\s+\[(.+?)\]") {
                $packages += [PSCustomObject]@{
                    Name = $matches[1].Trim()
                    Id = $matches[2].Trim()
                    Version = "Unknown"
                }
            }
        }
    }

    return ($packages | Sort-Object -Property Id -Unique)
}

function Resolve-WingetMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $false)][string]$RequestedVersion,
        [Parameter(Mandatory = $true)][bool]$SupportsPkgAgreements
    )

    $args = @("show", $PackageId, "--exact", "--accept-source-agreements")
    if ($SupportsPkgAgreements) { $args += "--accept-package-agreements" }
    if ($RequestedVersion) { $args += @("--version", $RequestedVersion) }
    $result = Invoke-Winget -Arguments $args
    if ($result.ExitCode -ne 0 -and -not ($result.Output | Select-String -Pattern "Found.*\[" -Quiet)) {
        throw "winget show failed for $PackageId (exit $($result.ExitCode))."
    }

    $lines = $result.Output
    $displayName = ($lines | Select-String -Pattern "Found (.+?) \[" | Select-Object -First 1 | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $resolvedId = ($lines | Select-String -Pattern "Found (.+?) \[(.+?)\]" | Select-Object -First 1 | ForEach-Object { $_.Matches[0].Groups[2].Value.Trim() })
    $versionFound = ($lines | Select-String -Pattern "^Version:\s+(.+)$" | Select-Object -First 1 | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $publisher = ($lines | Select-String -Pattern "^Publisher:\s+(.+)$" | Select-Object -First 1 | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    $homepage = ($lines | Select-String -Pattern "^Homepage:\s+(.+)$" | Select-Object -First 1 | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })

    $descriptionLines = @($lines | Select-String -Pattern "^Description:\s+(.+)$" | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
    if ($descriptionLines.Count -eq 0) { $descriptionLines = @("No description available.") }

    return [PSCustomObject]@{
        Id = if ($resolvedId) { $resolvedId } else { $PackageId }
        DisplayName = if ($displayName) { $displayName } else { $PackageId }
        Version = if ($RequestedVersion) { $RequestedVersion } elseif ($versionFound) { $versionFound } else { "Unknown" }
        Publisher = if ($publisher) { $publisher } else { "Unknown" }
        Homepage = if ($homepage) { $homepage } else { "" }
        Description = ($descriptionLines -join " ")
        Raw = $lines
    }
}

function New-ProgressReporter {
    param([bool]$UseGui)

    $state = [PSCustomObject]@{
        Form = $null
        Status = $null
        Progress = $null
        Log = $null
        UseGui = $UseGui
    }

    if ($UseGui) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $form = New-Object System.Windows.Forms.Form
        $form.Text = "Wingetter - Packaging Progress"
        $form.Size = New-Object System.Drawing.Size(760, 460)
        $form.StartPosition = "CenterScreen"
        $form.FormBorderStyle = "FixedDialog"
        $form.MaximizeBox = $false
        $form.ControlBox = $false

        $status = New-Object System.Windows.Forms.Label
        $status.Location = New-Object System.Drawing.Point(14, 12)
        $status.Size = New-Object System.Drawing.Size(715, 36)
        $status.Text = "Starting..."
        $form.Controls.Add($status)

        $bar = New-Object System.Windows.Forms.ProgressBar
        $bar.Location = New-Object System.Drawing.Point(14, 52)
        $bar.Size = New-Object System.Drawing.Size(715, 24)
        $bar.Minimum = 0
        $bar.Maximum = 100
        $form.Controls.Add($bar)

        $log = New-Object System.Windows.Forms.TextBox
        $log.Location = New-Object System.Drawing.Point(14, 90)
        $log.Size = New-Object System.Drawing.Size(715, 315)
        $log.Multiline = $true
        $log.ScrollBars = "Vertical"
        $log.ReadOnly = $true
        $log.Font = New-Object System.Drawing.Font("Consolas", 9)
        $form.Controls.Add($log)

        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()

        $state.Form = $form
        $state.Status = $status
        $state.Progress = $bar
        $state.Log = $log
    }

    return [PSCustomObject]@{
        Update = {
            param([int]$Percent, [string]$StatusText, [string]$LogText)
            $clamped = [Math]::Max(0, [Math]::Min($Percent, 100))
            Write-Host ("[{0}%] {1}" -f $clamped, $StatusText) -ForegroundColor Cyan
            if ($LogText) { Write-Host $LogText }
            if ($state.UseGui -and $state.Form) {
                $state.Progress.Value = $clamped
                $state.Status.Text = $StatusText
                if ($LogText) {
                    $state.Log.AppendText($LogText + [Environment]::NewLine)
                }
                [System.Windows.Forms.Application]::DoEvents()
            } else {
                Write-Progress -Activity "Wingetter packaging" -Status $StatusText -PercentComplete $clamped
            }
        }
        Complete = {
            param([string]$StatusText)
            if ($state.UseGui -and $state.Form) {
                $state.Progress.Value = 100
                $state.Status.Text = $StatusText
                $state.Log.AppendText($StatusText + [Environment]::NewLine)
                [System.Windows.Forms.Application]::DoEvents()
            } else {
                Write-Progress -Activity "Wingetter packaging" -Completed
            }
        }
        Close = {
            if ($state.UseGui -and $state.Form) {
                $state.Form.Close()
                $state.Form.Dispose()
            }
        }
    }
}

function Show-PackagingDialog {
    param(
        [string]$DefaultSearchTerm,
        [string]$DefaultOutputPath,
        [string]$DefaultVersion,
        [string]$DefaultIconPath,
        [string]$DefaultMarkdown
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $supportsPkgAgreements = Test-WingetSupportsPackageAgreement

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Wingetter - Intune Package Builder"
    $form.Size = New-Object System.Drawing.Size(980, 760)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    $searchLabel = New-Object System.Windows.Forms.Label
    $searchLabel.Text = "Search Winget app:"
    $searchLabel.Location = New-Object System.Drawing.Point(15, 16)
    $searchLabel.Size = New-Object System.Drawing.Size(130, 20)
    $form.Controls.Add($searchLabel)

    $searchText = New-Object System.Windows.Forms.TextBox
    $searchText.Location = New-Object System.Drawing.Point(150, 14)
    $searchText.Size = New-Object System.Drawing.Size(650, 24)
    $searchText.Text = $DefaultSearchTerm
    $form.Controls.Add($searchText)

    $searchButton = New-Object System.Windows.Forms.Button
    $searchButton.Text = "Search"
    $searchButton.Location = New-Object System.Drawing.Point(810, 12)
    $searchButton.Size = New-Object System.Drawing.Size(140, 28)
    $form.Controls.Add($searchButton)

    $resultLabel = New-Object System.Windows.Forms.Label
    $resultLabel.Text = "Select package to build:"
    $resultLabel.Location = New-Object System.Drawing.Point(15, 48)
    $resultLabel.Size = New-Object System.Drawing.Size(250, 20)
    $form.Controls.Add($resultLabel)

    $resultsPanel = New-Object System.Windows.Forms.Panel
    $resultsPanel.Location = New-Object System.Drawing.Point(15, 72)
    $resultsPanel.Size = New-Object System.Drawing.Size(935, 240)
    $resultsPanel.AutoScroll = $true
    $resultsPanel.BorderStyle = "FixedSingle"
    $form.Controls.Add($resultsPanel)

    $outputLabel = New-Object System.Windows.Forms.Label
    $outputLabel.Text = "Output destination:"
    $outputLabel.Location = New-Object System.Drawing.Point(15, 328)
    $outputLabel.Size = New-Object System.Drawing.Size(130, 20)
    $form.Controls.Add($outputLabel)

    $outputText = New-Object System.Windows.Forms.TextBox
    $outputText.Location = New-Object System.Drawing.Point(150, 326)
    $outputText.Size = New-Object System.Drawing.Size(650, 24)
    $outputText.Text = $DefaultOutputPath
    $form.Controls.Add($outputText)

    $browseOutputButton = New-Object System.Windows.Forms.Button
    $browseOutputButton.Text = "Browse..."
    $browseOutputButton.Location = New-Object System.Drawing.Point(810, 324)
    $browseOutputButton.Size = New-Object System.Drawing.Size(140, 28)
    $form.Controls.Add($browseOutputButton)

    $versionLabel = New-Object System.Windows.Forms.Label
    $versionLabel.Text = "Version override (optional):"
    $versionLabel.Location = New-Object System.Drawing.Point(15, 362)
    $versionLabel.Size = New-Object System.Drawing.Size(180, 20)
    $form.Controls.Add($versionLabel)

    $versionText = New-Object System.Windows.Forms.TextBox
    $versionText.Location = New-Object System.Drawing.Point(205, 360)
    $versionText.Size = New-Object System.Drawing.Size(220, 24)
    $versionText.Text = $DefaultVersion
    $form.Controls.Add($versionText)

    $iconLabel = New-Object System.Windows.Forms.Label
    $iconLabel.Text = "Icon path (optional):"
    $iconLabel.Location = New-Object System.Drawing.Point(15, 396)
    $iconLabel.Size = New-Object System.Drawing.Size(130, 20)
    $form.Controls.Add($iconLabel)

    $iconText = New-Object System.Windows.Forms.TextBox
    $iconText.Location = New-Object System.Drawing.Point(150, 394)
    $iconText.Size = New-Object System.Drawing.Size(650, 24)
    $iconText.Text = $DefaultIconPath
    $form.Controls.Add($iconText)

    $browseIconButton = New-Object System.Windows.Forms.Button
    $browseIconButton.Text = "Browse..."
    $browseIconButton.Location = New-Object System.Drawing.Point(810, 392)
    $browseIconButton.Size = New-Object System.Drawing.Size(140, 28)
    $form.Controls.Add($browseIconButton)

    $iconPreview = New-Object System.Windows.Forms.PictureBox
    $iconPreview.Location = New-Object System.Drawing.Point(810, 430)
    $iconPreview.Size = New-Object System.Drawing.Size(140, 140)
    $iconPreview.SizeMode = "Zoom"
    $iconPreview.BorderStyle = "FixedSingle"
    $form.Controls.Add($iconPreview)

    $mdLabel = New-Object System.Windows.Forms.Label
    $mdLabel.Text = "Description / notes (Markdown, optional):"
    $mdLabel.Location = New-Object System.Drawing.Point(15, 430)
    $mdLabel.Size = New-Object System.Drawing.Size(320, 20)
    $form.Controls.Add($mdLabel)

    $mdText = New-Object System.Windows.Forms.TextBox
    $mdText.Location = New-Object System.Drawing.Point(15, 454)
    $mdText.Size = New-Object System.Drawing.Size(785, 182)
    $mdText.Multiline = $true
    $mdText.ScrollBars = "Vertical"
    $mdText.Text = $DefaultMarkdown
    $form.Controls.Add($mdText)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "Search for a package and choose one radio option."
    $statusLabel.Location = New-Object System.Drawing.Point(15, 644)
    $statusLabel.Size = New-Object System.Drawing.Size(785, 28)
    $statusLabel.ForeColor = [System.Drawing.Color]::DarkSlateGray
    $form.Controls.Add($statusLabel)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "Create package"
    $okButton.Location = New-Object System.Drawing.Point(640, 674)
    $okButton.Size = New-Object System.Drawing.Size(160, 34)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object System.Drawing.Point(810, 674)
    $cancelButton.Size = New-Object System.Drawing.Size(140, 34)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $selectedCandidates = @()

    $refreshPreview = {
        if (Test-Path $iconText.Text) {
            try {
                if ($iconPreview.Image) {
                    $iconPreview.Image.Dispose()
                    $iconPreview.Image = $null
                }
                $iconPreview.Image = [System.Drawing.Image]::FromFile($iconText.Text)
            } catch {
                $iconPreview.Image = $null
            }
        } else {
            $iconPreview.Image = $null
        }
    }

    $renderCandidates = {
        param($candidates)
        $resultsPanel.Controls.Clear()
        $selectedCandidates = $candidates
        $y = 8
        foreach ($candidate in $candidates) {
            $rb = New-Object System.Windows.Forms.RadioButton
            $rb.Text = "{0} | {1} | {2}" -f $candidate.Name, $candidate.Id, $candidate.Version
            $rb.Tag = $candidate
            $rb.Location = New-Object System.Drawing.Point(10, $y)
            $rb.Size = New-Object System.Drawing.Size(900, 24)
            $resultsPanel.Controls.Add($rb)
            $y += 28
        }
        if ($resultsPanel.Controls.Count -gt 0) {
            $resultsPanel.Controls[0].Checked = $true
            $statusLabel.Text = "Select one app via radio button and click Create package."
        } else {
            $statusLabel.Text = "No package results found. Try a different search term."
        }
    }

    $searchAction = {
        try {
            $term = $searchText.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($term)) {
                [System.Windows.Forms.MessageBox]::Show("Enter a search value first.", "Wingetter")
                return
            }
            $statusLabel.Text = "Searching winget..."
            [System.Windows.Forms.Application]::DoEvents()

            $args = @("search", $term, "--accept-source-agreements")
            if ($supportsPkgAgreements) { $args += "--accept-package-agreements" }
            $searchResult = Invoke-Winget -Arguments $args
            $candidates = Parse-WingetSearchResults -SearchOutput $searchResult.Output
            & $renderCandidates $candidates
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Search failed: $($_.Exception.Message)", "Wingetter")
            $statusLabel.Text = "Search failed. Check winget availability."
        }
    }

    $searchButton.Add_Click($searchAction)
    $browseOutputButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $outputText.Text = $dialog.SelectedPath
        }
    })
    $browseIconButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = "Image Files|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.ico"
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $iconText.Text = $dialog.FileName
            & $refreshPreview
        }
    })
    $iconText.Add_TextChanged({ & $refreshPreview })

    $form.Add_Shown({
        if ($searchText.Text) {
            & $searchAction
        }
        & $refreshPreview
    })

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    $selected = $null
    foreach ($control in $resultsPanel.Controls) {
        if ($control -is [System.Windows.Forms.RadioButton] -and $control.Checked) {
            $selected = $control.Tag
            break
        }
    }
    if (-not $selected) {
        [System.Windows.Forms.MessageBox]::Show("Please select a package option.", "Wingetter")
        return $null
    }

    return [PSCustomObject]@{
        SearchTerm = $searchText.Text.Trim()
        Package = $selected
        OutputPath = $outputText.Text.Trim()
        Version = $versionText.Text.Trim()
        IconPath = $iconText.Text.Trim()
        DescriptionMarkdown = $mdText.Text
        UseGuiProgress = $true
        SupportsPkgAgreements = $supportsPkgAgreements
    }
}

function New-ScriptTemplates {
    param(
        [string]$PackageId,
        [string]$DisplayName,
        [string]$Version,
        [string]$InstallerFileName,
        [string]$InstallCommand
    )

    $installScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$logPath = Join-Path `$env:ProgramData "Microsoft\IntuneManagementExtension\Logs\$PackageId-install.log"
Start-Transcript -Path `$logPath -Force
try {
    Write-Host "Installing $DisplayName ($Version)"
    `$installer = Join-Path `$PSScriptRoot "$InstallerFileName"
    if (-not (Test-Path `$installer)) { throw "Installer not found: `$installer" }
    Write-Host "Running command: $InstallCommand"
    `$process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $InstallCommand" -PassThru -Wait -NoNewWindow
    if (`$process.ExitCode -in @(0,3010,1641)) {
        Write-Host "Install completed with accepted code: `$(`$process.ExitCode)"
        exit `$process.ExitCode
    }
    throw "Installer returned exit code `$(`$process.ExitCode)"
} catch {
    Write-Error `$_.Exception.Message
    exit 1
} finally {
    Stop-Transcript
}
"@

    $uninstallScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$logPath = Join-Path `$env:ProgramData "Microsoft\IntuneManagementExtension\Logs\$PackageId-uninstall.log"
Start-Transcript -Path `$logPath -Force
try {
    `$registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    `$entry = `$null
    foreach (`$path in `$registryPaths) {
        `$entry = Get-ItemProperty `$path -ErrorAction SilentlyContinue | Where-Object {
            (`$_.DisplayName -like "*$DisplayName*") -or (`$_.PSChildName -like "*$PackageId*")
        } | Select-Object -First 1
        if (`$entry) { break }
    }
    if (-not `$entry) { throw "No uninstall entry found for $DisplayName" }
    `$cmd = if (`$entry.QuietUninstallString) { `$entry.QuietUninstallString } else { `$entry.UninstallString }
    if (-not `$cmd) { throw "Uninstall command not found in registry entry" }
    Write-Host "Running uninstall command: `$cmd"
    `$process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `$cmd" -PassThru -Wait -NoNewWindow
    if (`$process.ExitCode -in @(0,3010,1641)) {
        exit `$process.ExitCode
    }
    throw "Uninstall exited with `$(`$process.ExitCode)"
} catch {
    Write-Error `$_.Exception.Message
    exit 1
} finally {
    Stop-Transcript
}
"@

    $detectionScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$logPath = Join-Path `$env:ProgramData "Microsoft\IntuneManagementExtension\Logs\$PackageId-detection.log"
Start-Transcript -Path `$logPath -Force
try {
    `$expectedVersion = "$Version"
    `$registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    `$matches = foreach (`$path in `$registryPaths) {
        Get-ItemProperty `$path -ErrorAction SilentlyContinue | Where-Object {
            (`$_.DisplayName -like "*$DisplayName*") -or (`$_.PSChildName -like "*$PackageId*")
        }
    }

    if (-not `$matches) {
        Write-Host "App not detected."
        exit 1
    }

    `$installed = `$matches | Sort-Object {
        try { [version]`$_.DisplayVersion } catch { [version]"0.0.0.0" }
    } -Descending | Select-Object -First 1

    `$installedVersion = `$installed.DisplayVersion
    if (-not `$installedVersion) {
        Write-Host "Installed entry found without DisplayVersion. Marking detected."
        exit 0
    }

    try {
        if ([version]`$installedVersion -ge [version]`$expectedVersion) {
            Write-Host "Detected version `$installedVersion (expected `$expectedVersion)."
            exit 0
        }
    } catch {
        if (`$installedVersion -eq `$expectedVersion) { exit 0 }
    }

    Write-Host "Detected version `$installedVersion is below expected `$expectedVersion."
    exit 1
} catch {
    Write-Error `$_.Exception.Message
    exit 1
} finally {
    Stop-Transcript
}
"@

    return [PSCustomObject]@{
        Install = $installScript
        Uninstall = $uninstallScript
        Detection = $detectionScript
    }
}

function Write-IntuneMarkdownReadme {
    param(
        [string]$Path,
        [hashtable]$AppJson,
        [hashtable]$Win32Json,
        [string]$DescriptionMarkdown
    )

    $fields = @(
        "displayName", "description", "publisher", "developer", "informationUrl", "displayVersion", "installCommandLine",
        "uninstallCommandLine", "fileName", "setupFilePath", "allowAvailableUninstall", "applicableArchitectures",
        "minimumSupportedWindowsRelease", "notes"
    )

    $lines = @(
        "# Intune Win32 Upload Package",
        "",
        "## Application Summary",
        ("- **Display Name:** {0}" -f $Win32Json.displayName),
        ("- **Package Identifier:** {0}" -f $AppJson.packageIdentifier),
        ("- **Version:** {0}" -f $Win32Json.displayVersion),
        ("- **Developer:** {0}" -f $Win32Json.developer),
        ("- **Publisher:** {0}" -f $Win32Json.publisher),
        "",
        "## Markdown Description",
        ""
    )

    if ($DescriptionMarkdown) {
        $lines += $DescriptionMarkdown
    } else {
        $lines += $Win32Json.description
    }

    $lines += @("", "## Intune Upload Field Reference", "", "| Field | Value |", "|---|---|")
    foreach ($field in $fields) {
        $value = if ($Win32Json.ContainsKey($field)) { $Win32Json[$field] } else { "" }
        if ($null -eq $value) { $value = "" }
        if ($value -is [System.Array] -or $value -is [hashtable]) {
            $value = ($value | ConvertTo-Json -Depth 8 -Compress)
        }
        $value = [string]$value -replace "\|", "\|"
        $lines += ("| {0} | {1} |" -f $field, $value)
    }

    $lines += @("", "## Files Generated", "", "- install.ps1", "- uninstall.ps1", "- detection.ps1", "- app.json", "- win32LobApp.json")
    $lines | Set-Content -Path $Path -Encoding UTF8
}

function Start-WingetDownload {
    param(
        [string]$PackageId,
        [string]$DownloadDirectory,
        [bool]$SupportsPkgAgreements,
        [scriptblock]$ProgressUpdate
    )

    $args = @("download", $PackageId, "--exact", "--download-directory", $DownloadDirectory, "--accept-source-agreements")
    if ($SupportsPkgAgreements) { $args += "--accept-package-agreements" }

    & $ProgressUpdate 30 "Downloading installer from winget..." "Running winget download for $PackageId"
    $result = Invoke-Winget -Arguments $args
    if ($result.ExitCode -ne 0) {
        throw "winget download failed for $PackageId (exit $($result.ExitCode))."
    }
}

function Get-InstallerFile {
    param([string]$Directory)
    return Get-ChildItem -Path $Directory -File -ErrorAction Stop |
        Where-Object { $_.Extension.ToLower() -in @(".exe", ".msi", ".msix", ".appx") } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-InstallCommandForInstaller {
    param([string]$InstallerFileName)
    $ext = [System.IO.Path]::GetExtension($InstallerFileName).ToLowerInvariant()
    switch ($ext) {
        ".msi" { return "msiexec /i `"$InstallerFileName`" /qn /norestart" }
        ".msix" { return "powershell.exe -ExecutionPolicy Bypass -Command `"Add-AppxPackage -Path '$InstallerFileName'`"" }
        ".appx" { return "powershell.exe -ExecutionPolicy Bypass -Command `"Add-AppxPackage -Path '$InstallerFileName'`"" }
        default { return "`"$InstallerFileName`" /S" }
    }
}

function Build-Package {
    param(
        [Parameter(Mandatory = $true)]$UserSelection,
        [Parameter(Mandatory = $true)]$ProgressReporter
    )

    $supportsPkgAgreements = $UserSelection.SupportsPkgAgreements
    $package = $UserSelection.Package
    $outputRoot = $UserSelection.OutputPath
    if (-not (Test-Path $outputRoot)) {
        New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    }

    $runLogPath = Join-Path $outputRoot ("wingetter-run-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

    try {
        & $ProgressReporter.Update 5 "Resolving package metadata..." "Selected package: $($package.Id)"
        $meta = Resolve-WingetMetadata -PackageId $package.Id -RequestedVersion $UserSelection.Version -SupportsPkgAgreements $supportsPkgAgreements

        $packageDirectory = Join-Path $outputRoot $meta.Id
        $versionDirectory = Join-Path $packageDirectory $meta.Version
        New-Item -ItemType Directory -Path $versionDirectory -Force | Out-Null
        & $ProgressReporter.Update 15 "Created output folder structure." "Output: $versionDirectory"

        Start-WingetDownload -PackageId $meta.Id -DownloadDirectory $versionDirectory -SupportsPkgAgreements $supportsPkgAgreements -ProgressUpdate $ProgressReporter.Update
        $installer = Get-InstallerFile -Directory $versionDirectory
        if (-not $installer) { throw "No installer file found after winget download." }
        & $ProgressReporter.Update 45 "Installer downloaded." $installer.Name

        $installCommand = Get-InstallCommandForInstaller -InstallerFileName $installer.Name
        $hash = (Get-FileHash -Path $installer.FullName -Algorithm SHA256).Hash
        & $ProgressReporter.Update 52 "Installer hash calculated." $hash

        $iconPathInOutput = Join-Path $versionDirectory "icon.png"
        if ($UserSelection.IconPath -and (Test-Path $UserSelection.IconPath)) {
            Copy-Item -Path $UserSelection.IconPath -Destination $iconPathInOutput -Force
            & $ProgressReporter.Update 58 "Icon copied and preview-ready." $iconPathInOutput
        } else {
            & $ProgressReporter.Update 58 "No custom icon selected." "Proceeding without icon."
        }

        $scripts = New-ScriptTemplates -PackageId $meta.Id -DisplayName $meta.DisplayName -Version $meta.Version -InstallerFileName $installer.Name -InstallCommand $installCommand
        $scripts.Install | Set-Content -Path (Join-Path $versionDirectory "install.ps1") -Encoding UTF8
        $scripts.Uninstall | Set-Content -Path (Join-Path $versionDirectory "uninstall.ps1") -Encoding UTF8
        $scripts.Detection | Set-Content -Path (Join-Path $versionDirectory "detection.ps1") -Encoding UTF8
        & $ProgressReporter.Update 68 "Generated install/uninstall/detection scripts." "Intune script set ready."

        $iconBase64 = ""
        if (Test-Path $iconPathInOutput) {
            $iconBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($iconPathInOutput))
        }

        $descriptionText = if ($UserSelection.DescriptionMarkdown) { $UserSelection.DescriptionMarkdown } else { $meta.Description }
        $uninstallCommand = "%windir%\sysnative\windowspowershell\v1.0\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File uninstall.ps1"
        $installEntry = "%windir%\sysnative\windowspowershell\v1.0\powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File install.ps1"

        $appJson = @{
            packageIdentifier = $meta.Id
            displayName = $meta.DisplayName
            description = $descriptionText
            version = $meta.Version
            source = 2
            publisher = $meta.Publisher
            informationUrl = $meta.Homepage
            publisherUrl = $meta.Homepage
            supportUrl = $meta.Homepage
            installerType = 7
            installerUrl = ""
            hash = $hash
            installCommandLine = $installEntry
            uninstallCommandLine = $uninstallCommand
            installerFilename = $installer.Name
            installerContext = 2
            architecture = 2
        }
        $appJson | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $versionDirectory "app.json") -Encoding UTF8

        $detectionScriptBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($scripts.Detection))
        $win32 = @{
            "@odata.type" = "#microsoft.graph.win32LobApp"
            description = $descriptionText
            developer = $meta.Publisher
            displayName = $meta.DisplayName
            informationUrl = $meta.Homepage
            notes = "Generated by Wingetter at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [Winget|$($meta.Id)]"
            publisher = $meta.Publisher
            fileName = "$($installer.BaseName).intunewin"
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
            displayVersion = $meta.Version
            installCommandLine = $installEntry
            installExperience = @{
                deviceRestartBehavior = "basedOnReturnCode"
                runAsAccount = "system"
            }
            minimumSupportedOperatingSystem = @{ v10_2004 = $true }
            minimumSupportedWindowsRelease = "2004"
            returnCodes = @(
                @{ returnCode = 0; type = "success" }
                @{ returnCode = 1707; type = "success" }
                @{ returnCode = 3010; type = "softReboot" }
                @{ returnCode = 1641; type = "hardReboot" }
                @{ returnCode = 1618; type = "retry" }
            )
            setupFilePath = $installer.Name
            uninstallCommandLine = $uninstallCommand
        }
        if ($iconBase64) {
            $win32.largeIcon = @{ type = "image/png"; value = $iconBase64 }
        }
        $win32 | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $versionDirectory "win32LobApp.json") -Encoding UTF8
        & $ProgressReporter.Update 80 "Generated JSON metadata artifacts." "app.json and win32LobApp.json complete."

        Write-IntuneMarkdownReadme -Path (Join-Path $versionDirectory "README.md") -AppJson $appJson -Win32Json $win32 -DescriptionMarkdown $UserSelection.DescriptionMarkdown
        & $ProgressReporter.Update 86 "Created README.md with full Intune fields." "README includes upload mapping and markdown description."

        & $ProgressReporter.Update 92 "Running Content Prep Tool..." "Checking intunewinapputil availability."
        if (-not (Get-Command intunewinapputil -ErrorAction SilentlyContinue)) {
            throw "intunewinapputil not found in PATH."
        }
        $intuneOutputDirectory = Split-Path $versionDirectory -Parent
        $intuneWinFile = Join-Path $intuneOutputDirectory "$($installer.BaseName).intunewin"
        if (Test-Path $intuneWinFile) { Remove-Item -Path $intuneWinFile -Force }
        & intunewinapputil -c $versionDirectory -s $installer.Name -o $intuneOutputDirectory -q
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $intuneWinFile)) {
            throw "intunewinapputil failed to produce output."
        }

        $runSummary = @(
            "Success at $(Get-Date -Format s)",
            "Package: $($meta.DisplayName)",
            "PackageId: $($meta.Id)",
            "Version: $($meta.Version)",
            "Output: $versionDirectory",
            "IntuneWin: $intuneWinFile"
        )
        $runSummary | Set-Content -Path $runLogPath -Encoding UTF8
        & $ProgressReporter.Complete "Packaging complete."

        return [PSCustomObject]@{
            Metadata = $meta
            VersionDirectory = $versionDirectory
            IntuneWinFile = $intuneWinFile
            RunLog = $runLogPath
            Success = $true
        }
    } catch {
        $failureMessage = "Failure at $(Get-Date -Format s): $($_.Exception.Message)"
        $failureLog = Join-Path $outputRoot "run-failure.log"
        $failureMessage | Set-Content -Path $failureLog -Encoding UTF8
        Add-Content -Path $runLogPath -Value $failureMessage
        & $ProgressReporter.Update 100 "Packaging failed." $failureMessage
        throw
    }
}

try {
    $useGui = -not $NoGui.IsPresent -and -not $AppName
    $supportsPkgAgreements = Test-WingetSupportsPackageAgreement

    if ($useGui) {
        $selection = Show-PackagingDialog -DefaultSearchTerm $AppName -DefaultOutputPath $OutputPath -DefaultVersion $Version -DefaultIconPath $IconPath -DefaultMarkdown $DescriptionMarkdown
        if (-not $selection) {
            Write-Host "Operation cancelled by user." -ForegroundColor Yellow
            exit 1
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($AppName)) {
            throw "When -NoGui is used, -AppName is required."
        }
        Write-Step "Searching package candidates for '$AppName'"
        $searchArgs = @("search", $AppName, "--accept-source-agreements")
        if ($supportsPkgAgreements) { $searchArgs += "--accept-package-agreements" }
        $searchResult = Invoke-Winget -Arguments $searchArgs
        $candidates = Parse-WingetSearchResults -SearchOutput $searchResult.Output
        if (-not $candidates -or $candidates.Count -eq 0) { throw "No package candidates found for '$AppName'." }
        $selected = $candidates | Where-Object { $_.Id -ieq $AppName } | Select-Object -First 1
        if (-not $selected) { $selected = $candidates[0] }

        $selection = [PSCustomObject]@{
            SearchTerm = $AppName
            Package = $selected
            OutputPath = $OutputPath
            Version = $Version
            IconPath = $IconPath
            DescriptionMarkdown = $DescriptionMarkdown
            UseGuiProgress = $false
            SupportsPkgAgreements = $supportsPkgAgreements
        }
    }

    $progress = New-ProgressReporter -UseGui $selection.UseGuiProgress
    try {
        $result = Build-Package -UserSelection $selection -ProgressReporter $progress
        Write-Success "Package created for $($result.Metadata.DisplayName) $($result.Metadata.Version)"
        Write-Success "Version output: $($result.VersionDirectory)"
        Write-Success "IntuneWin file: $($result.IntuneWinFile)"
    } finally {
        Start-Sleep -Milliseconds 400
        & $progress.Close
    }
} catch {
    Write-ErrorMessage $_.Exception.Message
    exit 1
}
