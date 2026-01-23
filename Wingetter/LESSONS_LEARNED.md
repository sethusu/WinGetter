# Lessons Learned - WebStorm Package Experience

This document captures key learnings from creating and troubleshooting the JetBrains.WebStorm IntuneWin package.

## Problem: Detection Script Failure

### Initial Issue
- WebStorm installed successfully via Company Portal
- Detection script failed with exit code 1
- Intune reported installation as failed/not detected

### Root Causes Identified

#### 1. Version Format Mismatch
**Problem**: JetBrains products use different version formats:
- `DisplayVersion` in registry: Build number format (e.g., `253.29346.242`)
- Marketing version: Standard format (e.g., `2025.3.1.1`)
- Marketing version is stored in `DisplayName` (e.g., "WebStorm 2025.3.1.1")

**Solution**: Extract version from `DisplayName` using regex pattern `(\d+\.\d+\.\d+\.\d+)` when detected for JetBrains products.

#### 2. Hashtable Property Access
**Problem**: PowerShell hashtables created with `@{ }` syntax require bracket notation for property access:
- ❌ `$hash.DisplayVersion` - Returns empty/null
- ✅ `$hash['DisplayVersion']` - Returns correct value

**Solution**: Use bracket notation `$hash['Property']` when accessing hashtable properties in detection scripts.

#### 3. Version Sorting Logic
**Problem**: When sorting hashtable arrays, the sorted objects may lose properties or require different access methods.

**Solution**: 
- For single installations: Direct access (no sorting needed)
- For multiple installations: Use bracket notation after sorting
- Add fallback logic for error cases

## Solutions Implemented

### 1. Version Extraction Logic
```powershell
# Extract version from DisplayName for JetBrains products
$extractedVersion = $null
if ($key.DisplayName -match "(\d+\.\d+\.\d+\.\d+)") {
    $extractedVersion = $matches[1]
}
$versionToUse = if ($extractedVersion) { $extractedVersion } else { $key.DisplayVersion }
```

### 2. Hashtable Access Pattern
```powershell
# Correct way to access hashtable properties
$installedVersion = $highestVersion['DisplayVersion']
$displayName = $highestVersion['DisplayName']
```

### 3. Single vs Multiple Version Handling
```powershell
if ($allMatchingVersions.Count -eq 1) {
    # Direct access - more efficient
    $highestVersion = $allMatchingVersions[0]
    $installedVersion = $highestVersion['DisplayVersion']
} else {
    # Sort and access
    $sortedVersions = $allMatchingVersions | Sort-Object -Property @{...}
    $highestVersion = $sortedVersions[0]
    $installedVersion = $highestVersion['DisplayVersion']
}
```

## Best Practices Established

### 1. Testing Detection Scripts
Always test detection scripts manually before deploying:
```powershell
powershell -ExecutionPolicy Bypass -File detection.ps1
echo "Exit Code: $LASTEXITCODE"
```

### 2. Log Analysis
Check detection logs for troubleshooting:
- Location: `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\{PackageId}-detection.log`
- Look for version extraction messages
- Verify exit codes (0 = success, 1 = failure)

### 3. Registry Inspection
Before creating packages, inspect registry entries:
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
    Where-Object { $_.DisplayName -like "*AppName*" } | 
    Select-Object DisplayName, DisplayVersion, PSChildName
```

### 4. Re-packaging After Fixes
When fixing detection scripts:
1. Update the local `detection.ps1` file
2. Re-run `intunewinapputil` to regenerate `.intunewin` package
3. Upload new package to Intune
4. Verify detection works on next sync cycle

## JetBrains-Specific Considerations

### Logo Download
- JetBrains products: Automatically download from CDN
- URLs follow pattern: `https://resources.jetbrains.com/storage/products/{product}/img/meta/{product}_logo_300x300.png`
- Fallback to alternative URLs if primary fails

### Version Patterns
- Marketing version in DisplayName: `"ProductName YYYY.M.M.M"` (e.g., "WebStorm 2025.3.1.1")
- Build number in DisplayVersion: `"XXX.XXXXX.XXX"` (e.g., "253.29346.242")
- Always extract from DisplayName for JetBrains products

## Monitoring and Troubleshooting

### Key Log Messages to Look For
- ✅ `"Extracted version from DisplayName: X.X.X.X"` - Version extraction working
- ✅ `"Found version: X.X.X.X"` - Version found successfully
- ✅ `"exiting with code 0"` - Detection passed
- ❌ `"exiting with code 1"` - Detection failed
- ❌ `"Highest version found:  (from )"` - Version extraction failed (empty)

### Common Issues and Fixes

| Issue | Symptom | Fix |
|-------|---------|-----|
| Version not extracted | "Highest version found:  (from )" | Check regex pattern matches DisplayName format |
| Hashtable access fails | Empty version after sorting | Use bracket notation `$hash['Property']` |
| Build number vs marketing version | Version comparison fails | Extract from DisplayName for JetBrains products |
| Multiple installations | Wrong version selected | Ensure sorting logic uses correct property access |

## Future Enhancements

### Potential Improvements
1. **Generic Version Extraction**: Apply DisplayName extraction to other products that use build numbers
2. **Publisher-Specific Logic**: Add detection logic for other publishers (Microsoft, Google, etc.)
3. **Version Normalization**: Create function to normalize different version formats
4. **Enhanced Logging**: Add more detailed logging for version extraction process
5. **Automatic Testing**: Add script to test detection scripts before packaging

### Extensibility
The current implementation is designed to be extensible:
- Logo download function can be extended for other publishers
- Version extraction logic can be made more generic
- Detection script template can be customized per publisher/product type

## References

- **Detection Script Location**: `{PackageDirectory}\detection.ps1`
- **Intune Logs**: `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\`
- **Registry Paths**: 
  - `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*`
  - `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*`

## Conclusion

The WebStorm package experience highlighted the importance of:
1. Understanding how different vendors store version information
2. Proper PowerShell hashtable access patterns
3. Testing detection scripts before deployment
4. Monitoring logs for troubleshooting
5. Re-packaging after fixes

These learnings have been incorporated into the Wingetter script to improve future package creation.
