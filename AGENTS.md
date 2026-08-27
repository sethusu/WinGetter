# AGENTS.md

## Cursor Cloud specific instructions

### Project Overview

Wingetter is a **Windows-only PowerShell toolset** for creating Microsoft Intune Win32 app packages (`.intunewin` files) from Winget applications. It has no build system, no managed dependencies, and no server-side components.

### Development Environment on Linux (Cloud Agent)

Since this is a Windows-only project, Cloud Agents run on Linux and **cannot execute the scripts end-to-end** (they require Windows APIs: registry, Windows Forms, `winget.exe`, `intunewinapputil.exe`). However, static analysis and linting work fully.

- **PowerShell Core (`pwsh`)** is installed for script parsing and linting.
- **PSScriptAnalyzer** module is installed for linting.

### Lint / Static Analysis

```bash
# Lint all scripts (errors + warnings)
pwsh -Command "Import-Module PSScriptAnalyzer; Get-ChildItem -Path /workspace/Wingetter -Filter '*.ps1' | ForEach-Object { Invoke-ScriptAnalyzer -Path \$_.FullName -Severity @('Error','Warning') }"

# Syntax-only check (parse all scripts)
pwsh -Command "Get-ChildItem -Path /workspace/Wingetter -Filter '*.ps1' | ForEach-Object { \$t=\$null; \$e=\$null; [System.Management.Automation.Language.Parser]::ParseFile(\$_.FullName, [ref]\$t, [ref]\$e); if(\$e.Count -gt 0){ Write-Error \"\$(\$_.Name): \$e\" } else { Write-Host \"OK: \$(\$_.Name)\" } }"
```

### Key Caveats

- All warnings from PSScriptAnalyzer about `Write-Host` are expected — these are interactive console scripts, not library modules.
- The `PSAvoidOverwritingBuiltInCmdlets` warning for `Write-Error` on the main script is a known intentional override.
- No automated tests exist in this repository; validation is done by running scripts on a Windows machine with Winget and Intune Content Prep Tool.
- There is no build step. The `.ps1` files are the deliverables.
