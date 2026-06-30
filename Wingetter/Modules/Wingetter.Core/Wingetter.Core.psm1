$privateFunctions = @(
    (Join-Path $PSScriptRoot 'Private\Write-WingetterLog.ps1')
    (Join-Path $PSScriptRoot 'Private\Search.ps1')
    (Join-Path $PSScriptRoot 'Private\Download.ps1')
    (Join-Path $PSScriptRoot 'Private\Logo.ps1')
    (Join-Path $PSScriptRoot 'Private\Scripts.ps1')
    (Join-Path $PSScriptRoot 'Private\Metadata.ps1')
    (Join-Path $PSScriptRoot 'Private\Packaging.ps1')
)

foreach ($file in $privateFunctions) {
    if (Test-Path $file) {
        . $file
    }
}

$publicFunctions = @(
    (Join-Path $PSScriptRoot 'Public\Invoke-WingetterPackage.ps1')
)

foreach ($file in $publicFunctions) {
    if (Test-Path $file) {
        . $file
    }
}

Export-ModuleMember -Function @(
    'Invoke-WingetterPackage'
    'Search-WingetPackage'
    'Get-WingetAppDetails'
    'Parse-WingetSearchResults'
    'Test-WingetterPrerequisites'
)
