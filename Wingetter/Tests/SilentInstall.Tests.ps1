BeforeAll {
    $moduleManifest = Join-Path $PSScriptRoot '..' 'Wingetter.psd1'
    Import-Module $moduleManifest -Force
}

Describe 'Resolve-WingetterInstallerEngineName' {
    It 'Maps winget installer types to engines' {
        InModuleScope Wingetter {
            Resolve-WingetterInstallerEngineName -Value 'inno' | Should -Be 'inno'
            Resolve-WingetterInstallerEngineName -Value 'nullsoft' | Should -Be 'nsis'
            Resolve-WingetterInstallerEngineName -Value 'burn' | Should -Be 'burn'
            Resolve-WingetterInstallerEngineName -Value 'msi' | Should -Be 'msi'
            Resolve-WingetterInstallerEngineName -Value 'msix' | Should -Be 'msix'
            Resolve-WingetterInstallerEngineName -Value 'exe' | Should -Be $null
        }
    }
}

Describe 'Test-WingetterSilentSwitchAdequacy' {
    It 'Rejects generic /S for Inno Setup' {
        $result = InModuleScope Wingetter {
            Test-WingetterSilentSwitchAdequacy -Engine 'inno' -SwitchText '/S'
        }
        $result.Adequate | Should -Be $false
        $result.Reason | Should -Match 'Inno'
    }

    It 'Rejects /VERYSILENT without /LANG for Inno Setup' {
        $result = InModuleScope Wingetter {
            Test-WingetterSilentSwitchAdequacy -Engine 'inno' -SwitchText '/VERYSILENT /NORESTART'
        }
        $result.Adequate | Should -Be $false
        $result.Reason | Should -Match 'LANG'
    }

    It 'Accepts /VERYSILENT with /LANG for Inno Setup' {
        $result = InModuleScope Wingetter {
            Test-WingetterSilentSwitchAdequacy -Engine 'inno' -SwitchText '/VERYSILENT /NORESTART /LANG=english'
        }
        $result.Adequate | Should -Be $true
    }

    It 'Rejects /SILENT as not fully silent for Inno Setup' {
        $result = InModuleScope Wingetter {
            Test-WingetterSilentSwitchAdequacy -Engine 'inno' -SwitchText '/SILENT'
        }
        $result.Adequate | Should -Be $false
        $result.Reason | Should -Match 'VERYSILENT'
    }

    It 'Accepts /S for NSIS' {
        InModuleScope Wingetter {
            (Test-WingetterSilentSwitchAdequacy -Engine 'nsis' -SwitchText '/S').Adequate | Should -Be $true
        }
    }

    It 'Accepts /quiet for MSI and Burn' {
        InModuleScope Wingetter {
            (Test-WingetterSilentSwitchAdequacy -Engine 'msi' -SwitchText '/quiet /norestart').Adequate | Should -Be $true
            (Test-WingetterSilentSwitchAdequacy -Engine 'burn' -SwitchText '/quiet').Adequate | Should -Be $true
            (Test-WingetterSilentSwitchAdequacy -Engine 'burn' -SwitchText '/S').Adequate | Should -Be $false
        }
    }
}

Describe 'Get-WingetterSilentInstallPlan' {
    It 'Uses msiexec quiet switches for MSI' {
        $plan = Get-WingetterSilentInstallPlan -InstallerFileName 'App.msi' -InstallerExtension '.msi'
        $plan.Engine | Should -Be 'msi'
        $plan.Command | Should -Be 'msiexec /i "App.msi" /quiet /norestart'
        $plan.Verified | Should -Be $true
    }

    It 'Uses Add-AppxPackage for MSIX' {
        $plan = Get-WingetterSilentInstallPlan -InstallerFileName 'App.msix' -InstallerExtension '.msix'
        $plan.Engine | Should -Be 'msix'
        $plan.Command | Should -Be 'Add-AppxPackage -Path "App.msix"'
        $plan.Verified | Should -Be $true
    }

    It 'Overrides Winget /S for Inno Setup' {
        $plan = Get-WingetterSilentInstallPlan -InstallerFileName 'PrusaSlicer.exe' -InstallerExtension '.exe' `
            -InstallerType 'inno' -SilentSwitch '/S'
        $plan.Engine | Should -Be 'inno'
        $plan.Overridden | Should -Be $true
        $plan.Verified | Should -Be $true
        $plan.Command | Should -Match '/VERYSILENT'
        $plan.Command | Should -Not -Match '(?i)(?<!VERY)/SILENT'
        $plan.Command | Should -Be '"PrusaSlicer.exe" /VERYSILENT /NORESTART /SUPPRESSMSGBOXES /SP- /LANG=english'
    }

    It 'Keeps a Winget Silent switch that is already adequate for Inno' {
        $plan = Get-WingetterSilentInstallPlan -InstallerFileName 'Setup.exe' -InstallerExtension '.exe' `
            -InstallerType 'inno' -SilentSwitch '/VERYSILENT /SUPPRESSMSGBOXES /LANG=english'
        $plan.Overridden | Should -Be $false
        $plan.ArgumentSource | Should -Be 'winget-silent'
        $plan.Command | Should -Match '/VERYSILENT'
        $plan.Command | Should -Match '/NORESTART'
    }

    It 'Adds /LANG=english when Winget Silent is /VERYSILENT without a language' {
        $plan = Get-WingetterSilentInstallPlan -InstallerFileName 'Setup.exe' -InstallerExtension '.exe' `
            -InstallerType 'inno' -SilentSwitch '/VERYSILENT /SUPPRESSMSGBOXES'
        $plan.ArgumentSource | Should -Be 'winget-silent-plus-lang'
        $plan.Verified | Should -Be $true
        $plan.Command | Should -Match '/LANG=english'
    }

    It 'Uses /S for NSIS' {
        $plan = Get-WingetterSilentInstallPlan -InstallerFileName 'setup.exe' -InstallerExtension '.exe' -InstallerType 'nullsoft'
        $plan.Engine | Should -Be 'nsis'
        $plan.Command | Should -Be '"setup.exe" /S'
        $plan.Verified | Should -Be $true
    }

    It 'Probes installer bytes for Inno Setup' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("wingetter-inno-{0}.exe" -f ([Guid]::NewGuid().ToString('N')))
        try {
            Set-Content -LiteralPath $temp -Value "MZ padding Inno Setup Setup Data more bytes" -Encoding ASCII
            $plan = Get-WingetterSilentInstallPlan -InstallerFileName ([System.IO.Path]::GetFileName($temp)) `
                -InstallerExtension '.exe' -InstallerPath $temp
            $plan.Engine | Should -Be 'inno'
            $plan.EngineSource | Should -Be 'file-probe'
            $plan.Command | Should -Match '/VERYSILENT'
            $plan.Command | Should -Match '/LANG=english'
        } finally {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-InstallerInstallCommand' {
    It 'Remains a thin wrapper over the silent-install plan' {
        InModuleScope Wingetter {
            Get-InstallerInstallCommand -InstallerFileName 'App.msi' -InstallerExtension '.msi' |
                Should -Be 'msiexec /i "App.msi" /quiet /norestart'
            Get-InstallerInstallCommand -InstallerFileName 'Setup.exe' -InstallerExtension '.exe' -InstallerType 'inno' |
                Should -Match '/VERYSILENT'
        }
    }
}

Describe 'Get-WingetSilentSwitchFromShowText' {
    It 'Reads the Silent switch and ignores SilentWithProgress' {
        $text = @"
Installer:
  Installer Type: inno
Installer Switches:
  Silent: /S
  SilentWithProgress: /SILENT /NORESTART
"@
        InModuleScope Wingetter -Parameters @{ ShowText = $text } {
            param($ShowText)
            Get-WingetSilentSwitchFromShowText -Text $ShowText | Should -Be '/S'
        }
    }
}

Describe 'Get-WingetterPackageSilentInstallInfo' {
    It 'Flags a packaged Inno /S command as a mismatch against verified switches' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("wingetter-silent-pkg-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $temp 'PrusaSlicer.exe') -Value 'MZ Inno Setup Setup Data' -Encoding ASCII
            $installScript = @"
`$installCommand = @'
"PrusaSlicer.exe" /S
'@
"@
            Set-Content -LiteralPath (Join-Path $temp 'install.ps1') -Value $installScript -Encoding UTF8

            $info = InModuleScope Wingetter -Parameters @{ Dir = $temp } {
                param($Dir)
                Get-WingetterPackageSilentInstallInfo -VersionDirectory $Dir
            }
            $info.PackagedCommand | Should -Be '"PrusaSlicer.exe" /S'
            $info.Mismatch | Should -Be $true
            $info.Recommended.Engine | Should -Be 'inno'
            $info.Recommended.Command | Should -Match '/VERYSILENT'
        } finally {
            Remove-Item -LiteralPath $temp -Recurse -Force
        }
    }
}

Describe 'New-WingetterUninstallScript' {
    It 'Uses Inno silent switches when the engine is inno' {
        InModuleScope Wingetter {
            $script = New-WingetterUninstallScript -PackageId 'Prusa3D.PrusaSlicer' -DisplayName 'PrusaSlicer' -InstallerEngine 'inno'
            $script | Should -Match '\$installerEngine = ''inno'''
            $script | Should -Match '/VERYSILENT'
        }
    }
}
