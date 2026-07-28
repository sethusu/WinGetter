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
| **[Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)** | `intunewinapputil` must be on your PATH |

Run the built-in check from PowerShell:

```powershell
cd Wingetter
Import-Module .\Wingetter.psd1
Test-WingetterPrerequisites
```

---

## Quick start (GUI — recommended)

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
6. Choose an **output folder** (default: `Documents\Wingetter Output`).
7. Click **Create Package** and wait for the progress steps to finish.
8. If multiple icons were found, pick the best match in the **icon picker** dialog.
9. Open the output folder and upload the `.intunewin` to Intune using the included `README.md` as your field guide.

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
Documents\Wingetter Output\
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
| `intunewinapputil` not found | Install the [Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) and add it to PATH |
| Packaging failed | Check `wingetter-packaging.log` in the version output folder and the GUI log panel |
| Wrong icon | Use the icon picker after packaging, or set a custom PNG before packaging |
| Detection fails on devices | Run `detection.ps1` locally; review logs in `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\` |
| GUI won't start | Run from PowerShell 5.1+ on Windows; WPF requires a desktop session |

More detail: [Wingetter/README.md](Wingetter/README.md)

---

## Repository layout

```
WinGetter/
├── README.md                          ← You are here
└── Wingetter/
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
```

---

## License

Provided as-is for creating Intune Win32 packages from Winget applications.

---

## Contributing

Issues and pull requests welcome on [GitHub](https://github.com/sethusu/WinGetter).
