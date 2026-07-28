@{
    ModuleVersion     = '2.1.2'
    GUID              = 'a3f8c2e1-9b4d-4f7a-8e6c-1d2b3a4c5e6f'
    Author            = 'Wingetter'
    CompanyName       = 'Wingetter'
    Copyright         = '(c) Wingetter. All rights reserved.'
    Description       = 'Create Intune Win32 packages from Winget applications.'
    PowerShellVersion = '5.1'
    RootModule        = 'Wingetter.psm1'
    FunctionsToExport = @(
        'Search-WingetPackages'
        'Get-WingetPackageDetails'
        'Invoke-WingetterPackaging'
        'Get-WingetterSettings'
        'Save-WingetterSettings'
        'Test-WingetterPrerequisites'
        'Install-WingetterContentPrepTool'
        'Resolve-PackageIcon'
        'Resolve-PackageIconCandidates'
        'Set-WingetterPackageIconFiles'
    )
    PrivateData       = @{
        PSData = @{
            Tags = @('Intune', 'Winget', 'Win32', 'MDM')
        }
    }
}
