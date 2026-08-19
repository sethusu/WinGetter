BeforeAll {
    $moduleManifest = Join-Path $PSScriptRoot '..' 'Wingetter.psd1'
    Import-Module $moduleManifest -Force

    $script:fixtureRoot = Join-Path $PSScriptRoot 'Fixtures'
}

Describe 'Normalize-WingetPackageId' {
    It 'Removes whitespace around dots and within IDs' {
        InModuleScope Wingetter {
            Normalize-WingetPackageId -Id 'Valve. Steam' | Should -Be 'Valve.Steam'
            Normalize-WingetPackageId -Id '  Google.Chrome  ' | Should -Be 'Google.Chrome'
        }
    }

    It 'Returns empty string for blank input' {
        InModuleScope Wingetter {
            Normalize-WingetPackageId -Id '' | Should -Be ''
            Normalize-WingetPackageId -Id '   ' | Should -Be ''
        }
    }
}

Describe 'Test-WingetPackageId' {
    It 'Recognizes publisher.package identifiers' {
        InModuleScope Wingetter {
            Test-WingetPackageId -Query 'Google.Chrome' | Should -Be $true
            Test-WingetPackageId -Query 'JetBrains.WebStorm' | Should -Be $true
            Test-WingetPackageId -Query '7zip.7zip' | Should -Be $true
        }
    }

    It 'Rejects free-form search terms' {
        InModuleScope Wingetter {
            Test-WingetPackageId -Query 'chrome' | Should -Be $false
            Test-WingetPackageId -Query 'web storm' | Should -Be $false
            Test-WingetPackageId -Query '' | Should -Be $false
        }
    }
}

Describe 'Parse-WingetSourceList' {
    It 'Parses all configured repositories including custom sources' {
        $fixture = Get-Content -Path (Join-Path $script:fixtureRoot 'source-list.txt') -Raw
        $sources = InModuleScope Wingetter -Parameters @{ Fixture = $fixture } {
            param($Fixture)
            Parse-WingetSourceList -SourceOutput $Fixture
        }

        $sources.Count | Should -Be 3
        $sources | Should -Contain 'winget'
        $sources | Should -Contain 'msstore'
        $sources | Should -Contain 'contoso'
    }
}

Describe 'Parse-WingetSearchResults' {
    It 'Parses multiple search results with Match column' {
        $fixture = Get-Content -Path (Join-Path $script:fixtureRoot 'search-multiple-results.txt') -Raw
        $packages = InModuleScope Wingetter -Parameters @{ Fixture = $fixture } {
            param($Fixture)
            Parse-WingetSearchResults -SearchOutput $Fixture
        }

        $packages.Count | Should -Be 3
        $packages[0].Id | Should -Be 'Google.Chrome'
        $packages[0].Version | Should -Be '131.0.6778.86'
        $packages[0].Source | Should -Be 'winget'
        $packages[1].Id | Should -Be 'Eloston.UngoogledChromium'
    }

    It 'Parses four-column tables and keeps Source' {
        $fixture = Get-Content -Path (Join-Path $script:fixtureRoot 'search-four-column.txt') -Raw
        $packages = InModuleScope Wingetter -Parameters @{ Fixture = $fixture } {
            param($Fixture)
            Parse-WingetSearchResults -SearchOutput $Fixture
        }

        $packages.Count | Should -Be 2
        $packages[0].Id | Should -Be 'Google.Chrome'
        $packages[0].Source | Should -Be 'winget'
        $packages[1].Id | Should -Be 'Microsoft.Edge'
    }

    It 'Includes MS Store packages without dotted IDs' {
        $fixture = Get-Content -Path (Join-Path $script:fixtureRoot 'search-msstore-mixed.txt') -Raw
        $packages = InModuleScope Wingetter -Parameters @{ Fixture = $fixture } {
            param($Fixture)
            Parse-WingetSearchResults -SearchOutput $Fixture
        }

        $packages.Count | Should -Be 2
        $packages[0].Id | Should -Be 'XP89DCGQ3K6VLD'
        $packages[0].Source | Should -Be 'msstore'
        $packages[1].Id | Should -Be 'Microsoft.PowerToys'
        $packages[1].Source | Should -Be 'winget'
    }

    It 'Parses VLC Command-match rows the same way winget search vlc displays them' {
        $fixture = Get-Content -Path (Join-Path $script:fixtureRoot 'search-vlc.txt') -Raw
        $packages = InModuleScope Wingetter -Parameters @{ Fixture = $fixture } {
            param($Fixture)
            Parse-WingetSearchResults -SearchOutput $Fixture
        }

        $packages.Count | Should -BeGreaterThan 0
        $packages.Id | Should -Contain 'VideoLAN.VLC'
        ($packages | Where-Object { $_.Id -eq 'VideoLAN.VLC' }).Source | Should -Be 'winget'
        $packages.Id | Should -Contain 'XPDM1ZW6815MQM'
    }

    It 'Recovers results from UTF-16 NUL-padded winget redirect output' {
        $fixture = Get-Content -Path (Join-Path $script:fixtureRoot 'search-vlc.txt') -Raw
        $nulPadded = (($fixture.ToCharArray() | ForEach-Object { "$_$([char]0)" }) -join '')

        $packages = InModuleScope Wingetter -Parameters @{ Fixture = $nulPadded } {
            param($Fixture)
            Parse-WingetSearchResults -SearchOutput $Fixture
        }

        $packages.Id | Should -Contain 'VideoLAN.VLC'
    }

    It 'Flags truncated package IDs' {
        $fixture = Get-Content -Path (Join-Path $script:fixtureRoot 'search-truncated-ids.txt') -Raw
        $packages = InModuleScope Wingetter -Parameters @{ Fixture = $fixture } {
            param($Fixture)
            Parse-WingetSearchResults -SearchOutput $Fixture
        }

        $packages.Count | Should -Be 3
        ($packages | Where-Object { $_.TruncatedId }).Count | Should -Be 2
        $packages[0].TruncatedId | Should -Be $false
        $packages[0].Id | Should -Be 'Microsoft.WindowsTerminal'
    }

    It 'Returns an empty array when no packages are found' {
        $fixture = Get-Content -Path (Join-Path $script:fixtureRoot 'search-no-results.txt') -Raw
        $packages = InModuleScope Wingetter -Parameters @{ Fixture = $fixture } {
            param($Fixture)
            Parse-WingetSearchResults -SearchOutput $Fixture
        }

        @($packages).Count | Should -Be 0
    }

    It 'Applies DefaultSource when Source column is missing' {
        $output = @"
Name                     Id                        Version
-----------------------------------------------------------
Example App              Contoso.Example           1.2.3
"@
        $packages = InModuleScope Wingetter -Parameters @{ Fixture = $output } {
            param($Fixture)
            Parse-WingetSearchResults -SearchOutput $Fixture -DefaultSource 'contoso'
        }

        $packages.Count | Should -Be 1
        $packages[0].Source | Should -Be 'contoso'
    }

    It 'Parses single Found line format' {
        $output = @(
            'Found Google Chrome [Google.Chrome]'
            'Version: 131.0.6778.86'
        )

        $packages = InModuleScope Wingetter -Parameters @{ Fixture = $output } {
            param($Fixture)
            Parse-WingetSearchResults -SearchOutput $Fixture -DefaultSource 'winget'
        }

        $packages.Count | Should -Be 1
        $packages[0].Id | Should -Be 'Google.Chrome'
        $packages[0].Source | Should -Be 'winget'
    }
}

Describe 'Sort-WingetPackageMatches' {
    It 'Prioritizes exact package ID matches' {
        $sorted = InModuleScope Wingetter {
            $packages = @(
                [PSCustomObject]@{ Name = 'Chromium'; Id = 'Eloston.UngoogledChromium'; Version = '1.0'; Source = 'winget'; TruncatedId = $false }
                [PSCustomObject]@{ Name = 'Google Chrome'; Id = 'Google.Chrome'; Version = '2.0'; Source = 'winget'; TruncatedId = $false }
            )
            Sort-WingetPackageMatches -Query 'Google.Chrome' -Packages $packages
        }

        $sorted[0].Id | Should -Be 'Google.Chrome'
    }

    It 'Keeps all repositories while preferring winget packaging candidates' {
        $sorted = InModuleScope Wingetter {
            $packages = @(
                [PSCustomObject]@{ Name = 'PowerToys'; Id = 'XP89DCGQ3K6VLD'; Version = 'Unknown'; Source = 'msstore'; TruncatedId = $false }
                [PSCustomObject]@{ Name = 'PowerToys (Preview)'; Id = 'Microsoft.PowerToys'; Version = '0.87.0'; Source = 'winget'; TruncatedId = $false }
                [PSCustomObject]@{ Name = 'PowerToys Internal'; Id = 'Contoso.PowerToys'; Version = '1.0.0'; Source = 'contoso'; TruncatedId = $false }
            )
            Sort-WingetPackageMatches -Query 'powertoys' -Packages $packages
        }

        $sorted.Count | Should -Be 3
        $sorted.Id | Should -Contain 'XP89DCGQ3K6VLD'
        $sorted.Id | Should -Contain 'Contoso.PowerToys'
        $sorted[0].Id | Should -Be 'Microsoft.PowerToys'
    }
}

Describe 'Search-WingetPackages' {
    It 'Searches every configured repository and merges results' {
        $wingetFixture = Get-Content -Path (Join-Path $script:fixtureRoot 'search-four-column.txt') -Raw
        $msstoreFixture = Get-Content -Path (Join-Path $script:fixtureRoot 'search-msstore-mixed.txt') -Raw

        $results = InModuleScope Wingetter -Parameters @{
            WingetFixture = $wingetFixture
            MsStoreFixture = $msstoreFixture
        } {
            param($WingetFixture, $MsStoreFixture)

            Mock Get-WingetConfiguredSources { return @('winget', 'msstore') }
            Mock Find-WingetPackagesFromModule { return $null }
            Mock Test-WingetSearchCountSupported { return $false }
            Mock Resolve-WingetTruncatedPackage { param($Package) return $Package }
            Mock Invoke-WingetCli {
                param($Command, $Arguments)
                if ($Command -eq 'search' -and ($Arguments -contains 'msstore')) {
                    return @{ Output = $MsStoreFixture; ExitCode = 0; SupportsPackageAgreements = $false }
                }
                if ($Command -eq 'search') {
                    return @{ Output = $WingetFixture; ExitCode = 0; SupportsPackageAgreements = $false }
                }
                return @{ Output = ''; ExitCode = 1; SupportsPackageAgreements = $false }
            }

            Search-WingetPackages -Query 'powertoys'
        }

        ($results | Where-Object { $_.Source -eq 'winget' }).Count | Should -BeGreaterThan 0
        ($results | Where-Object { $_.Source -eq 'msstore' }).Count | Should -BeGreaterThan 0
        $results.Id | Should -Contain 'XP89DCGQ3K6VLD'
    }

    It 'Finds VLC via unscoped winget-style query output' {
        $vlcFixture = Get-Content -Path (Join-Path $script:fixtureRoot 'search-vlc.txt') -Raw

        $results = InModuleScope Wingetter -Parameters @{ VlcFixture = $vlcFixture } {
            param($VlcFixture)

            Mock Get-WingetConfiguredSources { return @('winget', 'msstore') }
            Mock Find-WingetPackagesFromModule { return $null }
            Mock Test-WingetSearchCountSupported { return $false }
            Mock Resolve-WingetTruncatedPackage { param($Package) return $Package }
            Mock Invoke-WingetCli {
                param($Command, $Arguments)
                if ($Command -eq 'search') {
                    return @{ Output = $VlcFixture; ExitCode = 0; SupportsPackageAgreements = $false }
                }
                return @{ Output = ''; ExitCode = 1; SupportsPackageAgreements = $false }
            }

            Search-WingetPackages -Query 'VLC'
        }

        $results.Id | Should -Contain 'VideoLAN.VLC'
        ($results | Where-Object { $_.Id -eq 'VideoLAN.VLC' }).Name | Should -Match 'VLC'
    }

    It 'Uses exact show lookup for package IDs' {
        $results = InModuleScope Wingetter {
            Mock Get-WingetConfiguredSources { return @('winget') }
            Mock Find-WingetPackagesFromModule { return $null }
            Mock Test-WingetSearchCountSupported { return $false }
            Mock Resolve-WingetTruncatedPackage { param($Package) return $Package }
            Mock Invoke-WingetCli {
                param($Command, $Arguments)
                if ($Command -eq 'show' -and $Arguments -contains '--exact') {
                    return @{
                        Output = @(
                            'Found Google Chrome [Google.Chrome]'
                            'Version: 131.0.6778.86'
                            'Source: winget'
                        )
                        ExitCode = 0
                        SupportsPackageAgreements = $false
                    }
                }
                if ($Command -eq 'search') {
                    return @{ Output = 'No package found matching input criteria.'; ExitCode = -1978335212; SupportsPackageAgreements = $false }
                }
                return @{ Output = ''; ExitCode = 1; SupportsPackageAgreements = $false }
            }

            Search-WingetPackages -Query 'Google.Chrome'
        }

        $results.Count | Should -Be 1
        $results[0].Id | Should -Be 'Google.Chrome'
        $results[0].Source | Should -Be 'winget'
    }
}

Describe 'Get-WingetPackageDetails source fallback' {
    It 'Retries without --source when winget reports SOURCE_NAME_DOES_NOT_EXIST' {
        $details = InModuleScope Wingetter {
            Mock Get-WingetConfiguredSources { return @('winget', 'msstore') }
            Mock Invoke-WingetCli {
                param($Command, $Arguments)
                if ($Command -ne 'show') {
                    return @{ Output = ''; ExitCode = 1; SupportsPackageAgreements = $false }
                }

                if ($Arguments -contains '--source') {
                    return @{ Output = 'The source name does not exist.'; ExitCode = -1978335214; SupportsPackageAgreements = $false }
                }

                return @{
                    Output = @(
                        'Found VLC media player [VideoLAN.VLC]'
                        'Version: 3.0.20'
                        'Publisher: VideoLAN'
                        'Homepage: https://www.videolan.org'
                        'Source: winget'
                    )
                    ExitCode = 0
                    SupportsPackageAgreements = $false
                }
            }

            Get-WingetPackageDetails -PackageId 'VideoLAN.VLC' -Source 'msstore'
        }

        $details.PackageId | Should -Be 'VideoLAN.VLC'
        $details.Version | Should -Be '3.0.20'
        $details.Source | Should -Be 'winget'
    }

    It 'Skips unknown source names before calling winget show' {
        InModuleScope Wingetter {
            Mock Get-WingetConfiguredSources { return @('winget') }
            Mock Invoke-WingetCli {
                param($Command, $Arguments)
                if ($Command -eq 'show' -and $Arguments -contains '--source') {
                    throw 'should not pass unknown --source'
                }
                return @{
                    Output = @(
                        'Found Google Chrome [Google.Chrome]'
                        'Version: 131.0.6778.86'
                        'Publisher: Google'
                        'Source: winget'
                    )
                    ExitCode = 0
                    SupportsPackageAgreements = $false
                }
            }

            $details = Get-WingetPackageDetails -PackageId 'Google.Chrome' -Source 'not-a-real-source'
            $details.PackageId | Should -Be 'Google.Chrome'
        }
    }

    It 'Describes SOURCE_NAME_DOES_NOT_EXIST exit code' {
        InModuleScope Wingetter {
            Get-WingetExitCodeDescription -ExitCode -1978335214 | Should -Be 'The source name does not exist'
        }
    }
}

Describe 'Get-WingetDownloadArguments' {
    It 'Includes version and source when provided' {
        InModuleScope Wingetter {
            Mock Get-WingetConfiguredSources { return @('winget', 'msstore') }
            $args = Get-WingetDownloadArguments -PackageId 'Prusa3D.PrusaSlicer' `
                -DownloadDirectory 'C:\Temp\dl' -Version '2.9.6' -Source 'winget' -AcceptPackageAgreements

            $args | Should -Contain 'Prusa3D.PrusaSlicer'
            $args | Should -Contain '--exact'
            $args | Should -Contain '--download-directory'
            $args | Should -Contain 'C:\Temp\dl'
            $args | Should -Contain '--version'
            $args | Should -Contain '2.9.6'
            $args | Should -Contain '--source'
            $args | Should -Contain 'winget'
            $args | Should -Contain '--accept-package-agreements'
        }
    }

    It 'Omits unknown source names' {
        InModuleScope Wingetter {
            Mock Get-WingetConfiguredSources { return @('winget') }
            $args = Get-WingetDownloadArguments -PackageId 'Google.Chrome' -DownloadDirectory 'C:\Temp\dl' -Source 'not-a-real-source'

            $args | Should -Not -Contain '--source'
        }
    }
}
