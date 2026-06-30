# Wingetter Example Usage

# Launch the graphical interface (recommended)
.\Create-IntuneWinFromWinget.ps1 -Gui
# or directly:
.\Show-WingetterGui.ps1

# Interactive CLI mode
.\Create-IntuneWinFromWinget.ps1

# Command line with package ID
.\Create-IntuneWinFromWinget.ps1 -AppName "Google.Chrome"

# With specific version and output path
.\Create-IntuneWinFromWinget.ps1 -AppName "7zip.7zip" -Version "24.09" -OutputPath "C:\IntunePackages"

# With custom icon
.\Create-IntuneWinFromWinget.ps1 -AppName "JetBrains.WebStorm" -IconPath "C:\Icons\webstorm.png"
