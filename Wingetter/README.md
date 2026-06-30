# Wingetter - IntuneWin Package Creator from Winget

This tool automates the creation of IntuneWin packages from Winget applications with registry-based detection.

## Features

- ✅ Full GUI package builder with searchable Winget lookup
- ✅ Radio-button package selection when multiple apps match
- ✅ Output destination picker for package location
- ✅ Optional icon selection with built-in icon preview panel
- ✅ Optional Markdown description/notes for Intune metadata
- ✅ Live packaging progress tracker window
- ✅ Best-practice Intune script generation (`install.ps1`, `uninstall.ps1`, `detection.ps1`)
- ✅ Complete metadata generation (`app.json`, `win32LobApp.json`)
- ✅ Markdown `README.md` with Intune upload field reference
- ✅ Failure logging to `run-failure.log` when packaging errors occur

## Prerequisites

1. **Winget** - Windows Package Manager must be installed
2. **Content Prep Tool** - Must be installed and accessible via `intunewinapputil` command
3. **PowerShell** - Version 5.1 or later

## Usage

### Interactive GUI Mode (Recommended)

Run the script without parameters to open the GUI package builder:

```powershell
.\Create-IntuneWinFromWinget.ps1
```

The GUI lets you:

1. Search Winget
2. Select one app using radio buttons
3. Choose output destination
4. Optionally set version, icon, and Markdown description
5. Start packaging with live progress updates

### Command Line Usage

```powershell
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima"
```

### With Specific Version

```powershell
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima" -Version "5.47.0"
```

### With Custom Output Path

```powershell
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima" -OutputPath "C:\IntunePackages"
```

### With Custom Icon

```powershell
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima" -IconPath "C:\Icons\app-icon.png"
```

### No-GUI Mode

```powershell
.\Create-IntuneWinFromWinget.ps1 -NoGui -AppName "Google.Chrome" -OutputPath "C:\IntunePackages"
```

## Parameters

- **AppName** (Optional): Name or ID of the app in Winget.
  - In GUI mode, this is optional and can be entered in the search box.
  - In `-NoGui` mode, this is required.
  
- **Version** (Optional): Specific version to download. If not specified, latest version is used.

- **OutputPath** (Optional): Base directory for output. Default: `"D:\Intoon In Progress"`
  - Packages will be created in: `{OutputPath}\{PackageId}\{Version}\`

- **IconPath** (Optional): Path to icon file (PNG format recommended)
  - In GUI mode, this can be selected via file picker with preview.
  - If not provided, package is created without `largeIcon`.

- **DescriptionMarkdown** (Optional): Markdown content for app description/notes in README and metadata.

- **NoGui** (Optional switch): Runs in terminal-only mode.

## What the Script Does

1. **Searches Winget** for the specified application
2. **Downloads** the installer with proper filename
3. **Creates detection.ps1** - Registry-based detection script for Intune
4. **Creates uninstall.ps1** - Registry-driven uninstall script
5. **Creates install.ps1** - Standardized install wrapper script
6. **Handles icon files** - Copies selected icon to package directory
6. **Creates metadata files**:
   - `README.md` - Documentation + full Intune field mapping
   - `app.json` - Application metadata
   - `win32LobApp.json` - Intune app definition with detection script
7. **Writes failure diagnostics** to `run-failure.log` on failed run
8. **Packages with Content Prep Tool** - Creates the final `.intunewin` file

## Output Structure

```
{OutputPath}/
├── wingetter-run-YYYYMMDD-HHMMSS.log
├── run-failure.log (only on failure)
└── {PackageId}/
    └── {Version}/
        ├── {InstallerFileName}.exe|msi|msix|appx
        ├── install.ps1
        ├── uninstall.ps1
        ├── detection.ps1
        ├── app.json
        ├── win32LobApp.json
        ├── README.md
        ├── icon.png (optional)
        └── {InstallerBaseName}.intunewin (created in parent directory)
```

## Detection Script (`detection.ps1`)

The detection script uses **registry-based detection** instead of Winget, making it more reliable for Intune deployments:

- Checks `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*`
- Checks `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*`
- Verifies version matches or is higher than expected
- Returns appropriate exit codes for Intune

### Smart Version Detection

The detection script includes intelligent version handling:

- **JetBrains Products**: Automatically extracts marketing version from DisplayName (e.g., "2025.3.1.1") when DisplayVersion contains build numbers (e.g., "253.29346.242")
- **Multiple Versions**: Handles multiple installations and selects the highest version
- **Flexible Matching**: Uses flexible name matching to find applications even with slight variations in registry entries

## Install Script (`install.ps1`)

The install script:
- Runs from Intune as System context
- Transcripts to Intune Management Extension log directory
- Handles accepted return codes (`0`, `3010`, `1641`)

## Uninstall Script (`uninstall.ps1`)

The uninstall script:
- Searches registry for uninstall string
- Prefers quiet uninstall if available
- Adds `/S` flag for Nullsoft installers if needed
- Executes uninstall and returns proper exit codes

## Examples

### Example 1: Maxima
```powershell
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima"
```

### Example 2: Google Chrome
```powershell
.\Create-IntuneWinFromWinget.ps1 -AppName "Google.Chrome"
```

### Example 3: 7-Zip with specific version
```powershell
.\Create-IntuneWinFromWinget.ps1 -AppName "7zip.7zip" -Version "23.01"
```

## Troubleshooting

### "Winget search failed" or "Error reading input in prompt"
- Ensure Winget is installed: `winget --version`
- Check if the app name is correct
- Try using the exact package ID instead of search term
- The script automatically accepts source and package agreements. If you see prompt errors, ensure you're running the latest version of Winget that supports `--accept-package-agreements`

### "intunewinapputil not found"
- Install Microsoft Win32 Content Prep Tool
- Ensure it's in your PATH or use full path
- Check if the alias is set: `Get-Command intunewinapputil`

### "Could not find downloaded installer file"
- Check the download directory for the file
- Verify Winget download completed successfully
- Check file permissions

### Detection script not working
- Verify the app is actually installed
- Check registry keys manually: `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | Where-Object { $_.DisplayName -like "*AppName*" }`
- Review detection script logs in: `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\`
- For JetBrains products: Check if DisplayVersion contains build numbers instead of marketing versions. The script should automatically extract the version from DisplayName.
- Test detection script manually: `powershell -ExecutionPolicy Bypass -File detection.ps1` (should exit with code 0 if installed)

## Notes

- EXE installers default to `/S`; MSI/MSIX/APPX command logic is generated automatically.
- Icon files should be PNG format for best Intune compatibility.
- Existing files in the version directory can be overwritten by subsequent runs.
- IntuneWin files are generated one level above the version folder.

## Recent Improvements

### Version 1.1 (2026-01-22)
- ✅ Added automatic logo download for JetBrains products
- ✅ Added version extraction from DisplayName for JetBrains products (handles build numbers)
- ✅ Fixed hashtable property access in detection scripts
- ✅ Added version field to readme.txt
- ✅ Improved version sorting logic for multiple installations
- ✅ Enhanced error handling in detection scripts

## License

This script is provided as-is for creating IntuneWin packages from Winget applications.
