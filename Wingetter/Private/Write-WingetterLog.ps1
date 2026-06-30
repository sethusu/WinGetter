function Write-WingetterLog {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Step')]
        [string]$Level = 'Info',
        [scriptblock]$OnProgress
    )

    $event = @{
        Level   = $Level
        Message = $Message
        Time    = Get-Date
    }

    if ($OnProgress) {
        & $OnProgress $event
    }

    switch ($Level) {
        'Success' { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
        'Warning' { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
        'Error'   { Write-Host "[ERROR] $Message" -ForegroundColor Red }
        'Step'    { Write-Host "`n[$Message]" -ForegroundColor Cyan }
        default   { Write-Host $Message }
    }
}

function Write-WingetterProgress {
    param(
        [int]$Step,
        [int]$TotalSteps = 12,
        [string]$StepName,
        [int]$Percent = -1,
        [string]$Message = '',
        [ValidateSet('Running', 'Completed', 'Failed', 'Pending')]
        [string]$Status = 'Running',
        [scriptblock]$OnProgress
    )

    if ($Percent -lt 0) {
        $Percent = [math]::Min(100, [math]::Round(($Step / $TotalSteps) * 100))
    }

    $event = @{
        Type      = 'Progress'
        Step      = $Step
        TotalSteps = $TotalSteps
        StepName  = $StepName
        Percent   = $Percent
        Message   = $Message
        Status    = $Status
        Time      = Get-Date
    }

    if ($OnProgress) {
        & $OnProgress $event
    }
}

function Write-WingetterFailureLog {
    param(
        [string]$LogPath,
        [string]$Step,
        [object]$ErrorRecord
    )

    $entry = @"
================================================================================
Wingetter Packaging Failure
Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Step: $Step
Error: $($ErrorRecord.Exception.Message)
--------------------------------------------------------------------------------
$($ErrorRecord.ScriptStackTrace)
================================================================================

"@

    try {
        Add-Content -Path $LogPath -Value $entry -Encoding UTF8
    } catch {
        Write-Warning "Could not write failure log to $LogPath : $_"
    }
}
