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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'Wingetter.psd1') -Force

function Read-XamlWindow {
    param([string]$XamlPath)
    $xaml = Get-Content -Path $XamlPath -Raw
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    return [Windows.Markup.XamlReader]::Load($reader)
}

function Show-FolderBrowser {
    param([string]$Description, [string]$SelectedPath)
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    if ($SelectedPath -and (Test-Path $SelectedPath)) {
        $dialog.SelectedPath = $SelectedPath
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }
    return $null
}

function Show-OpenFileDialog {
    param([string]$Filter = 'PNG images (*.png)|*.png|All files (*.*)|*.*')
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = $Filter
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileName
    }
    return $null
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
            $bitmap.UriSource = [Uri]::new($ImagePath)
            $bitmap.EndInit()
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
    $window = Read-XamlWindow -XamlPath $dialogPath
    $window.Owner = $OwnerWindow

    $summary = $window.FindName('SearchSummaryText')
    $panel = $window.FindName('ResultsPanel')
    $selectButton = $window.FindName('SelectButton')
    $cancelButton = $window.FindName('CancelButton')

    $summary.Text = "Found $($Packages.Count) result(s) for '$SearchQuery'. Select the application you want to package."
    $radioGroup = New-Object System.Windows.Controls.RadioButton
    $selectedPackage = $null
    $firstRadio = $null

    foreach ($package in $Packages) {
        $border = New-Object System.Windows.Controls.Border
        $border.Margin = '0,0,0,8'
        $border.Padding = '10'
        $border.CornerRadius = 6
        $border.BorderBrush = '#D8DEE9'
        $border.BorderThickness = 1
        $border.Background = 'White'

        $stack = New-Object System.Windows.Controls.StackPanel
        $radio = New-Object System.Windows.Controls.RadioButton
        $radio.GroupName = 'WingetterPackageSelection'
        $radio.Margin = '0,0,0,4'
        $radio.Content = "$($package.Name)  ($($package.Id))"
        $radio.FontWeight = 'SemiBold'
        $radio.Tag = $package
        $radio.Add_Checked({
            param($sender, $e)
            $script:selectedPackage = $sender.Tag
        }.GetNewClosure())

        if (-not $firstRadio) {
            $firstRadio = $radio
            $selectedPackage = $package
        }

        $versionText = New-Object System.Windows.Controls.TextBlock
        $versionText.Text = "Version: $($package.Version)$(if ($package.Source) { "  |  Source: $($package.Source)" })"
        $versionText.Foreground = '#5C6B7A'
        $versionText.Margin = '22,0,0,0'

        $stack.Children.Add($radio) | Out-Null
        $stack.Children.Add($versionText) | Out-Null
        $border.Child = $stack
        $panel.Children.Add($border) | Out-Null
    }

    if ($firstRadio) {
        $firstRadio.IsChecked = $true
    }

    $result = $null
    $selectButton.Add_Click({
        if ($script:selectedPackage) {
            $script:dialogResult = $script:selectedPackage
            $window.DialogResult = $true
            $window.Close()
        } else {
            [System.Windows.MessageBox]::Show($window, 'Please select an application.', 'Wingetter', 'OK', 'Warning') | Out-Null
        }
    }.GetNewClosure())

    $cancelButton.Add_Click({
        $window.DialogResult = $false
        $window.Close()
    })

    if ($window.ShowDialog()) {
        return $script:selectedPackage
    }
    return $null
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

function Initialize-StepList {
    param($ListControl)
    $ListControl.Items.Clear()
    $steps = @(
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
    foreach ($step in $steps) {
        $ListControl.Items.Add([PSCustomObject]@{ Icon = '○'; Text = $step }) | Out-Null
    }
}

function Update-StepList {
    param(
        $ListControl,
        [int]$StepIndex,
        [ValidateSet('Pending', 'Running', 'Completed', 'Failed')]
        [string]$State
    )

    if ($StepIndex -lt 0 -or $StepIndex -ge $ListControl.Items.Count) {
        return
    }

    $item = $ListControl.Items[$StepIndex]
    switch ($State) {
        'Running' { $item.Icon = '▶' }
        'Completed' { $item.Icon = '✓' }
        'Failed' { $item.Icon = '✗' }
        default { $item.Icon = '○' }
    }
    $ListControl.Items.Refresh()
}

# Main window
$mainXamlPath = Join-Path $PSScriptRoot 'Wingetter.MainWindow.xaml'
$window = Read-XamlWindow -XamlPath $mainXamlPath

$prereqText = $window.FindName('PrereqStatusText')
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
$packButton = $window.FindName('PackButton')

$script:selectedPackage = $null
$script:customIconPath = $null
$script:lastOutputDirectory = $null
$script:isRunning = $false

$settings = Get-WingetterSettings
$outputPathBox.Text = $settings.OutputPath
$searchBox.Text = $settings.LastSearch
Initialize-StepList -ListControl $stepList

$prereqs = Test-WingetterPrerequisites
if ($prereqs.Issues.Count -eq 0) {
    $prereqText.Text = "Ready | Winget $($prereqs.WingetVersion) | Content Prep Tool: $($prereqs.ContentPrepToolPath)"
    $prereqText.Foreground = '#2E7D32'
} else {
    $prereqText.Text = 'Missing prerequisites: ' + ($prereqs.Issues -join ' ')
    $prereqText.Foreground = '#C62828'
    $packButton.IsEnabled = $false
}

function Update-SelectedAppDisplay {
    if ($script:selectedPackage) {
        $selectedAppText.Text = "Selected: $($script:selectedPackage.Name) | $($script:selectedPackage.Id) | Version: $($script:selectedPackage.Version)"
        $selectedAppText.Foreground = '#1B2A41'
    } else {
        $selectedAppText.Text = 'No application selected.'
        $selectedAppText.Foreground = '#5C6B7A'
    }
}

function Invoke-WingetterSearch {
    param([string]$Query)

    if ([string]::IsNullOrWhiteSpace($Query)) {
        [System.Windows.MessageBox]::Show($window, 'Enter an application name or Winget package ID to search.', 'Wingetter', 'OK', 'Information') | Out-Null
        return
    }

    try {
        $searchButton.IsEnabled = $false
        $selectAppButton.IsEnabled = $false
        Add-LogLine -LogControl $logText -Message "Searching Winget for '$Query'..."
        $packages = Search-WingetPackages -Query $Query.Trim()
        Save-WingetterSettings -LastSearch $Query.Trim()

        if ($packages.Count -eq 0) {
            Add-LogLine -LogControl $logText -Message 'No packages found.'
            [System.Windows.MessageBox]::Show($window, "No packages found for '$Query'.", 'Wingetter', 'OK', 'Warning') | Out-Null
            return
        }

        if ($packages.Count -eq 1) {
            $script:selectedPackage = $packages[0]
            Add-LogLine -LogControl $logText -Message "Auto-selected $($script:selectedPackage.Id)."
        } else {
            $picked = Show-WingetterSearchDialog -Packages $packages -SearchQuery $Query -OwnerWindow $window
            if ($picked) {
                $script:selectedPackage = $picked
                Add-LogLine -LogControl $logText -Message "Selected $($script:selectedPackage.Id) from search results."
            }
        }

        Update-SelectedAppDisplay
    }
    catch {
        Add-LogLine -LogControl $logText -Message "Search failed: $_"
        [System.Windows.MessageBox]::Show($window, "Search failed:`n$_", 'Wingetter', 'OK', 'Error') | Out-Null
    }
    finally {
        $searchButton.IsEnabled = $true
        $selectAppButton.IsEnabled = $true
    }
}

$searchButton.Add_Click({
    Invoke-WingetterSearch -Query $searchBox.Text
})

$selectAppButton.Add_Click({
    Invoke-WingetterSearch -Query $searchBox.Text
})

$searchBox.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Return') {
        Invoke-WingetterSearch -Query $searchBox.Text
    }
})

$browseOutputButton.Add_Click({
    $path = Show-FolderBrowser -Description 'Select output destination for Wingetter packages' -SelectedPath $outputPathBox.Text
    if ($path) {
        $outputPathBox.Text = $path
        Save-WingetterSettings -OutputPath $path
    }
})

$browseIconButton.Add_Click({
    $path = Show-OpenFileDialog
    if ($path) {
        $script:customIconPath = $path
        Set-IconPreview -ImageControl $iconPreview -StatusControl $iconStatus -ImagePath $path
        Add-LogLine -LogControl $logText -Message "Custom icon selected: $path"
    }
})

$openOutputButton.Add_Click({
    if ($script:lastOutputDirectory -and (Test-Path $script:lastOutputDirectory)) {
        Start-Process explorer.exe $script:lastOutputDirectory | Out-Null
    }
})

$packButton.Add_Click({
    if ($script:isRunning) { return }

    if (-not $script:selectedPackage) {
        [System.Windows.MessageBox]::Show($window, 'Search for and select an application before packaging.', 'Wingetter', 'OK', 'Warning') | Out-Null
        return
    }

    if ([string]::IsNullOrWhiteSpace($outputPathBox.Text)) {
        [System.Windows.MessageBox]::Show($window, 'Choose an output destination folder.', 'Wingetter', 'OK', 'Warning') | Out-Null
        return
    }

    $script:isRunning = $true
    $packButton.IsEnabled = $false
    $searchButton.IsEnabled = $false
    $selectAppButton.IsEnabled = $false
    $openOutputButton.IsEnabled = $false
    $progressBar.Value = 0
    Initialize-StepList -ListControl $stepList

    $versionOverride = $versionBox.Text.Trim()
    $outputPath = $outputPathBox.Text.Trim()
    Save-WingetterSettings -OutputPath $outputPath -LastPackageId $script:selectedPackage.Id

    $stepMap = @{
        1 = 0; 2 = 1; 3 = 2; 4 = 3; 5 = 4; 6 = 5; 7 = 6; 8 = 7; 9 = 8; 10 = 9; 12 = 10
    }

    $onProgress = {
        param($Event)
        $window.Dispatcher.Invoke([action]{
            if ($Event.Type -eq 'Progress') {
                if ($Event.Percent -ge 0) {
                    $progressBar.Value = [math]::Min(100, $Event.Percent)
                }
                if ($Event.Message) {
                    $progressStatus.Text = "$($Event.StepName): $($Event.Message)"
                } else {
                    $progressStatus.Text = $Event.StepName
                }

                if ($stepMap.ContainsKey($Event.Step)) {
                    $index = $stepMap[$Event.Step]
                    for ($i = 0; $i -lt $index; $i++) {
                        Update-StepList -ListControl $stepList -StepIndex $i -State Completed
                    }
                    if ($Event.Status -eq 'Completed') {
                        Update-StepList -ListControl $stepList -StepIndex $index -State Completed
                    } elseif ($Event.Status -eq 'Failed') {
                        Update-StepList -ListControl $stepList -StepIndex $index -State Failed
                    } else {
                        Update-StepList -ListControl $stepList -StepIndex $index -State Running
                    }
                }

                Add-LogLine -LogControl $logText -Message "$($Event.StepName) - $($Event.Message)"
            } else {
                Add-LogLine -LogControl $logText -Message $Event.Message
            }
        })
    }

    $packParams = @{
        PackageId = $script:selectedPackage.Id
        OutputPath = $outputPath
        OnProgress = $onProgress
    }
    if ($versionOverride) { $packParams.Version = $versionOverride }
    if ($script:customIconPath) { $packParams.IconPath = $script:customIconPath }

    try {
        Add-LogLine -LogControl $logText -Message "Starting packaging for $($script:selectedPackage.Id)..."
        $result = Invoke-WingetterPackaging @packParams

        $script:lastOutputDirectory = $result.VersionDirectory
        $openOutputButton.IsEnabled = $true
        Set-IconPreview -ImageControl $iconPreview -StatusControl $iconStatus -ImagePath $result.IconFile

        $progressStatus.Text = 'Packaging completed successfully.'
        Add-LogLine -LogControl $logText -Message "Success: $($result.IntuneWinFile)"
        [System.Windows.MessageBox]::Show(
            $window,
            "Package created successfully.`n`n$($result.DisplayName)`n$($result.IntuneWinFile)",
            'Wingetter',
            'OK',
            'Information'
        ) | Out-Null
    }
    catch {
        $progressStatus.Text = 'Packaging failed.'
        Add-LogLine -LogControl $logText -Message "Packaging failed: $_"
        [System.Windows.MessageBox]::Show(
            $window,
            "Packaging failed.`n`n$_`n`nSee wingetter-packaging.log in the output folder if it was created.",
            'Wingetter',
            'OK',
            'Error'
        ) | Out-Null
    }
    finally {
        $script:isRunning = $false
        $packButton.IsEnabled = $true
        $searchButton.IsEnabled = $true
        $selectAppButton.IsEnabled = $true
    }
})

if ($settings.LastPackageId) {
    Add-LogLine -LogControl $logText -Message "Last packaged app: $($settings.LastPackageId)"
}

Add-LogLine -LogControl $logText -Message 'Wingetter GUI ready.'
$window.ShowDialog() | Out-Null
