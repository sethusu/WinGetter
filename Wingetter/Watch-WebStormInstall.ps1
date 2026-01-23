# Quick script to watch WebStorm installation logs
$logPath = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs"
$packageId = "JetBrains.WebStorm"
$detectionLog = Join-Path $logPath "$packageId-detection.log"
$mainLog = Join-Path $logPath "IntuneManagementExtension.log"

Write-Host "=== WebStorm Installation Monitor ===" -ForegroundColor Cyan
Write-Host "Package: $packageId" -ForegroundColor Gray
Write-Host "Press Ctrl+C to stop`n" -ForegroundColor Yellow

while ($true) {
    Clear-Host
    Write-Host "=== $(Get-Date -Format 'HH:mm:ss') - WebStorm Installation Status ===" -ForegroundColor Cyan
    Write-Host ""
    
    # Check detection log
    if (Test-Path $detectionLog) {
        Write-Host "✓ Detection log found!" -ForegroundColor Green
        Write-Host "`n--- Detection Log (last 25 lines) ---" -ForegroundColor Yellow
        Get-Content $detectionLog -Tail 25
        Write-Host ""
    } else {
        Write-Host "⏳ Detection log not created yet..." -ForegroundColor Yellow
        Write-Host ""
    }
    
    # Check main log for WebStorm entries
    Write-Host "--- Main Log (WebStorm/JetBrains entries) ---" -ForegroundColor Yellow
    if (Test-Path $mainLog) {
        $webstormEntries = Get-Content $mainLog | Select-String -Pattern "WebStorm|JetBrains\.WebStorm" -Context 0,0 | Select-Object -Last 10
        if ($webstormEntries) {
            $webstormEntries | ForEach-Object { Write-Host $_ }
        } else {
            Write-Host "No WebStorm entries in main log yet..." -ForegroundColor Gray
        }
    }
    
    Write-Host "`n--- Recent Log Files (last 5 minutes) ---" -ForegroundColor Yellow
    Get-ChildItem -Path $logPath -Filter "*.log" | 
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-5) } |
        Sort-Object LastWriteTime -Descending | 
        Select-Object -First 5 Name, @{Name="Modified";Expression={$_.LastWriteTime.ToString("HH:mm:ss")}} | 
        Format-Table -AutoSize
    
    Start-Sleep -Seconds 3
}
