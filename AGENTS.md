# AGENTS.md

## Project overview

Wingetter is a Windows PowerShell tool that builds Intune Win32 (`.intunewin`) packages from Winget applications. It must run on Windows with Winget and the Microsoft Win32 Content Prep Tool installed.

## Repository layout

- `Wingetter/Create-IntuneWinFromWinget.ps1` — main CLI entry point
- `Wingetter/Modules/WingetSearch.psm1` — winget search/show parsing
- `Wingetter/Modules/ScriptTemplates.psm1` — install/detection/uninstall script generation
- `Wingetter/Tests/` — Pester tests with fixture files
- `Wingetter/Run-Tests.ps1` — test runner

## Development notes for cloud agents

- This project targets **Windows PowerShell 5.1+** and **PowerShell 7+**. Cloud Linux VMs can run parser/unit tests with `pwsh`, but end-to-end packaging requires Windows, Winget, and `intunewinapputil`.
- Run tests: `pwsh ./Wingetter/Run-Tests.ps1`
- Do not add multiple parallel GUI implementations. Keep one CLI path and one module structure.
- Detection scripts must use `[PSCustomObject]` (not hashtables) when sorting registry matches — hashtable dot-notation breaks version detection.
- `winget download` must pass `--version` when a specific version is requested.
- Intune install/uninstall commands should invoke `install.ps1` / `uninstall.ps1` via `%windir%\sysnative\windowspowershell\v1.0\powershell.exe`.

## Prerequisites (Windows)

1. Windows Package Manager (`winget`)
2. Microsoft Win32 Content Prep Tool (`intunewinapputil` in PATH)
3. PowerShell 5.1 or later

## Common failure modes

| Symptom | Likely cause | Fix |
|--------|--------------|-----|
| Winget search finds nothing | Fragile table parsing or truncated IDs | Use `WingetSearch.psm1`; pass exact package ID |
| Wrong version downloaded | Missing `--version` on `winget download` | Pass version to download helper |
| Detection exits 1 after install | Hashtable property access or build-number versions | Use `ScriptTemplates.psm1` detection script |
| Download falsely reported as failed | Over-broad error string matching | Check for real winget failure phrases only |
