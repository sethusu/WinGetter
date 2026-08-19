# WinGetter (Wingetter)

**Turn Winget apps into Intune Win32 packages in minutes.**

WinGetter automates the tedious parts of packaging desktop software for Microsoft Intune: downloading the installer via Winget, generating `install.ps1` / `detection.ps1` / `uninstall.ps1`, resolving an app icon, building the `.intunewin` file, and writing a field-by-field Intune upload guide.

Built for IT admins and packaging teams who want repeatable Win32 app onboarding without hand-writing detection scripts for every app.

---

## What you get

For each application, WinGetter produces:

| Output | Purpose |
|--------|---------|
| `{App}.intunewin` | Upload this to the Intune admin center |
| `install.ps1` | Silent install wrapper with Intune return codes |
| `detection.ps1` | Registry-based detection (no Winget required on devices) |
| `uninstall.ps1` | Quiet uninstall from registry uninstall string |
| `README.md` | Copy/paste reference for every Intune portal field |
| `logo.png` / `icon.png` | App icon for Intune upload |
| `app.json` / `win32LobApp.json` | Metadata exports |

---

## Requirements

| Requirement | Notes |
|-------------|-------|
| **Windows 10/11** | PowerShell 5.1 or later |
| **[Winget](https://learn.microsoft.com/en-us/windows/package-manager/winget/)** | `winget --version` must work in your shell |
| **[Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)** | `intunewinapputil` on PATH — install with `winget install --exact --id Microsoft.Win32ContentPrepTool` or the GUI **Install Content Prep** button |

Run the built-in check from PowerShell:

```powershell
cd Wingetter
Import-Module .\Wingetter.psd1
Test-WingetterPrerequisites
# If Content Prep Tool is missing:
Install-WingetterContentPrepTool
```

---

## Quick start (GUI — recommended)

### Option A — Double-click `Wingetter.exe` (easiest)

1. On a Windows machine, build once from the repo:

```powershell
cd Wingetter
.\Build\Build-WingetterExe.ps1
```

2. Open `dist\Wingetter\` (or unzip `dist\Wingetter-portable.zip` on another PC).
3. Double-click **Wingetter.exe** — no elevated PowerShell required.
4. Keep the whole folder together (`Gui\`, `Private\`, `Wingetter.psd1` must stay next to the exe).

The exe is a thin stub that starts the GUI in Windows PowerShell 5.1 (separate process).

From the source tree without building, you can also double-click `Wingetter\Start-Wingetter.cmd`.

### Option B — Run from PowerShell

1. **Clone or download** this repository.
2. Open **PowerShell** (not necessarily elevated).
3. Run:

```powershell
cd Wingetter
.\Create-IntuneWinFromWinget.ps1
```

Or launch the GUI directly:

```powershell
.\Gui\Start-WingetterGui.ps1
```

4. **Search** for an app (e.g. `Google.Chrome`, `7zip.7zip`, `Valve.Steam`).
5. **Select** the correct package from the search dialog.
6. Choose an **output folder** (default base: `Documents\Wingetter`; each app uses a subfolder named after its package ID).
7. Click **Create Package** and wait for the progress steps to finish.
8. If multiple icons were found, pick the best match in the **icon picker** dialog.
9. Click **Test in Sandbox** to install, detect, and uninstall in Windows Sandbox, confirming each step.
10. Open the output folder and upload the `.intunewin` to Intune using the included `README.md` as your field guide.

---

## Quick start (CLI)

For scripting or automation:

```powershell
cd Wingetter

# Package by Winget ID
.\Create-IntuneWinFromWinget.ps1 -AppName "Google.Chrome"

# Pin a specific version
.\Create-IntuneWinFromWinget.ps1 -AppName "7zip.7zip" -Version "24.09"

# Custom output path and icon
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima" `
    -OutputPath "C:\IntunePackages" `
    -IconPath "C:\Icons\maxima.png"
```

---

## Typical Intune workflow

1. **Package** the app with WinGetter on a Windows machine that has Winget and the Content Prep Tool.
2. **Review** the generated `README.md` in the version folder — it lists install command, detection method, publisher, description, and return codes.
3. **Upload** the `.intunewin` file in **Intune** → **Apps** → **Windows** → **Add** → **Windows app (Win32)**.
4. **Fill in** portal fields using the generated reference (or `win32LobApp.json` as a starting point).
5. **Assign** the app to a test group before broad rollout.
6. **Validate** on a pilot device — check `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\` for install/detection logs.

---

## Output folder layout

```
Documents\Wingetter\
└── Google.Chrome\
    ├── logo.png
    └── 131.0.6778.86\
        ├── GoogleChromeStandaloneEnterprise64.msi
        ├── install.ps1
        ├── detection.ps1
        ├── uninstall.ps1
        ├── README.md                 ← Intune upload cheat sheet
        ├── readme.txt
        ├── app.json
        ├── win32LobApp.json
        ├── icon.png
        ├── .icon-candidates\         ← Alternate icons (GUI picker)
        ├── validation.json           ← Written after a successful Test in Sandbox run
        └── ..\GoogleChromeStandaloneEnterprise64.intunewin
```

Default output path and last-used settings are saved to:

`%AppData%\Wingetter\settings.json`

---

## GUI features

- **Winget search** across all configured repositories (`winget`, `msstore`, custom) with a radio-button picker
- **Live progress** — step list, progress bar, and log panel
- **Icon preview** when you select an app
- **Icon picker after packaging** — choose among up to 3 downloaded icon candidates
- **Custom icon** — browse for your own PNG before packaging
- **Open output folder** when done
- **Test in Sandbox** — launch Windows Sandbox, run `install.ps1`, confirm, run `detection.ps1`, confirm, run `uninstall.ps1`, confirm; if all three are confirmed the package is marked validated

---

## Icon resolution

WinGetter finds app icons automatically using a ranked strategy:

1. **Installer extraction** (preferred) — largest icon from EXE/MSI, or PNG/ICO assets inside AppX/MSIX
2. Known publisher URLs (curated for common apps)
3. Winget manifest and `winget show` metadata
4. Publisher homepage (favicons, Open Graph images)
5. Wikimedia / web image search (last resort — often wrong or empty)

If the auto-selected icon looks wrong, use the **post-packaging icon picker** in the GUI or supply your own PNG via **Browse Icon**.

---

## Troubleshooting

| Problem | What to try |
|---------|-------------|
| `winget` not found | Install [App Installer](https://apps.microsoft.com/detail/9NBLGGH4NNS1) from the Microsoft Store |
| `intunewinapputil` not found | Click **Install Content Prep** in the GUI, run `Install-WingetterContentPrepTool`, or `winget install --exact --id Microsoft.Win32ContentPrepTool` |

| Packaging failed | Check `wingetter-packaging.log` in the version output folder and the GUI log panel |
| Wrong icon | Use the icon picker after packaging, or set a custom PNG before packaging |
| Detection fails on devices | Run `detection.ps1` locally or use **Test in Sandbox**; review logs in `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\` |
| GUI won't start | Double-click `Wingetter.exe` from a built `dist\Wingetter` folder, or run from PowerShell 5.1+ on Windows; WPF requires a desktop session |
| Antivirus blocks `Wingetter.exe` | ps2exe wrappers are occasionally flagged; build from source with `.\Build\Build-WingetterExe.ps1` or use `Start-Wingetter.cmd` / the `.ps1` entry points |

More detail: [Wingetter/README.md](Wingetter/README.md)

---

## Repository layout

```
WinGetter/
├── README.md                          ← You are here
├── dist/                              ← Created by the build script (not committed)
│   ├── Wingetter/                     ← Portable folder (double-click Wingetter.exe)
│   └── Wingetter-portable.zip
└── Wingetter/
    ├── Launch-Wingetter.ps1           ← ps2exe / double-click launcher
    ├── Start-Wingetter.cmd            ← Source-tree double-click helper
    ├── Build/
    │   └── Build-WingetterExe.ps1     ← Compiles Wingetter.exe with ps2exe
    ├── Create-IntuneWinFromWinget.ps1 ← CLI entry point (no args = GUI)
    ├── Gui/
    │   ├── Start-WingetterGui.ps1
    │   └── *.xaml                     ← WPF UI
    ├── Wingetter.psm1                 ← Core module
    ├── Private/                       ← Packaging, Winget, icons, scripts
    └── README.md                      ← Technical reference
```

---

## PowerShell module (advanced)

```powershell
Import-Module .\Wingetter\Wingetter.psd1

Search-WingetPackages -Query 'chrome'
Get-WingetPackageDetails -PackageId 'Google.Chrome'
Invoke-WingetterPackaging -PackageId 'Google.Chrome' -OutputPath 'C:\Out'
Test-WingetterWindowsSandbox
```

---

## License

Provided as-is for creating Intune Win32 packages from Winget applications.

---

## Contributing

Issues and pull requests welcome on [GitHub](https://github.com/sethusu/WinGetter).
