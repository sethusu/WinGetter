@echo off
REM Double-click helper for the source tree (no build required).
REM For a packaged Wingetter.exe, run: .\Build\Build-WingetterExe.ps1
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Launch-Wingetter.ps1"
