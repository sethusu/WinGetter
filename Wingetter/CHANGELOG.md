# Wingetter Changelog

## Version 2.0 - 2026-06-30

### GUI Reliability (follow-up)
- Fixed WPF search dialog crashes from invalid Brush/Thickness assignments
- Packaging and Winget search now run on background threads (no UI freeze/deadlock)
- Progress updates via thread-safe queue and DispatcherTimer
- Step list updates by replacing items (works without INotifyPropertyChanged)
- Search dialog always shown with radio buttons, even for a single result
- Selected search version auto-fills version field and is passed to packaging
- Partial packaging success (metadata without `.intunewin`) surfaced in the GUI

### New Features
- **WPF Graphical Interface** (`Gui/Start-WingetterGui.ps1`)
  - Winget search with dedicated **radio-button selection dialog** for multiple results
  - Output destination folder picker with persisted settings
  - Optional version override and custom icon selection
  - **Live progress tracker** with step list and log panel
  - **Icon preview** panel
  - Prerequisites status display
- **PowerShell module** (`Wingetter.psm1`) — core logic extracted for GUI and CLI reuse
- **`install.ps1`** — Intune Win32 install wrapper with transcript logging and standard return codes
- **`README.md`** — Markdown documentation with complete Intune portal upload field reference
- **`wingetter-packaging.log`** — failure log written to the output folder when packaging fails

### Enhancements
- Intune install/uninstall command lines now invoke `install.ps1` / `uninstall.ps1` via sysnative PowerShell
- Default output path changed to `%USERPROFILE%\Documents\Wingetter Output`
- Settings persisted to `%AppData%\Wingetter\settings.json`
- Running `Create-IntuneWinFromWinget.ps1` with no parameters launches the GUI

## Version 1.2 - 2026-01-22

### New Features
- **Interactive Input Dialog**: Added input dialog box that appears when AppName parameter is not provided
  - Uses Windows Forms InputBox for user-friendly input
  - Includes helpful examples in the dialog prompt
  - Allows running script without command-line parameters
  - Makes the tool more accessible for non-technical users

### Enhancements
- **Enhanced Logo Download**: Significantly improved automatic logo download functionality
  - **GitHub Support**: Automatically downloads logos from GitHub repositories with extensive pattern matching
    - Tries multiple branches (main, master, develop, dev)
    - Tries 20+ common paths (logo.png, icon.png, assets/logo.png, img/logo.png, etc.)
    - Extracts GitHub org/repo from homepage URLs automatically
    - Supports both raw.githubusercontent.com and github.com/raw patterns
  - **Homepage Support**: Attempts to download logos from application homepages with 15+ path variations
  - **Winget Manifest Support**: Tries to find icons in winget-pkgs repository structure
  - **Icon Extraction**: As a last resort, attempts to extract icons directly from EXE installers
  - **Image Validation**: Validates downloaded files are actual images (PNG, JPEG, GIF) before using them
  - **CDN Support**: Tries common CDN patterns (jsdelivr, etc.)
  - **Multiple URL Patterns**: Tries 50+ different URL patterns before giving up
  - **Product-Specific URLs**: Includes specific URLs for known products (e.g., Spyder IDE, JetBrains products)
  - **Smart Fallback Logic**: Tries web sources first, then installer extraction if available

### Changes
- Changed `AppName` parameter from `Mandatory=$true` to `Mandatory=$false`
- Script now prompts for Winget ID if not provided via parameter
- Enhanced `Get-LogoFromWeb` function to accept `Homepage` parameter
- Added support for GitHub-based projects and homepage-based logo downloads

---

## Version 1.1 - 2026-01-22

### Improvements from WebStorm Package Experience

#### JetBrains Product Support
- **Automatic Logo Download**: Added `Get-LogoFromWeb` function that automatically downloads logos for JetBrains products from official JetBrains CDN resources
- **Smart Version Detection**: JetBrains products store build numbers (e.g., "253.29346.242") in `DisplayVersion` but marketing versions (e.g., "2025.3.1.1") in `DisplayName`. The detection script now automatically extracts the marketing version from `DisplayName` when detected.

#### Detection Script Fixes
- **Hashtable Property Access**: Fixed issue where hashtable properties were accessed incorrectly, causing version comparison to fail. Now uses bracket notation (`$hash['Property']`) for reliable access.
- **Single vs Multiple Versions**: Improved logic to handle single installations more efficiently (direct access) vs multiple installations (sorting required).
- **Better Error Handling**: Added fallback mechanisms when version parsing fails.

#### Documentation Improvements
- **Version in Readme**: Added dedicated "Version:" line to readme.txt for easy reference
- **Enhanced Logging**: Detection scripts now provide better debug output for troubleshooting

### Technical Details

#### Version Extraction Logic
For JetBrains products, the detection script:
1. Checks if `DisplayName` contains a version pattern (e.g., "WebStorm 2025.3.1.1")
2. Extracts the marketing version using regex: `(\d+\.\d+\.\d+\.\d+)`
3. Falls back to `DisplayVersion` if extraction fails
4. Uses the extracted/fallback version for comparison

#### Logo Download URLs
The script tries multiple JetBrains CDN URLs:
- `https://resources.jetbrains.com/storage/products/{product}/img/meta/{product}_logo_300x300.png`
- `https://www.jetbrains.com/{product}/img/{product}_logo_300x300.png`
- `https://resources.jetbrains.com/storage/products/{product}/img/meta/{product}_icon_256x256.png`

### Files Modified
- `Create-IntuneWinFromWinget.ps1`: Added logo download function, improved detection script generation
- `README.md`: Updated with new features and troubleshooting information

### Testing
- Tested with JetBrains.WebStorm 2025.3.1.1
- Detection script verified to exit with code 0 when installed
- Logo download verified to work for WebStorm

---

## Version 1.0 - Initial Release

### Features
- Basic Winget package creation
- Registry-based detection scripts
- Uninstall script generation
- Content Prep Tool integration
- Metadata file generation
