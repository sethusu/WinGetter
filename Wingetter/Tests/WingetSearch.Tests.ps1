BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' 'Modules'
    Import-Module (Join-Path $moduleRoot 'WingetSearch.psm1') -Force

    $fixtureRoot = Join-Path $PSScriptRoot 'Fixtures'
    function Get-Fixture {
        param([string]$Name)
        Get-Content -Path (Join-Path $fixtureRoot $Name) -Raw
    }
}

Describe 'Normalize-WingetPackageId' {
    It 'Removes whitespace around dots in package IDs' {
        Normalize-WingetPackageId -Id 'Valve. Steam' | Should -Be 'Valve.Steam'
        Normalize-WingetPackageId -Id 'Microsoft. WindowsTerminal' | Should -Be 'Microsoft.WindowsTerminal'
    }
}

Describe 'Test-WingetPackageId' {
    It 'Recognizes publisher.package identifiers' {
        Test-WingetPackageId -Query 'Google.Chrome' | Should -Be $true
        Test-WingetPackageId -Query 'JetBrains.WebStorm' | Should -Be $true
        Test-WingetPackageId -Query '7zip.7zip' | Should -Be $true
    }

    It 'Rejects free-form search terms' {
        Test-WingetPackageId -Query 'chrome' | Should -Be $false
        Test-WingetPackageId -Query 'web storm' | Should -Be $false
        Test-WingetPackageId -Query '' | Should -Be $false
    }
}

Describe 'ConvertFrom-WingetShowOutput' {
    It 'Parses a single package from winget show output' {
        $package = ConvertFrom-WingetShowOutput -ShowOutput (Get-Fixture 'show-single-package.txt')

        $package.Name | Should -Be 'Google Chrome'
        $package.Id | Should -Be 'Google.Chrome'
        $package.Version | Should -Be '131.0.6778.86'
    }

    It 'Returns null when no package is found' {
        ConvertFrom-WingetShowOutput -ShowOutput 'No package found matching input criteria.' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-WingetSearchOutput' {
    It 'Parses multiple search results' {
        $packages = ConvertFrom-WingetSearchOutput -SearchOutput (Get-Fixture 'search-multiple-results.txt')

        $packages.Count | Should -Be 3
        $packages[0].Id | Should -Be 'Google.Chrome'
        $packages[0].Version | Should -Be '131.0.6778.86'
        $packages[1].Id | Should -Be 'Eloston.UngoogledChromium'
    }

    It 'Flags truncated package IDs' {
        $packages = ConvertFrom-WingetSearchOutput -SearchOutput (Get-Fixture 'search-truncated-ids.txt')

        $packages.Count | Should -Be 3
        ($packages | Where-Object { $_.TruncatedId }).Count | Should -Be 2
        $packages[0].TruncatedId | Should -Be $false
        $packages[0].Id | Should -Be 'Microsoft.WindowsTerminal'
    }

    It 'Parses MS Store packages without dotted IDs' {
        $packages = ConvertFrom-WingetSearchOutput -SearchOutput (Get-Fixture 'search-msstore-mixed.txt')

        $packages.Count | Should -Be 2
        $packages[0].Id | Should -Be 'XP89DCGQ3K6VLD'
        $packages[0].Version | Should -Be 'Unknown'
        $packages[1].Id | Should -Be 'Microsoft.PowerToys'
    }

    It 'Returns an empty array when no packages are found' {
        $packages = ConvertFrom-WingetSearchOutput -SearchOutput (Get-Fixture 'search-no-results.txt')
        $packages | Should -Be @()
    }

    It 'Parses array output from winget redirection' {
        $lines = (Get-Fixture 'search-multiple-results.txt') -split "`r?`n"
        $packages = ConvertFrom-WingetSearchOutput -SearchOutput $lines

        $packages.Count | Should -Be 3
    }

    It 'Parses single Found line format' {
        $output = @(
            'Found Google Chrome [Google.Chrome]'
            'Version: 131.0.6778.86'
        )

        $packages = ConvertFrom-WingetSearchOutput -SearchOutput $output
        $packages.Count | Should -Be 1
        $packages[0].Id | Should -Be 'Google.Chrome'
    }
}

Describe 'Sort-WingetPackageMatches' {
    It 'Prioritizes exact package ID matches' {
        $packages = @(
            [PSCustomObject]@{ Name = 'Chromium'; Id = 'Eloston.UngoogledChromium'; Version = '1.0'; Source = 'winget'; TruncatedId = $false }
            [PSCustomObject]@{ Name = 'Google Chrome'; Id = 'Google.Chrome'; Version = '2.0'; Source = 'winget'; TruncatedId = $false }
        )

        $sorted = Sort-WingetPackageMatches -Query 'Google.Chrome' -Packages $packages
        $sorted[0].Id | Should -Be 'Google.Chrome'
    }

    It 'Prefers winget source and non-truncated IDs' {
        $packages = @(
            [PSCustomObject]@{ Name = 'PowerToys'; Id = 'XP89DCGQ3K6VLD'; Version = 'Unknown'; Source = 'msstore'; TruncatedId = $false }
            [PSCustomObject]@{ Name = 'PowerToys (Preview)'; Id = 'Microsoft.PowerToys'; Version = '0.87.0'; Source = 'winget'; TruncatedId = $false }
        )

        $sorted = Sort-WingetPackageMatches -Query 'powertoys' -Packages $packages
        $sorted[0].Id | Should -Be 'Microsoft.PowerToys'
    }
}

Describe 'Resolve-WingetTruncatedPackage' {
    It 'Resolves truncated IDs using winget show mock' {
        $truncated = [PSCustomObject]@{
            Name        = 'Windows Terminal Preview'
            Id          = 'Microsoft.WindowsTerminal…'
            Version     = '1.19.3172.0'
            Source      = 'winget'
            TruncatedId = $true
        }

        $mockShow = {
            param($PackageId, $Exact)
            return [PSCustomObject]@{
                Name    = 'Windows Terminal Preview'
                Id      = 'Microsoft.WindowsTerminal.Preview'
                Version = '1.19.3172.0'
            }
        }

        $resolved = Resolve-WingetTruncatedPackage -Package $truncated -InvokeWingetShow $mockShow
        $resolved.Id | Should -Be 'Microsoft.WindowsTerminal.Preview'
        $resolved.TruncatedId | Should -Be $false
    }
}

Describe 'Search-WingetPackages' {
    It 'Uses exact show lookup for package IDs' {
        InModuleScope WingetSearch {
            Mock Invoke-WingetShowCommand {
                param($PackageId, $Version, $Exact)
                if ($Exact -and $PackageId -eq 'Google.Chrome') {
                    return [PSCustomObject]@{
                        Name    = 'Google Chrome'
                        Id      = 'Google.Chrome'
                        Version = '131.0.6778.86'
                    }
                }
                return $null
            }

            Mock Find-WingetPackagesFromModule { return $null }
            Mock Invoke-WingetSearchCommand { return 'unused' }

            $results = Search-WingetPackages -Query 'Google.Chrome'
            $results.Count | Should -Be 1
            $results[0].Id | Should -Be 'Google.Chrome'
        }
    }

    It 'Falls back to CLI search parsing when structured lookup is unavailable' {
        $fixtureContent = Get-Fixture 'search-multiple-results.txt'

        InModuleScope WingetSearch {
            param($SearchFixture)
            Mock Invoke-WingetShowCommand { return $null }
            Mock Find-WingetPackagesFromModule { return $null }
            Mock Invoke-WingetSearchCommand { return $SearchFixture }

            $results = Search-WingetPackages -Query 'chrome'
            $results.Count | Should -Be 3
            $results[0].Name | Should -Be 'Google Chrome'
        } -ArgumentList $fixtureContent
    }
}

Describe 'Select-WingetPackage' {
    It 'Auto-selects a single parsed package' {
        $output = @(
            'Found Google Chrome [Google.Chrome]'
            'Version: 131.0.6778.86'
        )

        $selected = Select-WingetPackage -SearchOutput $output -NoPrompt
        $selected.Id | Should -Be 'Google.Chrome'
    }

    It 'Returns top match without prompt when requested' {
        $packages = ConvertFrom-WingetSearchOutput -SearchOutput (Get-Fixture 'search-multiple-results.txt')
        $selected = Select-WingetPackage -SearchOutput $packages -Query 'Google.Chrome' -NoPrompt -DefaultSelection 1

        $selected.Id | Should -Be 'Google.Chrome'
    }
}
