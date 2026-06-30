# Wingetter - IntuneWin Package Creator from Winget

This tool automates the creation of IntuneWin packages from Winget applications with registry-based detection.

## Features

- ✅ **WPF graphical interface** with Winget search, radio-button package selection, output path picker, live progress bar, activity log, and icon preview
- ✅ Interactive CLI mode with `-AppName` or legacy InputBox fallback
- ✅ Automatic Winget search and download
- ✅ **install.ps1**, **detection.ps1**, and **uninstall.ps1** following Intune Win32 best practices (transcript logging, exit codes, `$PSScriptRoot`)
- ✅ Registry-based detection script (no Winget dependency at deploy time)
- ✅ Content Prep Tool integration
- ✅ Complete metadata file generation (`app.json`, `win32LobApp.json`)
- ✅ **README.md** with every Intune upload field in Markdown (display name, developer, version, commands, return codes, log paths)
- ✅ **wingetter-pack.log** written on packaging failure
- ✅ Enhanced automatic logo download (JetBrains, GitHub projects, homepage URLs, and more)
- ✅ Icon file handling with GUI preview
- ✅ Smart version detection (handles build numbers vs marketing versions)

## Prerequisites

1. **Winget** - Windows Package Manager must be installed
2. **Content Prep Tool** - Must be installed and accessible via `intunewinapputil` command
3. **PowerShell** - Version 5.1 or later

## Usage

### Graphical Interface (Recommended)

Run without parameters to open the Wingetter GUI:

```powershell
.\Create-IntuneWinFromWinget.ps1
```

Or launch the GUI directly:

```powershell
.\Start-WingetterGui.ps1
```

The GUI provides:

- Winget search with **radio-button package selection**
- **Output destination** folder picker
- Optional version override and custom icon with **live preview**
- **Live progress tracker** and scrollable activity log
- One-click open of the output folder when complete

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

## Parameters

- **AppName** (Optional): The name or ID of the application in Winget
  - If not provided, an input dialog will appear to prompt for the Winget ID
  - Examples: `"MaximaTeam.Maxima"`, `"maxima"`, `"Google.Chrome"`, `"JetBrains.WebStorm"`
  
- **Version** (Optional): Specific version to download. If not specified, latest version is used.

- **OutputPath** (Optional): Base directory for output. Default: `"D:\Intoon In Progress"`
  - Packages will be created in: `{OutputPath}\{PackageId}\{Version}\`

- **IconPath** (Optional): Path to icon file (PNG format recommended)
  - If not provided, script will look for `logo.png` in the parent directory
  - If neither found, package will be created without icon

## What the Script Does

1. **Searches Winget** for the specified application
2. **Downloads** the installer with proper filename
3. **Creates install.ps1** - Intune install wrapper with logging and exit-code handling
4. **Creates detection.ps1** - Registry-based detection script
5. **Creates uninstall.ps1** - Uninstall script that finds and executes the uninstaller
6. **Handles icon files** - Copies or downloads icon to package directory
7. **Creates metadata files**:
   - `README.md` - Full Intune upload reference (Markdown)
   - `readme.txt` - Quick reference
   - `app.json` - Application metadata
   - `win32LobApp.json` - Intune app definition with detection script
   - `wingetter-pack.log` - Failure log (only when packaging fails)
8. **Packages with Content Prep Tool** - Creates the final `.intunewin` file

## Output Structure

```
{OutputPath}/
└── {PackageId}/
    ├── logo.png (optional, if auto-downloaded)
    ├── {InstallerFileName}.intunewin
    └── {Version}/
        ├── {InstallerFileName}.exe
        ├── install.ps1
        ├── detection.ps1
        ├── uninstall.ps1
        ├── app.json
        ├── win32LobApp.json
        ├── README.md
        ├── readme.txt
        ├── icon.png
        └── wingetter-pack.log (on failure only)
```

## Detection Script

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

## Uninstall Script

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

- The script assumes silent install with `/S` flag. Adjust `installCommandLine` in JSON files if different flags are needed.
- Icon files should be PNG format for best compatibility with Intune.
- The script will overwrite existing files in the version directory.
- IntuneWin files are created in the parent directory (same level as version folder).
- **Automatic Logo Download**: The script automatically attempts to download logos from multiple sources with extensive pattern matching:
  - **JetBrains Products**: Official JetBrains CDN resources
  - **GitHub Projects**: Extensive GitHub repository searching
    - Tries multiple branches (main, master, develop, dev)
    - Tries 20+ common paths (logo.png, icon.png, assets/, img/, images/, etc.)
    - Automatically extracts org/repo from GitHub homepage URLs
    - Supports both raw.githubusercontent.com and github.com/raw patterns
  - **Homepage URLs**: 15+ common logo paths on application websites
  - **Winget Manifests**: Attempts to find icons in winget-pkgs repository
  - **CDN Patterns**: Tries common CDN hosting patterns
  - **Icon Extraction**: As last resort, extracts icons directly from EXE installers
  - **Image Validation**: Verifies downloaded files are valid images (PNG, JPEG, GIF)
  - **Smart Fallback**: Tries 50+ URL patterns before giving up
- **Version in Readme**: The readme.txt file now includes a dedicated "Version:" line for easy reference.

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
