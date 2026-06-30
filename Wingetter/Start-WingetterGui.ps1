<#
.SYNOPSIS
    Wingetter graphical interface for creating Intune Win32 packages from Winget.
.DESCRIPTION
    WPF-based GUI with Winget search, radio-button package selection, output path
    picker, live progress tracking, activity log, and icon preview.
.EXAMPLE
    .\Start-WingetterGui.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'Wingetter.Core.ps1')

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Wingetter — Intune Win32 Package Creator"
        Height="780" Width="980" MinHeight="640" MinWidth="860"
        WindowStartupLocation="CenterScreen"
        Background="#F5F6F8">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="140"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <StackPanel Grid.Row="0" Margin="0,0,0,12">
      <TextBlock Text="Wingetter" FontSize="22" FontWeight="SemiBold" Foreground="#1A1A2E"/>
      <TextBlock Text="Create Intune Win32 packages from Winget with detection, install/uninstall scripts, and upload metadata."
                 TextWrapping="Wrap" Foreground="#5A6270" Margin="0,4,0,0"/>
    </StackPanel>

    <!-- Search -->
    <Grid Grid.Row="1" Margin="0,0,0,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="txtSearch" Height="32" VerticalContentAlignment="Center"
               Padding="8,0" FontSize="13"
               ToolTip="Enter a Winget package ID or search term (e.g. JetBrains.WebStorm, chrome)"/>
      <Button x:Name="btnSearch" Grid.Column="1" Content="Search Winget" Width="130" Height="32"
              Margin="8,0,0,0" Padding="12,0" FontWeight="SemiBold"/>
      <Button x:Name="btnClear" Grid.Column="2" Content="Clear" Width="72" Height="32"
              Margin="8,0,0,0"/>
    </Grid>

    <!-- Main content: results + options -->
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="2*"/>
        <ColumnDefinition Width="12"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Search results -->
      <Border Grid.Column="0" BorderBrush="#D8DCE3" BorderThickness="1" CornerRadius="6" Background="White">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" Text="Search results — select one package" Margin="12,10,12,6"
                     FontWeight="SemiBold" Foreground="#333"/>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="8,0,8,8">
            <StackPanel x:Name="pnlResults"/>
          </ScrollViewer>
        </DockPanel>
      </Border>

      <!-- Options panel -->
      <StackPanel Grid.Column="2">
        <TextBlock Text="Package options" FontWeight="SemiBold" Margin="0,0,0,8"/>

        <TextBlock Text="Version override (optional)" Foreground="#5A6270" FontSize="11" Margin="0,0,0,2"/>
        <TextBox x:Name="txtVersion" Height="28" VerticalContentAlignment="Center" Padding="6,0"
                 ToolTip="Leave blank to use the version from Winget search"/>

        <TextBlock Text="Output destination" Foreground="#5A6270" FontSize="11" Margin="0,10,0,2"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBox x:Name="txtOutputPath" Height="28" VerticalContentAlignment="Center" Padding="6,0"/>
          <Button x:Name="btnBrowseOutput" Grid.Column="1" Content="..." Width="36" Height="28" Margin="6,0,0,0"/>
        </Grid>

        <TextBlock Text="Custom icon (optional)" Foreground="#5A6270" FontSize="11" Margin="0,10,0,2"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBox x:Name="txtIconPath" Height="28" VerticalContentAlignment="Center" Padding="6,0"/>
          <Button x:Name="btnBrowseIcon" Grid.Column="1" Content="..." Width="36" Height="28" Margin="6,0,0,0"/>
        </Grid>

        <Border Margin="0,14,0,0" BorderBrush="#D8DCE3" BorderThickness="1" CornerRadius="6"
                Background="White" Height="140">
          <DockPanel>
            <TextBlock DockPanel.Dock="Top" Text="Icon preview" Margin="10,8,10,4"
                       FontSize="11" Foreground="#5A6270"/>
            <Grid HorizontalAlignment="Center" VerticalAlignment="Center">
              <Image x:Name="imgIcon" Width="96" Height="96" Stretch="Uniform"/>
              <TextBlock x:Name="txtNoIcon" Text="No icon yet" Foreground="#AAB0B8"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
          </DockPanel>
        </Border>
      </StackPanel>
    </Grid>

    <!-- Progress -->
    <Border Grid.Row="3" Margin="0,12,0,8" Padding="12" BorderBrush="#D8DCE3" BorderThickness="1"
            CornerRadius="6" Background="White">
      <StackPanel>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="txtStep" Text="Ready" FontWeight="SemiBold"/>
          <TextBlock x:Name="txtPercent" Grid.Column="1" Text="0%" Foreground="#5A6270"/>
        </Grid>
        <ProgressBar x:Name="pbMain" Height="14" Margin="0,8,0,6" Minimum="0" Maximum="100"/>
        <TextBlock x:Name="txtStatus" Text="Search for an application to begin." Foreground="#5A6270"
                   TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

    <!-- Activity log -->
    <Border Grid.Row="4" BorderBrush="#D8DCE3" BorderThickness="1" CornerRadius="6" Background="#1E1E2E">
      <DockPanel>
        <TextBlock DockPanel.Dock="Top" Text="Activity log" Margin="10,6,10,4"
                   Foreground="#AAB0B8" FontSize="11"/>
        <ScrollViewer x:Name="svLog" VerticalScrollBarVisibility="Auto" Padding="8">
          <TextBox x:Name="txtLog" IsReadOnly="True" Background="Transparent" Foreground="#D4D8E0"
                   BorderThickness="0" FontFamily="Consolas" FontSize="11" TextWrapping="Wrap"/>
        </ScrollViewer>
      </DockPanel>
    </Border>

    <!-- Actions -->
    <Grid Grid.Row="5" Margin="0,12,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="txtFooter" VerticalAlignment="Center" Foreground="#5A6270" FontSize="11"/>
      <Button x:Name="btnOpenFolder" Grid.Column="1" Content="Open output folder" Width="150" Height="34"
              Margin="0,0,8,0" IsEnabled="False"/>
      <Button x:Name="btnPackage" Grid.Column="2" Content="Create package" Width="150" Height="34"
              FontWeight="SemiBold" IsEnabled="False"/>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

function Get-WpfControl([string]$Name) { return $window.FindName($Name) }

$txtSearch       = Get-WpfControl 'txtSearch'
$btnSearch       = Get-WpfControl 'btnSearch'
$btnClear        = Get-WpfControl 'btnClear'
$pnlResults      = Get-WpfControl 'pnlResults'
$txtVersion      = Get-WpfControl 'txtVersion'
$txtOutputPath   = Get-WpfControl 'txtOutputPath'
$btnBrowseOutput = Get-WpfControl 'btnBrowseOutput'
$txtIconPath     = Get-WpfControl 'txtIconPath'
$btnBrowseIcon   = Get-WpfControl 'btnBrowseIcon'
$imgIcon         = Get-WpfControl 'imgIcon'
$txtNoIcon       = Get-WpfControl 'txtNoIcon'
$txtStep         = Get-WpfControl 'txtStep'
$txtPercent      = Get-WpfControl 'txtPercent'
$pbMain          = Get-WpfControl 'pbMain'
$txtStatus       = Get-WpfControl 'txtStatus'
$txtLog          = Get-WpfControl 'txtLog'
$svLog           = Get-WpfControl 'svLog'
$btnOpenFolder   = Get-WpfControl 'btnOpenFolder'
$btnPackage      = Get-WpfControl 'btnPackage'
$txtFooter       = Get-WpfControl 'txtFooter'

$defaultOutput = if ($env:WINGETTER_OUTPUT_PATH) { $env:WINGETTER_OUTPUT_PATH } else { 'D:\Intoon In Progress' }
$txtOutputPath.Text = $defaultOutput

$script:SearchResults = @()
$script:SelectedPackage = $null
$script:LastOutputDirectory = $null
$script:IsBusy = $false
$script:RadioGroup = @()

function Add-LogLine {
    param([string]$Message, [string]$Level = 'Info')
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $prefix = switch ($Level) {
        'Success' { '[OK] ' }
        'Warning' { '[WARN] ' }
        'Error'   { '[ERR] ' }
        default   { '' }
    }
    $line = "[$timestamp] $prefix$Message"
    $txtLog.AppendText("$line`r`n")
    $txtLog.ScrollToEnd()
}

function Set-BusyState {
    param([bool]$Busy)
    $script:IsBusy = $Busy
    $btnSearch.IsEnabled = -not $Busy
    $btnPackage.IsEnabled = (-not $Busy) -and ($null -ne $script:SelectedPackage)
    $btnClear.IsEnabled = -not $Busy
    $btnBrowseOutput.IsEnabled = -not $Busy
    $btnBrowseIcon.IsEnabled = -not $Busy
    $txtSearch.IsEnabled = -not $Busy
}

function Update-ProgressUi {
    param([hashtable]$Event)

    if ($Event.Type -eq 'Log') {
        Add-LogLine -Message $Event.Message -Level $Event.Level
        return
    }

    if ($Event.Type -eq 'Icon' -and $Event.Path -and (Test-Path $Event.Path)) {
        try {
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.UriSource = [Uri]$Event.Path
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.EndInit()
            $imgIcon.Source = $bitmap
            $txtNoIcon.Visibility = 'Collapsed'
        }
        catch {
            Add-LogLine -Message "Could not load icon preview: $_" -Level Warning
        }
        return
    }

    if ($Event.Type -eq 'Progress') {
        if ($Event.Step) { $txtStep.Text = "Step $($Event.StepNumber)/$($Event.TotalSteps): $($Event.Step)" }
        if ($Event.Percent -ge 0) {
            $pbMain.Value = $Event.Percent
            $txtPercent.Text = "$([math]::Round($Event.Percent))%"
        }
        if ($Event.Message) { $txtStatus.Text = $Event.Message }
    }
}

function Show-IconPreview {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) {
        $imgIcon.Source = $null
        $txtNoIcon.Visibility = 'Visible'
        return
    }
    Update-ProgressUi @{ Type = 'Icon'; Path = $Path }
}

function Clear-SearchResults {
    $pnlResults.Children.Clear()
    $script:RadioGroup = @()
    $script:SelectedPackage = $null
    $btnPackage.IsEnabled = $false
}

function Add-SearchResultRadio {
    param($Package, [int]$Index)

    $border = New-Object System.Windows.Controls.Border
    $border.Margin = '0,0,0,6'
    $border.Padding = '10,8'
    $border.CornerRadius = 4
    $border.BorderThickness = 1
    $border.BorderBrush = '#E8EBF0'
    $border.Background = 'White'
    $border.Cursor = 'Hand'

    $panel = New-Object System.Windows.Controls.StackPanel
    $radio = New-Object System.Windows.Controls.RadioButton
    $radio.GroupName = 'WingetterPackage'
    $radio.Margin = '0,0,0,4'
    $radio.FontWeight = 'SemiBold'
    $radio.Content = "$($Package.Name)"
    $radio.Tag = $Package

    $idBlock = New-Object System.Windows.Controls.TextBlock
    $idBlock.Text = "ID: $($Package.Id)"
    $idBlock.Foreground = '#5A6270'
    $idBlock.FontSize = 11
    $idBlock.Margin = '22,0,0,0'

    $verBlock = New-Object System.Windows.Controls.TextBlock
    $verBlock.Text = "Version: $($Package.Version)"
    $verBlock.Foreground = '#5A6270'
    $verBlock.FontSize = 11
    $verBlock.Margin = '22,0,0,0'

    $panel.Children.Add($radio) | Out-Null
    $panel.Children.Add($idBlock) | Out-Null
    $panel.Children.Add($verBlock) | Out-Null
    $border.Child = $panel

    $selectAction = {
        param($pkg, $rb, $bd)
        $script:SelectedPackage = $pkg
        $rb.IsChecked = $true
        foreach ($b in $script:RadioGroup) {
            if ($b.Border -ne $bd) {
                $b.Border.Background = 'White'
                $b.Border.BorderBrush = '#E8EBF0'
            }
        }
        $bd.Background = '#F0F4FF'
        $bd.BorderBrush = '#4A7FE8'
        $btnPackage.IsEnabled = -not $script:IsBusy
        $txtFooter.Text = "Selected: $($pkg.Id)"
        if ([string]::IsNullOrWhiteSpace($txtVersion.Text)) {
            $txtVersion.Text = $pkg.Version
        }
    }

    $radio.Add_Checked({
        & $selectAction $Package $radio $border
    }.GetNewClosure())

    $border.Add_MouseLeftButtonUp({
        $radio.IsChecked = $true
    }.GetNewClosure())

    if ($Index -eq 0) { $radio.IsChecked = $true }

    $script:RadioGroup += @{ Border = $border; Radio = $radio }
    $pnlResults.Children.Add($border) | Out-Null
}

$btnBrowseOutput.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select output destination for Intune packages'
    if ($txtOutputPath.Text) { $dialog.SelectedPath = $txtOutputPath.Text }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtOutputPath.Text = $dialog.SelectedPath
    }
})

$btnBrowseIcon.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Image files (*.png;*.jpg;*.ico)|*.png;*.jpg;*.jpeg;*.ico|All files (*.*)|*.*'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtIconPath.Text = $dialog.FileName
        Show-IconPreview -Path $dialog.FileName
    }
})

$btnClear.Add_Click({
    Clear-SearchResults
    $txtSearch.Text = ''
    $txtVersion.Text = ''
    $txtStatus.Text = 'Search for an application to begin.'
    $txtStep.Text = 'Ready'
    $pbMain.Value = 0
    $txtPercent.Text = '0%'
    $txtFooter.Text = ''
    Add-LogLine 'Cleared search results.'
})

$btnSearch.Add_Click({
    $term = $txtSearch.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($term)) {
        [System.Windows.MessageBox]::Show('Enter a Winget package ID or search term.', 'Wingetter', 'OK', 'Warning') | Out-Null
        return
    }

    Set-BusyState -Busy $true
    Clear-SearchResults
    $pbMain.Value = 5
    $txtStep.Text = 'Searching Winget...'
    $txtStatus.Text = "Searching for '$term'..."
    Add-LogLine "Searching Winget for '$term'..."

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $runspace.SessionStateProxy.Path.SetLocation($scriptRoot) | Out-Null
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript({
        param($root, $searchTerm)
        . (Join-Path $root 'Wingetter.Core.ps1')
        Search-WingetPackages -SearchTerm $searchTerm
    }).AddArgument($scriptRoot).AddArgument($term)

    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()

        try {
            $results = $ps.EndInvoke($handle)
            $script:SearchResults = @($results)
            Clear-SearchResults

            if ($script:SearchResults.Count -eq 0) {
                Add-LogLine 'No packages found.' -Level Warning
                $txtStatus.Text = 'No packages found. Try a different search term.'
            }
            else {
                for ($i = 0; $i -lt $script:SearchResults.Count; $i++) {
                    Add-SearchResultRadio -Package $script:SearchResults[$i] -Index $i
                }
                Add-LogLine "Found $($script:SearchResults.Count) package(s)." -Level Success
                $txtStatus.Text = 'Select a package and click Create package.'
                $pbMain.Value = 10
            }
        }
        catch {
            Add-LogLine $_.Exception.Message -Level Error
            $txtStatus.Text = "Search failed: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Search failed', 'OK', 'Error') | Out-Null
        }
        finally {
            $ps.Dispose()
            $runspace.Close()
            Set-BusyState -Busy $false
        }
    })
    $timer.Start()
})

$btnPackage.Add_Click({
    if (-not $script:SelectedPackage) { return }

    $outputPath = $txtOutputPath.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($outputPath)) {
        [System.Windows.MessageBox]::Show('Select an output destination.', 'Wingetter', 'OK', 'Warning') | Out-Null
        return
    }

    $pkg = $script:SelectedPackage
    $versionOverride = $txtVersion.Text.Trim()
    $iconPath = $txtIconPath.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($iconPath)) { $iconPath = $null }

    Set-BusyState -Busy $true
    $btnOpenFolder.IsEnabled = $false
    $pbMain.Value = 0
  $txtStep.Text = 'Packaging...'
    Add-LogLine "Starting package for $($pkg.Id)..."

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $runspace.SessionStateProxy.Path.SetLocation($scriptRoot) | Out-Null
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    $progressQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()

    [void]$ps.AddScript({
        param($root, $packageId, $version, $output, $icon, $queue)
        . (Join-Path $root 'Wingetter.Core.ps1')
        $callback = {
            param($evt)
            $queue.Enqueue($evt)
        }
        Invoke-WingetterPackage -PackageId $packageId -Version $version -OutputPath $output -IconPath $icon -OnProgress $callback
    }).AddArgument($scriptRoot).AddArgument($pkg.Id).AddArgument($(if ($versionOverride) { $versionOverride } else { '' }))
      .AddArgument($outputPath).AddArgument($iconPath).AddArgument($progressQueue)

    $handle = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({
        $evt = $null
        while ($progressQueue.TryDequeue([ref]$evt)) {
            Update-ProgressUi -Event $evt
        }

        if (-not $handle.IsCompleted) { return }
        $timer.Stop()

        while ($progressQueue.TryDequeue([ref]$evt)) {
            Update-ProgressUi -Event $evt
        }

        try {
            $result = $ps.EndInvoke($handle)
            if ($result) {
                $script:LastOutputDirectory = $result.VersionDirectory
                $btnOpenFolder.IsEnabled = $true
                $txtFooter.Text = "Created: $($result.IntuneWinFile)"
                Add-LogLine "Package complete: $($result.IntuneWinFile)" -Level Success
                $txtStatus.Text = 'Package created successfully!'
                if ($result.IconPath) { Show-IconPreview -Path $result.IconPath }

                [System.Windows.MessageBox]::Show(
                    "Package created successfully!`n`n$($result.DisplayName) v$($result.Version)`n`n$($result.IntuneWinFile)",
                    'Wingetter',
                    'OK',
                    'Information'
                ) | Out-Null
            }
        }
        catch {
            Add-LogLine $_.Exception.Message -Level Error
            $txtStatus.Text = "Packaging failed. See wingetter-pack.log in the output folder."
            [System.Windows.MessageBox]::Show(
                "$($_.Exception.Message)`n`nA failure log (wingetter-pack.log) was written if the output folder was created.",
                'Packaging failed',
                'OK',
                'Error'
            ) | Out-Null
        }
        finally {
            $ps.Dispose()
            $runspace.Close()
            Set-BusyState -Busy $false
        }
    })
    $timer.Start()
})

$btnOpenFolder.Add_Click({
    if ($script:LastOutputDirectory -and (Test-Path $script:LastOutputDirectory)) {
        Start-Process explorer.exe -ArgumentList $script:LastOutputDirectory
    }
})

$txtSearch.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Return' -and -not $script:IsBusy) {
        $btnSearch.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
    }
})

Add-LogLine 'Wingetter ready. Search for an application to begin.'
$txtFooter.Text = 'Requires Winget and intunewinapputil on PATH'

[void]$window.ShowDialog()
