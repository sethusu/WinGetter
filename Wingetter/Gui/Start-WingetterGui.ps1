<#
.SYNOPSIS
    Launches the Wingetter graphical user interface.
.DESCRIPTION
    WPF-based GUI for searching Winget packages, selecting an app via radio buttons,
    choosing output destination, tracking live packaging progress, and previewing icons.
.EXAMPLE
    .\Start-WingetterGui.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# WinForms dialogs (folder/file pickers) render more reliably with visual styles enabled.
try {
    [System.Windows.Forms.Application]::EnableVisualStyles()
} catch {
    # Non-fatal — dialogs can still open without visual styles.
}

$moduleRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $moduleRoot 'Wingetter.psd1'
Import-Module $modulePath -Force

$brushConverter = New-Object System.Windows.Media.BrushConverter

function ConvertTo-WpfBrush {
    param([string]$Color)
    return $brushConverter.ConvertFromString($Color)
}

function New-WpfThickness {
    param(
        [double]$Left = 0,
        [double]$Top = 0,
        [double]$Right = 0,
        [double]$Bottom = 0
    )
    return New-Object System.Windows.Thickness($Left, $Top, $Right, $Bottom)
}

function Read-XamlWindow {
    param([string]$XamlPath)
    $xaml = Get-Content -Path $XamlPath -Raw
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    return [Windows.Markup.XamlReader]::Load($reader)
}

function Get-WinFormsOwnerWindow {
    param($OwnerWindow)

    if (-not $OwnerWindow) {
        return $null
    }

    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($OwnerWindow)
        # Ensure the WPF HWND exists before parenting WinForms dialogs.
        $null = $helper.EnsureHandle()
        if ($helper.Handle -eq [IntPtr]::Zero) {
            return $null
        }

        $owner = New-Object System.Windows.Forms.NativeWindow
        $owner.AssignHandle($helper.Handle)
        return $owner
    } catch {
        return $null
    }
}

function Show-FolderBrowser {
    param(
        [string]$Description,
        [string]$SelectedPath,
        $OwnerWindow = $null
    )

    # WinForms FolderBrowserDialog defaults RootFolder to Desktop. When SelectedPath
    # points at another drive (common for packaging folders like D:\...), ShowDialog
    # can throw / tear down the WPF host. Root at MyComputer so any path is valid.
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true
    $dialog.RootFolder = [Environment+SpecialFolder]::MyComputer

    if ($SelectedPath) {
        try {
            $candidate = [System.IO.Path]::GetFullPath($SelectedPath)
            if (Test-Path -LiteralPath $candidate) {
                $dialog.SelectedPath = $candidate
            }
        } catch {
            # Ignore unusable initial paths; dialog still opens at My Computer.
        }
    }

    $owner = Get-WinFormsOwnerWindow -OwnerWindow $OwnerWindow
    $result = [System.Windows.Forms.DialogResult]::Cancel
    $chosenPath = $null
    try {
        if ($owner) {
            $result = $dialog.ShowDialog($owner)
        } else {
            $result = $dialog.ShowDialog()
        }
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            $chosenPath = $dialog.SelectedPath
        }
    } finally {
        if ($owner) {
            try { $owner.ReleaseHandle() } catch { }
        }
        $dialog.Dispose()
    }

    return $chosenPath
}

function Show-OpenFileDialog {
    param(
        [string]$Filter = 'PNG images (*.png)|*.png|All files (*.*)|*.*',
        $OwnerWindow = $null
    )

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = $Filter
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false

    $owner = Get-WinFormsOwnerWindow -OwnerWindow $OwnerWindow
    $result = [System.Windows.Forms.DialogResult]::Cancel
    $chosenPath = $null
    try {
        if ($owner) {
            $result = $dialog.ShowDialog($owner)
        } else {
            $result = $dialog.ShowDialog()
        }
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            $chosenPath = $dialog.FileName
        }
    } finally {
        if ($owner) {
            try { $owner.ReleaseHandle() } catch { }
        }
        $dialog.Dispose()
    }

    return $chosenPath
}

function Set-IconPreview {
    param(
        $ImageControl,
        $StatusControl,
        [string]$ImagePath
    )

    if ($ImagePath -and (Test-Path $ImagePath)) {
        try {
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.UriSource = [Uri]::new((Resolve-Path $ImagePath).Path)
            $bitmap.EndInit()
            $bitmap.Freeze()
            $ImageControl.Source = $bitmap
            $StatusControl.Text = [System.IO.Path]::GetFileName($ImagePath)
            return
        } catch {
            $StatusControl.Text = "Could not load icon: $_"
        }
    }

    $ImageControl.Source = $null
}

function Show-WingetterSearchDialog {
    param(
        [array]$Packages,
        [string]$SearchQuery,
        $OwnerWindow
    )

    $dialogPath = Join-Path $PSScriptRoot 'Wingetter.SearchDialog.xaml'
    $dialogWindow = Read-XamlWindow -XamlPath $dialogPath
    $dialogWindow.Owner = $OwnerWindow

    $summary = $dialogWindow.FindName('SearchSummaryText')
    $panel = $dialogWindow.FindName('ResultsPanel')
    $selectButton = $dialogWindow.FindName('SelectButton')
    $cancelButton = $dialogWindow.FindName('CancelButton')

    $sourceNames = @($Packages | ForEach-Object { if ($_.Source) { $_.Source } else { $null } } | Where-Object { $_ } | Sort-Object -Unique)
    $sourceSuffix = if ($sourceNames.Count -gt 0) { " across: $($sourceNames -join ', ')" } else { '' }
    $summary.Text = "Found $($Packages.Count) result(s) for '$SearchQuery'$sourceSuffix. Select the application you want to package."

    $dialogSelection = @{ Package = $null }
    $firstRadio = $null

    foreach ($package in $Packages) {
        $border = New-Object System.Windows.Controls.Border
        $border.Margin = New-WpfThickness -Bottom 8
        $border.Padding = New-WpfThickness -Left 10 -Top 10 -Right 10 -Bottom 10
        $border.CornerRadius = New-Object System.Windows.CornerRadius(6)
        $border.BorderBrush = ConvertTo-WpfBrush '#D8DEE9'
        $border.BorderThickness = New-WpfThickness -Left 1 -Top 1 -Right 1 -Bottom 1
        $border.Background = [System.Windows.Media.Brushes]::White

        $stack = New-Object System.Windows.Controls.StackPanel
        $radio = New-Object System.Windows.Controls.RadioButton
        $radio.GroupName = 'WingetterPackageSelection'
        $radio.Margin = New-WpfThickness -Bottom 4
        $radio.Content = "$($package.Name)  ($($package.Id))"
        $radio.FontWeight = [System.Windows.FontWeights]::SemiBold
        $radio.Tag = $package

        $radio.Add_Checked({
            param($sender, $e)
            $dialogSelection.Package = $sender.Tag
        })

        if (-not $firstRadio) {
            $firstRadio = $radio
            $dialogSelection.Package = $package
        }

        $versionText = New-Object System.Windows.Controls.TextBlock
        $versionText.Text = "Version: $($package.Version)$(if ($package.Source) { "  |  Source: $($package.Source)" })"
        $versionText.Foreground = ConvertTo-WpfBrush '#5C6B7A'
        $versionText.Margin = New-WpfThickness -Left 22

        $stack.Children.Add($radio) | Out-Null
        $stack.Children.Add($versionText) | Out-Null
        $border.Child = $stack
        $panel.Children.Add($border) | Out-Null
    }

    if ($firstRadio) {
        $firstRadio.IsChecked = $true
    }

    $selectButton.Add_Click({
        if ($dialogSelection.Package) {
            $dialogWindow.Tag = $dialogSelection.Package
            $dialogWindow.DialogResult = $true
            $dialogWindow.Close()
        } else {
            [System.Windows.MessageBox]::Show($dialogWindow, 'Please select an application.', 'Wingetter', 'OK', 'Warning') | Out-Null
        }
    })

    $cancelButton.Add_Click({
        $dialogWindow.DialogResult = $false
        $dialogWindow.Close()
    })

    if ($dialogWindow.ShowDialog()) {
        return $dialogWindow.Tag
    }
    return $null
}

function Get-SandboxStepIcon {
    param([string]$State)
    switch ($State) {
        'Running' { return [char]0x25B6 }
        'Awaiting' { return [char]0x25B6 }
        'Confirmed' { return [char]0x2713 }
        'Failed' { return [char]0x2717 }
        default { return [char]0x25CB }
    }
}

function New-SandboxStepView {
    param(
        [string]$Title,
        [string]$State,
        [string]$Detail
    )
    return [PSCustomObject]@{
        Icon = Get-SandboxStepIcon $State
        Title = $Title
        Detail = $Detail
        State = $State
    }
}

function Update-SandboxDialogStepList {
    if (-not $script:sandboxDialog) { return }
    $ui = $script:sandboxDialog
    $ui.StepList.Items.Clear()
    foreach ($name in $ui.StepOrder) {
        $ui.StepList.Items.Add((New-SandboxStepView -Title $ui.StepTitles[$name] -State $ui.StepStates[$name] -Detail $ui.StepDetails[$name])) | Out-Null
    }
}

function Set-SandboxDialogLog {
    param([string]$Text)
    if (-not $script:sandboxDialog) { return }
    if ($Text -eq $script:sandboxDialog.LastLog) { return }
    $script:sandboxDialog.LastLog = $Text
    $script:sandboxDialog.LogBox.Text = $Text
    $script:sandboxDialog.LogBox.CaretIndex = $script:sandboxDialog.LogBox.Text.Length
    $script:sandboxDialog.LogBox.ScrollToEnd()
}

function Save-SandboxDialogReport {
    param(
        [string]$Outcome = 'in-progress',
        [string]$Message = ''
    )

    if (-not $script:sandboxDialog -or -not $script:sandboxDialog.Session) {
        return $null
    }

    try {
        $report = Write-WingetterSandboxTestReport `
            -VersionDirectory $script:sandboxDialog.Session.VersionDirectory `
            -HandshakeDirectory $script:sandboxDialog.Session.HandshakeDirectory `
            -Confirmations $script:sandboxDialog.Confirmations `
            -Outcome $Outcome `
            -Message $Message
        $script:sandboxDialog.Report = $report
        return $report
    } catch {
        return $null
    }
}

function Copy-SandboxDialogReportToClipboard {
    param($Report)

    if (-not $Report -or -not $Report.Text) {
        return $false
    }

    try {
        [System.Windows.Clipboard]::SetText([string]$Report.Text)
        return $true
    } catch {
        return $false
    }
}

function Complete-SandboxDialog {
    param(
        [bool]$Validated,
        [object]$Validation = $null,
        [string]$Message = ''
    )

    if (-not $script:sandboxDialog -or $script:sandboxDialog.Finished) { return }
    $script:sandboxDialog.Finished = $true

    $outcome = if ($Validated) { 'validated' } else { 'failed' }
    $report = Save-SandboxDialogReport -Outcome $outcome -Message $Message
    $copied = Copy-SandboxDialogReportToClipboard -Report $report

    $script:sandboxDialog.Result = [PSCustomObject]@{
        Validated = $Validated
        Validation = $Validation
        Message = $Message
        ReportPath = if ($report) { $report.Path } else { $null }
        ReportText = if ($report) { $report.Text } else { $null }
        ReportCopied = $copied
        FailureLogPath = if ($report) { $report.FailureLogPath } else { $null }
    }

    if ($script:sandboxDialog.Timer) {
        try { $script:sandboxDialog.Timer.Stop() } catch { }
    }
    try {
        Stop-WingetterSandboxSession -HandshakeDirectory $script:sandboxDialog.Session.HandshakeDirectory
    } catch { }

    $script:sandboxDialog.Window.Tag = $script:sandboxDialog.Result
    try {
        $script:sandboxDialog.Window.DialogResult = $Validated
    } catch { }
    try {
        $script:sandboxDialog.Window.Close()
    } catch { }
}

function Confirm-CurrentSandboxStep {
    param([bool]$Succeeded)

    if (-not $script:sandboxDialog -or $script:sandboxDialog.Finished) { return }
    $ui = $script:sandboxDialog
    $step = $ui.CurrentStep
    if ($ui.StepStates[$step] -ne 'Awaiting') { return }

    $status = Get-WingetterSandboxStatus -HandshakeDirectory $ui.Session.HandshakeDirectory
    $exitCode = $null
    $message = ''
    $silentUi = $false
    if ($status) {
        $exitCode = $status.exitCode
        $message = [string]$status.message
        if ($status.PSObject.Properties['silentUiDetected']) {
            $silentUi = [bool]$status.silentUiDetected
        }
    }
    if (-not $silentUi -and $message -match '(?i)not silent') {
        $silentUi = $true
    }

    if ($Succeeded) {
        $ui.Confirmations[$step] = @{
            Confirmed = $true
            ExitCode = $exitCode
            ConfirmedAt = (Get-Date).ToUniversalTime().ToString('o')
            Message = $message
            SilentUiDetected = $silentUi
        }
        $ui.StepStates[$step] = 'Confirmed'
        $ui.StepDetails[$step] = if ($silentUi) {
            "Confirmed, but NOT SILENT. Exit code: $exitCode"
        } else {
            "Confirmed. Exit code: $exitCode"
        }
        $ui.ConfirmButton.IsEnabled = $false
        $ui.FailButton.IsEnabled = $false

        $index = [array]::IndexOf($ui.StepOrder, $step)
        if ($index -lt ($ui.StepOrder.Count - 1)) {
            $next = $ui.StepOrder[$index + 1]
            $ui.CurrentStep = $next
            $ui.StepStates[$next] = 'Running'
            $ui.StepDetails[$next] = "Running $next in Windows Sandbox..."
            $ui.StatusText.Text = "Confirmed $step. Starting $next..."
            Set-WingetterSandboxCommand -HandshakeDirectory $ui.Session.HandshakeDirectory -Action $next
            Update-SandboxDialogStepList
        } else {
            $validation = Complete-WingetterSandboxTest -VersionDirectory $ui.Session.VersionDirectory -Confirmations $ui.Confirmations
            $ok = [bool]$validation.Validated
            $doneMessage = if ($ok) {
                'All three steps were confirmed. This package is marked as validated.'
            } else {
                'All three steps were confirmed, but silent-install validation failed (an installer dialog appeared). The package was not marked as validated. See sandbox-failure.log in the package folder.'
            }
            Complete-SandboxDialog -Validated $ok -Validation $validation -Message $doneMessage
        }
        return
    }

    $ui.Confirmations[$step] = @{
        Confirmed = $false
        ExitCode = $exitCode
        ConfirmedAt = (Get-Date).ToUniversalTime().ToString('o')
        Message = $message
        SilentUiDetected = $silentUi
    }
    $ui.StepStates[$step] = 'Failed'
    $ui.StepDetails[$step] = "Not confirmed. Exit code: $exitCode"
    $null = Complete-WingetterSandboxTest -VersionDirectory $ui.Session.VersionDirectory -Confirmations $ui.Confirmations
    Complete-SandboxDialog -Validated $false -Message "$step was not confirmed. The package was not marked as validated."
}

function Update-SandboxDialogFromStatus {
    if (-not $script:sandboxDialog -or $script:sandboxDialog.Finished) { return }
    $ui = $script:sandboxDialog

    $logText = Get-WingetterSandboxGuestLog -HandshakeDirectory $ui.Session.HandshakeDirectory -IncludeStepLogs
    if ($logText) {
        Set-SandboxDialogLog -Text $logText
    }

    $heartbeat = Get-WingetterSandboxHeartbeat -HandshakeDirectory $ui.Session.HandshakeDirectory
    if ($heartbeat) {
        $ui.HeartbeatSeen = $true
    } elseif (-not $ui.HeartbeatSeen) {
        $elapsed = (Get-Date) - $ui.Session.StartedAt
        if ($elapsed.TotalSeconds -gt 120) {
            $ui.StatusText.Text = 'Windows Sandbox did not start in time.'
            Complete-SandboxDialog -Validated $false -Message 'Windows Sandbox did not start. Confirm the feature is enabled, virtualization is available, and try again.'
            return
        }
        $ui.StatusText.Text = "Starting Windows Sandbox... ($([int]$elapsed.TotalSeconds)s)"
        return
    }

    $status = Get-WingetterSandboxStatus -HandshakeDirectory $ui.Session.HandshakeDirectory
    if (-not $status) { return }

    $step = $ui.CurrentStep
    $statusStep = [string]$status.step
    $state = [string]$status.state

    if ($statusStep -eq $step -and $state -eq 'running') {
        $ui.StepStates[$step] = 'Running'
        $ui.StepDetails[$step] = [string]$status.message
        $ui.StatusText.Text = [string]$status.message
        $ui.ConfirmButton.IsEnabled = $false
        $ui.FailButton.IsEnabled = $false
    } elseif ($statusStep -eq $step -and ($state -eq 'completed' -or $state -eq 'failed')) {
        $ui.StepStates[$step] = 'Awaiting'
        $exitLabel = if ($null -ne $status.exitCode) { "Exit code: $($status.exitCode). " } else { '' }
        $silentUi = $false
        if ($status.PSObject.Properties['silentUiDetected']) {
            $silentUi = [bool]$status.silentUiDetected
        }
        if (-not $silentUi -and [string]$status.message -match '(?i)not silent') {
            $silentUi = $true
        }
        $ui.StepDetails[$step] = "$exitLabel$($status.message) Confirm this step in Wingetter to continue."
        if ($silentUi) {
            $ui.StatusText.Text = "NOT SILENT: an installer dialog appeared. Use Step failed, or confirm to continue testing. The package will not be marked validated."
        } else {
            $ui.StatusText.Text = "Confirm $step, then the next script will run."
        }
        $ui.ConfirmButton.IsEnabled = $true
        $ui.FailButton.IsEnabled = $true
    }

    Update-SandboxDialogStepList
}

function Show-WingetterSandboxTestDialog {
    param(
        [object]$Session,
        $OwnerWindow
    )

    $dialogPath = Join-Path $PSScriptRoot 'Wingetter.SandboxTestDialog.xaml'
    $dialogWindow = Read-XamlWindow -XamlPath $dialogPath
    $dialogWindow.Owner = $OwnerWindow

    $summary = $dialogWindow.FindName('PackageSummaryText')
    $statusText = $dialogWindow.FindName('StatusText')
    $stepList = $dialogWindow.FindName('StepList')
    $logBox = $dialogWindow.FindName('LogTextBox')
    $confirmButton = $dialogWindow.FindName('ConfirmButton')
    $failButton = $dialogWindow.FindName('FailButton')
    $cancelButton = $dialogWindow.FindName('CancelButton')
    $copyReportButton = $dialogWindow.FindName('CopyReportButton')

    $displayName = if ($Session.DisplayName) { $Session.DisplayName } else { 'Packaged application' }
    $packageId = if ($Session.PackageId) { $Session.PackageId } else { '' }
    $version = if ($Session.Version) { $Session.Version } else { '' }
    $summary.Text = "$displayName $(if ($packageId) { "($packageId)" }) $(if ($version) { "version $version" })`nPackage folder: $($Session.VersionDirectory)"

    $script:sandboxDialog = @{
        Window = $dialogWindow
        StatusText = $statusText
        StepList = $stepList
        LogBox = $logBox
        ConfirmButton = $confirmButton
        FailButton = $failButton
        CopyReportButton = $copyReportButton
        Session = $Session
        Timer = $null
        CurrentStep = 'install'
        StepOrder = @('install', 'detect', 'uninstall')
        StepTitles = @{
            install = '1. Install (install.ps1)'
            detect = '2. Detect (detection.ps1)'
            uninstall = '3. Uninstall (uninstall.ps1)'
        }
        StepDetails = @{
            install = 'Windows Sandbox is starting. install.ps1 will run automatically.'
            detect = 'Runs after install is confirmed.'
            uninstall = 'Runs after detection is confirmed.'
        }
        StepStates = @{
            install = 'Running'
            detect = 'Pending'
            uninstall = 'Pending'
        }
        Confirmations = @{
            install = @{ Confirmed = $false; ExitCode = $null; ConfirmedAt = $null; Message = ''; SilentUiDetected = $false }
            detect = @{ Confirmed = $false; ExitCode = $null; ConfirmedAt = $null; Message = ''; SilentUiDetected = $false }
            uninstall = @{ Confirmed = $false; ExitCode = $null; ConfirmedAt = $null; Message = ''; SilentUiDetected = $false }
        }
        HeartbeatSeen = $false
        Finished = $false
        Result = $null
        Report = $null
        LastLog = ''
    }

    Update-SandboxDialogStepList
    $statusText.Text = 'Starting Windows Sandbox and running install.ps1...'

    $sandboxTimer = New-Object System.Windows.Threading.DispatcherTimer
    $sandboxTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $sandboxTimer.Add_Tick({ Update-SandboxDialogFromStatus })
    $script:sandboxDialog.Timer = $sandboxTimer
    $sandboxTimer.Start()

    $confirmButton.Add_Click({ Confirm-CurrentSandboxStep -Succeeded $true })
    $failButton.Add_Click({ Confirm-CurrentSandboxStep -Succeeded $false })
    if ($copyReportButton) {
        $copyReportButton.Add_Click({
            $report = Save-SandboxDialogReport -Outcome 'in-progress' -Message 'Copied from Test in Sandbox dialog.'
            if (-not $report) {
                $script:sandboxDialog.StatusText.Text = 'Could not write a sandbox report yet.'
                return
            }
            $copied = Copy-SandboxDialogReportToClipboard -Report $report
            if ($copied) {
                $script:sandboxDialog.StatusText.Text = "Chat-ready log copied. Saved to $($report.Path)"
            } else {
                $script:sandboxDialog.StatusText.Text = "Chat-ready log saved to $($report.Path)"
            }
        })
    }
    $cancelButton.Add_Click({
        Complete-SandboxDialog -Validated $false -Message 'Sandbox test was cancelled. The package was not marked as validated.'
    })
    $dialogWindow.Add_Closing({
        if ($script:sandboxDialog -and -not $script:sandboxDialog.Finished) {
            Complete-SandboxDialog -Validated $false -Message 'Sandbox test was closed before validation completed.'
        }
    })

    [void]$dialogWindow.ShowDialog()
    if ($script:sandboxDialog -and $script:sandboxDialog.Timer) {
        try { $script:sandboxDialog.Timer.Stop() } catch { }
    }
    $result = $null
    if ($dialogWindow.Tag) {
        $result = $dialogWindow.Tag
    } elseif ($script:sandboxDialog -and $script:sandboxDialog.Result) {
        $result = $script:sandboxDialog.Result
    }
    $script:sandboxDialog = $null
    if ($result) { return $result }
    return [PSCustomObject]@{
        Validated = $false
        Validation = $null
        Message = 'Sandbox test ended without a result.'
    }
}

function New-WpfBitmapImage {
    param([string]$ImagePath)

    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.UriSource = [Uri]::new((Resolve-Path $ImagePath).Path)
    $bitmap.EndInit()
    $bitmap.Freeze()
    return $bitmap
}

function Show-WingetterIconPickerDialog {
    param(
        [array]$Candidates,
        [string]$DisplayName,
        [string]$PackageId,
        $OwnerWindow
    )

    if (-not $Candidates -or $Candidates.Count -lt 2) {
        return $null
    }

    $dialogPath = Join-Path $PSScriptRoot 'Wingetter.IconPickerDialog.xaml'
    $dialogWindow = Read-XamlWindow -XamlPath $dialogPath
    $dialogWindow.Owner = $OwnerWindow

    $summary = $dialogWindow.FindName('IconSummaryText')
    $panel = $dialogWindow.FindName('CandidatesPanel')
    $useButton = $dialogWindow.FindName('UseSelectedButton')
    $keepButton = $dialogWindow.FindName('KeepCurrentButton')

    $summary.Text = "Packaging finished for $DisplayName ($PackageId). Pick the icon that best represents this app for Intune upload."

    $selection = @{
        Candidate = $Candidates[0]
    }
    $firstRadio = $null

    foreach ($candidate in $Candidates) {
        $card = New-Object System.Windows.Controls.Border
        $card.Width = 210
        $card.Margin = New-WpfThickness -Left 6 -Right 6
        $card.Padding = New-WpfThickness -Left 10 -Top 10 -Right 10 -Bottom 10
        $card.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $card.BorderBrush = ConvertTo-WpfBrush '#D8DEE9'
        $card.BorderThickness = New-WpfThickness -Left 1 -Top 1 -Right 1 -Bottom 1
        $card.Background = [System.Windows.Media.Brushes]::White

        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center

        $radio = New-Object System.Windows.Controls.RadioButton
        $radio.GroupName = 'WingetterIconSelection'
        $radio.Content = if ($candidate.Label) { $candidate.Label } else { 'Option' }
        $radio.FontWeight = [System.Windows.FontWeights]::SemiBold
        $radio.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $radio.Margin = New-WpfThickness -Bottom 8
        $radio.Tag = $candidate

        $radio.Add_Checked({
            param($sender, $e)
            $selection.Candidate = $sender.Tag
        })

        if (-not $firstRadio) {
            $firstRadio = $radio
            $selection.Candidate = $candidate
        }

        $image = New-Object System.Windows.Controls.Image
        $image.Width = 128
        $image.Height = 128
        $image.Stretch = [System.Windows.Media.Stretch]::Uniform
        $image.Margin = New-WpfThickness -Bottom 8
        if ($candidate.Path -and (Test-Path $candidate.Path)) {
            try {
                $image.Source = New-WpfBitmapImage -ImagePath $candidate.Path
            } catch {
                $image.Source = $null
            }
        }

        $sourceText = New-Object System.Windows.Controls.TextBlock
        $sourceText.Text = "Source: $($candidate.Source)"
        $sourceText.Foreground = ConvertTo-WpfBrush '#5C6B7A'
        $sourceText.FontSize = 12
        $sourceText.TextAlignment = [System.Windows.TextAlignment]::Center
        $sourceText.Margin = New-WpfThickness -Bottom 4

        $urlText = New-Object System.Windows.Controls.TextBlock
        $urlDisplay = if ($candidate.Url.Length -gt 48) { $candidate.Url.Substring(0, 45) + '...' } else { $candidate.Url }
        $urlText.Text = $urlDisplay
        $urlText.Foreground = ConvertTo-WpfBrush '#8A96A3'
        $urlText.FontSize = 11
        $urlText.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $urlText.TextAlignment = [System.Windows.TextAlignment]::Center
        $urlText.ToolTip = $candidate.Url

        $stack.Children.Add($radio) | Out-Null
        $stack.Children.Add($image) | Out-Null
        $stack.Children.Add($sourceText) | Out-Null
        $stack.Children.Add($urlText) | Out-Null
        $card.Child = $stack
        $panel.Children.Add($card) | Out-Null
    }

    if ($firstRadio) {
        $firstRadio.IsChecked = $true
    }

    $useButton.Add_Click({
        if ($selection.Candidate) {
            $dialogWindow.Tag = $selection.Candidate
            $dialogWindow.DialogResult = $true
            $dialogWindow.Close()
        }
    })

    $keepButton.Add_Click({
        $dialogWindow.Tag = $null
        $dialogWindow.DialogResult = $false
        $dialogWindow.Close()
    })

    if ($dialogWindow.ShowDialog()) {
        return $dialogWindow.Tag
    }
    return $null
}

function Invoke-PostPackagingIconSelection {
    param(
        [object]$Result,
        $OwnerWindow,
        $IconPreview,
        $IconStatus,
        $LogText
    )

    if ($Result.UsedCustomIcon) { return $Result }
    if (-not $Result.IconCandidates -or $Result.IconCandidates.Count -lt 2) { return $Result }
    if (-not $Result.LogoFile -or -not $Result.IconFile) { return $Result }

    $selected = Show-WingetterIconPickerDialog -Candidates $Result.IconCandidates `
        -DisplayName $Result.DisplayName -PackageId $Result.PackageId -OwnerWindow $OwnerWindow

    if ($selected) {
        Set-WingetterPackageIconFiles -SourceIconPath $selected.Path -LogoFilePath $Result.LogoFile -IconFilePath $Result.IconFile
        $Result.IconFile = $Result.IconFile
        Set-IconPreview -ImageControl $IconPreview -StatusControl $IconStatus -ImagePath $Result.IconFile
        Add-LogLine -LogControl $LogText -Message "Applied selected icon from $($selected.Source): $($selected.Url)"
    } else {
        Add-LogLine -LogControl $LogText -Message 'Kept the default icon candidate from packaging.'
    }

    return $Result
}

function Add-LogLine {
    param(
        $LogControl,
        [string]$Message
    )
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $LogControl.AppendText("[$timestamp] $Message`r`n")
    $LogControl.ScrollToEnd()
}

$script:StepLabels = @(
    'Load package details'
    'Create output directories'
    'Download installer from Winget'
    'Calculate installer hash'
    'Generate install.ps1'
    'Generate detection.ps1'
    'Generate uninstall.ps1'
    'Resolve application icon'
    'Write metadata and README.md'
    'Create .intunewin package'
    'Finalize output'
)

$script:StepStates = @('Pending') * $script:StepLabels.Count

function Initialize-StepList {
    param($ListControl)
    $script:StepStates = @('Pending') * $script:StepLabels.Count
    $ListControl.Items.Clear()
    for ($i = 0; $i -lt $script:StepLabels.Count; $i++) {
        $ListControl.Items.Add((New-StepListItem -Index $i)) | Out-Null
    }
}

function Get-StepIcon {
    param([string]$State)
    switch ($State) {
        'Running' { return [char]0x25B6 }
        'Completed' { return [char]0x2713 }
        'Failed' { return [char]0x2717 }
        default { return [char]0x25CB }
    }
}

function New-StepListItem {
    param([int]$Index)
    return [PSCustomObject]@{
        Icon = Get-StepIcon $script:StepStates[$Index]
        Text = $script:StepLabels[$Index]
    }
}

function Update-StepList {
    param(
        $ListControl,
        [int]$StepIndex,
        [ValidateSet('Pending', 'Running', 'Completed', 'Failed')]
        [string]$State
    )

    if ($StepIndex -lt 0 -or $StepIndex -ge $script:StepLabels.Count) {
        return
    }

    $script:StepStates[$StepIndex] = $State
    $ListControl.Items[$StepIndex] = New-StepListItem -Index $StepIndex
}

function Invoke-UiProgressUpdate {
    param(
        $Event,
        $ProgressBar,
        $ProgressStatus,
        $StepList,
        $LogText,
        $StepMap
    )

    if ($Event.Type -eq 'Progress') {
        if ($Event.Percent -ge 0) {
            $ProgressBar.Value = [math]::Min(100, $Event.Percent)
        }
        if ($Event.Message) {
            $ProgressStatus.Text = "$($Event.StepName): $($Event.Message)"
        } else {
            $ProgressStatus.Text = $Event.StepName
        }

        if ($StepMap.ContainsKey($Event.Step)) {
            $index = $StepMap[$Event.Step]
            for ($i = 0; $i -lt $index; $i++) {
                if ($script:StepStates[$i] -ne 'Failed') {
                    Update-StepList -ListControl $StepList -StepIndex $i -State Completed
                }
            }
            if ($Event.Status -eq 'Completed') {
                Update-StepList -ListControl $StepList -StepIndex $index -State Completed
            } elseif ($Event.Status -eq 'Failed') {
                Update-StepList -ListControl $StepList -StepIndex $index -State Failed
            } else {
                Update-StepList -ListControl $StepList -StepIndex $index -State Running
            }
        }

        if ($Event.Message) {
            Add-LogLine -LogControl $LogText -Message "$($Event.StepName) - $($Event.Message)"
        } else {
            Add-LogLine -LogControl $LogText -Message $Event.StepName
        }
    } elseif ($Event.Message) {
        Add-LogLine -LogControl $LogText -Message $Event.Message
    }
}

function Start-WingetterBackgroundPackaging {
    param(
        [hashtable]$PackArguments,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ProgressQueue
    )

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace

    $null = $powershell.AddScript({
        param($ModulePath, $PackageId, $Version, $Source, $OutputPath, $IconPath, $CollectIconCandidates, $Queue)
        Import-Module $ModulePath -Force
        $onProgress = {
            param($Event)
            $null = $Queue.Enqueue($Event)
        }
        $params = @{
            PackageId = $PackageId
            OutputPath = $OutputPath
            OnProgress = $onProgress
        }
        if ($Version) { $params.Version = $Version }
        if ($Source) { $params.Source = $Source }
        if ($IconPath) { $params.IconPath = $IconPath }
        if ($CollectIconCandidates) { $params.CollectIconCandidates = $true }
        Invoke-WingetterPackaging @params
    }).AddArgument($modulePath).
      AddArgument($PackArguments.PackageId).
      AddArgument($PackArguments.Version).
      AddArgument($PackArguments.Source).
      AddArgument($PackArguments.OutputPath).
      AddArgument($PackArguments.IconPath).
      AddArgument([bool]$PackArguments.CollectIconCandidates).
      AddArgument($ProgressQueue)

    return @{
        PowerShell = $powershell
        Runspace = $runspace
        AsyncResult = $powershell.BeginInvoke()
    }
}

function Start-WingetterBackgroundSearch {
    param(
        [string]$Query
    )

    $job = Start-Job -ArgumentList $modulePath, $Query -ScriptBlock {
        param($ModulePath, $SearchQuery)
        Import-Module $ModulePath -Force
        Search-WingetPackages -Query $SearchQuery
    }

    return $job
}

# Main window
$mainXamlPath = Join-Path $PSScriptRoot 'Wingetter.MainWindow.xaml'
$window = Read-XamlWindow -XamlPath $mainXamlPath

$prereqText = $window.FindName('PrereqStatusText')
$installContentPrepButton = $window.FindName('InstallContentPrepButton')
$searchBox = $window.FindName('SearchBox')
$searchButton = $window.FindName('SearchButton')
$selectAppButton = $window.FindName('SelectAppButton')
$selectedAppText = $window.FindName('SelectedAppText')
$outputPathBox = $window.FindName('OutputPathBox')
$browseOutputButton = $window.FindName('BrowseOutputButton')
$versionBox = $window.FindName('VersionBox')
$progressBar = $window.FindName('ProgressBar')
$progressStatus = $window.FindName('ProgressStatusText')
$stepList = $window.FindName('StepList')
$iconPreview = $window.FindName('IconPreview')
$iconStatus = $window.FindName('IconStatusText')
$browseIconButton = $window.FindName('BrowseIconButton')
$logText = $window.FindName('LogTextBox')
$openOutputButton = $window.FindName('OpenOutputButton')
$testSandboxButton = $window.FindName('TestSandboxButton')
$sandboxStatusText = $window.FindName('SandboxStatusText')
$packButton = $window.FindName('PackButton')

$script:selectedPackage = $null
$script:customIconPath = $null
$script:lastOutputDirectory = $null
$script:sandboxDialog = $null
$script:isRunning = $false
$script:searchJob = $null
$script:searchTimer = $null
$script:packTimer = $null
$script:packWorker = $null
$script:progressQueue = $null
$script:contentPrepInstallJob = $null
$script:contentPrepInstallTimer = $null

$stepMap = @{
    1 = 0; 2 = 1; 3 = 2; 4 = 3; 5 = 4; 6 = 5; 7 = 6; 8 = 7; 9 = 8; 10 = 9; 12 = 10
}

$settings = Get-WingetterSettings
$script:baseOutputPath = Get-WingetterBaseOutputPath -Path $settings.OutputPath -PackageId $settings.LastPackageId
$outputPathBox.Text = $script:baseOutputPath
$searchBox.Text = $settings.LastSearch
Initialize-StepList -ListControl $stepList

function Update-OutputPathForSelectedApp {
    if ($script:selectedPackage -and $script:selectedPackage.Id) {
        $outputPathBox.Text = Get-WingetterAppOutputPath -BasePath $script:baseOutputPath -PackageId $script:selectedPackage.Id
    } else {
        $outputPathBox.Text = $script:baseOutputPath
    }
}

function Update-PrereqStatusDisplay {
    param(
        [object]$Prerequisites = $null
    )

    if (-not $Prerequisites) {
        $Prerequisites = Test-WingetterPrerequisites
    }

    if ($Prerequisites.Issues.Count -eq 0) {
        $prereqText.Text = "Ready | Winget $($Prerequisites.WingetVersion) | Content Prep Tool: $($Prerequisites.ContentPrepToolPath)"
        $prereqText.Foreground = ConvertTo-WpfBrush '#2E7D32'
    } else {
        $prereqText.Text = 'Missing prerequisites: ' + ($Prerequisites.Issues -join ' ')
        $prereqText.Foreground = ConvertTo-WpfBrush '#C62828'
    }

    $showInstall = -not [bool]$Prerequisites.ContentPrepToolInstalled
    if ($showInstall) {
        $installContentPrepButton.Visibility = [System.Windows.Visibility]::Visible
        $installContentPrepButton.IsEnabled = [bool]$Prerequisites.WingetInstalled
        if (-not $Prerequisites.WingetInstalled) {
            $installContentPrepButton.ToolTip = 'Winget is required to install the Content Prep Tool.'
        } else {
            $installContentPrepButton.ToolTip = 'Install Microsoft Win32 Content Prep Tool (intunewinapputil) via winget'
        }
    } else {
        $installContentPrepButton.Visibility = [System.Windows.Visibility]::Collapsed
    }

    return $Prerequisites
}

$null = Update-PrereqStatusDisplay

function Set-SearchControlsEnabled {
    param([bool]$Enabled)
    $searchButton.IsEnabled = $Enabled
    $selectAppButton.IsEnabled = $Enabled
    $searchBox.IsEnabled = $Enabled
}

function Get-CurrentSandboxPackageDirectory {
    $packageId = $null
    if ($script:selectedPackage -and $script:selectedPackage.Id) {
        $packageId = $script:selectedPackage.Id
    }
    $version = ''
    if ($versionBox.Text) {
        $version = $versionBox.Text.Trim()
    }
    $path = ''
    if ($outputPathBox.Text) {
        $path = $outputPathBox.Text.Trim()
    }

    if ($path) {
        $resolved = Resolve-WingetterPackageVersionDirectory -Path $path -PackageId $packageId -Version $version
        if ($resolved) {
            return $resolved
        }
    }

    if ($script:lastOutputDirectory -and (Test-WingetterSandboxPackage -VersionDirectory $script:lastOutputDirectory)) {
        return $script:lastOutputDirectory
    }

    return $null
}

function Update-SandboxTestButtonState {
    $dir = Get-CurrentSandboxPackageDirectory
    $ready = [bool]($dir -and (Test-WingetterSandboxPackage -VersionDirectory $dir) -and -not $script:isRunning)
    $testSandboxButton.IsEnabled = $ready

    if (-not $dir) {
        $sandboxStatusText.Text = 'Create a package, then use Test in Sandbox to validate install, detection, and uninstall.'
        $sandboxStatusText.Foreground = ConvertTo-WpfBrush '#5C6B7A'
        return
    }

    $validation = Get-WingetterPackageValidation -VersionDirectory $dir
    if ($validation.Validated) {
        $when = ''
        if ($validation.ValidatedAt) {
            $when = " at $($validation.ValidatedAt)"
        }
        $sandboxStatusText.Text = "Validated in Windows Sandbox$when"
        $sandboxStatusText.Foreground = ConvertTo-WpfBrush '#2E7D32'
    } else {
        $sandboxStatusText.Text = 'Package ready. Test in Sandbox to confirm install, detection, and uninstall.'
        $sandboxStatusText.Foreground = ConvertTo-WpfBrush '#5C6B7A'
    }
}

function Invoke-WingetterSandboxTestFromUi {
    if ($script:isRunning) { return }

    $dir = Get-CurrentSandboxPackageDirectory
    if (-not $dir) {
        [System.Windows.MessageBox]::Show(
            $window,
            'Create a package first. Test in Sandbox needs install.ps1, detection.ps1, and uninstall.ps1.',
            'Wingetter',
            'OK',
            'Warning'
        ) | Out-Null
        return
    }

    $info = Get-WingetterSandboxPackageInfo -VersionDirectory $dir
    if (-not $info.Ready) {
        [System.Windows.MessageBox]::Show($window, $info.Reason, 'Wingetter', 'OK', 'Warning') | Out-Null
        return
    }

    $sandbox = Test-WingetterWindowsSandbox
    if (-not $sandbox.Enabled) {
        if (-not $sandbox.Supported) {
            [System.Windows.MessageBox]::Show($window, $sandbox.Reason, 'Wingetter', 'OK', 'Error') | Out-Null
            return
        }

        if ($sandbox.RestartPending) {
            [System.Windows.MessageBox]::Show($window, $sandbox.Reason, 'Wingetter', 'OK', 'Information') | Out-Null
            return
        }

        $confirm = [System.Windows.MessageBox]::Show(
            $window,
            "Windows Sandbox is not enabled on this device.`n`n$($sandbox.Reason)`n`nEnable Windows Sandbox now? This requires administrator approval and usually a restart.",
            'Wingetter',
            'YesNo',
            'Question'
        )
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

        try {
            $enableResult = Install-WingetterWindowsSandbox
            Add-LogLine -LogControl $logText -Message $enableResult.Message
            [System.Windows.MessageBox]::Show($window, $enableResult.Message, 'Wingetter', 'OK', 'Information') | Out-Null
            if ($enableResult.RestartNeeded -or -not $enableResult.Sandbox.Enabled) {
                return
            }
        } catch {
            Add-LogLine -LogControl $logText -Message "Could not enable Windows Sandbox: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show(
                $window,
                "Could not enable Windows Sandbox.`n`n$($_.Exception.Message)",
                'Wingetter',
                'OK',
                'Error'
            ) | Out-Null
            return
        }
    }

    try {
        Add-LogLine -LogControl $logText -Message "Starting Windows Sandbox test for $($info.DisplayName) $($info.Version)..."
        $session = Start-WingetterSandboxSession -VersionDirectory $dir
        $result = Show-WingetterSandboxTestDialog -Session $session -OwnerWindow $window
        if ($result -and $result.Message) {
            Add-LogLine -LogControl $logText -Message $result.Message
        }
        if ($result -and $result.ReportPath) {
            Add-LogLine -LogControl $logText -Message "Sandbox report: $($result.ReportPath)"
        }
        if ($result -and $result.FailureLogPath) {
            Add-LogLine -LogControl $logText -Message "Sandbox failure log: $($result.FailureLogPath)"
        }

        $dialogMessage = if ($result -and $result.Message) { [string]$result.Message } else { '' }
        if ($result -and $result.FailureLogPath) {
            $dialogMessage = "$dialogMessage`n`nFailure log (upload this for diagnostics):`n$($result.FailureLogPath)"
        }
        if ($result -and $result.ReportPath) {
            $dialogMessage = "$dialogMessage`n`nA chat-ready log was saved to:`n$($result.ReportPath)"
            if ($result.ReportCopied) {
                $dialogMessage = "$dialogMessage`n`nThe log is also on the clipboard so you can paste it into chat."
            }
        }

        if ($result.Validated) {
            [System.Windows.MessageBox]::Show($window, $dialogMessage, 'Wingetter', 'OK', 'Information') | Out-Null
        } elseif ($dialogMessage) {
            [System.Windows.MessageBox]::Show($window, $dialogMessage, 'Wingetter', 'OK', 'Warning') | Out-Null
        }
    } catch {
        Add-LogLine -LogControl $logText -Message "Sandbox test failed: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            $window,
            "Sandbox test failed.`n`n$($_.Exception.Message)",
            'Wingetter',
            'OK',
            'Error'
        ) | Out-Null
    } finally {
        Update-SandboxTestButtonState
    }
}

function Set-PackControlsEnabled {
    param([bool]$Enabled)
    $packButton.IsEnabled = $Enabled
    $searchButton.IsEnabled = $Enabled
    $selectAppButton.IsEnabled = $Enabled
    $searchBox.IsEnabled = $Enabled
    $browseOutputButton.IsEnabled = $Enabled
    $browseIconButton.IsEnabled = $Enabled
    if ($installContentPrepButton.Visibility -eq [System.Windows.Visibility]::Visible) {
        if (-not $Enabled) {
            $installContentPrepButton.IsEnabled = $false
        } else {
            # Keep disabled when Winget itself is missing (tooltip explains why).
            $installContentPrepButton.IsEnabled = ($installContentPrepButton.ToolTip -notlike '*Winget is required*')
        }
    }
    if (-not $Enabled) {
        $openOutputButton.IsEnabled = $false
        $testSandboxButton.IsEnabled = $false
    } else {
        if ($script:lastOutputDirectory -and (Test-Path -LiteralPath $script:lastOutputDirectory)) {
            $openOutputButton.IsEnabled = $true
        }
        Update-SandboxTestButtonState
    }
}

function Update-SelectedAppDisplay {
    if ($script:selectedPackage) {
        $sourcePart = if ($script:selectedPackage.Source) { " | Source: $($script:selectedPackage.Source)" } else { '' }
        $selectedAppText.Text = "Selected: $($script:selectedPackage.Name) | $($script:selectedPackage.Id) | Version: $($script:selectedPackage.Version)$sourcePart"
        $selectedAppText.Foreground = ConvertTo-WpfBrush '#1B2A41'
        $versionBox.Text = if ($script:selectedPackage.Version -ne 'Unknown') { $script:selectedPackage.Version } else { '' }
        Update-OutputPathForSelectedApp
    } else {
        $selectedAppText.Text = 'No application selected.'
        $selectedAppText.Foreground = ConvertTo-WpfBrush '#5C6B7A'
        Update-OutputPathForSelectedApp
    }
    Update-SandboxTestButtonState
}

function Start-PackageIconPreview {
    param(
        $Package,
        $IconPreview,
        $IconStatus,
        $LogText
    )

    if ($script:iconPreviewJob) {
        Remove-Job -Job $script:iconPreviewJob -Force -ErrorAction SilentlyContinue
        $script:iconPreviewJob = $null
    }

    $previewPath = Join-Path $env:TEMP "wingetter-preview-$($Package.Id -replace '[^A-Za-z0-9._-]', '_').png"
    if (Test-Path $previewPath) {
        Remove-Item $previewPath -Force -ErrorAction SilentlyContinue
    }

    $iconStatus.Text = 'Fetching icon preview...'
    Add-LogLine -LogControl $LogText -Message "Fetching icon preview for $($Package.Id)..."

    $script:iconPreviewJob = Start-Job -ArgumentList $modulePath, $Package, $previewPath -ScriptBlock {
        param($ModulePath, $SelectedPackage, $OutputPath)
        $ErrorActionPreference = 'Stop'
        try {
            Import-Module $ModulePath -Force
            $version = if ($SelectedPackage.Version -and $SelectedPackage.Version -ne 'Unknown') { $SelectedPackage.Version } else { $null }
            $detailParams = @{ PackageId = $SelectedPackage.Id }
            if ($version) { $detailParams.Version = $version }
            if ($SelectedPackage.Source) { $detailParams.Source = $SelectedPackage.Source }
            $details = Get-WingetPackageDetails @detailParams
            $homepage = if ($details.Homepage) { $details.Homepage } else { '' }
            Resolve-PackageIcon -PackageId $SelectedPackage.Id -DisplayName $SelectedPackage.Name `
                -Publisher $details.Publisher -Homepage $homepage -Version $details.Version `
                -OutputPath $OutputPath | Out-Null
            if (Test-Path $OutputPath) { return $OutputPath }
            return $null
        } catch {
            # Preview is best-effort -- never fail the job with a terminating error that
            # would tear down the WPF ShowDialog message pump in the parent process.
            return [PSCustomObject]@{
                PreviewFailed = $true
                Message = $_.Exception.Message
            }
        }
    }

    if ($script:iconPreviewTimer) {
        $script:iconPreviewTimer.Stop()
    }

    $script:iconPreviewTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:iconPreviewTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:iconPreviewTimer.Add_Tick({
        if (-not $script:iconPreviewJob -or $script:iconPreviewJob.State -eq 'Running') { return }

        $script:iconPreviewTimer.Stop()
        $job = $script:iconPreviewJob
        $script:iconPreviewJob = $null

        try {
            $previewResult = $null
            if ($job.State -eq 'Failed') {
                $err = Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-String
                $message = if ($err) { $err.Trim() } else { 'background job failed' }
                $iconStatus.Text = 'Icon preview unavailable. It will be resolved again during packaging.'
                Add-LogLine -LogControl $logText -Message "Icon preview failed for $($script:selectedPackage.Id): $message"
                return
            }

            $previewResult = Receive-Job -Job $job -ErrorAction SilentlyContinue
            if ($previewResult -is [array] -and $previewResult.Count -eq 1) {
                $previewResult = $previewResult[0]
            }

            if ($previewResult -and ($previewResult.PSObject.Properties.Name -contains 'PreviewFailed') -and $previewResult.PreviewFailed) {
                $iconStatus.Text = 'Icon preview unavailable. It will be resolved again during packaging.'
                Add-LogLine -LogControl $logText -Message "Icon preview failed for $($script:selectedPackage.Id): $($previewResult.Message)"
                return
            }

            $previewFile = $previewResult
            if ($previewFile -and (Test-Path -LiteralPath "$previewFile")) {
                Set-IconPreview -ImageControl $iconPreview -StatusControl $iconStatus -ImagePath $previewFile
                Add-LogLine -LogControl $logText -Message "Icon preview loaded for $($script:selectedPackage.Id)."
            } else {
                $iconStatus.Text = 'Icon preview unavailable. It will be resolved again during packaging.'
                Add-LogLine -LogControl $logText -Message "Icon preview unavailable for $($script:selectedPackage.Id)."
            }
        } catch {
            $iconStatus.Text = 'Icon preview unavailable. It will be resolved again during packaging.'
            Add-LogLine -LogControl $logText -Message "Icon preview failed: $($_.Exception.Message)"
        } finally {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    })
    $script:iconPreviewTimer.Start()
}

function Complete-WingetterSearch {
    param(
        [array]$Packages,
        [string]$Query,
        [object]$ErrorRecord = $null
    )

    Set-SearchControlsEnabled -Enabled $true
    $progressStatus.Text = 'Ready.'

    if ($ErrorRecord) {
        Add-LogLine -LogControl $logText -Message "Search failed: $($ErrorRecord.Exception.Message)"
        [System.Windows.MessageBox]::Show($window, "Search failed:`n$($ErrorRecord.Exception.Message)", 'Wingetter', 'OK', 'Error') | Out-Null
        return
    }

    Save-WingetterSettings -LastSearch $Query

    if ($Packages.Count -eq 0) {
        Add-LogLine -LogControl $logText -Message 'No packages found across configured Winget repositories.'
        [System.Windows.MessageBox]::Show($window, "No packages found for '$Query' in any configured Winget repository.", 'Wingetter', 'OK', 'Warning') | Out-Null
        return
    }

    $sourceSummary = @($Packages | ForEach-Object { if ($_.Source) { $_.Source } else { 'unknown' } } | Sort-Object -Unique) -join ', '
    Add-LogLine -LogControl $logText -Message "Found $($Packages.Count) package(s) from: $sourceSummary"

    $picked = Show-WingetterSearchDialog -Packages $Packages -SearchQuery $Query -OwnerWindow $window
    if ($picked) {
        $script:selectedPackage = $picked
        $sourceLabel = if ($script:selectedPackage.Source) { " [$($script:selectedPackage.Source)]" } else { '' }
        Add-LogLine -LogControl $logText -Message "Selected $($script:selectedPackage.Id) version $($script:selectedPackage.Version)$sourceLabel."
        Update-SelectedAppDisplay
        Start-PackageIconPreview -Package $script:selectedPackage -IconPreview $iconPreview -IconStatus $iconStatus -LogText $logText
    } else {
        Add-LogLine -LogControl $logText -Message 'Search selection cancelled.'
    }
}

function Invoke-WingetterSearch {
    param([string]$Query)

    if ($script:isRunning) { return }

    if ([string]::IsNullOrWhiteSpace($Query)) {
        [System.Windows.MessageBox]::Show($window, 'Enter an application name or Winget package ID to search.', 'Wingetter', 'OK', 'Information') | Out-Null
        return
    }

    if ($script:searchTimer) {
        $script:searchTimer.Stop()
        $script:searchTimer = $null
    }
    if ($script:searchJob) {
        Remove-Job -Job $script:searchJob -Force -ErrorAction SilentlyContinue
        $script:searchJob = $null
    }

    Set-SearchControlsEnabled -Enabled $false
    $progressStatus.Text = 'Searching all Winget repositories...'
    Add-LogLine -LogControl $logText -Message "Searching all Winget repositories for '$Query'..."

    $script:searchJob = Start-WingetterBackgroundSearch -Query $Query.Trim()
    $searchQuery = $Query.Trim()

    $script:searchTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:searchTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:searchTimer.Add_Tick({
        if ($script:searchJob.State -eq 'Running') { return }

        $script:searchTimer.Stop()
        $job = $script:searchJob
        $script:searchJob = $null
        $script:searchTimer = $null

        try {
            if ($job.State -eq 'Failed') {
                $err = Receive-Job -Job $job -ErrorAction SilentlyContinue
                throw ($err | Out-String)
            }
            $packages = Receive-Job -Job $job
            Complete-WingetterSearch -Packages $packages -Query $searchQuery
        } catch {
            Complete-WingetterSearch -Packages @() -Query $searchQuery -ErrorRecord $_
        } finally {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    })
    $script:searchTimer.Start()
}

function Complete-WingetterPackaging {
    param(
        [object]$Result = $null,
        [object]$ErrorRecord = $null
    )

    if ($script:packTimer) {
        $script:packTimer.Stop()
        $script:packTimer = $null
    }

    if ($script:packWorker) {
        if ($script:packWorker.PowerShell) {
            $script:packWorker.PowerShell.Dispose()
        }
        if ($script:packWorker.Runspace) {
            $script:packWorker.Runspace.Close()
        }
        $script:packWorker = $null
    }

    $script:progressQueue = $null
    $script:isRunning = $false
    Set-PackControlsEnabled -Enabled $true

    if ($ErrorRecord) {
        $progressStatus.Text = 'Packaging failed.'
        Add-LogLine -LogControl $logText -Message "Packaging failed: $($ErrorRecord.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            $window,
            "Packaging failed.`n`n$($ErrorRecord.Exception.Message)`n`nSee wingetter-packaging.log in the output folder if it was created.",
            'Wingetter',
            'OK',
            'Error'
        ) | Out-Null
        return
    }

    $script:lastOutputDirectory = $Result.VersionDirectory
    $openOutputButton.IsEnabled = $true
    Update-SandboxTestButtonState

    $Result = Invoke-PostPackagingIconSelection -Result $Result -OwnerWindow $window `
        -IconPreview $iconPreview -IconStatus $iconStatus -LogText $logText
    Set-IconPreview -ImageControl $iconPreview -StatusControl $iconStatus -ImagePath $Result.IconFile

    if ($Result.PackagingSucceeded) {
        $progressStatus.Text = 'Packaging completed successfully.'
        Add-LogLine -LogControl $logText -Message "Success: $($Result.IntuneWinFile)"
        [System.Windows.MessageBox]::Show(
            $window,
            "Package created successfully.`n`n$($Result.DisplayName)`n$($Result.IntuneWinFile)`n`nYou can click Test in Sandbox to confirm install, detection, and uninstall.",
            'Wingetter',
            'OK',
            'Information'
        ) | Out-Null
    } else {
        $progressStatus.Text = 'Packaging completed with warnings.'
        Add-LogLine -LogControl $logText -Message 'Metadata and scripts created, but .intunewin packaging failed or Content Prep Tool is unavailable.'
        [System.Windows.MessageBox]::Show(
            $window,
            "Package files were created, but the .intunewin step did not complete.`n`nOutput: $($Result.VersionDirectory)`n`nCheck wingetter-packaging.log for details.",
            'Wingetter',
            'OK',
            'Warning'
        ) | Out-Null
    }
}

function Start-WingetterPackagingFromUi {
    if (-not $script:selectedPackage) {
        [System.Windows.MessageBox]::Show($window, 'Search for and select an application before packaging.', 'Wingetter', 'OK', 'Warning') | Out-Null
        return
    }

    if ([string]::IsNullOrWhiteSpace($outputPathBox.Text)) {
        [System.Windows.MessageBox]::Show($window, 'Choose an output destination folder.', 'Wingetter', 'OK', 'Warning') | Out-Null
        return
    }

    $script:isRunning = $true
    Set-PackControlsEnabled -Enabled $false
    $progressBar.Value = 0
    Initialize-StepList -ListControl $stepList

    $versionOverride = $versionBox.Text.Trim()
    $outputPath = $outputPathBox.Text.Trim()
    $script:baseOutputPath = Get-WingetterBaseOutputPath -Path $outputPath -PackageId $script:selectedPackage.Id
    # Always pack into a folder named after the selected app.
    $appOutputPath = Get-WingetterAppOutputPath -BasePath $script:baseOutputPath -PackageId $script:selectedPackage.Id
    $outputPathBox.Text = $appOutputPath
    Save-WingetterSettings -OutputPath $script:baseOutputPath -LastPackageId $script:selectedPackage.Id

    $packageVersion = $versionOverride
    if (-not $packageVersion -and $script:selectedPackage.Version -and $script:selectedPackage.Version -ne 'Unknown') {
        $packageVersion = $script:selectedPackage.Version
    }

    $packArguments = @{
        PackageId = $script:selectedPackage.Id
        Version = $packageVersion
        Source = $script:selectedPackage.Source
        OutputPath = $appOutputPath
        IconPath = $script:customIconPath
        CollectIconCandidates = $true
    }

    $script:progressQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
    Add-LogLine -LogControl $logText -Message "Starting packaging for $($script:selectedPackage.Id)..."

    $script:packWorker = Start-WingetterBackgroundPackaging -PackArguments $packArguments -ProgressQueue $script:progressQueue

    $script:packTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:packTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:packTimer.Add_Tick({
        $item = $null
        while ($script:progressQueue -and $script:progressQueue.TryDequeue([ref]$item)) {
            Invoke-UiProgressUpdate -Event $item -ProgressBar $progressBar -ProgressStatus $progressStatus `
                -StepList $stepList -LogText $logText -StepMap $stepMap
        }

        if (-not $script:packWorker) { return }

        if ($script:packWorker.AsyncResult.IsCompleted) {
            $item = $null
            while ($script:progressQueue -and $script:progressQueue.TryDequeue([ref]$item)) {
                Invoke-UiProgressUpdate -Event $item -ProgressBar $progressBar -ProgressStatus $progressStatus `
                    -StepList $stepList -LogText $logText -StepMap $stepMap
            }

            $worker = $script:packWorker
            try {
                $result = $worker.PowerShell.EndInvoke($worker.AsyncResult)
                if ($result -is [array] -and $result.Count -eq 1) {
                    $result = $result[0]
                }
                Complete-WingetterPackaging -Result $result
            } catch {
                Complete-WingetterPackaging -ErrorRecord $_
            }
        }
    })
    $script:packTimer.Start()
}

$searchButton.Add_Click({ Invoke-WingetterSearch -Query $searchBox.Text })
$selectAppButton.Add_Click({ Invoke-WingetterSearch -Query $searchBox.Text })
$searchBox.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Return') {
        Invoke-WingetterSearch -Query $searchBox.Text
    }
})

$browseOutputButton.Add_Click({
    try {
        $initialPath = $script:baseOutputPath
        if (-not $initialPath -and $outputPathBox.Text) {
            $initialPath = $outputPathBox.Text.Trim()
        }

        $path = Show-FolderBrowser `
            -Description 'Select base output folder (each app gets its own subfolder)' `
            -SelectedPath $initialPath `
            -OwnerWindow $window

        if ($path) {
            $script:baseOutputPath = $path
            Update-OutputPathForSelectedApp
            $lastId = $null
            if ($script:selectedPackage -and $script:selectedPackage.Id) {
                $lastId = $script:selectedPackage.Id
            }
            Save-WingetterSettings -OutputPath $script:baseOutputPath -LastPackageId $lastId
            Add-LogLine -LogControl $logText -Message "Output base folder set to: $path"
            Update-SandboxTestButtonState
        }
    } catch {
        Add-LogLine -LogControl $logText -Message "Folder browser failed: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            $window,
            "Could not open the folder browser.`n`n$($_.Exception.Message)",
            'Wingetter',
            'OK',
            'Error'
        ) | Out-Null
    }
})

$browseIconButton.Add_Click({
    try {
        $path = Show-OpenFileDialog -OwnerWindow $window
        if ($path) {
            $script:customIconPath = $path
            Set-IconPreview -ImageControl $iconPreview -StatusControl $iconStatus -ImagePath $path
            Add-LogLine -LogControl $logText -Message "Custom icon selected: $path"
        }
    } catch {
        Add-LogLine -LogControl $logText -Message "Icon browser failed: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            $window,
            "Could not open the file browser.`n`n$($_.Exception.Message)",
            'Wingetter',
            'OK',
            'Error'
        ) | Out-Null
    }
})

$openOutputButton.Add_Click({
    if ($script:lastOutputDirectory -and (Test-Path $script:lastOutputDirectory)) {
        Start-Process explorer.exe $script:lastOutputDirectory | Out-Null
    }
})

$packButton.Add_Click({
    if ($script:isRunning) { return }
    Start-WingetterPackagingFromUi
})

$testSandboxButton.Add_Click({
    if ($script:isRunning) { return }
    Invoke-WingetterSandboxTestFromUi
})

$versionBox.Add_TextChanged({
    Update-SandboxTestButtonState
})

$installContentPrepButton.Add_Click({
    if ($script:isRunning -or $script:contentPrepInstallJob) { return }

    $confirm = [System.Windows.MessageBox]::Show(
        $window,
        "Install Microsoft Win32 Content Prep Tool via winget?`n`nwinget install --exact --id Microsoft.Win32ContentPrepTool",
        'Wingetter',
        'YesNo',
        'Question'
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $installContentPrepButton.IsEnabled = $false
    $prereqText.Text = 'Installing Content Prep Tool via winget...'
    $prereqText.Foreground = ConvertTo-WpfBrush '#5C6B7A'
    Add-LogLine -LogControl $logText -Message 'Installing Microsoft.Win32ContentPrepTool via winget...'

    $script:contentPrepInstallJob = Start-Job -ArgumentList $modulePath -ScriptBlock {
        param($ModulePath)
        Import-Module $ModulePath -Force
        Install-WingetterContentPrepTool
    }

    if ($script:contentPrepInstallTimer) {
        $script:contentPrepInstallTimer.Stop()
    }

    $script:contentPrepInstallTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:contentPrepInstallTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:contentPrepInstallTimer.Add_Tick({
        if (-not $script:contentPrepInstallJob -or $script:contentPrepInstallJob.State -eq 'Running') { return }

        $script:contentPrepInstallTimer.Stop()
        $job = $script:contentPrepInstallJob
        $script:contentPrepInstallJob = $null
        $script:contentPrepInstallTimer = $null

        try {
            if ($job.State -eq 'Failed') {
                $err = Receive-Job -Job $job -ErrorAction SilentlyContinue
                throw (($err | Out-String).Trim())
            }

            $result = Receive-Job -Job $job
            if ($result -is [array] -and $result.Count -eq 1) {
                $result = $result[0]
            }

            $prereqs = if ($result.Prerequisites) { $result.Prerequisites } else { Test-WingetterPrerequisites }
            $null = Update-PrereqStatusDisplay -Prerequisites $prereqs

            if ($result.Succeeded -and $prereqs.ContentPrepToolInstalled) {
                $pathNote = if ($result.ContentPrepToolPath) { $result.ContentPrepToolPath } else { 'available on PATH' }
                Add-LogLine -LogControl $logText -Message "Content Prep Tool installed: $pathNote"
                [System.Windows.MessageBox]::Show(
                    $window,
                    "Content Prep Tool is ready.`n`n$pathNote",
                    'Wingetter',
                    'OK',
                    'Information'
                ) | Out-Null
            } else {
                throw 'Install finished but intunewinapputil is still not available. You may need to restart Wingetter or add the tool to PATH.'
            }
        } catch {
            Add-LogLine -LogControl $logText -Message "Content Prep Tool install failed: $($_.Exception.Message)"
            $null = Update-PrereqStatusDisplay
            [System.Windows.MessageBox]::Show(
                $window,
                "Could not install the Content Prep Tool.`n`n$($_.Exception.Message)",
                'Wingetter',
                'OK',
                'Error'
            ) | Out-Null
        } finally {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    })
    $script:contentPrepInstallTimer.Start()
})

$window.Add_Closed({
    if ($script:searchTimer) { $script:searchTimer.Stop() }
    if ($script:packTimer) { $script:packTimer.Stop() }
    if ($script:iconPreviewTimer) { $script:iconPreviewTimer.Stop() }
    if ($script:contentPrepInstallTimer) { $script:contentPrepInstallTimer.Stop() }
    if ($script:sandboxDialog -and $script:sandboxDialog.Timer) {
        try { $script:sandboxDialog.Timer.Stop() } catch { }
    }
    if ($script:searchJob) { Remove-Job -Job $script:searchJob -Force -ErrorAction SilentlyContinue }
    if ($script:iconPreviewJob) { Remove-Job -Job $script:iconPreviewJob -Force -ErrorAction SilentlyContinue }
    if ($script:contentPrepInstallJob) { Remove-Job -Job $script:contentPrepInstallJob -Force -ErrorAction SilentlyContinue }
    if ($script:packWorker -and $script:packWorker.PowerShell) {
        try { $script:packWorker.PowerShell.Stop() } catch { }
        $script:packWorker.PowerShell.Dispose()
        $script:packWorker.Runspace.Close()
    }
})

if ($settings.LastPackageId) {
    Add-LogLine -LogControl $logText -Message "Last packaged app: $($settings.LastPackageId)"
    $previousPackage = Resolve-WingetterPackageVersionDirectory -Path $script:baseOutputPath -PackageId $settings.LastPackageId
    if ($previousPackage) {
        $script:lastOutputDirectory = $previousPackage
        $openOutputButton.IsEnabled = $true
    }
}

Update-SandboxTestButtonState
Add-LogLine -LogControl $logText -Message 'Wingetter GUI ready.'
[void]$window.ShowDialog()
