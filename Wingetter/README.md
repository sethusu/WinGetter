# Wingetter - IntuneWin Package Creator from Winget

Wingetter automates the creation of Microsoft Intune Win32 (`.intunewin`) packages from Winget applications, with registry-based detection scripts and full Intune upload documentation.

## Features

- **Graphical interface** with Winget search, radio-button package selection, output folder picker, live progress, and icon preview
- Automatic Winget search and download with progress tracking
- **install.ps1**, **uninstall.ps1**, and **detection.ps1** following Intune Win32 best practices (transcript logging, return codes, SYSTEM context)
- **README.md** with every Intune portal field: display name, version, publisher, description, install/uninstall commands, detection rules, return codes, and more
- **packaging.log** and **packaging-failure.log** for troubleshooting failed runs
- Complete metadata: `app.json`, `win32LobApp.json`, `readme.txt`
- Automatic icon discovery and preview
- Smart registry-based version detection (including JetBrains marketing versions)

## Prerequisites

1. **Windows** with PowerShell 5.1 or later
2. **Winget** (Windows Package Manager)
3. **Microsoft Win32 Content Prep Tool** (`intunewinapputil` on PATH)

## Quick Start

### GUI Mode (Recommended)

```powershell
.\Create-IntuneWinFromWinget.ps1 -Gui
```

Or launch the GUI directly:

```powershell
.\Show-WingetterGui.ps1
```

The GUI provides:

1. **Search** — enter an app name or Winget package ID
2. **Select** — choose from results using radio buttons in a search dialog
3. **Output destination** — browse to your preferred folder
4. **Icon preview** — view the app icon or browse for a custom one
5. **Pack for Intune** — watch live progress through download, scripting, and packaging
6. **Open Output Folder** — jump to the finished package when done

### CLI Mode

```powershell
.\Create-IntuneWinFromWinget.ps1 -AppName "Google.Chrome"
```

```powershell
.\Create-IntuneWinFromWinget.ps1 -AppName "7zip.7zip" -Version "24.09" -OutputPath "C:\IntunePackages"
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `-Gui` | Launch the graphical user interface |
| `-AppName` | Winget package ID or search term (prompts if omitted in CLI mode) |
| `-Version` | Specific version to download |
| `-OutputPath` | Base output directory (default: `Documents\Wingetter Output`) |
| `-IconPath` | Custom icon file path (PNG recommended) |

## Output Structure

```
{OutputPath}/
└── {PackageId}/
    ├── logo.png
    ├── {InstallerBase}.intunewin
    └── {Version}/
        ├── {Installer}.exe|.msi|...
        ├── install.ps1
        ├── uninstall.ps1
        ├── detection.ps1
        ├── README.md          ← Full Intune upload reference (Markdown)
        ├── readme.txt
        ├── app.json
        ├── win32LobApp.json
        ├── icon.png
        └── packaging.log      ← Run log (packaging-failure.log on error)
```

## Generated Scripts

### install.ps1

- Runs as SYSTEM from the package content folder
- Logs to `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\{packageId}-install.log`
- Handles Intune return codes: 0, 1707, 3010, 1641, 1618

### detection.ps1

- Registry-based detection (no Winget dependency on managed devices)
- Checks HKLM uninstall keys (64-bit and WOW6432)
- Version comparison with JetBrains DisplayName extraction support
- Logs to `{packageId}-detection.log`

### uninstall.ps1

- Finds uninstall string from registry
- Prefers quiet uninstall; adds `/S` for NSIS installers
- Logs to `{packageId}-uninstall.log`

## README.md

Each package includes a Markdown README with all fields needed for the Intune admin center:

- Display name, description, publisher, developer, version
- Information URL and Winget package ID
- Install and uninstall commands
- Detection type and logic
- Return code reference table
- Minimum OS, architecture, restart behavior
- Package contents listing and deployment notes

## Architecture

| File | Role |
|------|------|
| `Show-WingetterGui.ps1` | WinForms GUI entry point |
| `Create-IntuneWinFromWinget.ps1` | CLI/GUI launcher (`-Gui` switch) |
| `Wingetter.Core.psm1` | Shared packaging module |
| `Monitor-IntuneInstall.ps1` | Post-deploy IME log monitor |

## Troubleshooting

### Packaging failed

Check `packaging.log` or `packaging-failure.log` in the version output folder.

### Winget not found

```powershell
winget --version
```

### intunewinapputil not found

Install the [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) and ensure `intunewinapputil` is on PATH.

### Detection not working after deploy

Review logs at `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\` or use:

```powershell
.\Monitor-IntuneInstall.ps1 -PackageId "Publisher.PackageName"
```

## License

Provided as-is for creating Intune Win32 packages from Winget applications.
