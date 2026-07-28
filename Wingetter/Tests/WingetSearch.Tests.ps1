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

    It 'Uses exact show lookup for package IDs' {
        $results = InModuleScope Wingetter {
            Mock Get-WingetConfiguredSources { return @('winget') }
            Mock Find-WingetPackagesFromModule { return $null }
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
