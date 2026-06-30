BeforeAll {
    . (Join-Path $PSScriptRoot "..\WingetSearchParser.ps1")
}

Describe "Get-WingetPackagesFromSearchOutput" {
    It "returns no results when winget reports no package found" {
        $searchOutput = @(
            "No package found matching input criteria."
        )

        $result = Get-WingetPackagesFromSearchOutput -SearchOutput $searchOutput

        @($result).Count | Should -Be 0
    }

    It "parses standard table output rows" {
        $searchOutput = @(
            "Name                          Id                           Version     Match      Source",
            "-----------------------------------------------------------------------------------------",
            "Visual Studio Code            Microsoft.VisualStudioCode    1.95.3      Tag: vscode winget",
            "Visual Studio Code Insiders   Microsoft.VisualStudioCode.Insiders 1.96.0-insider Tag: vscode winget"
        )

        $result = Get-WingetPackagesFromSearchOutput -SearchOutput $searchOutput

        $result.Count | Should -Be 2
        $result[0].Name | Should -Be "Visual Studio Code"
        $result[0].Id | Should -Be "Microsoft.VisualStudioCode"
        $result[0].Version | Should -Be "1.95.3"
        $result[1].Id | Should -Be "Microsoft.VisualStudioCode.Insiders"
    }

    It "parses IDs that do not contain dots" {
        $searchOutput = @(
            "Name                          Id              Version      Source",
            "--------------------------------------------------------------------",
            "Apple Music                   XPDM27W10192Q0  Unknown      msstore"
        )

        $result = Get-WingetPackagesFromSearchOutput -SearchOutput $searchOutput

        $result.Count | Should -Be 1
        $result[0].Id | Should -Be "XPDM27W10192Q0"
        $result[0].Version | Should -Be "Unknown"
    }

    It "parses single-result found output" {
        $searchOutput = @(
            "Found PowerToys [Microsoft.PowerToys]",
            "Version: 0.91.0",
            "Publisher: Microsoft Corporation"
        )

        $result = Get-WingetPackagesFromSearchOutput -SearchOutput $searchOutput

        $result.Count | Should -Be 1
        $result[0].Name | Should -Be "PowerToys"
        $result[0].Id | Should -Be "Microsoft.PowerToys"
        $result[0].Version | Should -Be "0.91.0"
    }

    It "deduplicates duplicate IDs from mixed output noise" {
        $searchOutput = @(
            "Name                          Id                           Version      Source",
            "--------------------------------------------------------------------------------",
            "PowerToys                     Microsoft.PowerToys          0.91.0       winget",
            "PowerToys                     Microsoft.PowerToys          0.91.0       winget",
            "█  3.0 MB / 3.0 MB"
        )

        $result = Get-WingetPackagesFromSearchOutput -SearchOutput $searchOutput

        $result.Count | Should -Be 1
        $result[0].Id | Should -Be "Microsoft.PowerToys"
    }
}
