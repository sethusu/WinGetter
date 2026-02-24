# AGENTS.md

## Cursor Cloud specific instructions

### Overview

Wingetter is a collection of PowerShell scripts (`.ps1`) for automating the creation of Microsoft Intune `.intunewin` deployment packages from Winget applications. There is no build system, package manager lockfile, CI/CD, or backend service — just PowerShell scripts in the `Wingetter/` directory.

### Platform constraint

The scripts are **Windows-only** at runtime (they depend on Winget, Windows Registry, Windows Forms, and the Intune Content Prep Tool). On the Linux Cloud Agent VM, you can lint, parse, and test pure-logic functions but **cannot** execute the full end-to-end workflow.

### Linting

```bash
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path /workspace/Wingetter/ -Recurse"
```

No errors are expected. Warnings (e.g., `PSAvoidUsingWriteHost`) are intentional for this interactive CLI tool.

### Syntax validation

```bash
pwsh -NoProfile -Command '
Get-ChildItem /workspace/Wingetter/ -Filter *.ps1 -Recurse | ForEach-Object {
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e) | Out-Null
    if ($e.Count -gt 0) { Write-Error "Parse errors in $($_.Name): $e" }
    else { Write-Host "OK: $($_.Name)" }
}
'
```

### Testing individual functions

You can extract and test pure-logic functions (e.g., `Select-WingetPackage`) from `Create-IntuneWinFromWinget.ps1` using the PowerShell AST:

```bash
pwsh -NoProfile -Command '
$ast = [System.Management.Automation.Language.Parser]::ParseFile("/workspace/Wingetter/Create-IntuneWinFromWinget.ps1", [ref]$null, [ref]$null)
$func = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Select-WingetPackage" }, $true)
Invoke-Expression $func[0].Extent.Text
# Now call the function with test data
'
```

Functions that invoke Windows-only APIs (`Microsoft.VisualBasic.Interaction`, `System.Windows.Forms`, `winget`, registry access) will fail on Linux — this is expected.

### Key files

- `Wingetter/Create-IntuneWinFromWinget.ps1` — main script (~1370 lines, 8 functions)
- `Wingetter/Example-Usage.ps1` — usage examples
- `Wingetter/Monitor-IntuneInstall.ps1` — Intune install log monitor
- `Wingetter/Watch-WebStormInstall.ps1` — WebStorm-specific log monitor
- `Wingetter/Troubleshoot-RunInSandbox.ps1` — RunInSandbox diagnostic tool
- `Wingetter/README.md` — full documentation and usage
