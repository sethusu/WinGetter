# RunInSandbox Troubleshooting Guide for IntuneWin Packages

## Problem
Your IntuneWin packages fail to run when using RunInSandbox, even though you installed it with:
```powershell
Install-Module RunInSandbox -Scope CurrentUser
```

## Root Cause
**IntuneWin packages execute in the SYSTEM context**, not your user context. Modules installed with `-Scope CurrentUser` are stored in your user profile and are **not accessible to the SYSTEM account**.

## Quick Fix

### Option 1: Install for All Users (Recommended)
Run PowerShell as Administrator and install the module for all users:
```powershell
Install-Module RunInSandbox -Scope AllUsers -Force
```

Then optionally remove the CurrentUser installation:
```powershell
Uninstall-Module RunInSandbox -Scope CurrentUser
```

### Option 2: Import Module in Install Script
If you cannot install for AllUsers, ensure your install script explicitly imports the module:

```powershell
# At the beginning of your install script
$modulePath = (Get-Module -ListAvailable RunInSandbox | Select-Object -First 1).ModuleBase
if ($modulePath) {
    Import-Module "$modulePath\RunInSandbox.psd1" -ErrorAction Stop
} else {
    Write-Error "RunInSandbox module not found"
    Exit 1
}
```

## Verification Steps

### 1. Check Module Installation
```powershell
# Check where the module is installed
Get-Module -ListAvailable RunInSandbox | Select-Object ModuleBase, Version

# If ModuleBase contains your username, it's in CurrentUser scope
# If ModuleBase is in ProgramFiles, it's in AllUsers scope
```

### 2. Test as SYSTEM
Use psexec (from Sysinternals) to test as SYSTEM:
```powershell
# Download psexec if needed: https://learn.microsoft.com/sysinternals/downloads/psexec
psexec -s powershell.exe -Command "Import-Module RunInSandbox; Get-Command Invoke-Sandbox"
```

### 3. Check Intune Logs
Check the Intune Management Extension logs for errors:
```powershell
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\*.log" | 
    Select-String -Pattern "RunInSandbox|Error|Failed" -Context 2
```

## Common Issues and Solutions

### Issue: "Module not found" error
**Solution:** Install with `-Scope AllUsers` or import module with full path in your script.

### Issue: "Execution policy" error
**Solution:** Ensure execution policy allows script execution:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine
```

### Issue: Module imports but commands don't work
**Solution:** Check if you're using the correct command name:
```powershell
Get-Command -Module RunInSandbox
```

### Issue: Works in test but fails in Intune
**Solution:** 
1. Ensure module is installed for AllUsers
2. Check Intune Management Extension logs
3. Verify your install command includes module import
4. Test with psexec -s to simulate SYSTEM context

## Best Practices

1. **Always install modules for AllUsers** when they'll be used by IntuneWin packages
2. **Explicitly import modules** in your install scripts, even if installed for AllUsers
3. **Test as SYSTEM** before deploying to Intune
4. **Check logs** when troubleshooting deployment issues

## Using the Troubleshooting Script

Run the included troubleshooting script:
```powershell
# Run as Administrator for best results
.\Troubleshoot-RunInSandbox.ps1

# To automatically fix issues
.\Troubleshoot-RunInSandbox.ps1 -Fix
```

## Additional Resources

- [RunInSandbox Module Documentation](https://www.powershellgallery.com/packages/RunInSandbox)
- [Intune Management Extension Logs](https://learn.microsoft.com/mem/intune/apps/troubleshoot-app-install)
- [PowerShell Module Installation Scopes](https://learn.microsoft.com/powershell/module/powershellget/install-module)
