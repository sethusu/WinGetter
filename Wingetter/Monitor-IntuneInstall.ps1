# Monitor Intune installation logs for a specific package
param(
    [Parameter(Mandatory=$true)]
    [string]$PackageId,
    
    [Parameter(Mandatory=$false)]
    [int]$RefreshInterval = 2
)

$logPath = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs"
$detectionLog = Join-Path $logPath "$PackageId-detection.log"
$mainLog = Join-Path $logPath "IntuneManagementExtension.log"

Write-Host "Monitoring Intune installation for: $PackageId" -ForegroundColor Cyan
Write-Host "Log directory: $logPath" -ForegroundColor Gray
Write-Host "Press Ctrl+C to stop monitoring`n" -ForegroundColor Yellow

$lastDetectionSize = 0
$lastMainLogSize = 0

while ($true) {
    Clear-Host
    Write-Host "=== Intune Installation Monitor - $PackageId ===" -ForegroundColor Cyan
    Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n" -ForegroundColor Gray
    
    # Check for detection log
    if (Test-Path $detectionLog) {
        Write-Host "=== Detection Log ===" -ForegroundColor Green
        $currentSize = (Get-Item $detectionLog).Length
        if ($currentSize -gt $lastDetectionSize) {
            Get-Content $detectionLog -Tail 30 | Write-Host
            $lastDetectionSize = $currentSize
        } else {
            Get-Content $detectionLog -Tail 10 | Write-Host
        }
        Write-Host ""
    } else {
        Write-Host "Detection log not found yet: $detectionLog" -ForegroundColor Yellow
        Write-Host ""
    }
    
    # Check main log for package-related entries
    if (Test-Path $mainLog) {
        Write-Host "=== Recent Intune Management Extension Log (filtered for $PackageId) ===" -ForegroundColor Green
        $currentMainSize = (Get-Item $mainLog).Length
        if ($currentMainSize -gt $lastMainLogSize) {
            Get-Content $mainLog | Select-String -Pattern $PackageId -Context 2,2 | Select-Object -Last 15 | Write-Host
            $lastMainLogSize = $currentMainSize
        } else {
            Get-Content $mainLog | Select-String -Pattern $PackageId -Context 1,1 | Select-Object -Last 5 | Write-Host
        }
    }
    
    # Check for any new log files
    Write-Host "`n=== All Log Files (sorted by last modified) ===" -ForegroundColor Green
    Get-ChildItem -Path $logPath -Filter "*.log" | 
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) } |
        Sort-Object LastWriteTime -Descending | 
        Select-Object -First 5 Name, @{Name="Size";Expression={"{0:N0} KB" -f ($_.Length/1KB)}}, LastWriteTime | 
        Format-Table -AutoSize
    
    Start-Sleep -Seconds $RefreshInterval
}
