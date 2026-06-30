# AGENTS.md

## Cursor Cloud specific instructions

### What this repo is
`Wingetter/` is a collection of **PowerShell scripts** (no compiled app, no package
manager, no service to "serve"). The main tool `Create-IntuneWinFromWinget.ps1`
builds Intune `.intunewin` packages from Winget apps. The tooling it ultimately
drives (`winget`, the Win32 Content Prep Tool / `intunewinapputil`, the Windows
registry, and `Microsoft.VisualBasic` InputBox dialogs) is **Windows-only**, so
the full package-creation flow cannot run end-to-end on the Linux cloud VM.

### Dev environment
- The dev "runtime" is **PowerShell 7+ (`pwsh`)**. It is installed by the update
  script from Microsoft's apt repo (the stock Ubuntu repo has no `powershell`
  package — installing it that way is why the default install fails).
- **PSScriptAnalyzer** (the linter) is installed for the current user by the
  update script.

### Lint / build / test commands (run from `Wingetter/`)
- **Lint:** `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse"`
  - Treat only `Error` severity as a failure; the scripts currently emit
    `Warning`/`Information` findings only (no errors).
- **Build (syntax/parse check)** — there is no compile step; validate by parsing:
  `pwsh -NoProfile -Command 'Get-ChildItem -Filter *.ps1 | ForEach-Object { $t=$null;$e=$null; [System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e)|Out-Null; if($e.Count){throw $_.Name} }'`
- **Test:** there is no test framework in the repo. To exercise pure logic on
  Linux, extract a single function via the AST and invoke it (the main script
  body cannot be dot-sourced directly because it runs Windows-only Step code at
  load time). Example pattern used during setup is in `/tmp/hello_world_test.ps1`:
  parse the file, `FindAll` the `Select-WingetPackage` `FunctionDefinitionAst`,
  `[ScriptBlock]::Create(...)` it, then call it with mock `winget search` text.

### Gotchas
- Do **not** dot-source `Create-IntuneWinFromWinget.ps1` to test it — everything
  after line ~257 is top-level execution (`winget` search/download, registry
  detection, packaging) that fails off-Windows. Extract individual functions.
- `Select-WingetPackage`'s multi-match path pops a `Microsoft.VisualBasic`
  InputBox (GUI) and will hang/fail headless; the single-match path returns
  directly and is safe to test.
- Running the actual `.intunewin` creation requires Windows + `winget` +
  `intunewinapputil`; demonstrate Linux-side correctness with the parser/lint/parse
  checks above instead.
