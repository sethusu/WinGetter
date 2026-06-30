function Write-WingetterLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Step')]
        [string]$Level = 'Info',

        [scriptblock]$ProgressCallback,

        [string]$StepName,

        [int]$StepNumber = 0,

        [int]$TotalSteps = 11,

        [int]$PercentComplete = -1
    )

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $formatted = "[$timestamp] $Message"

    switch ($Level) {
        'Success' { $color = 'Green' }
        'Warning' { $color = 'Yellow' }
        'Error'   { $color = 'Red' }
        'Step'    { $color = 'Cyan' }
        default   { $color = 'Gray' }
    }

    if ($Level -eq 'Step') {
        Write-Host "`n[$StepName]" -ForegroundColor $color
    }
    elseif ($Level -eq 'Success') {
        Write-Host "[SUCCESS] $Message" -ForegroundColor $color
    }
    elseif ($Level -eq 'Error') {
        Write-Host "[ERROR] $Message" -ForegroundColor $color
    }
    else {
        Write-Host $formatted -ForegroundColor $color
    }

    if ($ProgressCallback) {
        & $ProgressCallback @{
            Step             = $StepName
            StepNumber       = $StepNumber
            TotalSteps       = $TotalSteps
            PercentComplete  = $PercentComplete
            Message          = $Message
            Level            = $Level
            Timestamp        = $timestamp
        }
    }
}

function Write-WingetterFileLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogPath,

        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    $directory = Split-Path $LogPath -Parent
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}
