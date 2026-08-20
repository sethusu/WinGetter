BeforeAll {
    $moduleManifest = Join-Path $PSScriptRoot '..' 'Wingetter.psd1'
    Import-Module $moduleManifest -Force
}

Describe 'Test-WingetterWindowsSandbox' {
    It 'Reports that Windows Sandbox is unavailable on non-Windows' {
        $result = Test-WingetterWindowsSandbox
        $result.Enabled | Should -Be $false
        $result.PSObject.Properties.Name | Should -Contain 'Supported'
        $result.PSObject.Properties.Name | Should -Contain 'Reason'
        $result.PSObject.Properties.Name | Should -Contain 'FeatureName'
        $result.FeatureName | Should -Be 'Containers-DisposableClientVM'

        if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
            $result.IsWindows | Should -Be $false
            $result.Supported | Should -Be $false
            $result.Reason | Should -Match 'Windows'
        }
    }
}

Describe 'ConvertTo-WingetterXmlText' {
    It 'Escapes XML special characters in mapped folder paths' {
        InModuleScope Wingetter {
            ConvertTo-WingetterXmlText -Value 'C:\Apps & Packages\<test>' |
                Should -Be 'C:\Apps &amp; Packages\&lt;test&gt;'
        }
    }

    It 'Returns an empty string for null or empty input' {
        InModuleScope Wingetter {
            ConvertTo-WingetterXmlText -Value '' | Should -Be ''
            ConvertTo-WingetterXmlText -Value $null | Should -Be ''
        }
    }
}

Describe 'New-WingetterSandboxWsbContent' {
    It 'Maps the package and handshake folders and starts the guest script' {
        InModuleScope Wingetter {
            $wsb = New-WingetterSandboxWsbContent `
                -HostPackagePath 'D:\Intune Packages\Google.Chrome\131.0' `
                -HostHandshakePath 'C:\Temp\WingetterSandbox-abc'

            $wsb | Should -Match '<HostFolder>D:\\Intune Packages\\Google.Chrome\\131.0</HostFolder>'
            $wsb | Should -Match '<SandboxFolder>C:\\WingetterPackage</SandboxFolder>'
            $wsb | Should -Match '<HostFolder>C:\\Temp\\WingetterSandbox-abc</HostFolder>'
            $wsb | Should -Match '<SandboxFolder>C:\\WingetterSandbox</SandboxFolder>'
            $wsb | Should -Match '<ReadOnly>true</ReadOnly>'
            $wsb | Should -Match '<ReadOnly>false</ReadOnly>'
            $wsb | Should -Match 'Start-WingetterSandboxGuest.ps1'
            $wsb | Should -Match '<MemoryInMB>4096</MemoryInMB>'
            $wsb | Should -Match '<LogonCommand>'
        }
    }
}

Describe 'New-WingetterSandboxGuestScript' {
    It 'Runs install, detection, and uninstall when commanded' {
        InModuleScope Wingetter {
            $script = New-WingetterSandboxGuestScript
            $script | Should -Match 'install.ps1'
            $script | Should -Match 'detection.ps1'
            $script | Should -Match 'uninstall.ps1'
            $script | Should -Match "action"
            $script | Should -Match 'Waiting for confirmation in Wingetter'
            $script | Should -Match 'C:\\WingetterTest'
            $script | Should -Match 'Copy-Item'
        }
    }
}

Describe 'Resolve-WingetterPackageVersionDirectory' {
    BeforeAll {
        $script:packageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wingetter-sandbox-pkg-{0}" -f ([Guid]::NewGuid().ToString('N')))
        $appRoot = Join-Path $script:packageRoot 'Google.Chrome'
        $versionDir = Join-Path $appRoot '131.0.6778.86'
        New-Item -ItemType Directory -Path $versionDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $versionDir 'install.ps1') -Value '# install'
        Set-Content -LiteralPath (Join-Path $versionDir 'detection.ps1') -Value '# detect'
        Set-Content -LiteralPath (Join-Path $versionDir 'uninstall.ps1') -Value '# uninstall'
        Set-Content -LiteralPath (Join-Path $versionDir 'setup.exe') -Value 'fake'
        $script:versionDir = $versionDir
        $script:appRoot = $appRoot
    }

    AfterAll {
        if ($script:packageRoot -and (Test-Path -LiteralPath $script:packageRoot)) {
            Remove-Item -LiteralPath $script:packageRoot -Recurse -Force
        }
    }

    It 'Returns the folder when it already contains install.ps1' {
        Resolve-WingetterPackageVersionDirectory -Path $script:versionDir | Should -Be ([System.IO.Path]::GetFullPath($script:versionDir))
    }

    It 'Finds the version folder under an app output path' {
        Resolve-WingetterPackageVersionDirectory -Path $script:appRoot -PackageId 'Google.Chrome' |
            Should -Be ([System.IO.Path]::GetFullPath($script:versionDir))
    }

    It 'Finds the app folder when given the base output path and package id' {
        Resolve-WingetterPackageVersionDirectory -Path $script:packageRoot -PackageId 'Google.Chrome' |
            Should -Be ([System.IO.Path]::GetFullPath($script:versionDir))
    }

    It 'Prefers the requested version folder' {
        $other = Join-Path $script:appRoot '130.0.0.0'
        New-Item -ItemType Directory -Path $other -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $other 'install.ps1') -Value '# old'
        try {
            Resolve-WingetterPackageVersionDirectory -Path $script:appRoot -PackageId 'Google.Chrome' -Version '131.0.6778.86' |
                Should -Be ([System.IO.Path]::GetFullPath($script:versionDir))
        } finally {
            Remove-Item -LiteralPath $other -Recurse -Force
        }
    }
}

Describe 'Get-WingetterSandboxPackageInfo' {
    It 'Requires install, detection, uninstall, and an installer file' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("wingetter-sandbox-info-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        try {
            $info = Get-WingetterSandboxPackageInfo -VersionDirectory $temp
            $info.Ready | Should -Be $false
            $info.Reason | Should -Match 'install.ps1'

            Set-Content -LiteralPath (Join-Path $temp 'install.ps1') -Value '# install'
            Set-Content -LiteralPath (Join-Path $temp 'detection.ps1') -Value '# detect'
            Set-Content -LiteralPath (Join-Path $temp 'uninstall.ps1') -Value '# uninstall'
            $info = Get-WingetterSandboxPackageInfo -VersionDirectory $temp
            $info.Ready | Should -Be $false
            $info.Reason | Should -Match 'installer'

            Set-Content -LiteralPath (Join-Path $temp 'app-setup.msi') -Value 'fake'
            '{"packageIdentifier":"Contoso.App","displayName":"Contoso App","version":"1.2.3"}' |
                Set-Content -LiteralPath (Join-Path $temp 'app.json') -Encoding UTF8
            $info = Get-WingetterSandboxPackageInfo -VersionDirectory $temp
            $info.Ready | Should -Be $true
            $info.PackageId | Should -Be 'Contoso.App'
            $info.DisplayName | Should -Be 'Contoso App'
            $info.Version | Should -Be '1.2.3'
        } finally {
            Remove-Item -LiteralPath $temp -Recurse -Force
        }
    }
}

Describe 'Start-WingetterSandboxSession' {
    It 'Writes WSB, guest script, and an install command without launching Sandbox' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("wingetter-sandbox-session-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $temp 'install.ps1') -Value '# install'
            Set-Content -LiteralPath (Join-Path $temp 'detection.ps1') -Value '# detect'
            Set-Content -LiteralPath (Join-Path $temp 'uninstall.ps1') -Value '# uninstall'
            Set-Content -LiteralPath (Join-Path $temp 'setup.exe') -Value 'fake'
            '{"packageIdentifier":"Contoso.App","displayName":"Contoso App","version":"1.2.3"}' |
                Set-Content -LiteralPath (Join-Path $temp 'app.json') -Encoding UTF8

            $session = Start-WingetterSandboxSession -VersionDirectory $temp -SkipLaunch
            try {
                $session.Launched | Should -Be $false
                $session.CurrentStep | Should -Be 'install'
                $session.PackageId | Should -Be 'Contoso.App'
                Test-Path -LiteralPath $session.WsbPath | Should -Be $true
                Test-Path -LiteralPath $session.GuestScriptPath | Should -Be $true
                $command = Get-Content -LiteralPath $session.CommandPath -Raw | ConvertFrom-Json
                $command.action | Should -Be 'install'
                $status = Get-WingetterSandboxStatus -HandshakeDirectory $session.HandshakeDirectory
                $status.state | Should -Be 'waiting'
                (Get-Content -LiteralPath $session.WsbPath -Raw) | Should -Match 'WingetterPackage'
            } finally {
                if ($session.HandshakeDirectory -and (Test-Path -LiteralPath $session.HandshakeDirectory)) {
                    Remove-Item -LiteralPath $session.HandshakeDirectory -Recurse -Force
                }
            }
        } finally {
            Remove-Item -LiteralPath $temp -Recurse -Force
        }
    }
}

Describe 'Test-WingetterSandboxConfirmations and Complete-WingetterSandboxTest' {
    BeforeEach {
        $script:validationDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wingetter-sandbox-valid-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:validationDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:validationDir 'install.ps1') -Value '# install'
        Set-Content -LiteralPath (Join-Path $script:validationDir 'detection.ps1') -Value '# detect'
        Set-Content -LiteralPath (Join-Path $script:validationDir 'uninstall.ps1') -Value '# uninstall'
        Set-Content -LiteralPath (Join-Path $script:validationDir 'setup.exe') -Value 'fake'
        '{"packageIdentifier":"Contoso.App","displayName":"Contoso App","version":"1.2.3"}' |
            Set-Content -LiteralPath (Join-Path $script:validationDir 'app.json') -Encoding UTF8
    }

    AfterEach {
        if ($script:validationDir -and (Test-Path -LiteralPath $script:validationDir)) {
            Remove-Item -LiteralPath $script:validationDir -Recurse -Force
        }
    }

    It 'Requires confirmation of install, detect, and uninstall' {
        $partial = @{
            install = @{ Confirmed = $true; ExitCode = 0 }
            detect = @{ Confirmed = $true; ExitCode = 0 }
            uninstall = @{ Confirmed = $false; ExitCode = 1 }
        }
        Test-WingetterSandboxConfirmations -Confirmations $partial | Should -Be $false

        $complete = @{
            install = @{ Confirmed = $true; ExitCode = 0 }
            detect = @{ Confirmed = $true; ExitCode = 1 }
            uninstall = @{ Confirmed = $true; ExitCode = 0 }
        }
        Test-WingetterSandboxConfirmations -Confirmations $complete | Should -Be $true
    }

    It 'Marks the package validated only when all three steps are confirmed' {
        $allConfirmed = @{
            install = @{ Confirmed = $true; ExitCode = 0; Message = 'installed' }
            detect = @{ Confirmed = $true; ExitCode = 0; Message = 'detected' }
            uninstall = @{ Confirmed = $true; ExitCode = 0; Message = 'uninstalled' }
        }

        $result = Complete-WingetterSandboxTest -VersionDirectory $script:validationDir -Confirmations $allConfirmed
        $result.Validated | Should -Be $true
        $result.Method | Should -Be 'WindowsSandbox'
        $result.Exists | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:validationDir 'validation.json') | Should -Be $true

        $app = Get-Content -LiteralPath (Join-Path $script:validationDir 'app.json') -Raw | ConvertFrom-Json
        $app.sandboxValidated | Should -Be $true
        $app.sandboxValidationMethod | Should -Be 'WindowsSandbox'
    }

    It 'Does not mark the package validated when a step is rejected' {
        $rejected = @{
            install = @{ Confirmed = $true; ExitCode = 0 }
            detect = @{ Confirmed = $false; ExitCode = 1 }
            uninstall = @{ Confirmed = $false; ExitCode = $null }
        }

        $result = Complete-WingetterSandboxTest -VersionDirectory $script:validationDir -Confirmations $rejected
        $result.Validated | Should -Be $false
        $app = Get-Content -LiteralPath (Join-Path $script:validationDir 'app.json') -Raw | ConvertFrom-Json
        $app.sandboxValidated | Should -Be $false
    }
}

Describe 'Set-WingetterSandboxCommand' {
    It 'Updates command.json with the next action' {
        $handshake = Join-Path ([System.IO.Path]::GetTempPath()) ("wingetter-sandbox-cmd-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $handshake -Force | Out-Null
        try {
            Set-WingetterSandboxCommand -HandshakeDirectory $handshake -Action detect
            $command = Get-Content -LiteralPath (Join-Path $handshake 'command.json') -Raw | ConvertFrom-Json
            $command.action | Should -Be 'detect'
        } finally {
            Remove-Item -LiteralPath $handshake -Recurse -Force
        }
    }
}
