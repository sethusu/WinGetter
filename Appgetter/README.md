# Appgetter - IntuneWin Package Creator (sister to Wingetter)

Appgetter is the companion tool to [Wingetter](../Wingetter/README.md) for building IntuneWin packages from Winget applications.

## Default location

Scripts and package output use this base path by default:

```
D:\intoon in progress\Appgetter
```

Packages are created under:

```
D:\intoon in progress\Appgetter\{PackageId}\{Version}\
```

Wingetter uses the parent folder `D:\intoon in progress` so the two tools stay side by side.

## Usage

```powershell
cd "D:\intoon in progress\Appgetter"
.\Create-IntuneWinFromWinget.ps1 -AppName "Google.Chrome"
```

Override the output root if needed:

```powershell
.\Create-IntuneWinFromWinget.ps1 -AppName "Google.Chrome" -OutputPath "D:\intoon in progress\Appgetter"
```

## Prerequisites

Same as Wingetter: Winget, Content Prep Tool (`intunewinapputil`), and PowerShell 5.1+.
