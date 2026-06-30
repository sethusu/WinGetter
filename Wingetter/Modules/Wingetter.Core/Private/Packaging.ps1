function Invoke-IntuneWinPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VersionDirectory,

        [Parameter(Mandatory)]
        [string]$InstallerFileName,

        [Parameter(Mandatory)]
        [string]$InstallerBaseName,

        [scriptblock]$ProgressCallback
    )

    $intunewinCmd = Get-Command intunewinapputil -ErrorAction SilentlyContinue
    if (-not $intunewinCmd) {
        throw 'intunewinapputil not found. Install Microsoft Win32 Content Prep Tool and ensure it is in PATH.'
    }

    $outputDirectory = Split-Path $VersionDirectory -Parent
    $intunewinFile = Join-Path $outputDirectory "$InstallerBaseName.intunewin"

    if (Test-Path $intunewinFile) {
        Remove-Item -Path $intunewinFile -Force
        Write-WingetterLog -Message 'Removed existing .intunewin file.' -Level Warning -ProgressCallback $ProgressCallback
    }

    Write-WingetterLog -Message "Running Content Prep Tool for $InstallerFileName..." -ProgressCallback $ProgressCallback

    if ($ProgressCallback) {
        & $ProgressCallback @{
            Step            = 'Package'
            StepNumber      = 11
            TotalSteps      = 11
            PercentComplete = 90
            Message         = 'Creating .intunewin package...'
            Level           = 'Info'
        }
    }

    & intunewinapputil -c $VersionDirectory -s $InstallerFileName -o $outputDirectory -q

    if ($LASTEXITCODE -eq 0 -and (Test-Path $intunewinFile)) {
        $fileInfo = Get-Item $intunewinFile
        Write-WingetterLog -Message "Created $($fileInfo.Name) ($([math]::Round($fileInfo.Length / 1MB, 2)) MB)" -Level Success -ProgressCallback $ProgressCallback
        return $intunewinFile
    }

    throw 'Content Prep Tool failed or output file was not created.'
}
