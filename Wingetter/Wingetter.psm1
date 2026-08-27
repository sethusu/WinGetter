$privateScripts = @(
    'Write-WingetterLog.ps1'
    'Settings.ps1'
    'Winget.ps1'
    'IconResolution.ps1'
    'SilentInstall.ps1'
    'Assets.ps1'
    'Scripts.ps1'
    'Packaging.ps1'
    'Sandbox.ps1'
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
    'Get-WingetterDefaultBaseOutputPath'
    'Get-WingetterBaseOutputPath'
    'Get-WingetterAppOutputPath'
    'Get-WingetterSettings'
    'Save-WingetterSettings'
    'Test-WingetterPrerequisites'
    'Install-WingetterContentPrepTool'
    'Resolve-PackageIcon'
    'Resolve-PackageIconCandidates'
    'Set-WingetterPackageIconFiles'
    'Test-WingetterWindowsSandbox'
    'Install-WingetterWindowsSandbox'
    'Resolve-WingetterPackageVersionDirectory'
    'Test-WingetterSandboxPackage'
    'Get-WingetterSandboxPackageInfo'
    'Start-WingetterSandboxSession'
    'Set-WingetterSandboxCommand'
    'Get-WingetterSandboxStatus'
    'Get-WingetterSandboxHeartbeat'
    'Get-WingetterSandboxGuestLog'
    'Write-WingetterSandboxTestReport'
    'Get-WingetterSandboxTestReportPath'
    'Get-WingetterSilentInstallPlan'
    'Get-WingetterSilentSwitchCandidates'
    'Get-WingetterSilentInstallCommandText'
    'Get-WingetterPackageSilentInstallInfo'
    'Update-WingetterPackagedSilentInstall'
    'Test-WingetterInstallExitSuccess'
    'Split-WingetterInstallCommand'
    'Resolve-WingetterSandboxStepStatus'
    'Stop-WingetterSandboxSession'
    'Test-WingetterSandboxConfirmations'
    'Complete-WingetterSandboxTest'
    'Get-WingetterPackageValidation'
)
