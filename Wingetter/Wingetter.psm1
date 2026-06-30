$privateScripts = @(
    'Write-WingetterLog.ps1'
    'Settings.ps1'
    'Winget.ps1'
    'Assets.ps1'
    'Scripts.ps1'
    'Packaging.ps1'
)

$privateRoot = Join-Path $PSScriptRoot 'Private'
foreach ($scriptName in $privateScripts) {
    $scriptPath = Join-Path $privateRoot $scriptName
    if (Test-Path $scriptPath) {
        . $scriptPath
    }
}

Export-ModuleMember -Function @(
    'Search-WingetPackages'
    'Get-WingetPackageDetails'
    'Invoke-WingetterPackaging'
    'Get-WingetterSettings'
    'Save-WingetterSettings'
    'Test-WingetterPrerequisites'
)
