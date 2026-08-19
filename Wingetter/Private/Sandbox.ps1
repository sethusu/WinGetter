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
    $tempPath = "$Path.tmp"
    Set-Content -LiteralPath $tempPath -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Read-WingetterSandboxJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }
        return $raw | ConvertFrom-Json
    } catch {
        return $null
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
    $tempPath = "$Path.tmp"
    Set-Content -LiteralPath $tempPath -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
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
        [string]$Message = ''
    )
    Write-GuestJson -Path $statusPath -Object @{
        step = $Step
        state = $State
        exitCode = $ExitCode
        message = $Message
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Read-CommandAction {
    if (-not (Test-Path -LiteralPath $commandPath)) {
        return $null
    }
    try {
        $raw = Get-Content -LiteralPath $commandPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $cmd = $raw | ConvertFrom-Json
        return [string]$cmd.action
    } catch {
        return $null
    }
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

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-GuestLog "Missing $scriptPath"
        Write-Status -Step $Step -State 'failed' -ExitCode 1 -Message "$scriptName was not found in the mapped package folder."
        return
    }

    $logDir = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    Set-Location -Path $packageRoot
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
        $exitCode = 1
    }

    $message = "$scriptName finished with exit code $exitCode."
    Write-GuestLog $message
    Write-Host $message
    Write-Host 'Waiting for confirmation in Wingetter...'
    Write-Status -Step $Step -State 'completed' -ExitCode ([int]$exitCode) -Message $message
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

$lastAction = ''
while ($true) {
    Write-Heartbeat
    $action = Read-CommandAction
    if ($action -and $action -ne $lastAction) {
        $lastAction = $action
        switch ($action) {
            'install' { Invoke-PackageStep -Step 'install' }
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
    $guestScript = Join-Path $HandshakeSandboxPath $GuestScriptFileName
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
        [string]$Action
    )

    $path = Join-Path $HandshakeDirectory 'command.json'
    Write-WingetterSandboxJson -Path $path -Object @{
        action   = $Action
        issuedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-WingetterSandboxStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HandshakeDirectory
    )

    return (Read-WingetterSandboxJson -Path (Join-Path $HandshakeDirectory 'status.json'))
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
        [int]$Tail = 40
    )

    $path = Join-Path $HandshakeDirectory 'guest.log'
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }

    try {
        $lines = Get-Content -LiteralPath $path -ErrorAction Stop
        if ($Tail -gt 0 -and $lines.Count -gt $Tail) {
            $lines = $lines | Select-Object -Last $Tail
        }
        return ($lines -join "`r`n")
    } catch {
        return ''
    }
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

    return $true
}

function ConvertTo-SandboxStepRecord {
    param($Item)

    $confirmedAt = Get-ConfirmationValue -Item $Item -Name 'ConfirmedAt'
    if (-not $confirmedAt -and [bool](Get-ConfirmationValue -Item $Item -Name 'Confirmed')) {
        $confirmedAt = (Get-Date).ToUniversalTime().ToString('o')
    }

    return [ordered]@{
        confirmed   = [bool](Get-ConfirmationValue -Item $Item -Name 'Confirmed')
        exitCode    = (Get-ConfirmationValue -Item $Item -Name 'ExitCode')
        confirmedAt = $confirmedAt
        message     = [string](Get-ConfirmationValue -Item $Item -Name 'Message')
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
