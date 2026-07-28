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
