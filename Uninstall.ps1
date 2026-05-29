#Requires -Version 5.1
<#
.SYNOPSIS
    Chrome Profile Sync - Uninstall v4.1
    Removes scripts from Program Files and the all-users Start Menu shortcut.
    Runs as System (admin) via Intune.
    Chrome junctions are left intact (data remains safely in OneDrive).

.NOTES
    Run context : System (admin)
    Version     : 4.1
#>

$ErrorActionPreference = 'Stop'

$ScriptsDir   = "$env:ProgramFiles\ChromeProfileSync"
$StartMenuDir = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonPrograms)
$ShortcutPath = "$StartMenuDir\Chrome Profile Sync.lnk"
$LogDir       = "$env:ProgramData\Logs\ChromeProfileSync"
$LogFile      = "$LogDir\Uninstall_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

Write-Log "=== Chrome Profile Sync Uninstall v4.1 started ==="

# -- Remove Start Menu shortcut ------------------------------------------------
if (Test-Path $ShortcutPath) {
    Remove-Item -Path $ShortcutPath -Force -ErrorAction SilentlyContinue
    Write-Log "Start Menu shortcut removed."
} else {
    Write-Log "Start Menu shortcut not found (skipping)." 'WARN'
}

# -- Remove scripts from Program Files -----------------------------------------
if (Test-Path $ScriptsDir) {
    Remove-Item -Path $ScriptsDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Scripts folder removed: $ScriptsDir"
} else {
    Write-Log "Scripts folder not found (skipping)." 'WARN'
}

Write-Log "=== Uninstall complete. ==="
Write-Log "Note: Chrome junctions and OneDrive data are not affected."
Write-Log "      Users can still use Chrome normally - profiles remain in OneDrive."
exit 0
