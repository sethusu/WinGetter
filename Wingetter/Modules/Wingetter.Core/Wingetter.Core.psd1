@{
    RootModule        = 'Wingetter.Core.psm1'
    ModuleVersion     = '2.0.0'
    GUID              = 'a3f8c2e1-9b4d-4f6a-8c7e-1d2e3f4a5b6c'
    Author            = 'Wingetter'
    Description       = 'Core packaging engine for Wingetter Intune Win32 packages from Winget.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Invoke-WingetterPackage'
        'Search-WingetPackage'
        'Get-WingetAppDetails'
        'Parse-WingetSearchResults'
        'Test-WingetterPrerequisites'
    )
    PrivateData       = @{
        PSData = @{
            Tags = @('Intune', 'Winget', 'Win32', 'Packaging')
        }
    }
}
