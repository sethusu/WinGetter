function ConvertTo-WingetterXmlText {
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return ''
    }

    return [System.Security.SecurityElement]::Escape($Value)
}

function Write-WingetterSandboxJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        $Object
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = $Object | ConvertTo-Json -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } finally {
        if ($stream) {
            $stream.Dispose()
        }
    }
}

function Read-WingetterSandboxJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    foreach ($candidate in @($Path, "$Path.tmp")) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }

        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            try {
                $stream = [System.IO.File]::Open(
                    $candidate,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::ReadWrite
                )
                try {
                    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
                    try {
                        $raw = $reader.ReadToEnd()
                    } finally {
                        $reader.Dispose()
                    }
                } finally {
                    $stream.Dispose()
                }

                if ([string]::IsNullOrWhiteSpace($raw)) {
                    break
                }

                return $raw | ConvertFrom-Json
            } catch {
                if ($attempt -lt 2) {
                    Start-Sleep -Milliseconds 50
                    continue
                }
            }
        }
    }

    return $null
}

function Read-WingetterSandboxText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [switch]$Raw
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($Raw) { return '' }
        return @()
    }

    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
            try {
                $text = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
        } finally {
            $stream.Dispose()
        }

        if ($Raw) {
            return $text
        }
        if ([string]::IsNullOrEmpty($text)) {
            return @()
        }
        return @($text -split '\r\n|\n|\r')
    } catch {
        if ($Raw) { return '' }
        return @()
    }
}

function Get-WingetterSandboxFeatureName {
    return 'Containers-DisposableClientVM'
}

function Get-WingetterWindowsSandboxExePath {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($env:SystemRoot) {
        $candidates.Add((Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'))
        $candidates.Add((Join-Path $env:SystemRoot 'Sysnative\WindowsSandbox.exe'))
    }

    $cmd = Get-Command WindowsSandbox -ErrorAction SilentlyContinue
    if ($cmd) {
        if ($cmd.Source) { $candidates.Add([string]$cmd.Source) }
        if ($cmd.Path) { $candidates.Add([string]$cmd.Path) }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Test-WingetterWindowsSandbox {
    <#
    .SYNOPSIS
        Checks whether Windows Sandbox is available and enabled on this device.
    #>
    [CmdletBinding()]
    param()

    $featureName = Get-WingetterSandboxFeatureName
    $result = [ordered]@{
        Enabled         = $false
        Supported       = $false
        RestartPending  = $false
        FeatureName     = $featureName
        FeatureState    = $null
        ExecutablePath  = $null
        Edition         = $null
        Reason          = $null
        IsWindows       = $false
    }

    if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
        $result.Reason = 'Windows Sandbox is only available on Windows 10/11 Pro, Enterprise, or Education.'
        return [PSCustomObject]$result
    }

    $result.IsWindows = $true

    try {
        $result.Edition = [string](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID
    } catch {
        $result.Edition = $null
    }

    $homeEditions = @('Core', 'CoreN', 'CoreSingleLanguage', 'CoreCountrySpecific')
    if ($result.Edition -and ($homeEditions -contains $result.Edition)) {
        $result.Reason = "Windows Sandbox is not available on Windows Home (edition: $($result.Edition)). Use Windows 10/11 Pro, Enterprise, or Education."
        return [PSCustomObject]$result
    }

    $result.ExecutablePath = Get-WingetterWindowsSandboxExePath

    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop
        $result.FeatureState = [string]$feature.State
        $result.Supported = $true
    } catch {
        if ($result.ExecutablePath) {
            $result.Supported = $true
        } else {
            $result.Reason = "Windows Sandbox is not available on this device. $($_.Exception.Message)"
            return [PSCustomObject]$result
        }
    }

    $state = [string]$result.FeatureState
    if ($state -eq 'EnablePending' -or $state -eq 'DisablePending') {
        $result.RestartPending = $true
    }

    if ($state -eq 'EnablePending') {
        $result.Reason = 'Windows Sandbox was enabled but Windows must be restarted before it can be used.'
        return [PSCustomObject]$result
    }

    if ($state -eq 'Disabled') {
        $result.Supported = $true
        $result.Reason = 'Windows Sandbox is not enabled on this device.'
        return [PSCustomObject]$result
    }

    if ($result.ExecutablePath) {
        $result.Enabled = $true
        $result.Supported = $true
        $result.Reason = $null
        return [PSCustomObject]$result
    }

    if ($state -eq 'Enabled') {
        $result.Supported = $true
        $result.Reason = 'Windows Sandbox is enabled but WindowsSandbox.exe was not found. Restart Windows and try again.'
        return [PSCustomObject]$result
    }

    $result.Supported = $true
    $result.Reason = 'Windows Sandbox is not enabled on this device.'
    return [PSCustomObject]$result
}

function Install-WingetterWindowsSandbox {
    <#
    .SYNOPSIS
        Prompts for elevation and enables the Windows Sandbox optional feature.
    .DESCRIPTION
        Runs Enable-WindowsOptionalFeature for Containers-DisposableClientVM.
        A reboot is usually required before Windows Sandbox can start.
    #>
    [CmdletBinding()]
    param()

    $current = Test-WingetterWindowsSandbox
    if ($current.Enabled) {
        return [PSCustomObject]@{
            Succeeded      = $true
            AlreadyEnabled = $true
            RestartNeeded  = $false
            Message        = 'Windows Sandbox is already enabled.'
            Sandbox        = $current
        }
    }

    if (-not $current.IsWindows) {
        throw $current.Reason
    }

    if ($current.RestartPending) {
        return [PSCustomObject]@{
            Succeeded      = $true
            AlreadyEnabled = $false
            RestartNeeded  = $true
            Message        = $current.Reason
            Sandbox        = $current
        }
    }

    if (-not $current.Supported) {
        throw $current.Reason
    }

    $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("wingetter-sandbox-enable-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
    $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("wingetter-enable-sandbox-{0}.ps1" -f ([Guid]::NewGuid().ToString('N')))

    $enableScript = @'
param([Parameter(Mandatory = $true)][string]$ResultPath)

$ErrorActionPreference = 'Stop'
$payload = @{
    Succeeded = $false
    RestartNeeded = $false
    State = $null
    Error = $null
    ExitCode = 0
}

try {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -ErrorAction SilentlyContinue
    if ($feature -and [string]$feature.State -eq 'Enabled') {
        $payload.Succeeded = $true
        $payload.State = 'Enabled'
    } elseif ($feature -and [string]$feature.State -eq 'EnablePending') {
        $payload.Succeeded = $true
        $payload.RestartNeeded = $true
        $payload.State = 'EnablePending'
    } else {
        $enabled = Enable-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -All -NoRestart -ErrorAction Stop
        $payload.Succeeded = $true
        $payload.State = [string]$enabled.State
        $payload.RestartNeeded = [bool]$enabled.RestartNeeded
        if ($payload.State -eq 'EnablePending') {
            $payload.RestartNeeded = $true
        }
    }
} catch {
    $optionalError = $_.Exception.Message
    try {
        $dism = Start-Process -FilePath "$env:SystemRoot\System32\dism.exe" -ArgumentList @(
            '/online',
            '/enable-feature',
            '/featurename:Containers-DisposableClientVM',
            '/all',
            '/norestart'
        ) -Wait -PassThru -NoNewWindow
        $payload.ExitCode = [int]$dism.ExitCode
        if ($dism.ExitCode -eq 0 -or $dism.ExitCode -eq 3010) {
            $payload.Succeeded = $true
            $payload.RestartNeeded = ($dism.ExitCode -eq 3010)
            $payload.State = if ($dism.ExitCode -eq 3010) { 'EnablePending' } else { 'Enabled' }
            $payload.Error = $null
        } else {
            $payload.Error = "DISM failed with exit code $($dism.ExitCode). $optionalError"
        }
    } catch {
        $payload.Error = $_.Exception.Message
        if ($optionalError) {
            $payload.Error = "$optionalError $($_.Exception.Message)"
        }
    }
}

$payload | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8
'@

    Set-Content -LiteralPath $scriptPath -Value $enableScript -Encoding UTF8

    try {
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            $scriptPath
            '-ResultPath'
            $resultPath
        )

        if ($process -and $process.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $resultPath)) {
            throw "Elevated enable step exited with code $($process.ExitCode)."
        }
    } catch {
        throw "Could not enable Windows Sandbox (administrator approval is required). $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }

    $enableResult = Read-WingetterSandboxJson -Path $resultPath
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue

    if (-not $enableResult) {
        throw 'Windows Sandbox enable did not return a result. The elevation prompt may have been cancelled.'
    }

    if (-not $enableResult.Succeeded) {
        $errorText = if ($enableResult.Error) { [string]$enableResult.Error } else { 'Unknown error.' }
        throw "Failed to enable Windows Sandbox. $errorText"
    }

    $sandbox = Test-WingetterWindowsSandbox
    $restartNeeded = [bool]$enableResult.RestartNeeded -or [bool]$sandbox.RestartPending
    $message = if ($restartNeeded) {
        'Windows Sandbox was enabled. Restart Windows, then click Test in Sandbox again.'
    } elseif ($sandbox.Enabled) {
        'Windows Sandbox is enabled.'
    } else {
        'Windows Sandbox enable finished. If Test in Sandbox still cannot start, restart Windows and try again.'
    }

    return [PSCustomObject]@{
        Succeeded      = $true
        AlreadyEnabled = $false
        RestartNeeded  = $restartNeeded
        Message        = $message
        Sandbox        = $sandbox
    }
}

function Resolve-WingetterPackageVersionDirectory {
    <#
    .SYNOPSIS
        Finds a packaged version folder that contains install.ps1.
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$PackageId,
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $installHere = Join-Path $Path 'install.ps1'
    if (Test-Path -LiteralPath $installHere) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $searchRoots = [System.Collections.Generic.List[string]]::new()
    $searchRoots.Add($Path)
    if ($PackageId) {
        $appPath = Get-WingetterAppOutputPath -BasePath $Path -PackageId $PackageId
        if ($appPath -and ($searchRoots -notcontains $appPath)) {
            $searchRoots.Add($appPath)
        }
    }

    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        if ($Version) {
            $versionDir = Join-Path $root $Version
            if (Test-Path -LiteralPath (Join-Path $versionDir 'install.ps1')) {
                return [System.IO.Path]::GetFullPath($versionDir)
            }
        }

        $candidates = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'install.ps1') })
        if ($candidates.Count -gt 0) {
            $latest = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            return $latest.FullName
        }
    }

    return $null
}

function Test-WingetterSandboxPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionDirectory
    )

    if (-not $VersionDirectory -or -not (Test-Path -LiteralPath $VersionDirectory)) {
        return $false
    }

    foreach ($name in @('install.ps1', 'detection.ps1', 'uninstall.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $VersionDirectory $name))) {
            return $false
        }
    }

    return $true
}

function Get-WingetterSandboxPackageInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionDirectory
    )

    $dir = $VersionDirectory
    $packageId = ''
    $displayName = ''
    $version = ''
    if ($dir) {
        $version = Split-Path -Path $dir -Leaf
    }

    $appJsonPath = Join-Path $dir 'app.json'
    if ($dir -and (Test-Path -LiteralPath $appJsonPath)) {
        try {
            $app = Get-Content -LiteralPath $appJsonPath -Raw | ConvertFrom-Json
            if ($app.packageIdentifier) { $packageId = [string]$app.packageIdentifier }
            if ($app.displayName) { $displayName = [string]$app.displayName }
            if ($app.version) { $version = [string]$app.version }
        } catch {
            # Metadata is optional for sandbox testing.
        }
    }

    $installer = $null
    if ($dir -and (Test-Path -LiteralPath $dir)) {
        $installer = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -in '.exe', '.msi', '.msix', '.appx' -and
                $_.Name -notlike '*intunewin*'
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    $reason = $null
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
        $reason = 'Package folder was not found. Create a package first.'
    } elseif (-not (Test-Path -LiteralPath (Join-Path $dir 'install.ps1'))) {
        $reason = 'install.ps1 was not found. Create a package first.'
    } elseif (-not (Test-Path -LiteralPath (Join-Path $dir 'detection.ps1'))) {
        $reason = 'detection.ps1 was not found. Create a package first.'
    } elseif (-not (Test-Path -LiteralPath (Join-Path $dir 'uninstall.ps1'))) {
        $reason = 'uninstall.ps1 was not found. Create a package first.'
    } elseif (-not $installer) {
        $reason = 'No installer file (.exe, .msi, .msix, or .appx) was found in the package folder.'
    }

    return [PSCustomObject]@{
        Ready             = ($null -eq $reason)
        Reason            = $reason
        VersionDirectory  = if ($dir) { [System.IO.Path]::GetFullPath($dir) } else { $dir }
        PackageId         = $packageId
        DisplayName       = $displayName
        Version           = $version
        InstallerFile     = if ($installer) { $installer.FullName } else { $null }
        InstallScript     = Join-Path $dir 'install.ps1'
        DetectionScript   = Join-Path $dir 'detection.ps1'
        UninstallScript   = Join-Path $dir 'uninstall.ps1'
    }
}

function New-WingetterSandboxGuestScript {
    return @'
# Windows Sandbox guest coordinator generated by Wingetter.
# Polls C:\WingetterSandbox\command.json and runs install / detect / uninstall.

$ErrorActionPreference = 'Continue'
$mappedPackageRoot = 'C:\WingetterPackage'
$packageRoot = 'C:\WingetterTest'
$handshakeRoot = 'C:\WingetterSandbox'
$commandPath = Join-Path $handshakeRoot 'command.json'
$statusPath = Join-Path $handshakeRoot 'status.json'
$statusNdjsonPath = Join-Path $handshakeRoot 'status.ndjson'
$heartbeatPath = Join-Path $handshakeRoot 'heartbeat.json'
$guestLogPath = Join-Path $handshakeRoot 'guest.log'

function Write-GuestLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        Add-Content -LiteralPath $guestLogPath -Value $line -Encoding UTF8
    } catch { }
    Write-Host $line
}

function Write-GuestJson {
    param([string]$Path, $Object)
    $json = $Object | ConvertTo-Json -Depth 6
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } finally {
        if ($stream) {
            $stream.Dispose()
        }
    }
}

function Write-Heartbeat {
    Write-GuestJson -Path $heartbeatPath -Object @{
        alive = $true
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        computerName = $env:COMPUTERNAME
    }
}

function Write-Status {
    param(
        [string]$Step,
        [string]$State,
        [object]$ExitCode = $null,
        [string]$Message = '',
        [object]$SilentUiDetected = $null,
        [object]$SilentUiWindows = $null
    )
    $payload = @{
        step = $Step
        state = $State
        exitCode = $ExitCode
        message = $Message
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($null -ne $SilentUiDetected) {
        $payload.silentUiDetected = [bool]$SilentUiDetected
    }
    if ($SilentUiWindows) {
        $payload.silentUiWindows = $SilentUiWindows
    }
    # Mapped-folder overwrites of status.json often stay stale on the host.
    # guest.log appends do propagate, so also append a status line and a new snapshot file.
    $json = $payload | ConvertTo-Json -Compress -Depth 6
    try {
        Add-Content -LiteralPath $statusNdjsonPath -Value $json -Encoding UTF8
    } catch { }
    $snapshot = Join-Path $handshakeRoot ('status-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff') + '.json')
    try {
        Write-GuestJson -Path $snapshot -Object $payload
    } catch { }
    try {
        Write-GuestJson -Path $statusPath -Object $payload
    } catch { }
    if ($State -eq 'completed' -or $State -eq 'failed') {
        Write-GuestLog ("STEP_DONE step={0} state={1} exitCode={2}" -f $Step, $State, $ExitCode)
    }
}

function Read-Command {
    if (-not (Test-Path -LiteralPath $commandPath)) {
        return $null
    }
    try {
        $raw = Get-Content -LiteralPath $commandPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Set-LocalInstallCommandOverride {
    param([string]$Command)
    $path = Join-Path $packageRoot 'install.ps1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "install.ps1 not found at $path"
    }
    $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    if ($raw -notmatch '(?s)\$installCommand = @''') {
        throw 'install.ps1 does not contain an $installCommand here-string to override.'
    }
    $nl = [Environment]::NewLine
    $replacement = ('$installCommand = @''' + $nl + $Command + $nl + '''@')
    $updated = [regex]::Replace($raw, '(?s)\$installCommand = @''.*?''@', $replacement, 1)
    if ($updated -eq $raw) {
        throw 'Failed to patch install.ps1 install command override.'
    }
    Set-Content -LiteralPath $path -Value $updated -Encoding UTF8
    Write-GuestLog ("Applied install command override: {0}" -f $Command)
}

function Invoke-BestEffortCleanupBeforeRetry {
    $scriptPath = Join-Path $packageRoot 'uninstall.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return
    }
    Write-GuestLog 'Best-effort uninstall before silent-switch retry'
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) -PassThru -NoNewWindow -WindowStyle Hidden
        if (-not $proc.WaitForExit(120000)) {
            Stop-ProcessTree -Id $proc.Id
            Write-GuestLog 'Best-effort uninstall timed out after 120 seconds'
        } else {
            Write-GuestLog ("Best-effort uninstall finished with exit code {0}" -f $proc.ExitCode)
        }
    } catch {
        Write-GuestLog "Best-effort uninstall failed: $_"
    }
}

function Copy-PackageStepLogs {
    param(
        [string]$Step,
        [int]$ExitCode,
        [string]$StdoutPath,
        [string]$StderrPath
    )

    $stepLogDir = Join-Path $handshakeRoot ('logs\' + $Step)
    if (-not (Test-Path -LiteralPath $stepLogDir)) {
        New-Item -ItemType Directory -Path $stepLogDir -Force | Out-Null
    }

    Write-GuestJson -Path (Join-Path $stepLogDir 'step.json') -Object @{
        step = $Step
        exitCode = $ExitCode
        finishedAt = (Get-Date).ToUniversalTime().ToString('o')
        computerName = $env:COMPUTERNAME
    }

    foreach ($sourcePath in @($StdoutPath, $StderrPath)) {
        if ($sourcePath -and (Test-Path -LiteralPath $sourcePath)) {
            Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $stepLogDir ([System.IO.Path]::GetFileName($sourcePath))) -Force -ErrorAction SilentlyContinue
        }
    }

    $imeLogs = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
    if (Test-Path -LiteralPath $imeLogs) {
        Get-ChildItem -LiteralPath $imeLogs -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stepLogDir $_.Name) -Force -ErrorAction SilentlyContinue
        }
        Write-GuestLog "Copied Intune logs for $Step to $stepLogDir"
    } else {
        Write-GuestLog "No Intune log folder found at $imeLogs"
    }
}

$uiIgnoreProcessNames = @(
    'powershell', 'powershell_ise', 'pwsh', 'cmd', 'conhost', 'explorer',
    'WindowsSandbox', 'WindowsSandboxClient', 'msedge', 'SearchHost', 'SearchUI',
    'StartMenuExperienceHost', 'ShellExperienceHost', 'TextInputHost',
    'ApplicationFrameHost', 'SystemSettings', 'dwm', 'sihost', 'ctfmon',
    'RuntimeBroker', 'LockApp', 'WWAHost'
)

function Test-IgnoredUiProcess {
    param([string]$ProcessName)
    foreach ($name in $uiIgnoreProcessNames) {
        if ([string]::Equals($name, $ProcessName, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-IgnoredInstallerSplash {
    param(
        [string]$ProcessName,
        [string]$Title
    )
    $t = ([string]$Title).Trim()
    if ($t -eq '(visible window, no title)') {
        $t = ''
    }
    # Inno Setup unpacks to {installer}.tmp. That process often has a generic
    # "Setup" window even under /VERYSILENT. The language wizard title is
    # "Select Setup Language", not "Setup".
    if ($ProcessName -match '\.tmp$') {
        if ([string]::IsNullOrWhiteSpace($t) -or $t -eq 'Setup' -or $t -eq 'Installing') {
            return $true
        }
    }
    return $false
}

function Get-InteractiveWindowSnapshot {
    $snapshot = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.MainWindowHandle -ne 0 -and $_.MainWindowHandle -ne [IntPtr]::Zero) {
            $snapshot[$_.Id] = $true
        }
    }
    return $snapshot
}

function Save-DesktopScreenshot {
    param([string]$Path)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bmp)
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $directory = Split-Path -Path $Path -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bmp.Dispose()
        return $true
    } catch {
        Write-GuestLog "Could not capture screenshot: $_"
        return $false
    }
}

function Stop-ProcessTree {
    param([int]$Id)
    if ($Id -le 0) { return }
    try {
        & taskkill.exe /PID $Id /T /F | Out-Null
    } catch { }
}

function Invoke-PackageStep {
    param(
        [ValidateSet('install', 'detect', 'uninstall')]
        [string]$Step
    )

    $scriptName = switch ($Step) {
        'install' { 'install.ps1' }
        'detect' { 'detection.ps1' }
        'uninstall' { 'uninstall.ps1' }
    }
    $scriptPath = Join-Path $packageRoot $scriptName

    Write-Host ''
    Write-Host ('========== {0} ==========' -f $Step.ToUpper())
    Write-GuestLog "Starting $scriptName"
    Write-Status -Step $Step -State 'running' -Message "Running $scriptName"

    $stepLogDir = Join-Path $handshakeRoot ('logs\' + $Step)
    if (-not (Test-Path -LiteralPath $stepLogDir)) {
        New-Item -ItemType Directory -Path $stepLogDir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-GuestLog "Missing $scriptPath"
        Write-Status -Step $Step -State 'failed' -ExitCode 1 -Message "$scriptName was not found in the mapped package folder."
        Copy-PackageStepLogs -Step $Step -ExitCode 1
        return
    }

    $logDir = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # Redirect to local disk. Mapped-folder stdout files stay open while the
    # host polls them, which can prevent powershell.exe from exiting.
    $localStepDir = Join-Path $env:TEMP ('WingetterStep-' + $Step)
    if (Test-Path -LiteralPath $localStepDir) {
        Remove-Item -LiteralPath $localStepDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $localStepDir -Force | Out-Null
    $stdoutPath = Join-Path $localStepDir 'console-stdout.txt'
    $stderrPath = Join-Path $localStepDir 'console-stderr.txt'

    function Copy-LiveStepOutput {
        try {
            if (Test-Path -LiteralPath $stdoutPath) {
                Copy-Item -LiteralPath $stdoutPath -Destination (Join-Path $stepLogDir 'console-stdout.txt') -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $stderrPath) {
                Copy-Item -LiteralPath $stderrPath -Destination (Join-Path $stepLogDir 'console-stderr.txt') -Force -ErrorAction SilentlyContinue
            }
            $imeLogs = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
            if (Test-Path -LiteralPath $imeLogs) {
                Get-ChildItem -LiteralPath $imeLogs -File -ErrorAction SilentlyContinue | ForEach-Object {
                    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stepLogDir $_.Name) -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { }
    }

    function Test-LocalScriptFinished {
        foreach ($candidate in @($stdoutPath, $stderrPath)) {
            if (-not (Test-Path -LiteralPath $candidate)) { continue }
            try {
                $text = Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop
                if ($text -match 'Windows PowerShell transcript end') { return $true }
                if ($text -match 'Install completed successfully') { return $true }
                if ($text -match 'Uninstall completed successfully') { return $true }
                if ($text -match 'not detected in registry, exiting with code') { return $true }
                if ($text -match 'is installed with version') { return $true }
                if ($text -match 'Uninstall returned exit code:') { return $true }
                if ($text -match 'Install failed with exit code') { return $true }
            } catch { }
        }
        return $false
    }

    # New visible windows during a silent step mean the installer ignored its
    # switches (for example Inno Setup Select Setup Language).
    $windowBaseline = Get-InteractiveWindowSnapshot
    $uiEvents = New-Object System.Collections.Generic.List[object]
    $killedForUi = $false
    $timedOut = $false
    $uiDetectedAt = $null
    $deadline = (Get-Date).AddMinutes(12)
    $ignoredSplashIds = @{}

    Set-Location -Path $packageRoot
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    $scriptFinished = $false
    while ($process) {
        try { $process.Refresh() } catch { }
        if ($process.HasExited) { break }

        Write-Heartbeat
        Copy-LiveStepOutput
        if ((Get-Date) -gt $deadline) {
            $timedOut = $true
            Write-GuestLog "Timed out waiting for $scriptName after 12 minutes. Stopping the process tree."
            Stop-ProcessTree -Id $process.Id
            break
        }

        Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.MainWindowHandle -eq 0 -or $_.MainWindowHandle -eq [IntPtr]::Zero) { return }
            if ($windowBaseline.ContainsKey($_.Id)) { return }
            if (Test-IgnoredUiProcess -ProcessName $_.ProcessName) { return }

            $title = [string]$_.MainWindowTitle
            if ([string]::IsNullOrWhiteSpace($title)) {
                $title = '(visible window, no title)'
            }
            if (Test-IgnoredInstallerSplash -ProcessName $_.ProcessName -Title $title) {
                if (-not $ignoredSplashIds.ContainsKey($_.Id)) {
                    $ignoredSplashIds[$_.Id] = $true
                    Write-GuestLog ("Ignoring Inno extractor window '{0}' ({1}); this is not a setup wizard." -f $title, $_.ProcessName)
                }
                return
            }
            foreach ($existing in $uiEvents) {
                if ($existing.processId -eq $_.Id) { return }
            }
            $uiEvents.Add(@{
                processName = $_.ProcessName
                windowTitle = $title
                processId = $_.Id
                detectedAt = (Get-Date).ToUniversalTime().ToString('o')
            }) | Out-Null
            if (-not $uiDetectedAt) {
                $uiDetectedAt = Get-Date
                $shotPath = Join-Path $stepLogDir 'ui-detected.png'
                if (Save-DesktopScreenshot -Path $shotPath) {
                    Write-GuestLog "Saved UI screenshot to $shotPath"
                }
            }
            Write-GuestLog ("WARNING: interactive window detected during {0}: '{1}' ({2}). The step is not silent." -f $Step, $title, $_.ProcessName)
            Write-Status -Step $Step -State 'running' -Message ("NOT SILENT: interactive window '{0}' ({1}). Capturing diagnostics, then stopping the installer." -f $title, $_.ProcessName) -SilentUiDetected $true -SilentUiWindows @($uiEvents)
        }

        if ($uiDetectedAt -and -not $killedForUi) {
            $waited = ((Get-Date) - $uiDetectedAt).TotalSeconds
            if ($waited -ge 12) {
                $killedForUi = $true
                Write-GuestLog "Stopping $scriptName because an interactive window blocked a silent install."
                Stop-ProcessTree -Id $process.Id
                break
            }
        }

        if (-not $scriptFinished -and (Test-LocalScriptFinished)) {
            $scriptFinished = $true
            Write-GuestLog "$scriptName output ended; waiting for powershell.exe to exit."
            try { $process.WaitForExit(15000) | Out-Null } catch { }
            try { $process.Refresh() } catch { }
            if (-not $process.HasExited) {
                Write-GuestLog "$scriptName finished writing output but powershell.exe is still running. Stopping it so confirmation can continue."
                Stop-ProcessTree -Id $process.Id
            }
            break
        }

        Start-Sleep -Seconds 1
    }

    if ($process) {
        try { $process.Refresh() } catch { }
    }
    if ($process -and -not $process.HasExited) {
        try { $process.WaitForExit(20000) | Out-Null } catch { }
        try { $process.Refresh() } catch { }
    }
    if ($process -and -not $process.HasExited) {
        Stop-ProcessTree -Id $process.Id
        try { $process.WaitForExit(5000) | Out-Null } catch { }
        try { $process.Refresh() } catch { }
    }

    Copy-LiveStepOutput

    $exitCode = 1
    if ($killedForUi) {
        $exitCode = 1603
    } elseif ($timedOut) {
        $exitCode = 1603
    } else {
        $outputExit = $null
        foreach ($candidate in @($stdoutPath, $stderrPath)) {
            if (-not (Test-Path -LiteralPath $candidate)) { continue }
            try {
                $text = Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop
                if ($text -match 'Install failed with exit code (-?\d+)') { $outputExit = [int]$Matches[1]; break }
                if ($text -match 'Uninstall returned exit code:\s*(-?\d+)') { $outputExit = [int]$Matches[1]; break }
                if ($text -match 'not detected in registry, exiting with code 1') { $outputExit = 1; break }
                if ($text -match 'Install completed successfully \(hard reboot required - 1641\)') { $outputExit = 1641; break }
                if ($text -match 'Install completed successfully \(reboot required - 3010\)') { $outputExit = 3010; break }
                if ($text -match 'Another installation is already in progress \(1618\)') { $outputExit = 1618; break }
                if ($text -match 'Install completed successfully') { $outputExit = 0; break }
                if ($text -match 'Uninstall completed successfully') { $outputExit = 0; break }
                if ($text -match 'is installed with version') { $outputExit = 0; break }
            } catch { }
        }
        if ($null -ne $outputExit) {
            $exitCode = $outputExit
        } elseif ($process -and $null -ne $process.ExitCode -and [int]$process.ExitCode -ge 0) {
            $exitCode = [int]$process.ExitCode
        } elseif ($scriptFinished) {
            $exitCode = 0
        }
    }

    $silentUi = ($uiEvents.Count -gt 0)
    if ($silentUi) {
        Write-GuestJson -Path (Join-Path $stepLogDir 'ui-activity.json') -Object @{
            step = $Step
            notSilent = $true
            killedForUi = $killedForUi
            timedOut = $timedOut
            events = @($uiEvents)
        }
    }

    Copy-PackageStepLogs -Step $Step -ExitCode $exitCode -StdoutPath $stdoutPath -StderrPath $stderrPath

    $message = "$scriptName finished with exit code $exitCode."
    if ($silentUi) {
        $titles = @($uiEvents | ForEach-Object { $_.windowTitle }) -join '; '
        $message = "$scriptName was not silent. Interactive window(s): $titles. Exit code $exitCode. Screenshot and logs were copied for diagnostics."
    } elseif ($timedOut) {
        $message = "$scriptName timed out after 12 minutes and was stopped. Exit code $exitCode."
    }
    Write-GuestLog $message
    Write-Host $message
    Write-Host 'Waiting for confirmation in Wingetter...'
    Write-Status -Step $Step -State 'completed' -ExitCode ([int]$exitCode) -Message $message -SilentUiDetected $silentUi -SilentUiWindows @($uiEvents)
}

$deadline = (Get-Date).AddMinutes(2)
while (-not (Test-Path -LiteralPath (Join-Path $mappedPackageRoot 'install.ps1'))) {
    if ((Get-Date) -gt $deadline) {
        Write-GuestLog "Mapped package folder not available: $mappedPackageRoot"
        Write-Status -Step 'idle' -State 'failed' -ExitCode 1 -Message 'Mapped package folder was not available inside Windows Sandbox.'
        return
    }
    Start-Sleep -Seconds 1
}

if (-not (Test-Path -LiteralPath $handshakeRoot)) {
    New-Item -ItemType Directory -Path $handshakeRoot -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $packageRoot)) {
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
}
Copy-Item -Path (Join-Path $mappedPackageRoot '*') -Destination $packageRoot -Recurse -Force
Write-GuestLog "Copied package files to $packageRoot"

Write-GuestLog 'Windows Sandbox guest coordinator is ready.'
Write-Heartbeat
Write-Status -Step 'idle' -State 'waiting' -Message 'Waiting for the first test command from Wingetter.'

$lastIssuedAt = ''
while ($true) {
    Write-Heartbeat
    $cmd = Read-Command
    if ($cmd -and $cmd.issuedAt -and ([string]$cmd.issuedAt -ne $lastIssuedAt)) {
        $lastIssuedAt = [string]$cmd.issuedAt
        $action = [string]$cmd.action
        switch ($action) {
            'install' {
                try {
                    if ($cmd.PSObject.Properties['installOverride'] -and $cmd.installOverride) {
                        Set-LocalInstallCommandOverride -Command ([string]$cmd.installOverride)
                    }
                    $attempt = 1
                    if ($cmd.PSObject.Properties['attempt'] -and $cmd.attempt) {
                        try { $attempt = [int]$cmd.attempt } catch { $attempt = 1 }
                    }
                    if ($attempt -gt 1) {
                        Invoke-BestEffortCleanupBeforeRetry
                    }
                } catch {
                    Write-GuestLog "Install override failed: $_"
                    Write-Status -Step 'install' -State 'failed' -ExitCode 1 -Message ("Install override failed: {0}" -f $_)
                    continue
                }
                Invoke-PackageStep -Step 'install'
            }
            'detect' { Invoke-PackageStep -Step 'detect' }
            'uninstall' { Invoke-PackageStep -Step 'uninstall' }
            'shutdown' {
                Write-GuestLog 'Shutdown requested.'
                Write-Status -Step 'shutdown' -State 'completed' -ExitCode 0 -Message 'Sandbox shutdown requested.'
                Start-Sleep -Seconds 1
                Stop-Computer -Force
                return
            }
            default {
                Write-GuestLog "Ignoring command: $action"
            }
        }
    }
    Start-Sleep -Seconds 1
}
'@
}

function New-WingetterSandboxWsbContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostPackagePath,
        [Parameter(Mandatory = $true)]
        [string]$HostHandshakePath,
        [string]$PackageSandboxPath = 'C:\WingetterPackage',
        [string]$HandshakeSandboxPath = 'C:\WingetterSandbox',
        [int]$MemoryInMB = 4096,
        [string]$GuestScriptFileName = 'Start-WingetterSandboxGuest.ps1'
    )

    $packageHost = ConvertTo-WingetterXmlText -Value $HostPackagePath.TrimEnd('\')
    $handshakeHost = ConvertTo-WingetterXmlText -Value $HostHandshakePath.TrimEnd('\')
    $packageSandbox = ConvertTo-WingetterXmlText -Value $PackageSandboxPath
    $handshakeSandbox = ConvertTo-WingetterXmlText -Value $HandshakeSandboxPath
    # Sandbox-side Windows paths must not use Join-Path (that resolves drives on the host).
    $guestScript = ($HandshakeSandboxPath.TrimEnd('\')) + '\' + $GuestScriptFileName
    $logonCommand = ConvertTo-WingetterXmlText -Value (
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -WindowStyle Normal -File `"$guestScript`""
    )
    $memory = [int]$MemoryInMB
    if ($memory -lt 2048) {
        $memory = 2048
    }

    return @"
<Configuration>
  <VGpu>Enable</VGpu>
  <Networking>Default</Networking>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$packageHost</HostFolder>
      <SandboxFolder>$packageSandbox</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$handshakeHost</HostFolder>
      <SandboxFolder>$handshakeSandbox</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>$logonCommand</Command>
  </LogonCommand>
  <MemoryInMB>$memory</MemoryInMB>
  <ClipboardRedirection>Enable</ClipboardRedirection>
</Configuration>
"@
}

function Start-WingetterSandboxSession {
    <#
    .SYNOPSIS
        Creates a Windows Sandbox session that can install, detect, and uninstall a packaged app.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionDirectory,
        [switch]$SkipLaunch,
        [int]$MemoryInMB = 4096
    )

    $package = Get-WingetterSandboxPackageInfo -VersionDirectory $VersionDirectory
    if (-not $package.Ready) {
        throw $package.Reason
    }

    $sessionId = [Guid]::NewGuid().ToString('N')
    $handshake = Join-Path ([System.IO.Path]::GetTempPath()) "WingetterSandbox-$sessionId"
    New-Item -ItemType Directory -Path $handshake -Force | Out-Null

    $guestScriptPath = Join-Path $handshake 'Start-WingetterSandboxGuest.ps1'
    Set-Content -LiteralPath $guestScriptPath -Value (New-WingetterSandboxGuestScript) -Encoding UTF8

    Write-WingetterSandboxJson -Path (Join-Path $handshake 'command.json') -Object @{
        action   = 'install'
        issuedAt = (Get-Date).ToUniversalTime().ToString('o')
    }

    Write-WingetterSandboxJson -Path (Join-Path $handshake 'status.json') -Object @{
        step      = 'idle'
        state     = 'waiting'
        exitCode  = $null
        message   = 'Waiting for Windows Sandbox to start.'
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }

    $wsbPath = Join-Path $handshake 'WingetterSandbox.wsb'
    $wsb = New-WingetterSandboxWsbContent `
        -HostPackagePath $package.VersionDirectory `
        -HostHandshakePath $handshake `
        -MemoryInMB $MemoryInMB
    Set-Content -LiteralPath $wsbPath -Value $wsb -Encoding UTF8

    $launched = $false
    $processId = $null
    if (-not $SkipLaunch) {
        $sandbox = Test-WingetterWindowsSandbox
        if (-not $sandbox.Enabled) {
            throw $sandbox.Reason
        }

        $process = Start-Process -FilePath $sandbox.ExecutablePath -ArgumentList @("`"$wsbPath`"") -PassThru
        $launched = $true
        if ($process) {
            $processId = $process.Id
        }
    }

    return [PSCustomObject]@{
        SessionId           = $sessionId
        HandshakeDirectory  = $handshake
        WsbPath             = $wsbPath
        GuestScriptPath     = $guestScriptPath
        VersionDirectory    = $package.VersionDirectory
        PackageId           = $package.PackageId
        DisplayName         = $package.DisplayName
        Version             = $package.Version
        CommandPath         = Join-Path $handshake 'command.json'
        StatusPath          = Join-Path $handshake 'status.json'
        HeartbeatPath       = Join-Path $handshake 'heartbeat.json'
        GuestLogPath        = Join-Path $handshake 'guest.log'
        Launched            = $launched
        ProcessId           = $processId
        CurrentStep         = 'install'
        StartedAt           = Get-Date
    }
}

function Set-WingetterSandboxCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HandshakeDirectory,
        [Parameter(Mandatory = $true)]
        [ValidateSet('install', 'detect', 'uninstall', 'shutdown', 'idle')]
        [string]$Action,
        [string]$InstallOverride,
        [int]$Attempt = 0
    )

    $path = Join-Path $HandshakeDirectory 'command.json'
    $payload = @{
        action   = $Action
        issuedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($Attempt -gt 0) {
        $payload.attempt = [int]$Attempt
    }
    if (-not [string]::IsNullOrWhiteSpace($InstallOverride)) {
        $payload.installOverride = $InstallOverride
    }
    Write-WingetterSandboxJson -Path $path -Object $payload
}

function Get-WingetterSandboxStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HandshakeDirectory
    )

    $candidates = New-Object System.Collections.Generic.List[object]

    foreach ($name in @('status.json')) {
        $obj = Read-WingetterSandboxJson -Path (Join-Path $HandshakeDirectory $name)
        if ($obj) {
            $candidates.Add($obj) | Out-Null
        }
    }

    Get-ChildItem -LiteralPath $HandshakeDirectory -File -Filter 'status-*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        $obj = Read-WingetterSandboxJson -Path $_.FullName
        if ($obj) {
            $candidates.Add($obj) | Out-Null
        }
    }

    $ndjsonPath = Join-Path $HandshakeDirectory 'status.ndjson'
    if (Test-Path -LiteralPath $ndjsonPath) {
        foreach ($line in @(Read-WingetterSandboxText -Path $ndjsonPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $candidates.Add(($line | ConvertFrom-Json)) | Out-Null
            } catch { }
        }
    }

    if ($candidates.Count -eq 0) {
        return $null
    }

    $best = $candidates[0]
    $bestTime = [datetime]::MinValue
    foreach ($candidate in $candidates) {
        $stamp = [datetime]::MinValue
        if ($candidate.updatedAt) {
            try { $stamp = [datetime]$candidate.updatedAt } catch { }
        }
        if ($stamp -ge $bestTime) {
            $bestTime = $stamp
            $best = $candidate
        }
    }

    return $best
}

function Get-WingetterSandboxHeartbeat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HandshakeDirectory
    )

    $path = Join-Path $HandshakeDirectory 'heartbeat.json'
    $heartbeat = Read-WingetterSandboxJson -Path $path
    if (-not $heartbeat) {
        return $null
    }

    $updatedAt = $null
    if ($heartbeat.updatedAt) {
        try {
            $updatedAt = [datetime]$heartbeat.updatedAt
        } catch {
            $updatedAt = $null
        }
    }

    $ageSeconds = $null
    if ($updatedAt) {
        $ageSeconds = [math]::Max(0, ((Get-Date).ToUniversalTime() - $updatedAt.ToUniversalTime()).TotalSeconds)
    }

    return [PSCustomObject]@{
        Alive      = [bool]$heartbeat.alive
        UpdatedAt  = $updatedAt
        AgeSeconds = $ageSeconds
        Raw        = $heartbeat
    }
}

function Get-WingetterSandboxGuestLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HandshakeDirectory,
        [int]$Tail = 40,
        [switch]$IncludeStepLogs
    )

    $blocks = New-Object System.Collections.Generic.List[string]
    $path = Join-Path $HandshakeDirectory 'guest.log'
    if (Test-Path -LiteralPath $path) {
        $lines = @(Read-WingetterSandboxText -Path $path)
        if ($Tail -gt 0 -and $lines.Count -gt $Tail) {
            $lines = $lines | Select-Object -Last $Tail
        }
        if ($lines) {
            $blocks.Add(($lines -join "`r`n")) | Out-Null
        }
    }

    if ($IncludeStepLogs) {
        foreach ($step in @('install', 'detect', 'uninstall')) {
            $stepDir = Join-Path (Join-Path $HandshakeDirectory 'logs') $step
            if (-not (Test-Path -LiteralPath $stepDir)) {
                continue
            }

            $ime = Get-ChildItem -LiteralPath $stepDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*-install.log' -or $_.Name -like '*-detection.log' -or $_.Name -like '*-uninstall.log' } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if (-not $ime) {
                $ime = Get-ChildItem -LiteralPath $stepDir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq 'console-stdout.txt' } |
                    Select-Object -First 1
            }
            if ($ime) {
                $stepLines = @(Read-WingetterSandboxText -Path $ime.FullName)
                if ($Tail -gt 0 -and $stepLines.Count -gt $Tail) {
                    $stepLines = $stepLines | Select-Object -Last $Tail
                }
                if ($stepLines) {
                    $blocks.Add(('--- {0} ({1}) ---' -f $step, $ime.Name)) | Out-Null
                    $blocks.Add(($stepLines -join "`r`n")) | Out-Null
                }
            }
        }
    }

    return ($blocks -join "`r`n")
}

function Limit-WingetterReportText {
    param(
        [string]$Text,
        [int]$MaxChars = 14000
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }
    if ($Text.Length -le $MaxChars) {
        return $Text
    }

    $keepHead = [int]($MaxChars * 0.65)
    $keepTail = $MaxChars - $keepHead - 80
    if ($keepTail -lt 500) {
        $keepTail = 500
        $keepHead = $MaxChars - $keepTail - 80
    }

    $omitted = $Text.Length - $MaxChars
    return (
        $Text.Substring(0, $keepHead) +
        "`r`n`r`n[... truncated $omitted characters ...]`r`n`r`n" +
        $Text.Substring($Text.Length - $keepTail)
    )
}

function Read-WingetterTextFile {
    param(
        [string]$Path,
        [int]$MaxChars = 14000
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        return (Limit-WingetterReportText -Text $raw -MaxChars $MaxChars)
    } catch {
        return ''
    }
}

function Copy-WingetterSandboxLogsToPackage {
    param(
        [string]$HandshakeDirectory,
        [string]$VersionDirectory
    )

    if (-not $HandshakeDirectory -or -not $VersionDirectory) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $HandshakeDirectory) -or -not (Test-Path -LiteralPath $VersionDirectory)) {
        return $null
    }

    $dest = Join-Path $VersionDirectory 'sandbox-logs'
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    $guestLog = Join-Path $HandshakeDirectory 'guest.log'
    if (Test-Path -LiteralPath $guestLog) {
        Copy-Item -LiteralPath $guestLog -Destination (Join-Path $dest 'guest.log') -Force -ErrorAction SilentlyContinue
    }

    foreach ($name in @('command.json', 'status.json', 'heartbeat.json', 'status.ndjson')) {
        $source = Join-Path $HandshakeDirectory $name
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $dest $name) -Force -ErrorAction SilentlyContinue
        }
    }
    Get-ChildItem -LiteralPath $HandshakeDirectory -File -Filter 'status-*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dest $_.Name) -Force -ErrorAction SilentlyContinue
    }

    $logsRoot = Join-Path $HandshakeDirectory 'logs'
    if (Test-Path -LiteralPath $logsRoot) {
        Copy-Item -Path $logsRoot -Destination (Join-Path $dest 'steps') -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $dest
}

function Get-WingetterSandboxTestReportPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionDirectory
    )

    return (Join-Path $VersionDirectory 'sandbox-test-report.txt')
}

function Write-WingetterSandboxTestReport {
    <#
    .SYNOPSIS
        Writes a chat-ready sandbox test report next to the packaged app.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionDirectory,
        [string]$HandshakeDirectory,
        [hashtable]$Confirmations,
        [string]$Outcome = 'in-progress',
        [string]$Message = ''
    )

    $info = $null
    try {
        $info = Get-WingetterSandboxPackageInfo -VersionDirectory $VersionDirectory
    } catch {
        $info = $null
    }

    $silentInfo = $null
    try {
        $silentInfo = Get-WingetterPackageSilentInstallInfo -VersionDirectory $VersionDirectory
    } catch {
        $silentInfo = $null
    }

    $copiedLogs = $null
    if ($HandshakeDirectory) {
        $copiedLogs = Copy-WingetterSandboxLogsToPackage -HandshakeDirectory $HandshakeDirectory -VersionDirectory $VersionDirectory
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('=== Wingetter sandbox test report ===')
    [void]$builder.AppendLine('Paste this entire file into chat if a sandbox install/detect/uninstall needs diagnosis.')
    [void]$builder.AppendLine(('Generated (UTC): {0}' -f (Get-Date).ToUniversalTime().ToString('o')))
    [void]$builder.AppendLine(('Outcome: {0}' -f $Outcome))
    if ($Message) {
        [void]$builder.AppendLine(('Message: {0}' -f $Message))
    }
    [void]$builder.AppendLine('')

    $displayName = if ($info -and $info.DisplayName) { $info.DisplayName } else { '' }
    $packageId = if ($info -and $info.PackageId) { $info.PackageId } else { '' }
    $version = if ($info -and $info.Version) { $info.Version } else { '' }
    [void]$builder.AppendLine('--- Package ---')
    [void]$builder.AppendLine(('Display name: {0}' -f $displayName))
    [void]$builder.AppendLine(('Package ID: {0}' -f $packageId))
    [void]$builder.AppendLine(('Version: {0}' -f $version))
    [void]$builder.AppendLine(('Package folder: {0}' -f $VersionDirectory))
    if ($HandshakeDirectory) {
        [void]$builder.AppendLine(('Handshake folder: {0}' -f $HandshakeDirectory))
    }
    if ($copiedLogs) {
        [void]$builder.AppendLine(('Copied sandbox logs: {0}' -f $copiedLogs))
    }
    [void]$builder.AppendLine('')

    [void]$builder.AppendLine('--- Silent install verification ---')
    if ($silentInfo -and $silentInfo.Recommended) {
        $plan = $silentInfo.Recommended
        [void]$builder.AppendLine(('Engine: {0} (source: {1})' -f $plan.Engine, $plan.EngineSource))
        if ($plan.ProbeSignature) {
            [void]$builder.AppendLine(('File signature: {0}' -f $plan.ProbeSignature))
        }
        [void]$builder.AppendLine(('Winget installer type: {0}' -f $plan.WingetInstallerType))
        [void]$builder.AppendLine(('Winget Silent switch: {0}' -f $plan.WingetSilentSwitch))
        [void]$builder.AppendLine(('Verified command: {0}' -f $plan.Command))
        [void]$builder.AppendLine(('Verified: {0}' -f $plan.Verified))
        if ($plan.Overridden) {
            [void]$builder.AppendLine(('Overridden: {0}' -f $plan.OverrideReason))
        }
        foreach ($warning in @($plan.Warnings)) {
            if ($warning) {
                [void]$builder.AppendLine(('Warning: {0}' -f $warning))
            }
        }
    } elseif ($silentInfo -and $silentInfo.Manifest) {
        [void]$builder.AppendLine(('Engine: {0}' -f $silentInfo.Manifest.engine))
        [void]$builder.AppendLine(('Command: {0}' -f $silentInfo.Manifest.command))
        [void]$builder.AppendLine(('Verified: {0}' -f $silentInfo.Manifest.verified))
    } else {
        [void]$builder.AppendLine('No silent-switches.json or installer was found to verify.')
    }

    if ($silentInfo -and $silentInfo.PackagedCommand) {
        [void]$builder.AppendLine(('Packaged install.ps1 command: {0}' -f $silentInfo.PackagedCommand))
    }
    if ($silentInfo -and $silentInfo.Mismatch) {
        [void]$builder.AppendLine(('WARNING: {0}' -f $silentInfo.MismatchReason))
        [void]$builder.AppendLine('Test in Sandbox runs the packaged install.ps1 as-is. Re-create the package with this Wingetter version to bake in verified silent switches.')
    }
    [void]$builder.AppendLine('')

    [void]$builder.AppendLine('--- Step results ---')
    foreach ($step in @('install', 'detect', 'uninstall')) {
        $item = $null
        if ($Confirmations -and $Confirmations.ContainsKey($step)) {
            $item = $Confirmations[$step]
        }
        $confirmed = if ($item) { Get-ConfirmationValue -Item $item -Name 'Confirmed' } else { $null }
        $exitCode = if ($item) { Get-ConfirmationValue -Item $item -Name 'ExitCode' } else { $null }
        $stepMessage = if ($item) { Get-ConfirmationValue -Item $item -Name 'Message' } else { $null }
        $confirmedAt = if ($item) { Get-ConfirmationValue -Item $item -Name 'ConfirmedAt' } else { $null }
        $silentUi = if ($item) { Get-ConfirmationValue -Item $item -Name 'SilentUiDetected' } else { $null }
        [void]$builder.AppendLine(('{0}: confirmed={1}; exitCode={2}; silentUi={3}; at={4}; message={5}' -f $step, $confirmed, $exitCode, $silentUi, $confirmedAt, $stepMessage))
    }
    [void]$builder.AppendLine('')

    $statusJson = ''
    $statusNdjson = ''
    $commandJson = ''
    if ($HandshakeDirectory) {
        $latestStatus = Get-WingetterSandboxStatus -HandshakeDirectory $HandshakeDirectory
        if ($latestStatus) {
            $statusJson = ($latestStatus | ConvertTo-Json -Depth 6)
        } else {
            $statusJson = Read-WingetterTextFile -Path (Join-Path $HandshakeDirectory 'status.json') -MaxChars 4000
        }
        $statusNdjson = Read-WingetterTextFile -Path (Join-Path $HandshakeDirectory 'status.ndjson') -MaxChars 8000
        $commandJson = Read-WingetterTextFile -Path (Join-Path $HandshakeDirectory 'command.json') -MaxChars 2000
    }
    if ($commandJson) {
        [void]$builder.AppendLine('--- command.json ---')
        [void]$builder.AppendLine($commandJson)
        [void]$builder.AppendLine('')
    }
    if ($statusJson) {
        [void]$builder.AppendLine('--- status.json ---')
        [void]$builder.AppendLine($statusJson)
        [void]$builder.AppendLine('')
    }
    if ($statusNdjson) {
        [void]$builder.AppendLine('--- status.ndjson ---')
        [void]$builder.AppendLine($statusNdjson)
        [void]$builder.AppendLine('')
    }

    $guestLogText = ''
    if ($HandshakeDirectory) {
        $guestLogText = Read-WingetterTextFile -Path (Join-Path $HandshakeDirectory 'guest.log') -MaxChars 12000
    } elseif ($copiedLogs) {
        $guestLogText = Read-WingetterTextFile -Path (Join-Path $copiedLogs 'guest.log') -MaxChars 12000
    }
    [void]$builder.AppendLine('--- Guest coordinator log ---')
    if ($guestLogText) {
        [void]$builder.AppendLine($guestLogText)
    } else {
        [void]$builder.AppendLine('(no guest.log yet)')
    }
    [void]$builder.AppendLine('')

    $logRoot = $null
    if ($HandshakeDirectory -and (Test-Path -LiteralPath (Join-Path $HandshakeDirectory 'logs'))) {
        $logRoot = Join-Path $HandshakeDirectory 'logs'
    } elseif ($copiedLogs -and (Test-Path -LiteralPath (Join-Path $copiedLogs 'steps'))) {
        $logRoot = Join-Path $copiedLogs 'steps'
    }

    foreach ($step in @('install', 'detect', 'uninstall')) {
        [void]$builder.AppendLine(('--- {0} logs ---' -f $step))
        if (-not $logRoot) {
            [void]$builder.AppendLine('(no copied step logs)')
            [void]$builder.AppendLine('')
            continue
        }

        $stepDir = Join-Path $logRoot $step
        if (-not (Test-Path -LiteralPath $stepDir)) {
            [void]$builder.AppendLine('(step not run or logs were not copied)')
            [void]$builder.AppendLine('')
            continue
        }

        $preferred = @(
            (Join-Path $stepDir 'step.json')
            (Join-Path $stepDir 'ui-activity.json')
            (Join-Path $stepDir 'console-stdout.txt')
            (Join-Path $stepDir 'console-stderr.txt')
        )
        $imeFiles = @(Get-ChildItem -LiteralPath $stepDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.log' } |
            Sort-Object Name)
        foreach ($filePath in @($preferred + @($imeFiles | ForEach-Object { $_.FullName }))) {
            if (-not $filePath -or -not (Test-Path -LiteralPath $filePath)) {
                continue
            }
            $content = Read-WingetterTextFile -Path $filePath -MaxChars 10000
            if (-not $content) {
                continue
            }
            [void]$builder.AppendLine(('[{0}]' -f ([System.IO.Path]::GetFileName($filePath))))
            [void]$builder.AppendLine($content)
            [void]$builder.AppendLine('')
        }
    }

    $text = $builder.ToString()
    $text = Limit-WingetterReportText -Text $text -MaxChars 80000
    $reportPath = Get-WingetterSandboxTestReportPath -VersionDirectory $VersionDirectory
    Set-Content -LiteralPath $reportPath -Value $text -Encoding UTF8

    $failureLog = Write-WingetterSandboxFailureLog `
        -VersionDirectory $VersionDirectory `
        -ReportText $text `
        -Outcome $Outcome `
        -Message $Message `
        -Confirmations $Confirmations `
        -PackageInfo $info `
        -CopiedLogsPath $copiedLogs `
        -HandshakeDirectory $HandshakeDirectory

    return [PSCustomObject]@{
        Path              = $reportPath
        Text              = $text
        CopiedLogsPath    = $copiedLogs
        FailureLogPath    = $failureLog
        Outcome           = $Outcome
    }
}

function Get-WingetterSandboxFailureLogPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionDirectory
    )

    return (Join-Path $VersionDirectory 'sandbox-failure.log')
}

function Write-WingetterSandboxFailureLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionDirectory,
        [string]$ReportText,
        [string]$Outcome,
        [string]$Message,
        [hashtable]$Confirmations,
        $PackageInfo,
        [string]$CopiedLogsPath,
        [string]$HandshakeDirectory
    )

    $failed = $Outcome -ne 'validated'
    $silentUi = $false
    $uiTitles = @()
    if ($Confirmations -and $Confirmations.ContainsKey('install')) {
        $silentUi = [bool](Get-ConfirmationValue -Item $Confirmations['install'] -Name 'SilentUiDetected')
    }

    $uiActivity = $null
    foreach ($root in @($HandshakeDirectory, $CopiedLogsPath)) {
        if (-not $root) { continue }
        $candidate = Join-Path (Join-Path (Join-Path $root 'logs') 'install') 'ui-activity.json'
        if (-not (Test-Path -LiteralPath $candidate)) {
            $candidate = Join-Path (Join-Path (Join-Path $root 'steps') 'install') 'ui-activity.json'
        }
        if (Test-Path -LiteralPath $candidate) {
            try {
                $uiActivity = Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
                $silentUi = $true
                if ($uiActivity.events) {
                    $uiTitles = @($uiActivity.events | ForEach-Object { $_.windowTitle })
                }
            } catch { }
            break
        }
    }

    if (-not $failed -and -not $silentUi) {
        $existing = Get-WingetterSandboxFailureLogPath -VersionDirectory $VersionDirectory
        if (Test-Path -LiteralPath $existing) {
            Remove-Item -LiteralPath $existing -Force -ErrorAction SilentlyContinue
        }
        return $null
    }

    $displayName = if ($PackageInfo -and $PackageInfo.DisplayName) { $PackageInfo.DisplayName } else { '' }
    $packageId = if ($PackageInfo -and $PackageInfo.PackageId) { $PackageInfo.PackageId } else { '' }
    $version = if ($PackageInfo -and $PackageInfo.Version) { $PackageInfo.Version } else { '' }

    $why = $Message
    if ($silentUi) {
        $titleText = if ($uiTitles.Count -gt 0) { ($uiTitles -join '; ') } else { 'an installer dialog' }
        $why = "Install was not silent. Windows Sandbox showed interactive UI ($titleText). Intune Win32 installs cannot click through that dialog."
        if ($Message) {
            $why = "$why $Message"
        }
    } elseif (-not $why) {
        $why = "Sandbox test outcome: $Outcome"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Wingetter sandbox failure') | Out-Null
    $lines.Add(('Generated (UTC): {0}' -f (Get-Date).ToUniversalTime().ToString('o'))) | Out-Null
    $lines.Add(('Package: {0} ({1}) {2}' -f $displayName, $packageId, $version)) | Out-Null
    $lines.Add(('Package folder: {0}' -f $VersionDirectory)) | Out-Null
    $lines.Add(('What failed: {0}' -f $why)) | Out-Null
    if ($silentUi) {
        $lines.Add('Silent UI: yes. Re-package so install.ps1 uses Inno /VERYSILENT /LANG=english, then re-test.') | Out-Null
    }
    $lines.Add('') | Out-Null
    $lines.Add('Upload this file together with sandbox-test-report.txt and the sandbox-logs folder.') | Out-Null
    $lines.Add('') | Out-Null
    if ($ReportText) {
        $lines.Add('--- Full report ---') | Out-Null
        $lines.Add($ReportText) | Out-Null
    }

    $failurePath = Get-WingetterSandboxFailureLogPath -VersionDirectory $VersionDirectory
    Set-Content -LiteralPath $failurePath -Value ($lines -join "`r`n") -Encoding UTF8

    if ($CopiedLogsPath -and (Test-Path -LiteralPath $CopiedLogsPath)) {
        Copy-Item -LiteralPath $failurePath -Destination (Join-Path $CopiedLogsPath 'sandbox-failure.log') -Force -ErrorAction SilentlyContinue
        $reportPath = Get-WingetterSandboxTestReportPath -VersionDirectory $VersionDirectory
        if (Test-Path -LiteralPath $reportPath) {
            Copy-Item -LiteralPath $reportPath -Destination (Join-Path $CopiedLogsPath 'sandbox-test-report.txt') -Force -ErrorAction SilentlyContinue
        }
    }

    return $failurePath
}

function Get-WingetterSandboxStepScriptName {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('install', 'detect', 'uninstall')]
        [string]$Step
    )

    switch ($Step) {
        'install' { return 'install.ps1' }
        'detect' { return 'detection.ps1' }
        'uninstall' { return 'uninstall.ps1' }
    }
}

function Get-WingetterSandboxStepCompletionFromText {
    param(
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [ValidateSet('install', 'detect', 'uninstall')]
        [string]$Step,
        [string]$Source = 'log'
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $scriptName = Get-WingetterSandboxStepScriptName -Step $Step
    $finished = $false
    $exitCode = $null
    $message = $null

    if ($Text -match ([regex]::Escape($scriptName) + ' finished with exit code (-?\d+)\.')) {
        $finished = $true
        $exitCode = [int]$Matches[1]
        $message = "$scriptName finished with exit code $exitCode."
    }

    if ($Text -match 'Windows PowerShell transcript end') {
        $finished = $true
        if (-not $message) {
            $message = "$scriptName finished (transcript ended)."
        }
    }

    switch ($Step) {
        'install' {
            if ($Text -match 'Install completed successfully \(hard reboot required - 1641\)') {
                $finished = $true
                if ($null -eq $exitCode) { $exitCode = 1641 }
            } elseif ($Text -match 'Install completed successfully \(reboot required - 3010\)') {
                $finished = $true
                if ($null -eq $exitCode) { $exitCode = 3010 }
            } elseif ($Text -match 'Install completed successfully') {
                $finished = $true
                if ($null -eq $exitCode) { $exitCode = 0 }
            } elseif ($Text -match 'Another installation is already in progress \(1618\)') {
                $finished = $true
                if ($null -eq $exitCode) { $exitCode = 1618 }
            } elseif ($Text -match 'Install failed with exit code (-?\d+)') {
                $finished = $true
                if ($null -eq $exitCode) { $exitCode = [int]$Matches[1] }
            }
        }
        'detect' {
            if ($Text -match 'not detected in registry, exiting with code 1') {
                $finished = $true
                if ($null -eq $exitCode) { $exitCode = 1 }
            } elseif ($Text -match 'is installed with version' -or $Text -match 'Detected version:') {
                $finished = $true
                if ($null -eq $exitCode) { $exitCode = 0 }
            }
        }
        'uninstall' {
            if ($Text -match 'Uninstall completed successfully') {
                $finished = $true
                if ($null -eq $exitCode) { $exitCode = 0 }
            } elseif ($Text -match 'Uninstall returned exit code:\s*(-?\d+)') {
                $finished = $true
                if ($null -eq $exitCode) { $exitCode = [int]$Matches[1] }
            } elseif ($Text -match 'Uninstall string not found') {
                $finished = $true
                if ($null -eq $exitCode) { $exitCode = 1 }
            }
        }
    }

    if ($Text -match ([regex]::Escape($scriptName) + ' was not silent') -or
        $Text -match ('STEP_DONE step=' + [regex]::Escape($Step)) -or
        $Text -match 'Waiting for confirmation in Wingetter') {
        $finished = $true
        if ($null -eq $exitCode -and $Text -match 'Exit code (\-?\d+)') {
            $exitCode = [int]$Matches[1]
        }
        if ($null -eq $exitCode -and $Text -match ('STEP_DONE step=' + [regex]::Escape($Step) + ' state=\S+ exitCode=(\-?\d+)')) {
            $exitCode = [int]$Matches[1]
        }
        if (-not $message) {
            $message = "$scriptName finished."
        }
    }

    # Packaged install.ps1 success beats a false "not silent" kill/exit code.
    if ($Step -eq 'install' -and $Text -match 'Install completed successfully') {
        $finished = $true
        if ($Text -match 'hard reboot required - 1641') {
            $exitCode = 1641
        } elseif ($Text -match 'reboot required - 3010') {
            $exitCode = 3010
        } else {
            $exitCode = 0
        }
        $message = "$scriptName finished with exit code $exitCode."
    }

    if (-not $finished) {
        return $null
    }
    if ($null -eq $exitCode) {
        $exitCode = 0
    }
    if (-not $message) {
        $message = "$scriptName finished with exit code $exitCode."
    }

    return [PSCustomObject]@{
        step = $Step
        state = 'completed'
        exitCode = $exitCode
        message = $message
        source = $Source
    }
}

function Get-WingetterSandboxStepCompletionFromLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HandshakeDirectory,
        [Parameter(Mandatory = $true)]
        [ValidateSet('install', 'detect', 'uninstall')]
        [string]$Step
    )

    $chunks = New-Object System.Collections.Generic.List[string]
    $guestLog = Join-Path $HandshakeDirectory 'guest.log'
    if (Test-Path -LiteralPath $guestLog) {
        $chunks.Add((Read-WingetterSandboxText -Path $guestLog -Raw)) | Out-Null
    }

    $stepDir = Join-Path (Join-Path $HandshakeDirectory 'logs') $Step
    if (Test-Path -LiteralPath $stepDir) {
        Get-ChildItem -LiteralPath $stepDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'console-stdout.txt' -or $_.Name -eq 'console-stderr.txt' -or $_.Name -like '*.log' } |
            ForEach-Object {
                $chunks.Add((Read-WingetterSandboxText -Path $_.FullName -Raw)) | Out-Null
            }
    }

    $text = ($chunks -join "`n")
    $source = if ($text -match 'Windows PowerShell transcript end' -or $text -match 'Install completed successfully') {
        'step-log'
    } else {
        'guest.log'
    }

    return Get-WingetterSandboxStepCompletionFromText -Text $text -Step $Step -Source $source
}

function Resolve-WingetterSandboxStepStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HandshakeDirectory,
        [Parameter(Mandatory = $true)]
        [ValidateSet('install', 'detect', 'uninstall')]
        [string]$Step,
        [string]$LogText
    )

    $status = Get-WingetterSandboxStatus -HandshakeDirectory $HandshakeDirectory
    if ($status) {
        $statusStep = [string]$status.step
        $state = [string]$status.state
        if ($statusStep -eq $Step -and ($state -eq 'completed' -or $state -eq 'failed')) {
            return $status
        }
    }

    $logStatus = Get-WingetterSandboxStepCompletionFromLog -HandshakeDirectory $HandshakeDirectory -Step $Step
    if (-not $logStatus -and $LogText) {
        $logStatus = Get-WingetterSandboxStepCompletionFromText -Text $LogText -Step $Step -Source 'dialog-log'
    }
    if ($logStatus) {
        return $logStatus
    }

    if ($status) {
        $statusStep = [string]$status.step
        $state = [string]$status.state
        if ($statusStep -eq $Step -and $state -eq 'running') {
            return $status
        }
    }

    return $null
}

function Stop-WingetterSandboxSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HandshakeDirectory,
        [switch]$Cleanup
    )

    if (Test-Path -LiteralPath $HandshakeDirectory) {
        Set-WingetterSandboxCommand -HandshakeDirectory $HandshakeDirectory -Action shutdown
    }

    if ($Cleanup -and (Test-Path -LiteralPath $HandshakeDirectory)) {
        Start-Sleep -Milliseconds 400
        Remove-Item -LiteralPath $HandshakeDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-ConfirmationValue {
    param($Item, [string]$Name)

    if ($null -eq $Item) {
        return $null
    }

    if ($Item -is [hashtable]) {
        if ($Item.ContainsKey($Name)) {
            return $Item[$Name]
        }
        return $null
    }

    $property = $Item.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }
    return $null
}

function Test-WingetterSandboxConfirmations {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Confirmations
    )

    foreach ($step in @('install', 'detect', 'uninstall')) {
        if (-not $Confirmations.ContainsKey($step)) {
            return $false
        }
        if (-not [bool](Get-ConfirmationValue -Item $Confirmations[$step] -Name 'Confirmed')) {
            return $false
        }
    }

    if ([bool](Get-ConfirmationValue -Item $Confirmations['install'] -Name 'SilentUiDetected')) {
        return $false
    }

    return $true
}

function ConvertTo-SandboxStepRecord {
    param($Item)

    $confirmedAt = Get-ConfirmationValue -Item $Item -Name 'ConfirmedAt'
    if (-not $confirmedAt -and [bool](Get-ConfirmationValue -Item $Item -Name 'Confirmed')) {
        $confirmedAt = (Get-Date).ToUniversalTime().ToString('o')
    }

    return [ordered]@{
        confirmed         = [bool](Get-ConfirmationValue -Item $Item -Name 'Confirmed')
        exitCode          = (Get-ConfirmationValue -Item $Item -Name 'ExitCode')
        confirmedAt       = $confirmedAt
        message           = [string](Get-ConfirmationValue -Item $Item -Name 'Message')
        silentUiDetected  = [bool](Get-ConfirmationValue -Item $Item -Name 'SilentUiDetected')
    }
}

function Complete-WingetterSandboxTest {
    <#
    .SYNOPSIS
        Writes validation.json when install, detect, and uninstall were all confirmed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionDirectory,
        [Parameter(Mandatory = $true)]
        [hashtable]$Confirmations
    )

    if (-not (Test-Path -LiteralPath $VersionDirectory)) {
        throw "Package folder was not found: $VersionDirectory"
    }

    $validated = Test-WingetterSandboxConfirmations -Confirmations $Confirmations
    $validatedAt = if ($validated) { (Get-Date).ToUniversalTime().ToString('o') } else { $null }

    $info = Get-WingetterSandboxPackageInfo -VersionDirectory $VersionDirectory
    $payload = [ordered]@{
        validated   = $validated
        method      = 'WindowsSandbox'
        validatedAt = $validatedAt
        packageId   = $info.PackageId
        displayName = $info.DisplayName
        version     = $info.Version
        steps       = [ordered]@{
            install   = ConvertTo-SandboxStepRecord -Item $Confirmations['install']
            detect    = ConvertTo-SandboxStepRecord -Item $Confirmations['detect']
            uninstall = ConvertTo-SandboxStepRecord -Item $Confirmations['uninstall']
        }
    }

    $validationPath = Join-Path $VersionDirectory 'validation.json'
    ($payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $validationPath -Encoding UTF8

    $appJsonPath = Join-Path $VersionDirectory 'app.json'
    if (Test-Path -LiteralPath $appJsonPath) {
        try {
            $app = Get-Content -LiteralPath $appJsonPath -Raw | ConvertFrom-Json
            $app | Add-Member -NotePropertyName sandboxValidated -NotePropertyValue $validated -Force
            $app | Add-Member -NotePropertyName sandboxValidatedAt -NotePropertyValue $validatedAt -Force
            $app | Add-Member -NotePropertyName sandboxValidationMethod -NotePropertyValue 'WindowsSandbox' -Force
            $app | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $appJsonPath -Encoding UTF8
        } catch {
            Write-Warning "Could not update app.json with sandbox validation: $_"
        }
    }

    return Get-WingetterPackageValidation -VersionDirectory $VersionDirectory
}

function Get-WingetterPackageValidation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionDirectory
    )

    $path = Join-Path $VersionDirectory 'validation.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return [PSCustomObject]@{
            Validated    = $false
            Method       = $null
            ValidatedAt  = $null
            PackageId    = $null
            Version      = $null
            Steps        = $null
            Path         = $path
            Exists       = $false
        }
    }

    try {
        $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return [PSCustomObject]@{
            Validated    = [bool]$data.validated
            Method       = [string]$data.method
            ValidatedAt  = $data.validatedAt
            PackageId    = [string]$data.packageId
            Version      = [string]$data.version
            Steps        = $data.steps
            Path         = $path
            Exists       = $true
        }
    } catch {
        return [PSCustomObject]@{
            Validated    = $false
            Method       = $null
            ValidatedAt  = $null
            PackageId    = $null
            Version      = $null
            Steps        = $null
            Path         = $path
            Exists       = $true
        }
    }
}
