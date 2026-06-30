[CmdletBinding()]
param(
    [string]$TestPath = (Join-Path $PSScriptRoot 'Tests' 'WingetSearch.Tests.ps1')
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name Pester)) {
    Write-Host 'Installing Pester module...' -ForegroundColor Cyan
    Install-Module -Name Pester -MinimumVersion 5.0 -Force -Scope CurrentUser -Repository PSGallery
}

$result = Invoke-Pester -Path $TestPath -PassThru
if ($result.FailedCount -gt 0) {
    exit 1
}

exit 0
