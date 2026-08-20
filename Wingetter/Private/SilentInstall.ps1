function ConvertTo-WingetterSwitchTokenList {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @($Value -split '\s+' | Where-Object { $_ })
}

function Test-WingetterSwitchHasToken {
    param(
        [string]$SwitchText,
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $wanted = $Token.Trim()
    if (-not $wanted) {
        return $false
    }

    foreach ($item in (ConvertTo-WingetterSwitchTokenList -Value $SwitchText)) {
        if ([string]::Equals($item, $wanted, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-WingetterSwitchHasLang {
    param([string]$SwitchText)

    foreach ($item in (ConvertTo-WingetterSwitchTokenList -Value $SwitchText)) {
        if ($item -like '/LANG=*') {
            return $true
        }
    }

    return $false
}

function Resolve-WingetterInstallerEngineName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    switch -Regex ($Value.Trim().ToLowerInvariant()) {
        '^inno' { return 'inno' }
        '^(nullsoft|nsis)' { return 'nsis' }
        '^burn' { return 'burn' }
        '^wix' { return 'wix' }
        '^msi$' { return 'msi' }
        '^(msix|appx)' { return 'msix' }
        'installshield' { return 'installshield' }
        'advanced.?installer' { return 'advancedinstaller' }
        default { return $null }
    }
}

function Get-WingetterInstallerProbeText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$HeadBytes = 1048576,
        [int]$TailBytes = 262144
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $length = [int64]$stream.Length
        if ($length -le 0) {
            return ''
        }

        $chunks = New-Object System.Collections.Generic.List[string]
        $headLen = [int][Math]::Min([int64]$HeadBytes, $length)
        $head = New-Object byte[] $headLen
        [void]$stream.Read($head, 0, $headLen)
        $chunks.Add([System.Text.Encoding]::ASCII.GetString($head))

        if ($length -gt $headLen -and $TailBytes -gt 0) {
            $tailLen = [int][Math]::Min([int64]$TailBytes, $length - $headLen)
            $stream.Seek(-1 * $tailLen, [System.IO.SeekOrigin]::End) | Out-Null
            $tail = New-Object byte[] $tailLen
            [void]$stream.Read($tail, 0, $tailLen)
            $chunks.Add([System.Text.Encoding]::ASCII.GetString($tail))
        }

        return ($chunks -join "`n")
    } catch {
        return ''
    } finally {
        if ($stream) {
            $stream.Dispose()
        }
    }
}

function Get-WingetterInstallerEngineFromFile {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $extension = [System.IO.Path]::GetExtension($Path)
    if ($extension) {
        switch ($extension.ToLowerInvariant()) {
            '.msi' { return [PSCustomObject]@{ Engine = 'msi'; Signature = 'extension' } }
            '.msix' { return [PSCustomObject]@{ Engine = 'msix'; Signature = 'extension' } }
            '.appx' { return [PSCustomObject]@{ Engine = 'msix'; Signature = 'extension' } }
        }
    }

    $text = Get-WingetterInstallerProbeText -Path $Path
    if (-not $text) {
        return $null
    }

    if ($text -match 'Inno Setup') {
        return [PSCustomObject]@{ Engine = 'inno'; Signature = 'Inno Setup' }
    }
    if ($text -match 'NullsoftInst' -or $text -match 'Nullsoft Install System') {
        return [PSCustomObject]@{ Engine = 'nsis'; Signature = 'NullsoftInst' }
    }
    if ($text -match 'wixburn' -or $text -match 'WiX Burn') {
        return [PSCustomObject]@{ Engine = 'burn'; Signature = 'WiX Burn' }
    }
    if ($text -match 'InstallShield') {
        return [PSCustomObject]@{ Engine = 'installshield'; Signature = 'InstallShield' }
    }
    if ($text -match 'Advanced Installer') {
        return [PSCustomObject]@{ Engine = 'advancedinstaller'; Signature = 'Advanced Installer' }
    }

    return $null
}

function Resolve-WingetterInstallerEngine {
    param(
        [string]$InstallerPath,
        [string]$InstallerExtension,
        [string]$InstallerType
    )

    $extension = $InstallerExtension
    if (-not $extension -and $InstallerPath) {
        $extension = [System.IO.Path]::GetExtension($InstallerPath)
    }

    if ($extension) {
        switch ($extension.ToLowerInvariant()) {
            '.msi' {
                return [PSCustomObject]@{ Engine = 'msi'; Source = 'extension'; Signature = $null }
            }
            '.msix' {
                return [PSCustomObject]@{ Engine = 'msix'; Source = 'extension'; Signature = $null }
            }
            '.appx' {
                return [PSCustomObject]@{ Engine = 'msix'; Source = 'extension'; Signature = $null }
            }
        }
    }

    $fromType = Resolve-WingetterInstallerEngineName -Value $InstallerType
    if ($fromType -and $fromType -ne 'wix') {
        return [PSCustomObject]@{ Engine = $fromType; Source = 'winget-type'; Signature = $null }
    }

    $fromFile = Get-WingetterInstallerEngineFromFile -Path $InstallerPath
    if ($fromFile) {
        return [PSCustomObject]@{ Engine = $fromFile.Engine; Source = 'file-probe'; Signature = $fromFile.Signature }
    }

    if ($fromType -eq 'wix') {
        return [PSCustomObject]@{ Engine = 'wix'; Source = 'winget-type'; Signature = $null }
    }

    return [PSCustomObject]@{ Engine = 'exe'; Source = 'unknown'; Signature = $null }
}

function Get-WingetterDefaultSilentArguments {
    param([string]$Engine)

    switch ($Engine) {
        'inno' { return '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /SP- /LANG=english' }
        'nsis' { return '/S' }
        'msi' { return '/quiet /norestart' }
        'burn' { return '/quiet /norestart' }
        'wix' { return '/quiet /norestart' }
        'installshield' { return '/s /v"/qn /norestart"' }
        'advancedinstaller' { return '/qn' }
        'msix' { return '' }
        default { return '/S' }
    }
}

function Test-WingetterSilentSwitchAdequacy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Engine,
        [string]$SwitchText
    )

    $text = if ($null -eq $SwitchText) { '' } else { $SwitchText.Trim() }

    switch ($Engine) {
        'msix' {
            return [PSCustomObject]@{
                Adequate = $true
                Reason   = 'MSIX/AppX install uses Add-AppxPackage and does not need silent switches.'
            }
        }
        'inno' {
            $hasSilent = Test-WingetterSwitchHasToken -SwitchText $text -Token '/SILENT'
            $hasVerySilent = Test-WingetterSwitchHasToken -SwitchText $text -Token '/VERYSILENT'
            if ($hasSilent -and -not $hasVerySilent) {
                return [PSCustomObject]@{
                    Adequate = $false
                    Reason   = 'Inno Setup /SILENT still shows a progress wizard. Intune/sandbox installs need /VERYSILENT.'
                }
            }
            if (-not $hasVerySilent) {
                return [PSCustomObject]@{
                    Adequate = $false
                    Reason   = 'Inno Setup ignores a generic /S switch and typically shows UI or fails in a sandbox.'
                }
            }
            if (-not (Test-WingetterSwitchHasLang -SwitchText $text)) {
                return [PSCustomObject]@{
                    Adequate = $false
                    Reason   = 'Inno Setup with ShowLanguageDialog=yes still shows Select Setup Language under /VERYSILENT unless /LANG= is set (PrusaSlicer does this).'
                }
            }
            return [PSCustomObject]@{
                Adequate = $true
                Reason   = 'Inno Setup /VERYSILENT /LANG is fully silent.'
            }
        }
        'nsis' {
            if (Test-WingetterSwitchHasToken -SwitchText $text -Token '/S') {
                return [PSCustomObject]@{
                    Adequate = $true
                    Reason   = 'NSIS /S is silent.'
                }
            }
            return [PSCustomObject]@{
                Adequate = $false
                Reason   = 'NSIS installers require /S for a silent install.'
            }
        }
        'msi' {
            if ((Test-WingetterSwitchHasToken -SwitchText $text -Token '/quiet') -or
                (Test-WingetterSwitchHasToken -SwitchText $text -Token '/qn') -or
                ($text -match '(?i)(?:^|\s)/q[nb]?(?:\s|$)')) {
                return [PSCustomObject]@{
                    Adequate = $true
                    Reason   = 'MSI quiet switches are present.'
                }
            }
            return [PSCustomObject]@{
                Adequate = $false
                Reason   = 'MSI installs require /quiet or /qn.'
            }
        }
        { $_ -in @('burn', 'wix') } {
            if ((Test-WingetterSwitchHasToken -SwitchText $text -Token '/quiet') -or
                (Test-WingetterSwitchHasToken -SwitchText $text -Token '/silent') -or
                (Test-WingetterSwitchHasToken -SwitchText $text -Token '/qn')) {
                return [PSCustomObject]@{
                    Adequate = $true
                    Reason   = 'WiX Burn /quiet is silent.'
                }
            }
            return [PSCustomObject]@{
                Adequate = $false
                Reason   = 'WiX Burn installers require /quiet or /silent. A generic /S switch is not enough.'
            }
        }
        'installshield' {
            if ((Test-WingetterSwitchHasToken -SwitchText $text -Token '/s') -or
                (Test-WingetterSwitchHasToken -SwitchText $text -Token '/silent') -or
                ($text -match '(?i)/v".*/qn')) {
                return [PSCustomObject]@{
                    Adequate = $true
                    Reason   = 'InstallShield silent switches are present.'
                }
            }
            return [PSCustomObject]@{
                Adequate = $false
                Reason   = 'InstallShield typically needs /s /v"/qn".'
            }
        }
        'advancedinstaller' {
            if ((Test-WingetterSwitchHasToken -SwitchText $text -Token '/qn') -or
                (Test-WingetterSwitchHasToken -SwitchText $text -Token '/quiet')) {
                return [PSCustomObject]@{
                    Adequate = $true
                    Reason   = 'Advanced Installer quiet switches are present.'
                }
            }
            return [PSCustomObject]@{
                Adequate = $false
                Reason   = 'Advanced Installer requires /qn or /quiet.'
            }
        }
        default {
            if ([string]::IsNullOrWhiteSpace($text)) {
                return [PSCustomObject]@{
                    Adequate = $false
                    Reason   = 'No silent switch was provided for an unknown EXE installer.'
                }
            }
            if ((Test-WingetterSwitchHasToken -SwitchText $text -Token '/S') -or
                (Test-WingetterSwitchHasToken -SwitchText $text -Token '/quiet') -or
                (Test-WingetterSwitchHasToken -SwitchText $text -Token '/silent') -or
                (Test-WingetterSwitchHasToken -SwitchText $text -Token '/VERYSILENT') -or
                (Test-WingetterSwitchHasToken -SwitchText $text -Token '/qn')) {
                return [PSCustomObject]@{
                    Adequate = $true
                    Reason   = 'A common silent switch is present, but the installer engine was not identified.'
                }
            }
            return [PSCustomObject]@{
                Adequate = $false
                Reason   = 'The provided switch does not look silent for an unknown EXE installer.'
            }
        }
    }
}

function Get-WingetterSilentInstallCommandText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerFileName,
        [string]$Engine,
        [string]$Arguments
    )

    $fileName = $InstallerFileName
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        $fileName = 'setup.exe'
    }

    switch ($Engine) {
        'msi' {
            $argText = if ($Arguments) { " $Arguments" } else { ' /quiet /norestart' }
            return "msiexec /i `"$fileName`"$argText"
        }
        'msix' {
            return "Add-AppxPackage -Path `"$fileName`""
        }
        default {
            if ([string]::IsNullOrWhiteSpace($Arguments)) {
                return "`"$fileName`""
            }
            return "`"$fileName`" $Arguments"
        }
    }
}

function Get-WingetterSilentInstallPlan {
    param(
        [string]$InstallerFileName,
        [string]$InstallerExtension,
        [string]$InstallerPath,
        [string]$InstallerType,
        [string]$SilentSwitch
    )

    $fileName = $InstallerFileName
    if (-not $fileName -and $InstallerPath) {
        $fileName = [System.IO.Path]::GetFileName($InstallerPath)
    }

    $extension = $InstallerExtension
    if (-not $extension -and $fileName) {
        $extension = [System.IO.Path]::GetExtension($fileName)
    }

    $resolved = Resolve-WingetterInstallerEngine -InstallerPath $InstallerPath -InstallerExtension $extension -InstallerType $InstallerType
    $engine = $resolved.Engine
    $warnings = New-Object System.Collections.Generic.List[string]
    $defaultArguments = Get-WingetterDefaultSilentArguments -Engine $engine
    $wingetSwitch = if ($null -eq $SilentSwitch) { '' } else { $SilentSwitch.Trim() }

    $arguments = $defaultArguments
    $overridden = $false
    $overrideReason = ''
    $argumentSource = 'engine-default'

    if ($engine -eq 'msix') {
        $arguments = ''
        $argumentSource = 'msix'
    } elseif ($wingetSwitch) {
        $wingetCheck = Test-WingetterSilentSwitchAdequacy -Engine $engine -SwitchText $wingetSwitch
        if ($wingetCheck.Adequate) {
            $arguments = $wingetSwitch
            $argumentSource = 'winget-silent'
            if ($engine -eq 'inno' -and -not (Test-WingetterSwitchHasToken -SwitchText $arguments -Token '/NORESTART')) {
                $arguments = ($arguments.Trim() + ' /NORESTART').Trim()
            }
            if ($engine -eq 'msi' -and -not (Test-WingetterSwitchHasToken -SwitchText $arguments -Token '/norestart')) {
                $arguments = ($arguments.Trim() + ' /norestart').Trim()
            }
        } elseif (
            $engine -eq 'inno' -and
            (Test-WingetterSwitchHasToken -SwitchText $wingetSwitch -Token '/VERYSILENT') -and
            (-not (Test-WingetterSwitchHasLang -SwitchText $wingetSwitch))
        ) {
            $arguments = ($wingetSwitch.Trim() + ' /LANG=english').Trim()
            $argumentSource = 'winget-silent-plus-lang'
            $warnings.Add('Added /LANG=english. Inno Setup still shows Select Setup Language under /VERYSILENT when ShowLanguageDialog=yes unless /LANG is set.') | Out-Null
            if (-not (Test-WingetterSwitchHasToken -SwitchText $arguments -Token '/NORESTART')) {
                $arguments = ($arguments.Trim() + ' /NORESTART').Trim()
            }
        } else {
            $overridden = $true
            $overrideReason = $wingetCheck.Reason
            $arguments = $defaultArguments
            $argumentSource = 'engine-default-override'
            $warnings.Add("Winget Silent switch '$wingetSwitch' was rejected for engine '$engine'. $($wingetCheck.Reason)") | Out-Null
        }
    }

    if ($engine -eq 'inno' -and -not (Test-WingetterSwitchHasLang -SwitchText $arguments)) {
        $arguments = ($arguments.Trim() + ' /LANG=english').Trim()
        $warnings.Add('Added /LANG=english so Inno Setup does not show the language dialog.') | Out-Null
    }

    $finalCheck = Test-WingetterSilentSwitchAdequacy -Engine $engine -SwitchText $arguments
    $verified = [bool]$finalCheck.Adequate
    if ($engine -eq 'exe') {
        $warnings.Add('Installer engine was not identified. Using a generic /S switch; re-test in Sandbox.') | Out-Null
        $verified = $false
    } elseif (-not $verified) {
        $warnings.Add($finalCheck.Reason) | Out-Null
    }

    $command = Get-WingetterSilentInstallCommandText -InstallerFileName $fileName -Engine $engine -Arguments $arguments

    return [PSCustomObject]@{
        Engine                = $engine
        EngineSource          = $resolved.Source
        ProbeSignature        = $resolved.Signature
        InstallerFileName     = $fileName
        InstallerExtension    = $extension
        InstallerPath         = $InstallerPath
        WingetInstallerType   = $InstallerType
        WingetSilentSwitch    = $wingetSwitch
        Arguments             = $arguments
        ArgumentSource        = $argumentSource
        Command               = $command
        Verified              = $verified
        Overridden            = $overridden
        OverrideReason        = $overrideReason
        Warnings              = @($warnings)
        AdequacyReason        = $finalCheck.Reason
        GeneratedAt           = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Write-WingetterSilentSwitchManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        $Plan
    )

    $payload = [ordered]@{
        engine              = [string]$Plan.Engine
        engineSource        = [string]$Plan.EngineSource
        probeSignature      = [string]$Plan.ProbeSignature
        installerFile       = [string]$Plan.InstallerFileName
        wingetInstallerType = [string]$Plan.WingetInstallerType
        wingetSilentSwitch  = [string]$Plan.WingetSilentSwitch
        arguments           = [string]$Plan.Arguments
        argumentSource      = [string]$Plan.ArgumentSource
        command             = [string]$Plan.Command
        verified            = [bool]$Plan.Verified
        overridden          = [bool]$Plan.Overridden
        overrideReason      = [string]$Plan.OverrideReason
        warnings            = @($Plan.Warnings)
        adequacyReason      = [string]$Plan.AdequacyReason
        generatedAt         = [string]$Plan.GeneratedAt
    }

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    ($payload | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}

function Get-WingetterInstallCommandFromScript {
    param([string]$ScriptPath)

    if (-not $ScriptPath -or -not (Test-Path -LiteralPath $ScriptPath)) {
        return ''
    }

    try {
        $raw = Get-Content -LiteralPath $ScriptPath -Raw -ErrorAction Stop
        $match = [regex]::Match($raw, '(?s)\$installCommand = @''(.*?)''@')
        if ($match.Success) {
            return $match.Groups[1].Value.Trim()
        }
    } catch {
        return ''
    }

    return ''
}

function Get-WingetterPackageSilentInstallInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionDirectory
    )

    $installer = $null
    if (Test-Path -LiteralPath $VersionDirectory) {
        $installer = Get-ChildItem -LiteralPath $VersionDirectory -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -in '.exe', '.msi', '.msix', '.appx' -and
                $_.Name -notlike '*intunewin*'
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    $manifest = $null
    $manifestPath = Join-Path $VersionDirectory 'silent-switches.json'
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        } catch {
            $manifest = $null
        }
    }

    $packagedCommand = Get-WingetterInstallCommandFromScript -ScriptPath (Join-Path $VersionDirectory 'install.ps1')

    $recommended = $null
    if ($installer) {
        $recommended = Get-WingetterSilentInstallPlan `
            -InstallerFileName $installer.Name `
            -InstallerExtension $installer.Extension `
            -InstallerPath $installer.FullName `
            -InstallerType $(if ($manifest) { [string]$manifest.wingetInstallerType } else { '' }) `
            -SilentSwitch $(if ($manifest) { [string]$manifest.wingetSilentSwitch } else { '' })
    }

    $mismatch = $false
    $mismatchReason = ''
    if ($packagedCommand -and $recommended -and $recommended.Command) {
        if (-not [string]::Equals($packagedCommand, [string]$recommended.Command, [StringComparison]::OrdinalIgnoreCase)) {
            $mismatch = $true
            $mismatchReason = "Packaged install.ps1 uses '$packagedCommand' but the verified command for this engine is '$($recommended.Command)'."
        }
    } elseif ($packagedCommand -and $recommended) {
        $packagedCheck = Test-WingetterSilentSwitchAdequacy -Engine $recommended.Engine -SwitchText $packagedCommand
        if (-not $packagedCheck.Adequate) {
            $mismatch = $true
            $mismatchReason = "Packaged install.ps1 command is not silent for engine '$($recommended.Engine)'. $($packagedCheck.Reason)"
        }
    }

    return [PSCustomObject]@{
        Manifest         = $manifest
        ManifestPath     = $manifestPath
        PackagedCommand  = $packagedCommand
        Recommended      = $recommended
        InstallerPath    = if ($installer) { $installer.FullName } else { $null }
        Mismatch         = $mismatch
        MismatchReason   = $mismatchReason
    }
}
