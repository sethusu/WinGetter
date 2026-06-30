BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' 'Modules'
    Import-Module (Join-Path $moduleRoot 'ScriptTemplates.psm1') -Force
}

Describe 'Get-WingetterRegistryVersion' {
    It 'Extracts JetBrains marketing version from DisplayName' {
        $key = [PSCustomObject]@{
            DisplayName = 'WebStorm 2025.3.1.1'
            DisplayVersion = '253.29346.242'
        }

        Get-WingetterRegistryVersion -RegistryKey $key | Should -Be '2025.3.1.1'
    }

    It 'Falls back to DisplayVersion when DisplayName has no version' {
        $key = [PSCustomObject]@{
            DisplayName = 'Google Chrome'
            DisplayVersion = '131.0.6778.86'
        }

        Get-WingetterRegistryVersion -RegistryKey $key | Should -Be '131.0.6778.86'
    }
}

Describe 'New-WingetterDetectionScript' {
    It 'Uses PSCustomObject sorting instead of hashtable property access' {
        $script = New-WingetterDetectionScript -PackageId 'JetBrains.WebStorm' -DisplayName 'WebStorm' -Version '2025.3.1.1'

        $script | Should -Match '\[PSCustomObject\]@'
        $script | Should -Match '\$_.DisplayVersion'
        $script | Should -Not -Match "\['DisplayVersion'\]"
    }

    It 'Includes flexible search tokens from display name and package id' {
        $script = New-WingetterDetectionScript -PackageId 'Tableau.Desktop' -DisplayName 'Tableau Desktop' -Version '2024.1.0'

        $script | Should -Match 'Tableau'
        $script | Should -Match 'Desktop'
    }
}

Describe 'Get-WingetterIntunePowerShellCommand' {
    It 'Returns sysnative PowerShell invocation' {
        $command = Get-WingetterIntunePowerShellCommand -ScriptFileName 'install.ps1'

        $command | Should -Match 'sysnative'
        $command | Should -Match 'install\.ps1'
    }
}
