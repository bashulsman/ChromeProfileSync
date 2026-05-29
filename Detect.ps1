#Requires -Version 5.1
<#
.SYNOPSIS
    Chrome Profile Sync - Detection Script v4.1
    Detected (exit 0) when scripts exist in Program Files and the
    all-users Start Menu shortcut is present.

.NOTES
    Run context : System (admin) or User
    Version     : 4.1
#>

$ScriptsDir   = "$env:ProgramFiles\ChromeProfileSync"
$StartMenuDir = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonPrograms)
$ShortcutPath = "$StartMenuDir\Chrome Profile Sync.lnk"

$scriptsOK   = Test-Path (Join-Path $ScriptsDir 'Install.ps1')
$shortcutOK  = Test-Path $ShortcutPath

if ($scriptsOK -and $shortcutOK) {
    Write-Host "Detected: Chrome Profile Sync v4.1 is installed."
    exit 0
} else {
    if (-not $scriptsOK)  { Write-Host "Not detected: Install.ps1 not found in $ScriptsDir" }
    if (-not $shortcutOK) { Write-Host "Not detected: all-users Start Menu shortcut not found." }
    exit 1
}
