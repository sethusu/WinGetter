# Wingetter - IntuneWin Package Creator from Winget

Wingetter automates the creation of Intune Win32 (`.intunewin`) packages from Winget applications, including registry-based detection scripts, install/uninstall wrappers, and complete Intune upload documentation.

## Features

- **Graphical interface** with Winget search, radio-button app selection, output folder picker, live progress tracking, and icon preview
- **CLI mode** for scripting and automation
- Automatic Winget search and installer download
- **`install.ps1`**, **`detection.ps1`**, and **`uninstall.ps1`** following Intune Win32 best practices (transcript logging, return codes, sysnative PowerShell invocation)
- **`README.md`** with every Intune portal field documented in Markdown (name, description, publisher, developer, version, commands, detection, return codes, and more)
- **`win32LobApp.json`** and **`app.json`** metadata exports
- Automatic logo download and icon extraction
- **`wingetter-packaging.log`** written when a packaging run fails
- Settings persistence (`%AppData%\Wingetter\settings.json`)

## Prerequisites

1. **Windows** with **PowerShell 5.1+**
2. **Winget** — Windows Package Manager
3. **Microsoft Win32 Content Prep Tool** — `intunewinapputil` on PATH

## Quick Start (GUI)

```powershell
cd Wingetter
.\Gui\Start-WingetterGui.ps1
```

Or launch via the main script with no parameters:

```powershell
.\Create-IntuneWinFromWinget.ps1
```

### Using the GUI

1. Enter an app name or Winget package ID (e.g. `Google.Chrome`, `webstorm`) and click **Search**.
2. If multiple results are found, a **search dialog** opens with **radio buttons** — select the app you want to package and click **Select**.
3. Choose an **output destination** (defaults to `Documents\Wingetter Output`).
4. Optionally set a specific **version** or **custom icon**.
5. Click **Create Package** and watch the **live progress tracker** and step list.
6. Preview the resolved **icon** in the right panel.
7. When complete, click **Open Output Folder** to review the generated files.

## CLI Usage

```powershell
.\Create-IntuneWinFromWinget.ps1 -AppName "Google.Chrome"
.\Create-IntuneWinFromWinget.ps1 -AppName "7zip.7zip" -Version "23.01"
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima" -OutputPath "C:\IntunePackages"
.\Create-IntuneWinFromWinget.ps1 -UseGui
```

## Parameters

| Parameter | Description |
|---|---|
| `AppName` | Winget package ID or search term. Omit to launch the GUI. |
| `Version` | Optional specific version to download. |
| `OutputPath` | Base output directory. Defaults to saved settings. |
| `IconPath` | Optional custom PNG icon path. |
| `UseGui` | Force the graphical interface. |

## Output Structure

```
{OutputPath}/
└── {PackageId}/
    ├── logo.png
    └── {Version}/
        ├── {Installer}.exe|.msi|.msix|.appx
        ├── install.ps1
        ├── detection.ps1
        ├── uninstall.ps1
        ├── README.md              ← Full Intune upload reference (Markdown)
        ├── readme.txt             ← Legacy summary
        ├── app.json
        ├── win32LobApp.json
        ├── icon.png
        ├── wingetter-packaging.log  ← Created when packaging fails
        └── ../{InstallerBase}.intunewin
```

## Intune Scripts

### install.ps1

- Runs the silent installer command (`/S`, MSI quiet, or AppX)
- Logs to `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\{PackageId}-install.log`
- Returns standard Intune return codes (0, 3010, 1641, 1618)

### detection.ps1

- Registry-based detection (no Winget dependency on target devices)
- Checks 64-bit and WOW6432Node uninstall keys
- JetBrains marketing version extraction from DisplayName
- Logs to `{PackageId}-detection.log`

### uninstall.ps1

- Finds uninstall string in registry
- Prefers quiet uninstall; adds `/S` for NSIS-style EXE when needed
- Logs to `{PackageId}-uninstall.log`

## README.md

Each package includes a Markdown README with a complete **Intune Portal Upload Reference** table covering:

- Display name, description, publisher, developer
- App version, Winget package ID, information URL
- Install and uninstall command lines
- Setup file name, IntuneWin file name, SHA-256 hash
- Detection method, architecture, minimum Windows release
- Install behavior, restart behavior, return codes, icon status

## Module API

The core logic lives in `Wingetter.psm1`:

```powershell
Import-Module .\Wingetter.psd1

Search-WingetPackages -Query 'chrome'
Get-WingetPackageDetails -PackageId 'Google.Chrome'
Invoke-WingetterPackaging -PackageId 'Google.Chrome' -OutputPath 'C:\Out'
Test-WingetterPrerequisites
Get-WingetterSettings
```

## Troubleshooting

### Prerequisites check fails in GUI

- Install Winget: `winget --version`
- Install Content Prep Tool and ensure `intunewinapputil` is on PATH

### Packaging failed

- Check `wingetter-packaging.log` in the version output folder
- Review the log panel in the GUI

### Detection not working after deployment

- Test locally: `powershell -ExecutionPolicy Bypass -File detection.ps1`
- Review logs in `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\`

## License

Provided as-is for creating IntuneWin packages from Winget applications.
