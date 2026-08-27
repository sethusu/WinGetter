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
- **Test in Sandbox** — enable Windows Sandbox if needed, then confirm install, detection, and uninstall before marking the package validated
- Tiered icon resolution (installer extraction first, then Winget/homepage, then web search)
- **`wingetter-packaging.log`** written when a packaging run fails
- Settings persistence (`%AppData%\Wingetter\settings.json`)

> **New to WinGetter?** Start with the [repository README](../README.md) for a coworker-friendly overview.

## Prerequisites

1. **Windows** with **PowerShell 5.1+**
2. **Winget** — Windows Package Manager
3. **Microsoft Win32 Content Prep Tool** — `intunewinapputil` on PATH  
   Install via winget (`Microsoft.Win32ContentPrepTool`), from the GUI **Install Content Prep** button, or with `Install-WingetterContentPrepTool`

## Quick Start (GUI)

### Double-click executable

Build a portable folder on Windows:

```powershell
cd Wingetter
.\Build\Build-WingetterExe.ps1
```

Then double-click `dist\Wingetter\Wingetter.exe` (or unzip `dist\Wingetter-portable.zip` elsewhere). No elevated PowerShell is required. Keep `Wingetter.exe` next to `Gui\`, `Private\`, and `Wingetter.psd1`.

From the source tree without compiling, double-click `Start-Wingetter.cmd`.

### From PowerShell

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
3. Choose an **output destination** (defaults to `Documents\Wingetter\{PackageId}` after you select an app).
4. Optionally set a specific **version** or **custom icon**.
5. Click **Create Package** and watch the **live progress tracker** and step list.
6. Preview the resolved **icon** in the right panel.
7. When packaging finishes, pick the best icon from the **icon picker** if multiple candidates were found.
8. When complete, click **Open Output Folder** to review the generated files, or **Test in Sandbox** to validate install, detection, and uninstall.

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
| `OutputPath` | Base output directory. Defaults to `Documents\Wingetter`; each package is written to `{OutputPath}\{PackageId}\`. |
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
        ├── silent-switches.json   ← Verified silent-install engine and switches
        ├── sandbox-test-report.txt ← Chat-ready Windows Sandbox log
        ├── sandbox-failure.log      ← Written when a sandbox test fails (upload this)
        ├── sandbox-logs/            ← Copied guest/IME logs from the last sandbox test
        ├── .icon-candidates/        ← Alternate icon downloads (GUI picker)
        ├── wingetter-packaging.log  ← Created when packaging fails
        └── ../{InstallerBase}.intunewin
```

## Intune Scripts

### install.ps1

- Runs a verified silent installer command for the detected engine (Inno `/VERYSILENT /LANG=english`, NSIS `/S`, MSI quiet, AppX)
- Rejects generic `/S` when the installer is Inno Setup (it is not silent for that engine)
- Logs to `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\{PackageId}-install.log`
- Returns standard Intune return codes (0, 3010, 1641, 1618)

### detection.ps1

- Registry-based detection (no Winget dependency on target devices)
- Checks 64-bit and WOW6432Node uninstall keys
- JetBrains marketing version extraction from DisplayName
- Logs to `{PackageId}-detection.log`

### uninstall.ps1

- Finds uninstall string in registry
- Prefers quiet uninstall; uses Inno `/VERYSILENT` or NSIS `/S` when a quiet string is missing
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
Install-WingetterContentPrepTool   # winget install Microsoft.Win32ContentPrepTool
Test-WingetterWindowsSandbox
Get-WingetterSettings
```

## Tests

```powershell
.\Run-Tests.ps1
.\Build\Test-PackagingScripts.ps1   # launcher / build script sanity checks
```

## Building Wingetter.exe (ps2exe)

On Windows:

```powershell
.\Build\Build-WingetterExe.ps1
```

This installs the Gallery `ps2exe` module (CurrentUser) if needed, stages runtime files under `..\dist\Wingetter\`, compiles `Launch-Wingetter.ps1` to `Wingetter.exe` (no console, no admin manifest), and creates `..\dist\Wingetter-portable.zip`.

The `.exe` is a thin stub: it starts `Gui\Start-WingetterGui.ps1` in a separate Windows PowerShell 5.1 process so module parsing (including regex quantifiers in `Private\Winget.ps1`) runs outside the ps2exe host. Launch uses `-EncodedCommand` so folders with spaces work, and writes `%TEMP%\Wingetter-launch.log`.

To diagnose on Windows without rebuilding:

```powershell
.\Build\Diagnose-WingetterLaunch.ps1
.\Build\Diagnose-WingetterLaunch.ps1 -StartGui
```

## Troubleshooting

### Wingetter.exe crashes after selecting an app

If choosing a search result closes the GUI with `Failed to get app information from Winget (exit code: -1978335214)`, the selected package's source name is not available on that machine. Version **2.2.3+** retries `winget show` without `--source` and keeps the window open if icon preview fails.

### Wingetter.exe flashes or shows regex parse errors

If the GUI fails with errors in `Private\Winget.ps1` mentioning `\s{2,}` / `Missing expression after ','`, you are likely running an older build that embeds UTF-8 glyphs in a BOM-less script. Rebuild from source (`.\Build\Build-WingetterExe.ps1`) — version **2.2.2+** keeps those scripts ASCII-safe for Windows PowerShell 5.1.

Startup details are always written to `%TEMP%\Wingetter-launch.log`.

### Prerequisites check fails in GUI

- Install Winget: `winget --version`
- Click **Install Content Prep** in the header, or run `Install-WingetterContentPrepTool`
- Or install manually: `winget install --exact --id Microsoft.Win32ContentPrepTool` and ensure `intunewinapputil` is on PATH

### Search returns few or no results

- Confirm repositories with `winget source list` (WinGetter searches an unscoped query first, then each listed source)
- Try the same term in a terminal: `winget search VLC` — WinGetter now follows that query matching (name/id/moniker/tags/commands)
- Try the exact package ID (e.g. `VideoLAN.VLC` / `Google.Chrome`) — exact IDs resolve via `winget show --exact`
- For the most reliable structured search on Windows, install `Microsoft.WinGet.Client`

### Packaging failed

- Check `wingetter-packaging.log` in the version output folder
- Review the log panel in the GUI
- If the dialog shows `exit code: -1978335209 -- No manifest found matching the criteria` for apps like RStudio, you hit a truncated SemVer build version (`2025.05.1` instead of `2025.05.1+513`). Version **2.4.2+** keeps the `+N` suffix from search and retries `winget show` without `--version` when needed.
- If choosing a different post-packaging icon shows `The property 'IconFile' cannot be found on this object`, upgrade to **2.5.1+** (Content Prep Tool stdout was polluting the packaging result).

### Sandbox install exit 666660 (RStudio / NsisMultiUser)

Exit **666660** means the Nullsoft MultiUser installer rejected the command line. Bare `/S` is invalid; the installer needs `/S /currentuser` or `/S /allusers`. Version **2.5.0+** packages `*_User_*` installers with `/currentuser`, and **Test in Sandbox** auto-retries alternate silent switches, then permanently updates `install.ps1` when one succeeds.

### Detection not working after deployment

- Test locally: `powershell -ExecutionPolicy Bypass -File detection.ps1`
- Use **Test in Sandbox** in the GUI to confirm install, detection, and uninstall before uploading to Intune
- Review logs in `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\`

## Test in Sandbox

Windows Sandbox (Windows 10/11 Pro, Enterprise, or Education) can install, detect, and uninstall a packaged app in a disposable VM before you upload it to Intune.

1. Create a package so the version folder contains `install.ps1`, `detection.ps1`, `uninstall.ps1`, and the installer.
2. Click **Test in Sandbox**.
3. If Windows Sandbox is not enabled, Wingetter prompts to enable the `Containers-DisposableClientVM` optional feature (administrator approval; usually a reboot).
4. Windows Sandbox starts and runs `install.ps1`. If install fails, Wingetter automatically retries alternate silent switches (for example `/S /currentuser` for RStudio). The first switch that succeeds is written permanently to `install.ps1`.
5. Confirm the successful install step in Wingetter.
6. Confirm **detection**, then confirm **uninstall**.
7. If all three steps are confirmed **and the install stayed silent** (no language/wizard dialog), Wingetter writes `validation.json` and sets `sandboxValidated` on `app.json`.
8. After the test (pass or fail), Wingetter writes `sandbox-test-report.txt` in the package folder and copies Intune/guest logs to `sandbox-logs\`. On failure it also writes `sandbox-failure.log` in that same folder — upload that file for diagnostics. Use **Copy report** in the dialog to grab a log before the sandbox closes. If you already built an `.intunewin` before a sandbox switch fix, re-run Content Prep so the archive includes the updated `install.ps1`.

## License

Provided as-is for creating IntuneWin packages from Winget applications.
