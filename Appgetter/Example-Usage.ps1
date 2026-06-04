# Example usage script for Appgetter
# Default output: D:\intoon in progress\Appgetter

# Example 1: Basic usage with app name
Write-Host "Example 1: Basic usage" -ForegroundColor Cyan
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima"

# Example 2: With specific version
Write-Host "`nExample 2: With specific version" -ForegroundColor Cyan
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima" -Version "5.47.0"

# Example 3: Explicit Appgetter output path (same as default)
Write-Host "`nExample 3: With Appgetter output path" -ForegroundColor Cyan
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima" -OutputPath "D:\intoon in progress\Appgetter"

# Example 4: With custom icon
Write-Host "`nExample 4: With custom icon" -ForegroundColor Cyan
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima" -IconPath "D:\intoon in progress\Appgetter\Maxima\MaximaTeam.Maxima\logo.png"
