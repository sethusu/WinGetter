<#
.SYNOPSIS
    Wingetter graphical user interface for creating Intune Win32 packages from Winget.
.DESCRIPTION
    Provides a WinForms GUI with:
    - Winget search dialog with radio-button package selection
    - Output destination folder picker
    - Live progress tracking
    - Application icon preview
    - One-click packaging via Wingetter.Core module
.EXAMPLE
    .\Show-WingetterGui.ps1
#>

#Requires -Version 5.1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$modulePath = Join-Path $PSScriptRoot 'Wingetter.Core.psm1'
if (-not (Test-Path $modulePath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Wingetter.Core.psm1 not found at:`n$modulePath",
        'Wingetter Error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

Import-Module $modulePath -Force

function Show-WingetterSearchDialog {
    param(
        [Parameter(Mandatory)]
        [array]$Packages
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Wingetter - Select Package'
    $form.Size = New-Object System.Drawing.Size(620, [Math]::Min(520, 160 + ($Packages.Count * 72)))
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $header = New-Object System.Windows.Forms.Label
    $header.Text = "Found $($Packages.Count) matching package(s). Select the application to pack:"
    $header.Location = New-Object System.Drawing.Point(16, 12)
    $header.Size = New-Object System.Drawing.Size(560, 24)
    $form.Controls.Add($header)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(12, 40)
    $panel.Size = New-Object System.Drawing.Size(580, [Math]::Min(320, $Packages.Count * 72 + 8))
    $panel.AutoScroll = $true
    $panel.BorderStyle = 'FixedSingle'
    $form.Controls.Add($panel)

    $radioButtons = @()
    $y = 8

    for ($i = 0; $i -lt $Packages.Count; $i++) {
        $pkg = $Packages[$i]

        $radio = New-Object System.Windows.Forms.RadioButton
        $radio.Location = New-Object System.Drawing.Point(12, $y)
        $radio.Size = New-Object System.Drawing.Size(540, 20)
        $radio.Text = $pkg.Name
        $radio.Tag = $pkg
        if ($i -eq 0) { $radio.Checked = $true }
        $panel.Controls.Add($radio)
        $radioButtons += $radio

        $detail = New-Object System.Windows.Forms.Label
        $detail.Location = New-Object System.Drawing.Point(32, ($y + 22))
        $detail.Size = New-Object System.Drawing.Size(520, 36)
        $detail.Text = "ID: $($pkg.Id)`nVersion: $($pkg.Version)"
        $detail.ForeColor = [System.Drawing.Color]::DimGray
        $panel.Controls.Add($detail)

        $y += 72
    }

    $buttonPanelY = $panel.Bottom + 12

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'Select'
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okButton.Location = New-Object System.Drawing.Point(400, $buttonPanelY)
    $okButton.Size = New-Object System.Drawing.Size(90, 30)
    $form.Controls.Add($okButton)
    $form.AcceptButton = $okButton

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = New-Object System.Drawing.Point(500, $buttonPanelY)
    $cancelButton.Size = New-Object System.Drawing.Size(90, 30)
    $form.Controls.Add($cancelButton)
    $form.CancelButton = $cancelButton

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $selected = $radioButtons | Where-Object { $_.Checked } | Select-Object -First 1
    if ($selected) { return $selected.Tag }
    return $null
}

function Show-WingetterMainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Wingetter - Intune Win32 Package Creator'
    $form.Size = New-Object System.Drawing.Size(900, 720)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(820, 620)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    # --- Search section ---
    $searchGroup = New-Object System.Windows.Forms.GroupBox
    $searchGroup.Text = 'Search Winget'
    $searchGroup.Location = New-Object System.Drawing.Point(12, 12)
    $searchGroup.Size = New-Object System.Drawing.Size(860, 88)
    $form.Controls.Add($searchGroup)

    $searchHint = New-Object System.Windows.Forms.Label
    $searchHint.Location = New-Object System.Drawing.Point(16, 28)
    $searchHint.Size = New-Object System.Drawing.Size(620, 16)
    $searchHint.Text = 'Enter app name or Winget package ID (e.g. Google.Chrome)'
    $searchHint.ForeColor = [System.Drawing.Color]::Gray
    $searchGroup.Controls.Add($searchHint)

    $searchBox = New-Object System.Windows.Forms.TextBox
    $searchBox.Location = New-Object System.Drawing.Point(16, 46)
    $searchBox.Size = New-Object System.Drawing.Size(620, 24)
    $searchGroup.Controls.Add($searchBox)

    $searchButton = New-Object System.Windows.Forms.Button
    $searchButton.Text = 'Search'
    $searchButton.Location = New-Object System.Drawing.Point(648, 44)
    $searchButton.Size = New-Object System.Drawing.Size(90, 28)
    $searchGroup.Controls.Add($searchButton)

    $clearButton = New-Object System.Windows.Forms.Button
    $clearButton.Text = 'Clear'
    $clearButton.Location = New-Object System.Drawing.Point(748, 44)
    $clearButton.Size = New-Object System.Drawing.Size(90, 28)
    $searchGroup.Controls.Add($clearButton)

    # --- Selected app section ---
    $appGroup = New-Object System.Windows.Forms.GroupBox
    $appGroup.Text = 'Selected Application'
    $appGroup.Location = New-Object System.Drawing.Point(12, 108)
    $appGroup.Size = New-Object System.Drawing.Size(560, 120)
    $form.Controls.Add($appGroup)

    $appNameLabel = New-Object System.Windows.Forms.Label
    $appNameLabel.Location = New-Object System.Drawing.Point(16, 28)
    $appNameLabel.Size = New-Object System.Drawing.Size(520, 22)
    $appNameLabel.Text = 'No application selected'
    $appNameLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $appGroup.Controls.Add($appNameLabel)

    $appDetailLabel = New-Object System.Windows.Forms.Label
    $appDetailLabel.Location = New-Object System.Drawing.Point(16, 54)
    $appDetailLabel.Size = New-Object System.Drawing.Size(520, 52)
    $appDetailLabel.Text = 'Search for an application above to begin.'
    $appGroup.Controls.Add($appDetailLabel)

    # --- Icon preview ---
    $iconGroup = New-Object System.Windows.Forms.GroupBox
    $iconGroup.Text = 'Icon Preview'
    $iconGroup.Location = New-Object System.Drawing.Point(584, 108)
    $iconGroup.Size = New-Object System.Drawing.Size(288, 120)
    $form.Controls.Add($iconGroup)

    $iconPicture = New-Object System.Windows.Forms.PictureBox
    $iconPicture.Location = New-Object System.Drawing.Point(16, 24)
    $iconPicture.Size = New-Object System.Drawing.Size(72, 72)
    $iconPicture.SizeMode = 'Zoom'
    $iconPicture.BorderStyle = 'FixedSingle'
    $iconGroup.Controls.Add($iconPicture)

    $iconStatusLabel = New-Object System.Windows.Forms.Label
    $iconStatusLabel.Location = New-Object System.Drawing.Point(100, 40)
    $iconStatusLabel.Size = New-Object System.Drawing.Size(170, 40)
    $iconStatusLabel.Text = 'Icon will appear after packaging or when a custom icon is chosen.'
    $iconGroup.Controls.Add($iconStatusLabel)

    $browseIconButton = New-Object System.Windows.Forms.Button
    $browseIconButton.Text = 'Browse Icon...'
    $browseIconButton.Location = New-Object System.Drawing.Point(100, 82)
    $browseIconButton.Size = New-Object System.Drawing.Size(120, 26)
    $iconGroup.Controls.Add($browseIconButton)

    # --- Output destination ---
    $outputGroup = New-Object System.Windows.Forms.GroupBox
    $outputGroup.Text = 'Output Destination'
    $outputGroup.Location = New-Object System.Drawing.Point(12, 236)
    $outputGroup.Size = New-Object System.Drawing.Size(860, 72)
    $form.Controls.Add($outputGroup)

    $defaultOutput = Join-Path $env:USERPROFILE 'Documents\Wingetter Output'
    $outputBox = New-Object System.Windows.Forms.TextBox
    $outputBox.Location = New-Object System.Drawing.Point(16, 28)
    $outputBox.Size = New-Object System.Drawing.Size(700, 24)
    $outputBox.Text = $defaultOutput
    $outputGroup.Controls.Add($outputBox)

    $browseOutputButton = New-Object System.Windows.Forms.Button
    $browseOutputButton.Text = 'Browse...'
    $browseOutputButton.Location = New-Object System.Drawing.Point(728, 26)
    $browseOutputButton.Size = New-Object System.Drawing.Size(110, 28)
    $outputGroup.Controls.Add($browseOutputButton)

    # --- Version override ---
    $versionLabel = New-Object System.Windows.Forms.Label
    $versionLabel.Text = 'Version override (optional):'
    $versionLabel.Location = New-Object System.Drawing.Point(28, 318)
    $versionLabel.Size = New-Object System.Drawing.Size(180, 20)
    $form.Controls.Add($versionLabel)

    $versionBox = New-Object System.Windows.Forms.TextBox
    $versionBox.Location = New-Object System.Drawing.Point(210, 316)
    $versionBox.Size = New-Object System.Drawing.Size(160, 24)
    $form.Controls.Add($versionBox)

    # --- Progress ---
    $progressGroup = New-Object System.Windows.Forms.GroupBox
    $progressGroup.Text = 'Progress'
    $progressGroup.Location = New-Object System.Drawing.Point(12, 348)
    $progressGroup.Size = New-Object System.Drawing.Size(860, 88)
    $form.Controls.Add($progressGroup)

    $stepLabel = New-Object System.Windows.Forms.Label
    $stepLabel.Location = New-Object System.Drawing.Point(16, 24)
    $stepLabel.Size = New-Object System.Drawing.Size(820, 20)
    $stepLabel.Text = 'Ready'
    $progressGroup.Controls.Add($stepLabel)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(16, 48)
    $progressBar.Size = New-Object System.Drawing.Size(820, 24)
    $progressBar.Style = 'Continuous'
    $progressGroup.Controls.Add($progressBar)

    # --- Log output ---
    $logGroup = New-Object System.Windows.Forms.GroupBox
    $logGroup.Text = 'Activity Log'
    $logGroup.Location = New-Object System.Drawing.Point(12, 444)
    $logGroup.Size = New-Object System.Drawing.Size(860, 180)
    $form.Controls.Add($logGroup)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = New-Object System.Drawing.Point(16, 24)
    $logBox.Size = New-Object System.Drawing.Size(820, 140)
    $logBox.Multiline = $true
    $logBox.ScrollBars = 'Vertical'
    $logBox.ReadOnly = $true
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $logGroup.Controls.Add($logBox)

    # --- Action buttons ---
    $packButton = New-Object System.Windows.Forms.Button
    $packButton.Text = 'Pack for Intune'
    $packButton.Location = New-Object System.Drawing.Point(12, 636)
    $packButton.Size = New-Object System.Drawing.Size(140, 34)
    $packButton.Enabled = $false
    $packButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($packButton)

    $openFolderButton = New-Object System.Windows.Forms.Button
    $openFolderButton.Text = 'Open Output Folder'
    $openFolderButton.Location = New-Object System.Drawing.Point(162, 636)
    $openFolderButton.Size = New-Object System.Drawing.Size(150, 34)
    $openFolderButton.Enabled = $false
    $form.Controls.Add($openFolderButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close'
    $closeButton.Location = New-Object System.Drawing.Point(772, 636)
    $closeButton.Size = New-Object System.Drawing.Size(100, 34)
    $form.Controls.Add($closeButton)

    # --- State ---
    $script:SelectedPackage = $null
    $script:CustomIconPath = $null
    $script:LastOutputDirectory = $null
    $script:IsRunning = $false

    function Add-LogMessage {
        param([string]$Message)
        $timestamp = Get-Date -Format 'HH:mm:ss'
        $logBox.AppendText("[$timestamp] $Message`r`n")
        $logBox.SelectionStart = $logBox.Text.Length
        $logBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }

    function Set-UiRunning {
        param([bool]$Running)
        $script:IsRunning = $Running
        $searchButton.Enabled = -not $Running
        $packButton.Enabled = (-not $Running) -and ($null -ne $script:SelectedPackage)
        $searchBox.Enabled = -not $Running
        $browseOutputButton.Enabled = -not $Running
        $browseIconButton.Enabled = -not $Running
        $clearButton.Enabled = -not $Running
    }

    function Update-IconPreview {
        param([string]$IconPath)

        if ($IconPath -and (Test-Path $IconPath)) {
            try {
                $img = [System.Drawing.Image]::FromFile($IconPath)
                $iconPicture.Image = $img
                $iconStatusLabel.Text = "Icon loaded:`n$(Split-Path $IconPath -Leaf)"
            }
            catch {
                $iconStatusLabel.Text = 'Could not load icon preview.'
            }
        }
    }

    $searchButton.Add_Click({
        if ($script:IsRunning) { return }
        $term = $searchBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($term)) {
            [System.Windows.Forms.MessageBox]::Show('Enter an application name or Winget package ID to search.', 'Wingetter', 'OK', 'Warning') | Out-Null
            return
        }

        Set-UiRunning -Running $true
        Add-LogMessage "Searching Winget for: $term"
        $stepLabel.Text = 'Searching...'
        $progressBar.Value = 5

        try {
            $packages = Search-WingetPackage -SearchTerm $term -ProgressCallback {
                param($Percent, $Status, $Step)
                $progressBar.Value = [Math]::Min(100, [Math]::Max(0, $Percent))
                $stepLabel.Text = $Status
                [System.Windows.Forms.Application]::DoEvents()
            }

            Add-LogMessage "Found $($packages.Count) package(s)."

            if ($packages.Count -eq 1) {
                $script:SelectedPackage = $packages[0]
            }
            else {
                $script:SelectedPackage = Show-WingetterSearchDialog -Packages $packages
            }

            if ($script:SelectedPackage) {
                $appNameLabel.Text = $script:SelectedPackage.Name
                $appDetailLabel.Text = "Package ID: $($script:SelectedPackage.Id)`r`nVersion: $($script:SelectedPackage.Version)"
                $versionBox.Text = $script:SelectedPackage.Version
                Add-LogMessage "Selected: $($script:SelectedPackage.Name) ($($script:SelectedPackage.Id))"
                $packButton.Enabled = $true
            }
            else {
                Add-LogMessage 'Package selection cancelled.'
            }
        }
        catch {
            Add-LogMessage "Search failed: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Search Failed', 'OK', 'Error') | Out-Null
        }
        finally {
            $progressBar.Value = 0
            $stepLabel.Text = 'Ready'
            Set-UiRunning -Running $false
        }
    })

    $clearButton.Add_Click({
        if ($script:IsRunning) { return }
        $script:SelectedPackage = $null
        $script:CustomIconPath = $null
        $appNameLabel.Text = 'No application selected'
        $appDetailLabel.Text = 'Search for an application above to begin.'
        $versionBox.Text = ''
        $iconPicture.Image = $null
        $iconStatusLabel.Text = 'Icon will appear after packaging or when a custom icon is chosen.'
        $packButton.Enabled = $false
        $openFolderButton.Enabled = $false
        Add-LogMessage 'Selection cleared.'
    })

    $browseOutputButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Select output destination for Intune packages'
        $dialog.SelectedPath = $outputBox.Text
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $outputBox.Text = $dialog.SelectedPath
            Add-LogMessage "Output path set to: $($dialog.SelectedPath)"
        }
    })

    $browseIconButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Image Files|*.png;*.jpg;*.jpeg;*.ico;*.bmp|All Files|*.*'
        $dialog.Title = 'Select application icon'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:CustomIconPath = $dialog.FileName
            Update-IconPreview -IconPath $script:CustomIconPath
            Add-LogMessage "Custom icon selected: $($dialog.FileName)"
        }
    })

    $packButton.Add_Click({
        if ($script:IsRunning -or -not $script:SelectedPackage) { return }

        $outputPath = $outputBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($outputPath)) {
            [System.Windows.Forms.MessageBox]::Show('Select an output destination.', 'Wingetter', 'OK', 'Warning') | Out-Null
            return
        }

        if (-not (Test-Path $outputPath)) {
            try {
                New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show("Cannot create output directory: $outputPath", 'Wingetter', 'OK', 'Error') | Out-Null
                return
            }
        }

        Set-UiRunning -Running $true
        $openFolderButton.Enabled = $false
        $progressBar.Value = 0
        Add-LogMessage "Starting packaging for $($script:SelectedPackage.Id)..."

        $versionOverride = $versionBox.Text.Trim()
        $packageId = $script:SelectedPackage.Id
        $displayName = $script:SelectedPackage.Name
        $iconPath = $script:CustomIconPath

        try {
            $result = Invoke-WingetterPackage `
                -PackageId $packageId `
                -DisplayName $displayName `
                -Version $(if ($versionOverride) { $versionOverride } else { $null }) `
                -OutputPath $outputPath `
                -IconPath $iconPath `
                -ProgressCallback {
                    param($Percent, $Status, $Step)
                    $progressBar.Value = [Math]::Min(100, [Math]::Max(0, $Percent))
                    $stepLabel.Text = if ($Step) { "[$Step] $Status" } else { $Status }
                    Add-LogMessage $Status
                    [System.Windows.Forms.Application]::DoEvents()
                }

            $script:LastOutputDirectory = $result.VersionDirectory
            $openFolderButton.Enabled = $true

            if ($result.IconPath) {
                Update-IconPreview -IconPath $result.IconPath
            }

            Add-LogMessage 'Packaging completed successfully!'
            Add-LogMessage "IntuneWin: $($result.IntuneWinFile)"
            Add-LogMessage "README: $(Join-Path $result.VersionDirectory 'README.md')"

            [System.Windows.Forms.MessageBox]::Show(
                "Package created successfully!`n`n$($result.DisplayName) v$($result.Version)`n`nOutput:`n$($result.VersionDirectory)",
                'Wingetter - Success',
                'OK',
                'Information'
            ) | Out-Null
        }
        catch {
            Add-LogMessage "Packaging failed: $($_.Exception.Message)"
            $failureLog = if ($script:LastOutputDirectory) {
                Join-Path $script:LastOutputDirectory 'packaging-failure.log'
            } else { 'packaging-failure.log in output folder' }

            [System.Windows.Forms.MessageBox]::Show(
                "Packaging failed:`n$($_.Exception.Message)`n`nSee log: $failureLog",
                'Wingetter - Error',
                'OK',
                'Error'
            ) | Out-Null
        }
        finally {
            Set-UiRunning -Running $false
        }
    })

    $openFolderButton.Add_Click({
        if ($script:LastOutputDirectory -and (Test-Path $script:LastOutputDirectory)) {
            Start-Process explorer.exe $script:LastOutputDirectory
        }
    })

    $closeButton.Add_Click({ $form.Close() })

    $searchBox.Add_KeyDown({
        if ($_.KeyCode -eq 'Enter') {
            $searchButton.PerformClick()
            $_.SuppressKeyPress = $true
        }
    })

    [void]$form.ShowDialog()
}

Show-WingetterMainForm
