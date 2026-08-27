BeforeAll {
    $moduleManifest = Join-Path $PSScriptRoot '..' 'Wingetter.psd1'
    Import-Module $moduleManifest -Force
}

Describe 'Get-IconUrlPriorityScore' {
    It 'Ranks installer-local icons above web image search' {
        InModuleScope Wingetter {
            $installer = Get-IconUrlPriorityScore -Url 'C:\temp\setup.exe' -DisplayName 'VLC' -PackageId 'VideoLAN.VLC' -Source 'Installer'
            $web = Get-IconUrlPriorityScore -Url 'https://cdn.example/logo.png' -DisplayName 'VLC' -PackageId 'VideoLAN.VLC' -Source 'WebSearch'
            $installer | Should -BeGreaterThan $web
        }
    }

    It 'Prefers known publisher icons over Wikimedia and Bing search' {
        InModuleScope Wingetter {
            $known = Get-IconUrlPriorityScore -Url 'https://example.com/logo.png' -DisplayName 'Chrome' -PackageId 'Google.Chrome' -Source 'Known'
            $wiki = Get-IconUrlPriorityScore -Url 'https://upload.wikimedia.org/wikipedia/commons/chrome.png' -DisplayName 'Chrome' -PackageId 'Google.Chrome' -Source 'Wikimedia'
            $web = Get-IconUrlPriorityScore -Url 'https://bingcdn.example/chrome.png' -DisplayName 'Chrome' -PackageId 'Google.Chrome' -Source 'WebSearch'
            $known | Should -BeGreaterThan $wiki
            $wiki | Should -BeGreaterThan $web
        }
    }

    It 'Penalizes SVG URLs that cannot be converted by the PNG saver' {
        InModuleScope Wingetter {
            $png = Get-IconUrlPriorityScore -Url 'https://example.com/logo.png' -DisplayName 'App' -PackageId 'Pub.App' -Source 'Known'
            $svg = Get-IconUrlPriorityScore -Url 'https://example.com/logo.svg' -DisplayName 'App' -PackageId 'Pub.App' -Source 'Known'
            $png | Should -BeGreaterThan $svg
        }
    }
}

Describe 'Test-ImageBytes' {
    It 'Recognizes PNG magic bytes' {
        InModuleScope Wingetter {
            $png = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
            Test-ImageBytes -Bytes $png | Should -Be $true
        }
    }

    It 'Rejects empty or tiny buffers' {
        InModuleScope Wingetter {
            Test-ImageBytes -Bytes $null | Should -Be $false
            Test-ImageBytes -Bytes ([byte[]](1, 2, 3)) | Should -Be $false
        }
    }
}

Describe 'Get-ImageFileQualityScore helpers' {
    It 'Scores square logo-like names higher than splash screens when files exist' {
        InModuleScope Wingetter {
            $canDraw = $false
            try {
                Add-Type -AssemblyName System.Drawing -ErrorAction Stop
                $probe = New-Object System.Drawing.Bitmap 8, 8
                $probe.Dispose()
                $canDraw = $true
            } catch {
                $canDraw = $false
            }

            if (-not $canDraw) {
                Set-ItResult -Skipped -Because 'System.Drawing is unavailable in this environment'
                return
            }

            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wingetter-icon-test-{0}" -f ([Guid]::NewGuid().ToString('N')))
            New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
            try {
                $logoPath = Join-Path $tempRoot 'Square150x150Logo.png'
                $splashPath = Join-Path $tempRoot 'SplashScreen.png'

                $logo = New-Object System.Drawing.Bitmap 150, 150
                $splash = New-Object System.Drawing.Bitmap 620, 300
                try {
                    $logo.Save($logoPath, [System.Drawing.Imaging.ImageFormat]::Png)
                    $splash.Save($splashPath, [System.Drawing.Imaging.ImageFormat]::Png)
                } finally {
                    $logo.Dispose()
                    $splash.Dispose()
                }

                $logoScore = Get-ImageFileQualityScore -Path $logoPath
                $splashScore = Get-ImageFileQualityScore -Path $splashPath
                $logoScore | Should -BeGreaterThan $splashScore
            } finally {
                Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Resolve-WingetterPackagingUiResult' {
    It 'Selects the packaging object from Content Prep Tool stdout noise' {
        $packResult = [PSCustomObject]@{
            PackageId = 'Posit.RStudio'
            VersionDirectory = 'D:\Out\Posit.RStudio\2026.08.1+195'
            IconFile = 'D:\Out\Posit.RStudio\2026.08.1+195\icon.png'
            LogoFile = 'D:\Out\Posit.RStudio\logo.png'
        }
        $raw = @(
            'Microsoft Win32 Content Prep Tool'
            'Copyright (c)'
            $packResult
            'File created successfully'
        )

        $resolved = Resolve-WingetterPackagingUiResult -Raw $raw
        $resolved.PackageId | Should -Be 'Posit.RStudio'
        $resolved.IconFile | Should -Match 'icon\.png$'
    }

    It 'Throws when no packaging object is present' {
        { Resolve-WingetterPackagingUiResult -Raw @('a', 'b') } | Should -Throw '*could not read the packaging result*'
    }
}

Describe 'Update-WingetterPackageIconSelection' {
    It 'Copies the selected icon and refreshes win32LobApp.json largeIcon' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("wingetter-icon-sel-{0}" -f ([Guid]::NewGuid().ToString('N')))
        $versionDir = Join-Path $root '1.0.0'
        New-Item -ItemType Directory -Path $versionDir -Force | Out-Null
        try {
            $png = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D)
            $source = Join-Path $root 'candidate.png'
            $logo = Join-Path $root 'logo.png'
            $icon = Join-Path $versionDir 'icon.png'
            [System.IO.File]::WriteAllBytes($source, $png)
            [System.IO.File]::WriteAllBytes((Join-Path $versionDir 'old.png'), $png)
            @{
                displayName = 'RStudio'
                largeIcon = @{ type = 'image/png'; value = 'old' }
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $versionDir 'win32LobApp.json') -Encoding UTF8

            $updated = Update-WingetterPackageIconSelection `
                -VersionDirectory $versionDir `
                -SourceIconPath $source `
                -LogoFilePath $logo `
                -IconFilePath $icon

            (Test-Path -LiteralPath $updated.IconFile) | Should -Be $true
            (Test-Path -LiteralPath $updated.LogoFile) | Should -Be $true
            $win32 = Get-Content -LiteralPath (Join-Path $versionDir 'win32LobApp.json') -Raw | ConvertFrom-Json
            $win32.largeIcon.value | Should -Not -Be 'old'
            $win32.largeIcon.value.Length | Should -BeGreaterThan 10
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
