BeforeAll {
    $moduleManifest = Join-Path $PSScriptRoot '..' 'Wingetter.psd1'
    Import-Module $moduleManifest -Force
}

Describe 'New-WingetterMetadataFiles licensing export' {
    It 'Writes licensing details to app.json, README.md, and win32LobApp notes' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("wingetter-metadata-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        try {
            $details = [PSCustomObject]@{
                PackageId = 'Contoso.App'
                DisplayName = 'Contoso App'
                Description = 'Contoso sample app'
                Version = '1.2.3'
                Publisher = 'Contoso'
                Developer = 'Contoso'
                Homepage = 'https://contoso.example/app'
            }
            $license = 'DG4P47-NIWEFM-VT98ZG-8FMEQ9'

            InModuleScope Wingetter -Parameters @{
                PackageDetails = $details
                VersionDirectory = $temp
                LicensingInfo = $license
            } {
                param($PackageDetails, $VersionDirectory, $LicensingInfo)
                New-WingetterMetadataFiles `
                    -PackageDetails $PackageDetails `
                    -VersionDirectory $VersionDirectory `
                    -InstallerFileName 'setup.exe' `
                    -InstallerHash 'ABC123' `
                    -InstallerInstallCommand '"setup.exe" /S' `
                    -DetectionScript '# detect' `
                    -InstallScript '# install' `
                    -UninstallScript '# uninstall' `
                    -IconFilePath (Join-Path $VersionDirectory 'missing-icon.png') `
                    -SilentInstallPlan @{ Engine = 'nsis'; Verified = $true } `
                    -LicensingInfo $LicensingInfo | Out-Null
            }

            $appJson = Get-Content -LiteralPath (Join-Path $temp 'app.json') -Raw | ConvertFrom-Json
            $appJson.licensingDetails | Should -Be $license

            $readme = Get-Content -LiteralPath (Join-Path $temp 'README.md') -Raw
            $readme | Should -Match [regex]::Escape('| **Licensing details** | ' + $license + ' |')

            $win32 = Get-Content -LiteralPath (Join-Path $temp 'win32LobApp.json') -Raw | ConvertFrom-Json
            $win32.notes | Should -Match [regex]::Escape("[License|$license]")
        } finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
