# Example usage script for Wingetter
# This file demonstrates various ways to use the Create-IntuneWinFromWinget.ps1 script

# Example 1: Basic usage with app name
Write-Host "Example 1: Basic usage" -ForegroundColor Cyan
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima"

# Example 2: With specific version
Write-Host "`nExample 2: With specific version" -ForegroundColor Cyan
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima" -Version "5.47.0"

# Example 3: With custom output path
Write-Host "`nExample 3: With custom output path" -ForegroundColor Cyan
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima" -OutputPath "C:\IntunePackages"

# Example 4: With custom icon
Write-Host "`nExample 4: With custom icon" -ForegroundColor Cyan
.\Create-IntuneWinFromWinget.ps1 -AppName "MaximaTeam.Maxima" -IconPath "D:\intoon in progress\Maxima\MaximaTeam.Maxima\logo.png"

# Example 5: Other popular applications
Write-Host "`nExample 5: Other applications" -ForegroundColor Cyan
# .\Create-IntuneWinFromWinget.ps1 -AppName "Google.Chrome"
# .\Create-IntuneWinFromWinget.ps1 -AppName "7zip.7zip"
# .\Create-IntuneWinFromWinget.ps1 -AppName "Mozilla.Firefox"
# .\Create-IntuneWinFromWinget.ps1 -AppName "Microsoft.VisualStudioCode"
