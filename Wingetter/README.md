# Wingetter - IntuneWin Package Creator from Winget

Wingetter automates the creation of Intune Win32 (`.intunewin`) packages from Winget applications, including registry-based detection scripts, install/uninstall wrappers, and complete Intune upload documentation.

## Features

- **Graphical interface** with Winget search, radio-button app selection, output folder picker, live progress tracking, and icon preview
- **Post-packaging icon picker** — choose among up to 3 downloaded icon candidates after packaging completes
- **CLI mode** for scripting and automation
- Automatic Winget search and installer download
- **`install.ps1`**, **`detection.ps1`**, and **`uninstall.ps1`** following Intune Win32 best practices (transcript logging, return codes, sysnative PowerShell invocation)
- **`README.md`** with every Intune portal field documented in Markdown (name, description, publisher, developer, version, commands, detection, return codes, and more)
- **`win32LobApp.json`** and **`app.json`** metadata exports
- Tiered icon resolution (installer extraction first, then Winget/homepage, then web search)
- **`wingetter-packaging.log`** written when a packaging run fails
- Settings persistence (`%AppData%\Wingetter\settings.json`)

> **New to WinGetter?** Start with the [repository README](../README.md) for a coworker-friendly overview.

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
   Search queries **every configured Winget repository** (`winget`, `msstore`, and any custom sources).
2. A **search dialog** opens with **radio buttons** — each result shows version and source; select the app you want to package and click **Select**.
3. Choose an **output destination** (defaults to `Documents\Wingetter Output`).
4. Optionally set a specific **version** or **custom icon**.
5. Click **Create Package** and watch the **live progress tracker** and step list.
6. Preview the resolved **icon** in the right panel.
7. When packaging finishes, pick the best icon from the **icon picker** if multiple candidates were found.
8. When complete, click **Open Output Folder** to review the generated files.

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
        ├── .icon-candidates/        ← Alternate icon downloads (GUI picker)
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

## Icon Resolution

Wingetter resolves icons using a **tiered, scored strategy** (most reliable first):

| Priority | Source | Notes |
|----------|--------|-------|
| 1 | **Installer (local)** | Extract largest icon from EXE/MSI, or search PNG/ICO assets inside AppX/MSIX packages |
| 2 | Known publisher URLs | Curated PNG/ICO URLs (e.g. Steam, JetBrains, Microsoft) |
| 3 | `winget show` + manifest | IconUrl and homepage metadata from winget-pkgs |
| 4 | Homepage metadata | Favicons, apple-touch-icon, Open Graph images |
| 5 | Wikimedia Commons | Optional brand logo lookup |
| 6 | Web image search | Last resort only — demoted because scrapes often return the wrong logo |

**Why installer-first?** Web PNG search frequently returns the wrong brand (or nothing). The downloaded Winget installer already contains the real app icon — extracting it (or finding packaged `.png` assets in MSIX) is more accurate for Intune.

**ICO favicons** are converted to **PNG** for Intune. In the GUI, up to **3 distinct candidates** are collected; the installer icon is always attempted first, then web fallbacks fill remaining slots for the picker.

GitHub and generic favicon URLs are deprioritized or filtered unless the app homepage is on GitHub.

### Tips for best results

- Use the **GUI icon preview** after selecting an app — if preview fails, pick a **Custom Icon** before packaging
- After packaging, use the **icon picker** if the default icon looks wrong
- For internal apps, always supply `-IconPath` or a PNG in the app folder
- PNG 256×256 or larger works best for Intune portal upload

## Module API

The core logic lives in `Wingetter.psm1`:

```powershell
Import-Module .\Wingetter.psd1

Search-WingetPackages -Query 'chrome'   # searches all configured repositories
Get-WingetPackageDetails -PackageId 'Google.Chrome'
Invoke-WingetterPackaging -PackageId 'Google.Chrome' -OutputPath 'C:\Out'
Test-WingetterPrerequisites
Get-WingetterSettings
```

## Tests

```powershell
.\Run-Tests.ps1
```

## Troubleshooting

### Prerequisites check fails in GUI

- Install Winget: `winget --version`
- Install Content Prep Tool and ensure `intunewinapputil` is on PATH

### Search returns few or no results

- Confirm repositories with `winget source list` (WinGetter searches an unscoped query first, then each listed source)
- Try the same term in a terminal: `winget search VLC` — WinGetter now follows that query matching (name/id/moniker/tags/commands)
- Try the exact package ID (e.g. `VideoLAN.VLC` / `Google.Chrome`) — exact IDs resolve via `winget show --exact`
- For the most reliable structured search on Windows, install `Microsoft.WinGet.Client`

### Packaging failed

- Check `wingetter-packaging.log` in the version output folder
- Review the log panel in the GUI

### Detection not working after deployment

- Test locally: `powershell -ExecutionPolicy Bypass -File detection.ps1`
- Review logs in `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\`

## License

Provided as-is for creating IntuneWin packages from Winget applications.
