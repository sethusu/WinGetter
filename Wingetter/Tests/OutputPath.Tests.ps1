Describe 'Wingetter output path helpers' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Wingetter.psd1'
        Import-Module $modulePath -Force
        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'WingetterPathTests'
    }

    It 'defaults the base folder to Documents\Wingetter under the user profile' {
        $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }
        $expected = Join-Path $homeDir 'Documents\Wingetter'
        Get-WingetterDefaultBaseOutputPath | Should -Be $expected
    }

    It 'builds an app-named folder under the base path' {
        $base = Join-Path $script:testRoot 'Packages'
        $appPath = Get-WingetterAppOutputPath -BasePath $base -PackageId 'Google.Chrome'
        $appPath | Should -Be (Join-Path $base 'Google.Chrome')
    }

    It 'does not double-nest when OutputPath already ends with PackageId' {
        $appPath = Join-Path (Join-Path $script:testRoot 'Packages') 'VideoLAN.VLC'
        $resolved = Get-WingetterAppOutputPath -BasePath $appPath -PackageId 'VideoLAN.VLC'
        $resolved | Should -Be $appPath
    }

    It 'strips the app folder when recovering the base path' {
        $base = Join-Path $script:testRoot 'Packages'
        $appPath = Join-Path $base '7zip.7zip'
        $resolved = Get-WingetterBaseOutputPath -Path $appPath -PackageId '7zip.7zip'
        $resolved | Should -Be $base
    }
}
