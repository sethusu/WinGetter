<#
.SYNOPSIS
    Launches the Wingetter graphical user interface.
.DESCRIPTION
    Provides a modern WPF GUI for searching Winget packages, selecting apps via
    radio buttons, configuring output destination, tracking live progress, and
    previewing application icons.
.EXAMPLE
    .\Start-WingetterGui.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $scriptRoot 'Modules\Wingetter.Core\Wingetter.Core.psm1'

if (-not (Test-Path $modulePath)) {
    Write-Error "Wingetter.Core module not found at: $modulePath"
    exit 1
}

Import-Module $modulePath -Force

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Wingetter - Intune Win32 Package Creator"
        Height="780" Width="1020"
        MinHeight="640" MinWidth="900"
        WindowStartupLocation="CenterScreen"
        Background="#F5F6FA">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Background" Value="#2563EB"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#94A3B8"/>
                </Trigger>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#1D4ED8"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#E2E8F0"/>
            <Setter Property="Foreground" Value="#1E293B"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#CBD5E1"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="BorderBrush" Value="#CBD5E1"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="#334155"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Margin" Value="0,0,0,10"/>
            <Setter Property="Padding" Value="10"/>
            <Setter Property="BorderBrush" Value="#E2E8F0"/>
            <Setter Property="Foreground" Value="#1E293B"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
    </Window.Resources>

    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="180"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <StackPanel Grid.Row="0" Margin="0,0,0,12">
            <TextBlock Text="Wingetter" FontSize="26" FontWeight="Bold" Foreground="#1E293B"/>
            <TextBlock Text="Create Intune Win32 packages from Winget applications" FontSize="13" Foreground="#64748B" Margin="0,2,0,0"/>
            <TextBlock x:Name="PrereqStatus" Text="Checking prerequisites..." FontSize="12" Foreground="#64748B" Margin="0,6,0,0"/>
        </StackPanel>

        <!-- Search -->
        <GroupBox Grid.Row="1" Header="Search Winget">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="SearchBox" Grid.Column="0" Margin="0,0,8,0"
                         ToolTip="Enter package ID or search term (e.g. JetBrains.WebStorm, chrome)"/>
                <Button x:Name="SearchButton" Grid.Column="1" Content="Search" Width="100"/>
            </Grid>
        </GroupBox>

        <!-- Main content: results + settings -->
        <Grid Grid.Row="2" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="2*"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- Package selection -->
            <GroupBox Grid.Column="0" Header="Select Application">
                <Grid>
                    <TextBlock x:Name="NoResultsText" Text="Search for an application to see results."
                               Foreground="#94A3B8" FontStyle="Italic" VerticalAlignment="Center"
                               HorizontalAlignment="Center" Visibility="Visible"/>
                    <ScrollViewer x:Name="ResultsScroller" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
                        <StackPanel x:Name="ResultsPanel" Margin="4"/>
                    </ScrollViewer>
                </Grid>
            </GroupBox>

            <!-- Settings + Icon -->
            <StackPanel Grid.Column="2">
                <GroupBox Header="Package Settings">
                    <StackPanel>
                        <Label Content="Output Destination"/>
                        <Grid Margin="0,0,0,8">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBox x:Name="OutputPathBox" Grid.Column="0" Margin="0,0,4,0"/>
                            <Button x:Name="BrowseOutputButton" Grid.Column="1" Content="Browse"
                                    Style="{StaticResource SecondaryButton}" Padding="10,6"/>
                        </Grid>
                        <Label Content="Version Override (optional)"/>
                        <TextBox x:Name="VersionBox" Margin="0,0,0,4"
                                 ToolTip="Leave blank to use the latest version from Winget"/>
                        <Label Content="Custom Icon (optional)"/>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBox x:Name="IconPathBox" Grid.Column="0" Margin="0,0,4,0"/>
                            <Button x:Name="BrowseIconButton" Grid.Column="1" Content="Browse"
                                    Style="{StaticResource SecondaryButton}" Padding="10,6"/>
                        </Grid>
                    </StackPanel>
                </GroupBox>

                <GroupBox Header="Icon Preview">
                    <Border Background="White" BorderBrush="#E2E8F0" BorderThickness="1"
                            CornerRadius="8" Height="140" HorizontalAlignment="Stretch">
                        <Grid>
                            <TextBlock x:Name="NoIconText" Text="No icon available"
                                       Foreground="#94A3B8" HorizontalAlignment="Center"
                                       VerticalAlignment="Center" FontStyle="Italic"/>
                            <Image x:Name="IconPreview" Stretch="Uniform" Margin="12"
                                   Visibility="Collapsed" MaxHeight="116"/>
                        </Grid>
                    </Border>
                </GroupBox>
            </StackPanel>
        </Grid>

        <!-- Progress -->
        <GroupBox Grid.Row="3" Header="Progress" Margin="0,0,0,10">
            <StackPanel>
                <TextBlock x:Name="ProgressStepText" Text="Ready" FontSize="13" Foreground="#334155" Margin="0,0,0,6"/>
                <ProgressBar x:Name="ProgressBar" Height="18" Minimum="0" Maximum="100" Value="0"/>
                <TextBlock x:Name="ProgressDetailText" Text="" FontSize="12" Foreground="#64748B" Margin="0,4,0,0"/>
            </StackPanel>
        </GroupBox>

        <!-- Log -->
        <GroupBox Grid.Row="4" Header="Activity Log">
            <TextBox x:Name="LogBox" IsReadOnly="True" TextWrapping="Wrap"
                     VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"
                     Background="#1E293B" Foreground="#E2E8F0" BorderThickness="0" Padding="8"/>
        </GroupBox>

        <!-- Actions -->
        <Grid Grid.Row="5" Margin="0,10,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="StatusBar" Grid.Column="0" VerticalAlignment="Center"
                       Foreground="#64748B" FontSize="12" Text="Ready to search"/>
            <Button x:Name="OpenOutputButton" Grid.Column="1" Content="Open Output Folder"
                    Style="{StaticResource SecondaryButton}" IsEnabled="False"/>
            <Button x:Name="ClearLogButton" Grid.Column="2" Content="Clear Log"
                    Style="{StaticResource SecondaryButton}"/>
            <Button x:Name="PackageButton" Grid.Column="3" Content="Create Package" Width="150" IsEnabled="False"/>
        </Grid>
    </Grid>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# Get named controls
$searchBox = $window.FindName('SearchBox')
$searchButton = $window.FindName('SearchButton')
$outputPathBox = $window.FindName('OutputPathBox')
$browseOutputButton = $window.FindName('BrowseOutputButton')
$versionBox = $window.FindName('VersionBox')
$iconPathBox = $window.FindName('IconPathBox')
$browseIconButton = $window.FindName('BrowseIconButton')
$resultsPanel = $window.FindName('ResultsPanel')
$resultsScroller = $window.FindName('ResultsScroller')
$noResultsText = $window.FindName('NoResultsText')
$progressBar = $window.FindName('ProgressBar')
$progressStepText = $window.FindName('ProgressStepText')
$progressDetailText = $window.FindName('ProgressDetailText')
$logBox = $window.FindName('LogBox')
$packageButton = $window.FindName('PackageButton')
$openOutputButton = $window.FindName('OpenOutputButton')
$clearLogButton = $window.FindName('ClearLogButton')
$statusBar = $window.FindName('StatusBar')
$prereqStatus = $window.FindName('PrereqStatus')
$iconPreview = $window.FindName('IconPreview')
$noIconText = $window.FindName('NoIconText')

# State
$script:SearchResults = @()
$script:SelectedPackage = $null
$script:LastOutputDirectory = $null
$script:IsRunning = $false
function New-HexBrush {
    param([string]$Hex)
    $color = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    return [System.Windows.Media.SolidColorBrush]::new($color)
}

# Default output path
$defaultOutput = if (Test-Path 'D:\Intoon In Progress') {
    'D:\Intoon In Progress'
}
else {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Wingetter Output'
}
$outputPathBox.Text = $defaultOutput

function Add-LogEntry {
    param([string]$Message, [string]$Level = 'Info')
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $prefix = switch ($Level) {
        'Success' { '[OK] ' }
        'Warning' { '[WARN] ' }
        'Error'   { '[ERR] ' }
        default   { '' }
    }
    $line = "[$timestamp] $prefix$Message"
    $logBox.AppendText("$line`r`n")
    $logBox.ScrollToEnd()
}

function Set-UiBusy {
    param([bool]$Busy)
    $script:IsRunning = $Busy
    $searchButton.IsEnabled = -not $Busy
    $packageButton.IsEnabled = (-not $Busy) -and ($null -ne $script:SelectedPackage)
    $searchBox.IsEnabled = -not $Busy
}

function Update-IconPreview {
    param([string]$Path)
    if ($Path -and (Test-Path $Path)) {
        try {
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.UriSource = [Uri]::new((Resolve-Path $Path).Path)
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.EndInit()
            $iconPreview.Source = $bitmap
            $iconPreview.Visibility = 'Visible'
            $noIconText.Visibility = 'Collapsed'
        }
        catch {
            $iconPreview.Visibility = 'Collapsed'
            $noIconText.Visibility = 'Visible'
        }
    }
    else {
        $iconPreview.Visibility = 'Collapsed'
        $noIconText.Visibility = 'Visible'
    }
}

function Show-SearchResults {
    param($Packages)

    $resultsPanel.Children.Clear()
    $script:SearchResults = $Packages
    $script:SelectedPackage = $null
    $packageButton.IsEnabled = $false

    if ($Packages.Count -eq 0) {
        $noResultsText.Text = 'No packages found. Try a different search term.'
        $noResultsText.Visibility = 'Visible'
        $resultsScroller.Visibility = 'Collapsed'
        return
    }

    $noResultsText.Visibility = 'Collapsed'
    $resultsScroller.Visibility = 'Visible'

    for ($i = 0; $i -lt $Packages.Count; $i++) {
        $pkg = $Packages[$i]
        $radio = New-Object System.Windows.Controls.RadioButton
        $radio.GroupName = 'PackageSelection'
        $radio.Margin = [Thickness]::new(0, 0, 0, 8)
        $radio.Padding = [Thickness]::new(8, 6, 8, 6)
        $radio.Tag = $pkg
        $radio.Cursor = [System.Windows.Input.Cursors]::Hand

        $content = New-Object System.Windows.Controls.StackPanel
        $nameBlock = New-Object System.Windows.Controls.TextBlock
        $nameBlock.Text = $pkg.Name
        $nameBlock.FontWeight = [System.Windows.FontWeights]::SemiBold
        $nameBlock.FontSize = 14
        $nameBlock.Foreground = New-HexBrush '#1E293B'

        $idBlock = New-Object System.Windows.Controls.TextBlock
        $idBlock.Text = "$($pkg.Id)  |  v$($pkg.Version)"
        $idBlock.FontSize = 12
        $idBlock.Foreground = New-HexBrush '#64748B'
        $idBlock.Margin = [Thickness]::new(0, 2, 0, 0)

        $content.Children.Add($nameBlock) | Out-Null
        $content.Children.Add($idBlock) | Out-Null
        $radio.Content = $content

        if ($i -eq 0) {
            $radio.IsChecked = $true
            $script:SelectedPackage = $pkg
            $packageButton.IsEnabled = -not $script:IsRunning
        }

        $radio.Add_Checked({
            param($sender, $e)
            if ($sender.IsChecked) {
                $script:SelectedPackage = $sender.Tag
                $packageButton.IsEnabled = -not $script:IsRunning
                $statusBar.Text = "Selected: $($script:SelectedPackage.Name)"
            }
        })

        $border = New-Object System.Windows.Controls.Border
        $border.BorderBrush = New-HexBrush '#E2E8F0'
        $border.BorderThickness = [Thickness]::new(1)
        $border.CornerRadius = [CornerRadius]::new(6)
        $border.Margin = [Thickness]::new(0, 0, 0, 6)
        $border.Child = $radio
        $border.Background = [System.Windows.Media.Brushes]::White

        $resultsPanel.Children.Add($border) | Out-Null
    }

    $statusBar.Text = "Found $($Packages.Count) package(s) — select one to package"
}

# Check prerequisites on load
$window.Add_Loaded({
    try {
        $prereq = Test-WingetterPrerequisites
        $parts = @()
        foreach ($check in $prereq.Checks.GetEnumerator()) {
            $icon = if ($check.Value.Ok) { '✓' } else { '✗' }
            $parts += "$icon $($check.Key)"
        }
        $prereqStatus.Text = ($parts -join '  |  ')
        if (-not $prereq.AllOk) {
            $prereqStatus.Foreground = New-HexBrush '#DC2626'
            Add-LogEntry -Message 'Some prerequisites are missing. Packaging may fail.' -Level Warning
            foreach ($check in $prereq.Checks.GetEnumerator()) {
                if (-not $check.Value.Ok) {
                    Add-LogEntry -Message "$($check.Key): $($check.Value.Detail)" -Level Warning
                }
            }
        }
        else {
            $prereqStatus.Foreground = New-HexBrush '#16A34A'
            Add-LogEntry -Message 'All prerequisites met. Ready to package.' -Level Success
        }
    }
    catch {
        $prereqStatus.Text = 'Could not verify prerequisites'
        Add-LogEntry -Message $_.Exception.Message -Level Error
    }
})

# Search
$searchButton.Add_Click({
    $query = $searchBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($query)) {
        [System.Windows.MessageBox]::Show('Enter a package ID or search term.', 'Wingetter', 'OK', 'Warning') | Out-Null
        return
    }

    Set-UiBusy -Busy $true
    $statusBar.Text = 'Searching...'
    Add-LogEntry -Message "Searching Winget for '$query'..."

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $runspace.SessionStateProxy.Path.SetLocation($scriptRoot) | Out-Null
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    $null = $powershell.AddScript({
        param($modPath, $q)
        Import-Module $modPath -Force
        Search-WingetPackage -Query $q
    }).AddArgument($modulePath).AddArgument($query)

    $handle = $powershell.BeginInvoke()
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        if ($handle.IsCompleted) {
            $timer.Stop()
            try {
                $results = $powershell.EndInvoke($handle)
                Show-SearchResults -Packages $results
                Add-LogEntry -Message "Found $($results.Count) package(s)." -Level Success
            }
            catch {
                Add-LogEntry -Message $_.Exception.Message -Level Error
                [System.Windows.MessageBox]::Show($_.Exception.Message, 'Search Failed', 'OK', 'Error') | Out-Null
                $statusBar.Text = 'Search failed'
            }
            finally {
                $powershell.Dispose()
                $runspace.Close()
                Set-UiBusy -Busy $false
            }
        }
    })
    $timer.Start()
})

$searchBox.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Return') {
        $searchButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
    }
})

# Browse output
$browseOutputButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select output destination for Intune packages'
    if ($outputPathBox.Text) { $dialog.SelectedPath = $outputPathBox.Text }
    if ($dialog.ShowDialog() -eq 'OK') {
        $outputPathBox.Text = $dialog.SelectedPath
    }
})

# Browse icon
$browseIconButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Image Files (*.png;*.jpg;*.ico)|*.png;*.jpg;*.jpeg;*.ico|All Files (*.*)|*.*'
    if ($dialog.ShowDialog() -eq 'OK') {
        $iconPathBox.Text = $dialog.FileName
        Update-IconPreview -Path $dialog.FileName
    }
})

# Clear log
$clearLogButton.Add_Click({
    $logBox.Clear()
})

# Open output
$openOutputButton.Add_Click({
    if ($script:LastOutputDirectory -and (Test-Path $script:LastOutputDirectory)) {
        Start-Process explorer.exe $script:LastOutputDirectory
    }
})

# Package
$packageButton.Add_Click({
    if (-not $script:SelectedPackage) {
        [System.Windows.MessageBox]::Show('Select a package from the search results.', 'Wingetter', 'OK', 'Warning') | Out-Null
        return
    }

    $outputPath = $outputPathBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($outputPath)) {
        [System.Windows.MessageBox]::Show('Specify an output destination.', 'Wingetter', 'OK', 'Warning') | Out-Null
        return
    }

    Set-UiBusy -Busy $true
    $progressBar.Value = 0
    $progressStepText.Text = 'Starting...'
    $progressDetailText.Text = ''
    $openOutputButton.IsEnabled = $false

    $pkg = $script:SelectedPackage
    $versionOverride = $versionBox.Text.Trim()
    $iconOverride = $iconPathBox.Text.Trim()

    Add-LogEntry -Message "Packaging $($pkg.Name) ($($pkg.Id))..."
    $statusBar.Text = "Packaging $($pkg.Name)..."

    $sync = [hashtable]::Synchronized(@{})
    $progressScript = {
        param($Update)
        $window.Dispatcher.Invoke([action]{
            if ($Update.Step) {
                $progressStepText.Text = $Update.Step
            }
            if ($Update.PercentComplete -ge 0) {
                $progressBar.Value = $Update.PercentComplete
            }
            if ($Update.Message) {
                $progressDetailText.Text = $Update.Message
                $level = if ($Update.Level) { $Update.Level } else { 'Info' }
                Add-LogEntry -Message $Update.Message -Level $level
            }
            if ($Update.IconPath) {
                Update-IconPreview -Path $Update.IconPath
            }
            if ($Update.OutputDirectory) {
                $script:LastOutputDirectory = $Update.OutputDirectory
                $openOutputButton.IsEnabled = $true
            }
        })
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('sync', $sync) | Out-Null
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace

    $null = $powershell.AddScript({
        param($modPath, $pkgId, $ver, $out, $icon, $cb)
        Import-Module $modPath -Force
        $params = @{
            PackageId         = $pkgId
            OutputPath        = $out
            ProgressCallback  = $cb
        }
        if ($ver) { $params.Version = $ver }
        if ($icon) { $params.IconPath = $icon }
        Invoke-WingetterPackage @params
    }).AddArgument($modulePath).AddArgument($pkg.Id).AddArgument($versionOverride).AddArgument($outputPath).AddArgument($iconOverride).AddArgument($progressScript)

    $handle = $powershell.BeginInvoke()
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({
        if ($handle.IsCompleted) {
            $timer.Stop()
            try {
                $result = $powershell.EndInvoke($handle)
                $progressBar.Value = 100
                $progressStepText.Text = 'Complete'
                $statusBar.Text = "Package created: $($result.DisplayName)"
                Add-LogEntry -Message "Package created successfully at $($result.OutputDirectory)" -Level Success
                Add-LogEntry -Message "IntuneWin file: $($result.IntuneWinFile)" -Level Success
                Update-IconPreview -Path $result.IconPath
                $script:LastOutputDirectory = $result.OutputDirectory
                $openOutputButton.IsEnabled = $true

                [System.Windows.MessageBox]::Show(
                    "Package created successfully!`n`n$($result.DisplayName) v$($result.Version)`n`nOutput:`n$($result.OutputDirectory)",
                    'Wingetter - Success',
                    'OK',
                    'Information'
                ) | Out-Null
            }
            catch {
                $progressStepText.Text = 'Failed'
                $statusBar.Text = 'Packaging failed'
                Add-LogEntry -Message $_.Exception.Message -Level Error
                [System.Windows.MessageBox]::Show(
                    "Packaging failed:`n`n$($_.Exception.Message)`n`nCheck packaging-error.log in the output folder for details.",
                    'Wingetter - Error',
                    'OK',
                    'Error'
                ) | Out-Null
            }
            finally {
                $powershell.Dispose()
                $runspace.Close()
                Set-UiBusy -Busy $false
                $packageButton.IsEnabled = ($null -ne $script:SelectedPackage)
            }
        }
    })
    $timer.Start()
})

$window.ShowDialog() | Out-Null
