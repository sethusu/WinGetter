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

function Get-WingetterNsisScopeHint {
    param([string]$InstallerFileName)

    if ([string]::IsNullOrWhiteSpace($InstallerFileName)) {
        return ''
    }

    # Winget often publishes RStudio/DBeaver-style NsisMultiUser builds as User_* or Machine_*.
    if ($InstallerFileName -match '(?i)(^|[^A-Za-z0-9])User([^A-Za-z0-9]|$)') {
        return 'currentuser'
    }
    if ($InstallerFileName -match '(?i)(Machine|AllUsers)') {
        return 'allusers'
    }

    return ''
}

function Test-WingetterSwitchHasNsisScope {
    param([string]$SwitchText)

    return (
        (Test-WingetterSwitchHasToken -SwitchText $SwitchText -Token '/currentuser') -or
        (Test-WingetterSwitchHasToken -SwitchText $SwitchText -Token '/allusers')
    )
}

function Get-WingetterDefaultSilentArguments {
    param(
        [string]$Engine,
        [string]$InstallerFileName
    )

    switch ($Engine) {
        'inno' { return '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /SP- /LANG=english' }
        'nsis' {
            # NsisMultiUser (RStudio, DBeaver, ...) rejects bare /S with exit 666660
            # ("invalid command-line parameters") unless /currentuser or /allusers is set.
            $scope = Get-WingetterNsisScopeHint -InstallerFileName $InstallerFileName
            if ($scope) {
                return "/S /$scope"
            }
            return '/S'
        }
        'msi' { return '/quiet /norestart' }
        'burn' { return '/quiet /norestart' }
        'wix' { return '/quiet /norestart' }
        'installshield' { return '/s /v"/qn /norestart"' }
        'advancedinstaller' { return '/qn' }
        'msix' { return '' }
        default { return '/S' }
    }
}

function Test-WingetterInstallExitSuccess {
    param($ExitCode)

    if ($null -eq $ExitCode -or "$ExitCode" -eq '') {
        return $false
    }

    try {
        $code = [int]$ExitCode
    } catch {
        return $false
    }

    return ($code -eq 0 -or $code -eq 3010 -or $code -eq 1641)
}

function Get-WingetterSilentSwitchCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Engine,
        [string]$InstallerFileName,
        [string]$CurrentArguments,
        [string]$WingetSilentSwitch
    )

    return @(Get-WingetterSilentSwitchCandidateInfo `
            -Engine $Engine `
            -InstallerFileName $InstallerFileName `
            -CurrentArguments $CurrentArguments `
            -WingetSilentSwitch $WingetSilentSwitch |
            ForEach-Object { $_.Arguments })
}

function Get-WingetterSilentSwitchCandidateInfo {
    <#
    .SYNOPSIS
        Returns labeled silent-switch candidates for an installer engine (for Try again UI).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Engine,
        [string]$InstallerFileName,
        [string]$CurrentArguments,
        [string]$WingetSilentSwitch
    )

    $items = New-Object System.Collections.Generic.List[object]

    $add = {
        param(
            [string]$Arguments,
            [string]$Label,
            [string]$Description
        )
        $trimmed = if ($null -eq $Arguments) { '' } else { $Arguments.Trim() }
        foreach ($existing in $items) {
            if ([string]::Equals([string]$existing.Arguments, $trimmed, [StringComparison]::OrdinalIgnoreCase)) {
                return
            }
        }
        $items.Add([PSCustomObject]@{
                Arguments   = $trimmed
                Label       = $Label
                Description = $Description
                Engine      = $Engine
                Display     = if ([string]::IsNullOrWhiteSpace($trimmed)) {
                    "$Label (no switches)"
                } else {
                    "$Label - $trimmed"
                }
            }) | Out-Null
    }

    if ($null -ne $CurrentArguments) {
        & $add $CurrentArguments 'Packaged / last tried' 'The switch currently in install.ps1 (or the last sandbox attempt).'
    }

    switch ($Engine) {
        'nsis' {
            $scope = Get-WingetterNsisScopeHint -InstallerFileName $InstallerFileName
            if ($scope -eq 'currentuser') {
                & $add '/S /currentuser' 'NSIS MultiUser (per-user)' 'Required by RStudio/DBeaver-style NsisMultiUser User installers. Bare /S returns 666660.'
                & $add '/S /allusers' 'NSIS MultiUser (all users)' 'Machine-wide; needs elevation in sandbox/Intune system context.'
            } elseif ($scope -eq 'allusers') {
                & $add '/S /allusers' 'NSIS MultiUser (all users)' 'Machine-wide silent install for Machine_* Nullsoft packages.'
                & $add '/S /currentuser' 'NSIS MultiUser (per-user)' 'Per-user fallback if all-users elevation fails.'
            } else {
                & $add '/S /currentuser' 'NSIS MultiUser (per-user)' 'Try this if bare /S returns 666660 (invalid parameters).'
                & $add '/S /allusers' 'NSIS MultiUser (all users)' 'Machine-wide; needs elevation.'
            }
            & $add '/S' 'NSIS classic silent' 'Standard Nullsoft /S (not enough for MultiUser installers).'
            & $add '/S /NCRC' 'NSIS silent + skip CRC' 'Skips CRC check; sometimes used by older NSIS packages.'
            if ($WingetSilentSwitch) {
                & $add $WingetSilentSwitch 'Winget Silent metadata' 'Value from winget show Silent:.'
            }
        }
        'inno' {
            & $add '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /SP- /LANG=english' 'Inno fully silent + language' 'Recommended Intune/sandbox switch set (avoids language dialog).'
            & $add '/VERYSILENT /NORESTART /LANG=english' 'Inno very silent + language' 'Minimal set that stays silent when ShowLanguageDialog=yes.'
            & $add '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /SP-' 'Inno very silent (no LANG)' 'May still show Select Setup Language.'
            & $add '/SILENT /NORESTART /LANG=english' 'Inno silent (shows progress)' 'Not fully silent; progress wizard may appear.'
            if ($WingetSilentSwitch) {
                & $add $WingetSilentSwitch 'Winget Silent metadata' 'Value from winget show Silent:.'
            }
        }
        'msi' {
            & $add '/quiet /norestart' 'MSI quiet' 'Standard msiexec quiet install.'
            & $add '/qn /norestart' 'MSI /qn' 'No UI msiexec level.'
            & $add '/qb /norestart' 'MSI basic UI' 'Basic progress UI only.'
            & $add '/qr /norestart' 'MSI reduced UI' 'Reduced UI msiexec level.'
        }
        { $_ -in @('burn', 'wix') } {
            & $add '/quiet /norestart' 'WiX Burn quiet' 'Standard Burn silent switch.'
            & $add '/silent /norestart' 'WiX Burn silent' 'Alternate Burn silent switch.'
            & $add '/qn' 'WiX /qn' 'MSI-style quiet passed through Burn.'
            & $add '/passive' 'WiX passive' 'Progress only; not fully silent.'
        }
        'installshield' {
            & $add '/s /v"/qn /norestart"' 'InstallShield silent + MSI quiet' 'Common InstallShield + embedded MSI pattern.'
            & $add '/s /v/qn' 'InstallShield /s /v/qn' 'Shorter InstallShield silent form.'
            & $add '/silent' 'InstallShield /silent' 'Generic InstallShield silent.'
            & $add '/s' 'InstallShield /s' 'Basic InstallShield silent.'
        }
        'advancedinstaller' {
            & $add '/qn' 'Advanced Installer /qn' 'Fully quiet.'
            & $add '/quiet' 'Advanced Installer /quiet' 'Alternate quiet switch.'
            & $add '/passive' 'Advanced Installer /passive' 'Progress only.'
        }
        'msix' {
            & $add '' 'Add-AppxPackage' 'MSIX/AppX uses Add-AppxPackage; no silent EXE switches.'
        }
        default {
            & $add '/S' 'Generic /S' 'Common NSIS-style silent guess.'
            & $add '/S /currentuser' 'Generic /S /currentuser' 'NsisMultiUser per-user guess.'
            & $add '/S /allusers' 'Generic /S /allusers' 'NsisMultiUser all-users guess.'
            & $add '/quiet' 'Generic /quiet' 'MSI/Burn-style quiet guess.'
            & $add '/silent' 'Generic /silent' 'Generic silent guess.'
            & $add '/VERYSILENT /LANG=english' 'Generic Inno very silent' 'Inno-style guess for unknown EXE.'
            & $add '/qn' 'Generic /qn' 'MSI quiet level guess.'
            if ($WingetSilentSwitch) {
                & $add $WingetSilentSwitch 'Winget Silent metadata' 'Value from winget show Silent:.'
            }
        }
    }

    # ToArray avoids @($genericList) binder failures on some PowerShell hosts.
    return @($items.ToArray())
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
    $defaultArguments = Get-WingetterDefaultSilentArguments -Engine $engine -InstallerFileName $fileName
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
            if ($engine -eq 'nsis' -and -not (Test-WingetterSwitchHasNsisScope -SwitchText $arguments)) {
                $scope = Get-WingetterNsisScopeHint -InstallerFileName $fileName
                if ($scope) {
                    $arguments = ($arguments.Trim() + " /$scope").Trim()
                    $argumentSource = 'winget-silent-plus-scope'
                    $warnings.Add("Added /$scope. NsisMultiUser installers (RStudio, DBeaver, ...) reject bare /S with exit 666660 unless /currentuser or /allusers is set.") | Out-Null
                }
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

function Split-WingetterInstallCommand {
    param([string]$Command)

    $text = if ($null -eq $Command) { '' } else { $Command.Trim() }
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [PSCustomObject]@{ FileName = ''; Arguments = ''; EngineHint = '' }
    }

    if ($text -match '(?i)^msiexec\b') {
        $args = ($text -replace '(?i)^msiexec\s+/i\s+"[^"]+"\s*', '').Trim()
        $file = ''
        if ($text -match '(?i)^msiexec\s+/i\s+"([^"]+)"') {
            $file = $matches[1]
        }
        return [PSCustomObject]@{ FileName = $file; Arguments = $args; EngineHint = 'msi' }
    }

    if ($text -match '(?i)^Add-AppxPackage\b') {
        $file = ''
        if ($text -match '-Path\s+"([^"]+)"') {
            $file = $matches[1]
        }
        return [PSCustomObject]@{ FileName = $file; Arguments = ''; EngineHint = 'msix' }
    }

    if ($text -match '^"([^"]+)"\s*(.*)$') {
        return [PSCustomObject]@{
            FileName   = $matches[1].Trim()
            Arguments  = $matches[2].Trim()
            EngineHint = ''
        }
    }

    $parts = ConvertTo-WingetterSwitchTokenList -Value $text
    if ($parts.Count -eq 0) {
        return [PSCustomObject]@{ FileName = ''; Arguments = ''; EngineHint = '' }
    }

    return [PSCustomObject]@{
        FileName   = $parts[0]
        Arguments  = (($parts | Select-Object -Skip 1) -join ' ').Trim()
        EngineHint = ''
    }
}

function Update-WingetterPackagedSilentInstall {
    <#
    .SYNOPSIS
        Permanently rewrites install.ps1 / silent-switches.json / app.json after a sandbox switch succeeds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionDirectory,
        [Parameter(Mandatory = $true)]
        [string]$Arguments,
        [string]$Engine,
        [string]$ArgumentSource = 'sandbox-retry',
        [string]$PackageId,
        [string]$DisplayName,
        [string]$Version
    )

    if (-not (Test-Path -LiteralPath $VersionDirectory)) {
        throw "Package folder not found: $VersionDirectory"
    }

    $info = Get-WingetterPackageSilentInstallInfo -VersionDirectory $VersionDirectory
    $installerFileName = $null
    if ($info.InstallerPath) {
        $installerFileName = [System.IO.Path]::GetFileName($info.InstallerPath)
    } elseif ($info.Manifest -and $info.Manifest.installerFile) {
        $installerFileName = [string]$info.Manifest.installerFile
    } elseif ($info.PackagedCommand) {
        $installerFileName = (Split-WingetterInstallCommand -Command $info.PackagedCommand).FileName
    }

    if ([string]::IsNullOrWhiteSpace($installerFileName)) {
        throw 'Could not determine installer file name for silent-switch update.'
    }

    $resolvedEngine = $Engine
    if ([string]::IsNullOrWhiteSpace($resolvedEngine)) {
        if ($info.Recommended) {
            $resolvedEngine = [string]$info.Recommended.Engine
        } elseif ($info.Manifest) {
            $resolvedEngine = [string]$info.Manifest.engine
        } else {
            $resolvedEngine = 'exe'
        }
    }

    $command = Get-WingetterSilentInstallCommandText `
        -InstallerFileName $installerFileName `
        -Engine $resolvedEngine `
        -Arguments $Arguments

    $appJsonPath = Join-Path $VersionDirectory 'app.json'
    $app = $null
    if (Test-Path -LiteralPath $appJsonPath) {
        try {
            $app = Get-Content -LiteralPath $appJsonPath -Raw | ConvertFrom-Json
        } catch {
            $app = $null
        }
    }

    $resolvedPackageId = if ($PackageId) { $PackageId } elseif ($app -and $app.packageIdentifier) { [string]$app.packageIdentifier } else { 'Unknown.Package' }
    $resolvedDisplayName = if ($DisplayName) { $DisplayName } elseif ($app -and $app.displayName) { [string]$app.displayName } else { $resolvedPackageId }
    $resolvedVersion = if ($Version) { $Version } elseif ($app -and $app.version) { [string]$app.version } else { 'Unknown' }

    $installScript = New-WingetterInstallScript `
        -PackageId $resolvedPackageId `
        -DisplayName $resolvedDisplayName `
        -Version $resolvedVersion `
        -InstallCommand $command
    $installScriptPath = Join-Path $VersionDirectory 'install.ps1'
    $installScript | Set-Content -LiteralPath $installScriptPath -Encoding UTF8

    $plan = [PSCustomObject]@{
        Engine              = $resolvedEngine
        EngineSource        = if ($info.Recommended) { $info.Recommended.EngineSource } elseif ($info.Manifest) { [string]$info.Manifest.engineSource } else { 'sandbox-retry' }
        ProbeSignature      = if ($info.Recommended) { $info.Recommended.ProbeSignature } elseif ($info.Manifest) { [string]$info.Manifest.probeSignature } else { $null }
        InstallerFileName   = $installerFileName
        WingetInstallerType = if ($info.Manifest) { [string]$info.Manifest.wingetInstallerType } else { '' }
        WingetSilentSwitch  = if ($info.Manifest) { [string]$info.Manifest.wingetSilentSwitch } else { '' }
        Arguments           = $Arguments
        ArgumentSource      = $ArgumentSource
        Command             = $command
        Verified            = $true
        Overridden          = $true
        OverrideReason      = 'Selected by sandbox silent-switch retry.'
        Warnings            = @('Silent switch was discovered and saved during Test in Sandbox.')
        AdequacyReason      = 'Sandbox install succeeded with this switch (exit 0/3010/1641, no installer UI).'
        GeneratedAt         = (Get-Date).ToUniversalTime().ToString('o')
    }

    $manifestPath = Write-WingetterSilentSwitchManifest -Path (Join-Path $VersionDirectory 'silent-switches.json') -Plan $plan

    if ($app) {
        $app | Add-Member -NotePropertyName silentInstallCommand -NotePropertyValue $command -Force
        $app | Add-Member -NotePropertyName silentInstallVerified -NotePropertyValue $true -Force
        $app | Add-Member -NotePropertyName installerEngine -NotePropertyValue $resolvedEngine -Force
        $app | Add-Member -NotePropertyName silentInstallArgumentSource -NotePropertyValue $ArgumentSource -Force
        ($app | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $appJsonPath -Encoding UTF8
    }

    return [PSCustomObject]@{
        VersionDirectory = $VersionDirectory
        InstallScriptPath = $installScriptPath
        ManifestPath = $manifestPath
        Command = $command
        Arguments = $Arguments
        Engine = $resolvedEngine
        ArgumentSource = $ArgumentSource
    }
}
