<#
.SYNOPSIS
    Troubleshooting script for RunInSandbox issues with IntuneWin packages.
.DESCRIPTION
    This script helps diagnose and fix issues with RunInSandbox when testing IntuneWin packages.
    IntuneWin packages run as SYSTEM, which cannot access CurrentUser-scoped modules.
.NOTES
    Run this script as Administrator to check and fix module installation issues.
#>

[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$TestAsSystem
)

Write-Host "RunInSandbox Troubleshooting Script" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host ""

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "WARNING: Not running as Administrator. Some checks may fail." -ForegroundColor Yellow
    Write-Host "For best results, run this script as Administrator." -ForegroundColor Yellow
    Write-Host ""
}

# Step 1: Check if RunInSandbox module is installed
Write-Host "[1] Checking RunInSandbox module installation..." -ForegroundColor Cyan
$module = Get-Module -ListAvailable -Name RunInSandbox
if ($module) {
    Write-Host "  ✓ RunInSandbox module found" -ForegroundColor Green
    Write-Host "    Location: $($module.ModuleBase)" -ForegroundColor Gray
    Write-Host "    Version: $($module.Version)" -ForegroundColor Gray
    Write-Host "    Scope: $($module.PrivateData.PSData.Tags -join ', ')" -ForegroundColor Gray
    
    # Check module path
    $modulePath = $module.ModuleBase
    if ($modulePath -like "*$env:USERPROFILE*" -or $modulePath -like "*Documents\WindowsPowerShell*") {
        Write-Host "  ⚠ Module is installed in CurrentUser scope" -ForegroundColor Yellow
        Write-Host "    This means SYSTEM account cannot access it!" -ForegroundColor Yellow
        $needsSystemScope = $true
    } else {
        Write-Host "  ✓ Module appears to be in system scope" -ForegroundColor Green
        $needsSystemScope = $false
    }
} else {
    Write-Host "  ✗ RunInSandbox module not found" -ForegroundColor Red
    $needsSystemScope = $null
}

Write-Host ""

# Step 2: Check module paths
Write-Host "[2] Checking PowerShell module paths..." -ForegroundColor Cyan
$modulePaths = $env:PSModulePath -split ';'
Write-Host "  Module search paths:" -ForegroundColor Gray
foreach ($path in $modulePaths) {
    $exists = Test-Path $path
    $status = if ($exists) { "✓" } else { "✗" }
    $color = if ($exists) { "Green" } else { "Red" }
    Write-Host "    $status $path" -ForegroundColor $color
}

# Check if RunInSandbox exists in system paths
$systemModulePaths = $modulePaths | Where-Object { $_ -notlike "*$env:USERPROFILE*" -and $_ -notlike "*Documents\WindowsPowerShell*" }
$foundInSystemPath = $false
foreach ($path in $systemModulePaths) {
    $testPath = Join-Path $path "RunInSandbox"
    if (Test-Path $testPath) {
        Write-Host "  ✓ Found RunInSandbox in system path: $testPath" -ForegroundColor Green
        $foundInSystemPath = $true
    }
}

if (-not $foundInSystemPath -and $module) {
    Write-Host "  ⚠ RunInSandbox not found in system module paths" -ForegroundColor Yellow
}

Write-Host ""

# Step 3: Check execution policy
Write-Host "[3] Checking PowerShell execution policy..." -ForegroundColor Cyan
$execPolicy = Get-ExecutionPolicy
$execPolicyList = Get-ExecutionPolicy -List
Write-Host "  Current execution policy: $execPolicy" -ForegroundColor Gray
Write-Host "  Execution policy list:" -ForegroundColor Gray
foreach ($scope in $execPolicyList) {
    Write-Host "    $($scope.Scope): $($scope.ExecutionPolicy)" -ForegroundColor Gray
}

if ($execPolicy -eq "Restricted") {
    Write-Host "  ⚠ Execution policy is Restricted - scripts may not run" -ForegroundColor Yellow
}

Write-Host ""

# Step 4: Test module import
Write-Host "[4] Testing RunInSandbox module import..." -ForegroundColor Cyan
try {
    Import-Module RunInSandbox -Force -ErrorAction Stop
    Write-Host "  ✓ Module imported successfully" -ForegroundColor Green
    
    # Check available commands
    $commands = Get-Command -Module RunInSandbox
    Write-Host "  Available commands:" -ForegroundColor Gray
    foreach ($cmd in $commands) {
        Write-Host "    - $($cmd.Name)" -ForegroundColor Gray
    }
} catch {
    Write-Host "  ✗ Failed to import module: $_" -ForegroundColor Red
}

Write-Host ""

# Step 5: Check if module works
Write-Host "[5] Testing RunInSandbox functionality..." -ForegroundColor Cyan
try {
    $testResult = Get-Command Invoke-Sandbox -ErrorAction SilentlyContinue
    if ($testResult) {
        Write-Host "  ✓ Invoke-Sandbox command is available" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ Invoke-Sandbox command not found" -ForegroundColor Yellow
        Write-Host "    Available commands:" -ForegroundColor Gray
        Get-Command -Module RunInSandbox | ForEach-Object {
            Write-Host "      - $($_.Name)" -ForegroundColor Gray
        }
    }
} catch {
    Write-Host "  ✗ Error checking commands: $_" -ForegroundColor Red
}

Write-Host ""

# Step 6: Simulate SYSTEM context check
Write-Host "[6] Checking SYSTEM context access..." -ForegroundColor Cyan
if ($isAdmin) {
    Write-Host "  Testing module access as SYSTEM..." -ForegroundColor Gray
    
    # Create a test script that SYSTEM would run
    $testScript = @"
`$module = Get-Module -ListAvailable -Name RunInSandbox
if (`$module) {
    Write-Host "Module found: `$(`$module.ModuleBase)"
    try {
        Import-Module RunInSandbox -Force
        Write-Host "Module imported successfully"
        Exit 0
    } catch {
        Write-Host "Failed to import: `$_"
        Exit 1
    }
} else {
    Write-Host "Module not found"
    Exit 1
}
"@
    
    $testScriptPath = Join-Path $env:TEMP "Test-RunInSandbox-System.ps1"
    $testScript | Set-Content -Path $testScriptPath -Encoding UTF8
    
    try {
        # Run as SYSTEM using psexec or scheduled task method
        # For simplicity, we'll use Start-Process with SYSTEM token if available
        Write-Host "  Note: To fully test SYSTEM context, you may need to:" -ForegroundColor Yellow
        Write-Host "    1. Use psexec -s powershell.exe" -ForegroundColor Yellow
        Write-Host "    2. Create a scheduled task running as SYSTEM" -ForegroundColor Yellow
        Write-Host "    3. Test the actual IntuneWin package deployment" -ForegroundColor Yellow
    } catch {
        Write-Host "  ⚠ Could not test SYSTEM context directly" -ForegroundColor Yellow
    }
    
    if (Test-Path $testScriptPath) {
        Remove-Item $testScriptPath -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "  ⚠ Cannot test SYSTEM context without Administrator privileges" -ForegroundColor Yellow
}

Write-Host ""

# Step 7: Recommendations
Write-Host "[7] Recommendations" -ForegroundColor Cyan
Write-Host ""

if ($needsSystemScope -eq $true) {
    Write-Host "  ISSUE FOUND: RunInSandbox is installed in CurrentUser scope" -ForegroundColor Red
    Write-Host ""
    Write-Host "  SOLUTION: Install the module for all users (requires Administrator):" -ForegroundColor Yellow
    Write-Host "    Install-Module RunInSandbox -Scope AllUsers -Force" -ForegroundColor White
    Write-Host ""
    
    if ($Fix -and $isAdmin) {
        Write-Host "  Attempting to fix by installing for AllUsers..." -ForegroundColor Cyan
        try {
            Install-Module RunInSandbox -Scope AllUsers -Force -AllowClobber
            Write-Host "  ✓ Module installed for AllUsers" -ForegroundColor Green
            Write-Host "  You may want to remove the CurrentUser installation:" -ForegroundColor Yellow
            Write-Host "    Uninstall-Module RunInSandbox -Scope CurrentUser" -ForegroundColor White
        } catch {
            Write-Host "  ✗ Failed to install for AllUsers: $_" -ForegroundColor Red
        }
    } elseif ($Fix) {
        Write-Host "  ⚠ Cannot fix without Administrator privileges" -ForegroundColor Yellow
    }
} elseif ($needsSystemScope -eq $null) {
    Write-Host "  ISSUE FOUND: RunInSandbox module is not installed" -ForegroundColor Red
    Write-Host ""
    Write-Host "  SOLUTION: Install the module:" -ForegroundColor Yellow
    if ($isAdmin) {
        Write-Host "    Install-Module RunInSandbox -Scope AllUsers -Force" -ForegroundColor White
    } else {
        Write-Host "    Install-Module RunInSandbox -Scope CurrentUser -Force" -ForegroundColor White
        Write-Host "    (Note: For IntuneWin testing, you'll need AllUsers scope)" -ForegroundColor Yellow
    }
    
    if ($Fix) {
        Write-Host ""
        Write-Host "  Attempting to install module..." -ForegroundColor Cyan
        try {
            if ($isAdmin) {
                Install-Module RunInSandbox -Scope AllUsers -Force -AllowClobber
                Write-Host "  ✓ Module installed for AllUsers" -ForegroundColor Green
            } else {
                Install-Module RunInSandbox -Scope CurrentUser -Force -AllowClobber
                Write-Host "  ✓ Module installed for CurrentUser" -ForegroundColor Green
                Write-Host "  ⚠ WARNING: IntuneWin packages run as SYSTEM and may not access this!" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  ✗ Failed to install module: $_" -ForegroundColor Red
        }
    }
} else {
    Write-Host "  ✓ Module appears to be correctly installed" -ForegroundColor Green
    Write-Host ""
    Write-Host "  If IntuneWin packages still fail, check:" -ForegroundColor Yellow
    Write-Host "    1. Execution policy allows script execution" -ForegroundColor Gray
    Write-Host "    2. Install command includes: Import-Module RunInSandbox" -ForegroundColor Gray
    Write-Host "    3. Check Intune Management Extension logs:" -ForegroundColor Gray
    Write-Host "       C:\ProgramData\Microsoft\IntuneManagementExtension\Logs" -ForegroundColor Gray
}

Write-Host ""

# Step 8: Additional troubleshooting tips
Write-Host "[8] Additional Troubleshooting Tips" -ForegroundColor Cyan
Write-Host ""
Write-Host "  If your IntuneWin install command uses RunInSandbox, ensure:" -ForegroundColor Yellow
Write-Host "    1. The install script imports the module:" -ForegroundColor Gray
Write-Host "       Import-Module RunInSandbox -ErrorAction Stop" -ForegroundColor White
Write-Host ""
Write-Host "    2. Or use full path to module:" -ForegroundColor Gray
Write-Host "       `$modulePath = (Get-Module -ListAvailable RunInSandbox | Select-Object -First 1).ModuleBase" -ForegroundColor White
Write-Host "       Import-Module `"`$modulePath\RunInSandbox.psd1`"" -ForegroundColor White
Write-Host ""
Write-Host "    3. Check Intune Management Extension logs for errors:" -ForegroundColor Gray
Write-Host "       Get-Content `"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\*.log`" | Select-String -Pattern `"RunInSandbox|Error|Failed`"" -ForegroundColor White
Write-Host ""
Write-Host "    4. Test your install command manually as SYSTEM:" -ForegroundColor Gray
Write-Host "       psexec -s powershell.exe -Command `"Your-Install-Command`"" -ForegroundColor White
Write-Host ""

# Summary
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "Troubleshooting Complete" -ForegroundColor Cyan
Write-Host ""
if ($needsSystemScope -and -not $Fix) {
    Write-Host "To automatically fix the issue, run:" -ForegroundColor Yellow
    Write-Host "  .\Troubleshoot-RunInSandbox.ps1 -Fix" -ForegroundColor White
    Write-Host "(Requires Administrator privileges)" -ForegroundColor Gray
}
