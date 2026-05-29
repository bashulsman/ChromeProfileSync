#Requires -Version 5.1
<#
.SYNOPSIS
    Chrome Profile Sync v5.0
    Backup Chrome profiles to OneDrive and restore them on a new machine.
    No junctions - profiles are copied directly so Chrome reads 100% local files.

.PARAMETER Setup
    Intune deployment mode (System/admin): copies scripts to Program Files
    and creates an All Users Start Menu shortcut. Does NOT start the UI.

.NOTES
    Run context : Setup = System (admin)   |   Normal = User
    Author      : b.hulsman
    Version     : 5.0

    Intune install:
        Install behavior : System
        Install command  : powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File Install.ps1 -Setup
        Uninstall command: powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -Command "& (Join-Path $Env:ProgramFiles 'ChromeProfileSync\Uninstall.ps1')"
#>

param([switch]$Setup)

$ErrorActionPreference = 'Stop'

# -- Paths ---------------------------------------------------------------------
$ScriptsDir      = "$env:ProgramFiles\ChromeProfileSync"
$StartMenuDir    = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonPrograms)
$ShortcutPath    = "$StartMenuDir\Chrome Profile Sync.lnk"
$UserDataDir     = "$env:LOCALAPPDATA\ChromeProfileSync"
$ConfigFile      = "$UserDataDir\config.json"
$LogDir          = "$env:LOCALAPPDATA\Logs\ChromeProfileSync"
$LogFile         = "$LogDir\ChromeProfileSync_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$AppName         = 'Chrome Profile Sync'
$AppVersion      = '5.0'
$CacheDirs       = @('Cache', 'Code Cache', 'GPUCache', 'ShaderCache')
$ChromeUserData  = "$env:LOCALAPPDATA\Google\Chrome\User Data"
$ExcludedFolders = @('System Profile', 'Guest Profile')

# Directories skipped during backup (temp/cache/regeneratable).
# Passed to robocopy /XD so local data is never deleted - only excluded from the copy.
$BackupExcludeDirs = @(
    'Cache'                                  # Main browser cache        (pre-cleared too)
    'Code Cache'                             # Compiled JS/WASM cache    (pre-cleared too)
    'GPUCache'                               # GPU shader cache          (pre-cleared too)
    'ShaderCache'                            # Shader cache              (pre-cleared too)
    'DawnCache'                              # WebGPU cache
    'CacheStorage'                           # Service Worker cache storage
    'ScriptCache'                            # Compiled service worker scripts
    'blob_storage'                           # Temporary blob data
    'Safe Browsing'                          # Safe Browsing DB (300+ MB, regenerates)
    'Safe Browsing Extended Reporting'       # Safe Browsing reporting data
    'Thumbnails'                             # Page thumbnail cache
    'VideoDecodeStats'                       # Video performance stats
    'Crash Reports'                          # Crash report files
    'crashpad'                               # Crash reporter metadata
    'optimization_guide_hint_cache_leveldb'  # Optimization hints cache
    'BudgetDatabase'                         # Site engagement budget
    'Feature Engagement Tracker'             # UI feature usage tracking
    'heavy_ad_intervention_opt_out.db'       # Heavy ad intervention data
    'GCM Store'                              # Google Cloud Messaging store
)

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

# -- OneDrive resolution -------------------------------------------------------
function Get-CurrentUpn {
    if ($env:USERPRINCIPALNAME -and $env:USERPRINCIPALNAME -match '@') { return $env:USERPRINCIPALNAME }
    try { $r = & whoami /upn 2>$null; if ($r -match '@') { return $r.Trim() } } catch {}
    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
        return [System.DirectoryServices.AccountManagement.UserPrincipal]::Current.UserPrincipalName
    } catch {}
    return $null
}

function Get-OneDriveAccounts {
    $result = @()
    $keys = Get-ChildItem 'HKCU:\SOFTWARE\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue
    foreach ($k in $keys) {
        $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if ($p.UserFolder -and (Test-Path $p.UserFolder)) {
            $result += [PSCustomObject]@{ Email = $p.UserEmail; Folder = $p.UserFolder; IsBusiness = ($k.PSChildName -like 'Business*') }
        }
    }
    return $result
}

function Get-OneDrivePath {
    $upn      = Get-CurrentUpn
    $accounts = Get-OneDriveAccounts
    Write-Log "UPN: $upn  OneDrive accounts: $($accounts.Count)"
    if (Test-Path $ConfigFile) {
        try {
            $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            if ($cfg.Folder -and (Test-Path $cfg.Folder)) {
                Write-Log "Using saved config: $($cfg.Email)"
                return [PSCustomObject]@{ Folder = $cfg.Folder; Email = $cfg.Email; Accounts = $accounts; Upn = $upn }
            }
        } catch {}
    }
    if ($upn) {
        $m = $accounts | Where-Object { $_.Email -ieq $upn } | Select-Object -First 1
        if ($m) { return [PSCustomObject]@{ Folder = $m.Folder; Email = $m.Email; Accounts = $accounts; Upn = $upn } }
    }
    if ($accounts.Count -eq 1) {
        return [PSCustomObject]@{ Folder = $accounts[0].Folder; Email = $accounts[0].Email; Accounts = $accounts; Upn = $upn }
    }
    return [PSCustomObject]@{ Folder = $null; Email = $null; Accounts = $accounts; Upn = $upn }
}

function Save-OneDriveConfig {
    param([string]$Email, [string]$Folder)
    New-Item -ItemType Directory -Path $UserDataDir -Force | Out-Null
    @{ Email = $Email; Folder = $Folder; SavedAt = (Get-Date -Format 'o') } |
        ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
}

# -- Chrome helpers ------------------------------------------------------------
function Get-ChromeProfileFolders {
    param([string]$UserDataPath)
    if (-not (Test-Path $UserDataPath)) { return @() }
    Get-ChildItem -Path $UserDataPath -Directory -ErrorAction SilentlyContinue | Where-Object {
        $name = $_.Name
        if ($name -in $ExcludedFolders) { return $false }
        if (Test-Path (Join-Path $_.FullName 'Preferences')) { return $true }
        if ($name -eq 'Default' -or $name -match '^Profile \d+$') { return $true }
        return $false
    }
}

function Get-ProfileDisplayName {
    param([string]$ProfilePath)
    $f = Join-Path $ProfilePath 'Preferences'
    if (-not (Test-Path $f)) { return '' }
    try {
        $prefs    = Get-Content $f -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $gaia     = $prefs.profile.gaia_name
        $uname    = $prefs.profile.user_name
        $acct     = $prefs.account_info | Select-Object -First 1
        $fullName = if ($acct) { $acct.full_name } else { '' }
        $email    = if ($acct) { $acct.email } else { '' }
        if (-not $email -and $uname -match '@') { $email = $uname }
        if ($gaia -and $gaia -ne '')            { return if ($email) { "$gaia  ($email)" } else { $gaia } }
        if ($fullName -and $fullName -ne '')     { return if ($email) { "$fullName  ($email)" } else { $fullName } }
        if ($email -and $email -ne '')           { return $email }
        $pName = $prefs.profile.name
        return if ($pName) { $pName } else { '' }
    } catch { return '' }
}

function Get-FolderSizeBytes {
    param([string]$Path)
    try {
        return (Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
    } catch { return 0 }
}

function Format-GB { param([long]$Bytes) return "$([math]::Round($Bytes / 1GB, 2)) GB" }

# -- Chrome Local State repair ------------------------------------------------
# Ensures all profile folders are registered in Chrome's profile registry.
# Chrome sometimes removes profiles it can't validate; this adds them back.
# Uses the profile folder name (e.g. "Profile 14") when the stored name is
# the generic "Person 1" default, so each profile has a unique identifier.
function Repair-ChromeLocalState {
    param([string]$ChromeUserDataPath)
    $lsp = Join-Path $ChromeUserDataPath 'Local State'
    if (-not (Test-Path $lsp)) { Write-Log "Local State not found - cannot repair." 'WARN'; return }
    try {
        $json = Get-Content $lsp -Raw -Encoding UTF8 | ConvertFrom-Json
        $known = @($json.profile.info_cache.PSObject.Properties.Name)
        Write-Log "Local State has $($known.Count) profile(s): $($known -join ', ')"
        $dirs  = Get-ChromeProfileFolders -UserDataPath $ChromeUserDataPath
        Write-Log "Profile folders on disk: $($dirs.Count)"
        $changed = 0

        foreach ($p in $dirs) {
            # Helper: read a meaningful name for this profile
            $dn = $p.Name; $gn = ''   # folder name is always the fallback
            $pf = Join-Path $p.FullName 'Preferences'
            if (Test-Path $pf) {
                try {
                    $pr = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json
                    # Only use profile.name if it's actually meaningful
                    $raw = $pr.profile.name
                    if ($raw -and $raw -ne '' -and $raw -ne 'Person 1') { $dn = $raw }
                    if ($pr.profile.gaia_name -and $pr.profile.gaia_name -ne '') { $gn = $pr.profile.gaia_name }
                } catch {}
            }

            if ($p.Name -notin $known) {
                # Profile missing from Local State - add it
                $entry = [PSCustomObject]@{ name = $dn; gaia_name = $gn; is_using_default_name = $false; avatar_index = 0; background_apps = $false }
                $json.profile.info_cache | Add-Member -NotePropertyName $p.Name -NotePropertyValue $entry -Force
                Write-Log "  Added: $($p.Name) -> '$dn'"
                $changed++
            } else {
                # Profile exists - fix generic "Person 1" name to use folder name
                $curName = $json.profile.info_cache.($p.Name).name
                if ($curName -eq 'Person 1' -or $curName -eq '') {
                    $json.profile.info_cache.($p.Name).name = $dn
                    Write-Log "  Renamed: $($p.Name) 'Person 1' -> '$dn'"
                    $changed++
                }
            }
        }

        if ($changed -gt 0) {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($lsp, ($json | ConvertTo-Json -Depth 50), $utf8NoBom)
            Write-Log "Local State repaired: $changed profile(s) updated."
        } else {
            Write-Log "Local State already has all profiles with valid names."
        }
    } catch { Write-Log "Repair-ChromeLocalState error: $_" 'WARN' }
}

# -- Close Chrome --------------------------------------------------------------
function Stop-ChromeSilently {
    $chrome = Get-Process -Name chrome -ErrorAction SilentlyContinue
    if (-not $chrome) { Write-Log "Chrome not running."; return }

    Write-Log "Closing Chrome gracefully..."
    $chrome | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    Start-Sleep -Seconds 4

    # Only call taskkill if Chrome is STILL running after the graceful close.
    # Calling taskkill when Chrome is already gone causes a non-zero exit code
    # which PowerShell treats as a terminating error under $ErrorActionPreference=Stop.
    $still = Get-Process -Name chrome -ErrorAction SilentlyContinue
    if ($still) {
        Write-Log "Chrome still running - force killing..."
        try {
            & "$env:SystemRoot\System32\taskkill.exe" /F /IM chrome.exe /T 2>$null | Out-Null
        } catch {
            Write-Log "taskkill error (continuing): $_" 'WARN'
        }
        Start-Sleep -Seconds 2
        # Final fallback
        Get-Process -Name chrome -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Write-Log "Chrome closed."
}

# -- Progress UI helpers -------------------------------------------------------
function Set-Step {
    param([System.Windows.Forms.Label]$L, [string]$Text, [System.Drawing.Color]$Color)
    $L.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $L.ForeColor = $Color; $L.Text = $Text
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-Progress {
    param([System.Windows.Forms.ProgressBar]$Bar, [System.Windows.Forms.Label]$Lbl,
          [long]$Done, [long]$Total, [int]$ProfDone, [int]$ProfTotal)
    $pct = if ($Total -gt 0) { [math]::Min(100, [int]($Done * 100 / $Total)) } else { 100 }
    $Bar.Value = $pct
    $Lbl.Text  = "$(Format-GB $Done) of $(Format-GB $Total)   ($ProfDone of $ProfTotal profiles)"
    [System.Windows.Forms.Application]::DoEvents()
}

# -- SAVE TO ONEDRIVE ----------------------------------------------------------
# Copies profiles to OneDrive backup folder. Local profiles remain intact.
# Chrome keeps reading from local disk - no junctions, no cloud-only issues.
function Invoke-SaveToOneDrive {
    param([string]$OneDriveTarget,
          [System.Windows.Forms.Label]$StatusLabel,
          [System.Windows.Forms.ProgressBar]$ProgressBar,
          [System.Windows.Forms.Label]$ProgressLabel)
    Write-Log "=== Save to OneDrive: $OneDriveTarget ==="
    $blue = [System.Drawing.Color]::FromArgb(0, 120, 212)

    Set-Step -L $StatusLabel -Text 'Step 1/3  -  Closing Chrome...' -Color $blue
    Stop-ChromeSilently

    Set-Step -L $StatusLabel -Text 'Step 2/3  -  Clearing caches and measuring profiles...' -Color $blue
    $ProgressLabel.Text = 'Calculating...'; [System.Windows.Forms.Application]::DoEvents()

    New-Item -ItemType Directory -Path $OneDriveTarget -Force | Out-Null
    $profiles = Get-ChromeProfileFolders -UserDataPath $ChromeUserData

    # Clear cache folders before measuring/copying to reduce upload size
    foreach ($p in $profiles) {
        foreach ($c in $CacheDirs) {
            $cp = Join-Path $p.FullName $c
            if (Test-Path $cp) { Remove-Item -Path $cp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    # Measure what needs copying
    $profileSizes = [ordered]@{}
    $totalBytes   = 0L
    foreach ($p in $profiles) {
        $sz = Get-FolderSizeBytes -Path $p.FullName
        $profileSizes[$p.Name] = $sz; $totalBytes += $sz
        $ProgressLabel.Text = "Measured: $($p.Name)"
        [System.Windows.Forms.Application]::DoEvents()
    }
    $rootBytes  = (Get-ChildItem -Path $ChromeUserData -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    $totalBytes += $rootBytes
    Write-Log "Total to copy: $(Format-GB $totalBytes) across $($profiles.Count) profiles"

    Set-Step -L $StatusLabel -Text "Step 3/3  -  Copying $(Format-GB $totalBytes) to OneDrive..." -Color $blue
    $robolog      = "$LogDir\robocopy_save_$(Get-Date -Format 'yyyyMMddHHmmss').log"
    $copiedBytes  = 0L
    $profsDone    = 0

    # Root files first (Local State, etc.) - /LEV:1 = only root level
    & robocopy $ChromeUserData $OneDriveTarget /LEV:1 /COPY:DAT /XJ /R:2 /W:3 /NP /LOG+:$robolog /XD @BackupExcludeDirs | Out-Null
    $copiedBytes += $rootBytes

    foreach ($p in $profiles) {
        Set-Step -L $StatusLabel -Text "Step 3/3  -  Copying profile: $($p.Name)..." -Color $blue
        $src = $p.FullName; $dst = Join-Path $OneDriveTarget $p.Name
        & robocopy $src $dst /E /COPY:DAT /XJ /R:2 /W:3 /NP /LOG+:$robolog /XD @BackupExcludeDirs | Out-Null
        $copiedBytes += $profileSizes[$p.Name]; $profsDone++
        Update-Progress -Bar $ProgressBar -Lbl $ProgressLabel -Done $copiedBytes -Total $totalBytes -ProfDone $profsDone -ProfTotal $profiles.Count
        Write-Log "Copied: $($p.Name) ($(Format-GB $profileSizes[$p.Name]))"
    }

    $ProgressBar.Value  = 100
    $ProgressLabel.Text = "$($profiles.Count) profiles backed up to OneDrive"
    Write-Log "=== Save complete. Local profiles unchanged. ==="
    return $true
}

# -- RESTORE FROM ONEDRIVE -----------------------------------------------------
# Copies profiles FROM OneDrive to local disk. After this Chrome reads 100%
# local files - no junctions, no cloud-only issues, no sync dependency.
function Invoke-RestoreFromOneDrive {
    param([string]$OneDriveTarget,
          [System.Windows.Forms.Label]$StatusLabel,
          [System.Windows.Forms.ProgressBar]$ProgressBar,
          [System.Windows.Forms.Label]$ProgressLabel)
    Write-Log "=== Restore from OneDrive: $OneDriveTarget ==="
    if (-not (Test-Path $OneDriveTarget)) { Write-Log "Source not found." 'ERROR'; return $false }

    $blue = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $ProgressBar.Value = 0; $ProgressLabel.Text = ''

    # Step 1: close Chrome
    Set-Step -L $StatusLabel -Text 'Step 1/4  -  Closing Chrome...' -Color $blue
    $ProgressBar.Value = 5; [System.Windows.Forms.Application]::DoEvents()
    Stop-ChromeSilently

    # Step 2: back up existing local User Data
    if (Test-Path $ChromeUserData) {
        Set-Step -L $StatusLabel -Text 'Step 2/4  -  Backing up existing local profiles...' -Color $blue
        $ProgressBar.Value = 15; [System.Windows.Forms.Application]::DoEvents()
        $bak = "$ChromeUserData.bak_$(Get-Date -Format 'yyyyMMddHHmmss')"
        Rename-Item -Path $ChromeUserData -NewName $bak
        Write-Log "Backed up existing local data to: $bak"
    }

    # Step 3: measure then copy from OneDrive to local disk
    $cloudProfiles = Get-ChromeProfileFolders -UserDataPath $OneDriveTarget
    Write-Log "Profiles in OneDrive: $($cloudProfiles.Count)"

    Set-Step -L $StatusLabel -Text 'Step 3/4  -  Measuring OneDrive profiles...' -Color $blue
    $ProgressBar.Value = 20; [System.Windows.Forms.Application]::DoEvents()
    $profileSizes = [ordered]@{}
    $totalBytes   = 0L
    foreach ($p in $cloudProfiles) {
        $sz = Get-FolderSizeBytes -Path $p.FullName
        $profileSizes[$p.Name] = $sz; $totalBytes += $sz
        $ProgressLabel.Text = "Measured: $($p.Name)"
        [System.Windows.Forms.Application]::DoEvents()
    }
    $rootBytes  = (Get-ChildItem -Path $OneDriveTarget -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    $totalBytes += $rootBytes

    Set-Step -L $StatusLabel -Text "Step 3/4  -  Copying $(Format-GB $totalBytes) to local disk..." -Color $blue
    New-Item -ItemType Directory -Path $ChromeUserData -Force | Out-Null
    $robolog     = "$LogDir\robocopy_restore_$(Get-Date -Format 'yyyyMMddHHmmss').log"
    $copiedBytes = 0L; $profsDone = 0

    # Root files first (Local State, First Run, etc.)
    & robocopy $OneDriveTarget $ChromeUserData /LEV:1 /COPY:DAT /XJ /R:2 /W:3 /NP /LOG+:$robolog | Out-Null
    $copiedBytes += $rootBytes
    Update-Progress -Bar $ProgressBar -Lbl $ProgressLabel -Done $copiedBytes -Total $totalBytes -ProfDone 0 -ProfTotal $cloudProfiles.Count

    foreach ($p in $cloudProfiles) {
        Set-Step -L $StatusLabel -Text "Step 3/4  -  Copying: $($p.Name)..." -Color $blue
        $src = $p.FullName; $dst = Join-Path $ChromeUserData $p.Name
        & robocopy $src $dst /E /COPY:DAT /XJ /R:2 /W:3 /NP /LOG+:$robolog | Out-Null
        $copiedBytes += $profileSizes[$p.Name]; $profsDone++
        Update-Progress -Bar $ProgressBar -Lbl $ProgressLabel -Done $copiedBytes -Total $totalBytes -ProfDone $profsDone -ProfTotal $cloudProfiles.Count
        Write-Log "Restored: $($p.Name) ($(Format-GB $profileSizes[$p.Name]))"
    }
    $ProgressBar.Value = 95

    # Step 4: repair Local State so Chrome sees all profiles
    Set-Step -L $StatusLabel -Text 'Step 4/4  -  Repairing Chrome profile registry...' -Color $blue
    [System.Windows.Forms.Application]::DoEvents()
    Repair-ChromeLocalState -ChromeUserDataPath $ChromeUserData

    $ProgressBar.Value  = 100
    $ProgressLabel.Text = "All $($cloudProfiles.Count) profiles restored to local disk"
    Write-Log "=== Restore complete. All profiles are 100% local. Chrome can now open. ==="
    return $true
}

# -- OneDrive selector dialog --------------------------------------------------
function Show-OneDriveSelector {
    param([array]$Accounts, [string]$CurrentUpn)
    Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $AppName; $form.ClientSize = New-Object System.Drawing.Size(520,380)
    $form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false; $form.BackColor = [System.Drawing.Color]::White
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $pnl = New-Object System.Windows.Forms.Panel
    $pnl.Dock = 'Top'; $pnl.Height = 64; $pnl.BackColor = [System.Drawing.Color]::FromArgb(0,120,212)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Select OneDrive Account'; $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 14)
    $lbl.Location = New-Object System.Drawing.Point(16,16); $lbl.AutoSize = $true
    $pnl.Controls.Add($lbl); $form.Controls.Add($pnl)
    $upnText = if ($CurrentUpn) { "`"$CurrentUpn`"" } else { 'your account' }
    $li = New-Object System.Windows.Forms.Label
    $li.Text = "The account $upnText was not found.`nSelect which OneDrive to use:"
    $li.Location = New-Object System.Drawing.Point(16,80); $li.Size = New-Object System.Drawing.Size(488,40)
    $form.Controls.Add($li)
    $pA = New-Object System.Windows.Forms.Panel
    $pA.Location = New-Object System.Drawing.Point(16,126); $pA.Size = New-Object System.Drawing.Size(488,190)
    $pA.AutoScroll = $true; $pA.BorderStyle = 'FixedSingle'
    $pA.BackColor = [System.Drawing.Color]::FromArgb(250,250,250); $form.Controls.Add($pA)
    $radios = @(); $y = 10
    foreach ($acct in $Accounts) {
        $rb = New-Object System.Windows.Forms.RadioButton
        $rb.Text = "$($acct.Email)`n$($acct.Folder)"
        $rb.Location = New-Object System.Drawing.Point(8,$y); $rb.Size = New-Object System.Drawing.Size(466,50)
        $rb.Tag = $acct; $pA.Controls.Add($rb); $radios += $rb; $y += 58
    }
    $bOK = New-Object System.Windows.Forms.Button
    $bOK.Text = 'Use this OneDrive'; $bOK.Size = New-Object System.Drawing.Size(148,32)
    $bOK.Location = New-Object System.Drawing.Point(356,332)
    $bOK.BackColor = [System.Drawing.Color]::FromArgb(0,120,212); $bOK.ForeColor = [System.Drawing.Color]::White
    $bOK.FlatStyle = 'Flat'; $bOK.FlatAppearance.BorderSize = 0
    $bOK.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Controls.Add($bOK)
    $bNo = New-Object System.Windows.Forms.Button
    $bNo.Text = 'Cancel'; $bNo.Size = New-Object System.Drawing.Size(80,32)
    $bNo.Location = New-Object System.Drawing.Point(268,332)
    $bNo.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Controls.Add($bNo)
    $form.CancelButton = $bNo
    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $sel = $radios | Where-Object { $_.Checked } | Select-Object -First 1
        if ($sel) { return $sel.Tag }
    }
    return $null
}

# -- Main dialog ---------------------------------------------------------------
function Show-MainDialog {
    param([PSCustomObject]$OdInfo)
    Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing

    $odFolder = $OdInfo.Folder
    if (-not $odFolder -and $OdInfo.Accounts.Count -gt 1) {
        $sel = Show-OneDriveSelector -Accounts $OdInfo.Accounts -CurrentUpn $OdInfo.Upn
        if ($sel) { Save-OneDriveConfig -Email $sel.Email -Folder $sel.Folder; $odFolder = $sel.Folder }
    }
    $odTarget = if ($odFolder) { "$odFolder\ChromeProfileBackup" } else { $null }

    # -- Form ------------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $AppName; $form.ClientSize = New-Object System.Drawing.Size(780,610)
    $form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false; $form.BackColor = [System.Drawing.Color]::White
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $pnlHdr = New-Object System.Windows.Forms.Panel
    $pnlHdr.Dock = 'Top'; $pnlHdr.Height = 64; $pnlHdr.BackColor = [System.Drawing.Color]::FromArgb(0,120,212)
    $lblHdr = New-Object System.Windows.Forms.Label
    $lblHdr.Text = "$AppName  v$AppVersion"; $lblHdr.ForeColor = [System.Drawing.Color]::White
    $lblHdr.Font = New-Object System.Drawing.Font('Segoe UI', 14)
    $lblHdr.Location = New-Object System.Drawing.Point(16,16); $lblHdr.AutoSize = $true
    $pnlHdr.Controls.Add($lblHdr); $form.Controls.Add($pnlHdr)

    $odText = if ($odFolder) { "OneDrive:  $($OdInfo.Email)   |   $odFolder" } else { "OneDrive: not configured" }
    $lblOD = New-Object System.Windows.Forms.Label
    $lblOD.Text = $odText; $lblOD.Location = New-Object System.Drawing.Point(16,74)
    $lblOD.Size = New-Object System.Drawing.Size(748,18); $lblOD.ForeColor = [System.Drawing.Color]::FromArgb(70,70,70)
    $form.Controls.Add($lblOD)

    function Make-ColHdr { param([string]$T, [int]$X)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $T; $l.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $l.ForeColor = [System.Drawing.Color]::FromArgb(0,120,212)
        $l.Location = New-Object System.Drawing.Point($X,102); $l.AutoSize = $true; return $l
    }
    $form.Controls.Add((Make-ColHdr -T 'LOCAL PROFILES' -X 16))
    $form.Controls.Add((Make-ColHdr -T 'ONEDRIVE BACKUP' -X 406))

    $lblOdPath = New-Object System.Windows.Forms.Label
    $lblOdPath.Text = if ($odTarget) { $odTarget } else { '(not configured)' }
    $lblOdPath.Location = New-Object System.Drawing.Point(406,118); $lblOdPath.Size = New-Object System.Drawing.Size(290,16)
    $lblOdPath.ForeColor = [System.Drawing.Color]::FromArgb(120,120,120)
    $lblOdPath.Font = New-Object System.Drawing.Font('Segoe UI', 7); $form.Controls.Add($lblOdPath)

    $btnBrowseOD = New-Object System.Windows.Forms.Button
    $btnBrowseOD.Text = 'Browse...'; $btnBrowseOD.Size = New-Object System.Drawing.Size(66,18)
    $btnBrowseOD.Location = New-Object System.Drawing.Point(698,116)
    $btnBrowseOD.FlatStyle = 'Flat'; $btnBrowseOD.Font = New-Object System.Drawing.Font('Segoe UI', 7)
    $form.Controls.Add($btnBrowseOD)

    $lstLocal = New-Object System.Windows.Forms.ListBox
    $lstLocal.Location = New-Object System.Drawing.Point(16,122); $lstLocal.Size = New-Object System.Drawing.Size(374,260)
    $lstLocal.BorderStyle = 'FixedSingle'; $lstLocal.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $lstLocal.HorizontalScrollbar = $true; $form.Controls.Add($lstLocal)

    $lstCloud = New-Object System.Windows.Forms.ListBox
    $lstCloud.Location = New-Object System.Drawing.Point(398,137); $lstCloud.Size = New-Object System.Drawing.Size(366,245)
    $lstCloud.BorderStyle = 'FixedSingle'; $lstCloud.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $lstCloud.HorizontalScrollbar = $true; $form.Controls.Add($lstCloud)

    $div = New-Object System.Windows.Forms.Label
    $div.BorderStyle = 'Fixed3D'; $div.Location = New-Object System.Drawing.Point(0,394)
    $div.Size = New-Object System.Drawing.Size(780,2); $form.Controls.Add($div)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'Backup to OneDrive'; $btnSave.Size = New-Object System.Drawing.Size(210,44)
    $btnSave.Location = New-Object System.Drawing.Point(16,406)
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(0,120,212); $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.FlatStyle = 'Flat'; $btnSave.FlatAppearance.BorderSize = 0
    $btnSave.Font = New-Object System.Drawing.Font('Segoe UI', 10); $form.Controls.Add($btnSave)

    $lblSave = New-Object System.Windows.Forms.Label
    $lblSave.Text = "Copy local profiles to OneDrive.`nChrome stays on local disk. Use on old machine."
    $lblSave.Location = New-Object System.Drawing.Point(16,458); $lblSave.Size = New-Object System.Drawing.Size(230,36)
    $lblSave.ForeColor = [System.Drawing.Color]::FromArgb(100,100,100); $form.Controls.Add($lblSave)

    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = 'Restore from OneDrive'; $btnRestore.Size = New-Object System.Drawing.Size(210,44)
    $btnRestore.Location = New-Object System.Drawing.Point(252,406)
    $btnRestore.BackColor = [System.Drawing.Color]::FromArgb(16,124,16); $btnRestore.ForeColor = [System.Drawing.Color]::White
    $btnRestore.FlatStyle = 'Flat'; $btnRestore.FlatAppearance.BorderSize = 0
    $btnRestore.Font = New-Object System.Drawing.Font('Segoe UI', 10); $form.Controls.Add($btnRestore)

    $lblRestore = New-Object System.Windows.Forms.Label
    $lblRestore.Text = "Copy profiles from OneDrive to local disk.`nUse on new or reinstalled machine."
    $lblRestore.Location = New-Object System.Drawing.Point(252,458); $lblRestore.Size = New-Object System.Drawing.Size(200,36)
    $lblRestore.ForeColor = [System.Drawing.Color]::FromArgb(100,100,100); $form.Controls.Add($lblRestore)

    $btnReset = New-Object System.Windows.Forms.Button
    $btnReset.Text = 'Reset & Restore'; $btnReset.Size = New-Object System.Drawing.Size(170,44)
    $btnReset.Location = New-Object System.Drawing.Point(478,406)
    $btnReset.BackColor = [System.Drawing.Color]::FromArgb(200,80,0); $btnReset.ForeColor = [System.Drawing.Color]::White
    $btnReset.FlatStyle = 'Flat'; $btnReset.FlatAppearance.BorderSize = 0
    $btnReset.Font = New-Object System.Drawing.Font('Segoe UI', 10); $form.Controls.Add($btnReset)

    $lblReset = New-Object System.Windows.Forms.Label
    $lblReset.Text = "Wipe broken local Chrome data`nand restore from OneDrive backup."
    $lblReset.Location = New-Object System.Drawing.Point(478,458); $lblReset.Size = New-Object System.Drawing.Size(178,36)
    $lblReset.ForeColor = [System.Drawing.Color]::FromArgb(100,100,100); $form.Controls.Add($lblReset)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Close'; $btnClose.Size = New-Object System.Drawing.Size(80,44)
    $btnClose.Location = New-Object System.Drawing.Point(664,406)
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Controls.Add($btnClose)
    $form.CancelButton = $btnClose

    $lblProgDetail = New-Object System.Windows.Forms.Label
    $lblProgDetail.Text = ''; $lblProgDetail.Location = New-Object System.Drawing.Point(16,504)
    $lblProgDetail.Size = New-Object System.Drawing.Size(748,18)
    $lblProgDetail.ForeColor = [System.Drawing.Color]::FromArgb(0,120,212)
    $lblProgDetail.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $lblProgDetail.Visible = $false; $form.Controls.Add($lblProgDetail)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(16,526); $progressBar.Size = New-Object System.Drawing.Size(748,22)
    $progressBar.Minimum = 0; $progressBar.Maximum = 100; $progressBar.Value = 0
    $progressBar.Style = 'Continuous'; $progressBar.Visible = $false; $form.Controls.Add($progressBar)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = 'Ready.'; $lblStatus.Location = New-Object System.Drawing.Point(16,558)
    $lblStatus.Size = New-Object System.Drawing.Size(748,22); $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(80,80,80)
    $form.Controls.Add($lblStatus)

    # -- Profile lists ---------------------------------------------------------
    function Update-Lists {
        $lstLocal.Items.Clear(); $lstCloud.Items.Clear()
        $localProfiles = Get-ChromeProfileFolders -UserDataPath $ChromeUserData
        if ($localProfiles.Count -eq 0) {
            $lstLocal.Items.Add('(no local profiles found)')
        } else {
            foreach ($p in $localProfiles) {
                $dn  = Get-ProfileDisplayName -ProfilePath $p.FullName
                $hasBackup = $odTarget -and (Test-Path (Join-Path $odTarget $p.Name))
                $tag = if ($hasBackup) { '[Backed Up]' } else { '[Local]' }
                $row = if ($dn) { "$tag  $dn" } else { "$tag  $($p.Name)" }
                $lstLocal.Items.Add($row)
            }
        }
        if (-not $odTarget) {
            $lstCloud.Items.Add('(OneDrive not configured)')
        } elseif (-not (Test-Path $odTarget)) {
            $lstCloud.Items.Add('(no backup found)')
            $lstCloud.Items.Add('')
            $lstCloud.Items.Add("Checked: $odTarget")
            $lstCloud.Items.Add('')
            $lstCloud.Items.Add('Run Backup to OneDrive on your')
            $lstCloud.Items.Add('old machine first, or use Browse...')
        } else {
            $cloudProfiles = Get-ChromeProfileFolders -UserDataPath $odTarget
            if ($cloudProfiles.Count -eq 0) {
                $lstCloud.Items.Add('(no profiles in backup folder)')
            } else {
                foreach ($p in $cloudProfiles) {
                    $dn  = Get-ProfileDisplayName -ProfilePath $p.FullName
                    $mod = (Get-Item $p.FullName -ErrorAction SilentlyContinue).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                    $row = if ($dn) { "[Backup]  $dn" } else { "[Backup]  $($p.Name)" }
                    if ($mod) { $row += "  ($mod)" }
                    $lstCloud.Items.Add($row)
                }
            }
        }
    }
    Update-Lists

    # Browse button
    $btnBrowseOD.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Select the ChromeProfileBackup folder inside your OneDrive'
        $dlg.ShowNewFolderButton = $false
        $dlg.SelectedPath = if ($odFolder -and (Test-Path $odFolder)) { $odFolder } else { $env:USERPROFILE }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $picked = $dlg.SelectedPath
            $script:odTarget = if ((Split-Path $picked -Leaf) -eq 'ChromeProfileBackup') { $picked }
                               else {
                                   $c = Join-Path $picked 'ChromeProfileBackup'
                                   if (Test-Path $c) { $c } else { $picked }
                               }
            $odTarget = $script:odTarget
            $lblOdPath.Text = $odTarget
            Write-Log "Browsed to: $odTarget"
            Update-Lists
        }
    })

    # Shared helpers
    function Start-Op {
        $btnSave.Enabled = $false; $btnRestore.Enabled = $false; $btnReset.Enabled = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $progressBar.Value = 0; $lblProgDetail.Text = ''
        $progressBar.Visible = $true; $lblProgDetail.Visible = $true
        [System.Windows.Forms.Application]::DoEvents()
    }
    function End-Op {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnSave.Enabled = $true; $btnRestore.Enabled = $true; $btnReset.Enabled = $true
    }

    # -- Save button -----------------------------------------------------------
    $btnSave.Add_Click({
        if (-not $odTarget) {
            [System.Windows.Forms.MessageBox]::Show('OneDrive is not configured.', $AppName, 'OK', 'Warning') | Out-Null; return
        }
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "This will copy your Chrome profiles to OneDrive as a backup.`nChrome will be closed if running.`nYour local profiles are NOT moved or deleted.`n`nContinue?",
            $AppName, 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
        Start-Op
        New-Item -ItemType Directory -Path $odFolder -Force -ErrorAction SilentlyContinue | Out-Null
        try {
            if (Invoke-SaveToOneDrive -OneDriveTarget $odTarget -StatusLabel $lblStatus -ProgressBar $progressBar -ProgressLabel $lblProgDetail) {
                $lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
                $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(16,124,16)
                $lblStatus.Text = 'Done! Profiles backed up to OneDrive.'
                Update-Lists
                [System.Windows.Forms.MessageBox]::Show(
                    "Your Chrome profiles have been backed up to OneDrive successfully!" +
                    "`n`nImportant: wait for OneDrive to finish syncing (green checkmark in taskbar)" +
                    "`nbefore restoring on another computer.",
                    'Backup Complete', 'OK', 'Information') | Out-Null
            }
        } catch {
            $lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
            $lblStatus.Text = "Error: $_"; Write-Log "Save error: $_" 'ERROR'
        }
        End-Op
    })

    # -- Restore button --------------------------------------------------------
    $btnRestore.Add_Click({
        $curTarget = if ($script:odTarget) { $script:odTarget } else { $odTarget }
        if (-not $curTarget -or -not (Test-Path $curTarget)) {
            [System.Windows.Forms.MessageBox]::Show(
                "Backup folder not found.`n`nChecked: $curTarget`n`nRun Backup to OneDrive on your old machine first, or use Browse... to locate the folder.",
                $AppName, 'OK', 'Warning') | Out-Null; return
        }
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Please close Chrome completely before continuing.`n`n" +
            "This will copy profiles from OneDrive directly to your local disk.`n" +
            "Chrome will read 100% local files - no sync dependency.`n`n" +
            "Existing local profiles will be backed up automatically.`n`nContinue?",
            $AppName, 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
        Start-Op
        try {
            if (Invoke-RestoreFromOneDrive -OneDriveTarget $curTarget -StatusLabel $lblStatus -ProgressBar $progressBar -ProgressLabel $lblProgDetail) {
                $lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
                $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(16,124,16)
                $lblStatus.Text = 'Done! All profiles restored to local disk. Open Chrome now.'
                Update-Lists
                [System.Windows.Forms.MessageBox]::Show(
                    "All Chrome profiles have been restored to your local disk!" +
                    "`n`nProfiles are named by their folder ID (Profile 1, Profile 14, etc.)" +
                    "`nYou can rename them in Chrome via Settings > You and Google." +
                    "`n`n--- About saved passwords and cookies ---" +
                    "`nChrome encrypts credentials using this machine's Windows key (DPAPI)." +
                    "`nIf restoring to the SAME machine: credentials should work." +
                    "`nIf restoring to a NEW machine: saved passwords and session cookies" +
                    "`ncannot be transferred - you will need to log in to websites again." +
                    "`nBookmarks, extensions, and settings are restored regardless.",
                    'Restore Complete', 'OK', 'Information') | Out-Null
            }
        } catch {
            $lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
            $lblStatus.Text = "Error: $_"; Write-Log "Restore error: $_" 'ERROR'
        }
        End-Op
    })

    # -- Reset & Restore button ------------------------------------------------
    $btnReset.Add_Click({
        $curTarget = if ($script:odTarget) { $script:odTarget } else { $odTarget }
        $hasBackup = $curTarget -and (Test-Path $curTarget)
        $bakPath   = "$ChromeUserData.broken_$(Get-Date -Format 'yyyyMMddHHmmss')"

        $msg = "WARNING: This will rename your current Chrome User Data folder`n" +
               "so Chrome starts completely fresh.`n`n" +
               "Broken data will be saved to:`n$bakPath`n`n"
        $msg += if ($hasBackup) {
            "An OneDrive backup was found and will be restored immediately.`n`n" +
            "Close Chrome now, then click Yes to Reset and Restore."
        } else {
            "No OneDrive backup found - Chrome will start with a blank profile.`n" +
            "Run Backup to OneDrive on a working machine first if you want profiles back.`n`n" +
            "Close Chrome now, then click Yes to reset."
        }

        $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'Reset Chrome - Are you sure?', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }

        Start-Op
        $orange = [System.Drawing.Color]::FromArgb(200,80,0)
        try {
            Set-Step -L $lblStatus -Text 'Closing Chrome...' -Color $orange
            Stop-ChromeSilently

            if (Test-Path $ChromeUserData) {
                Rename-Item -Path $ChromeUserData -NewName $bakPath
                Write-Log "Broken User Data renamed to: $bakPath"
            }

            if ($hasBackup) {
                $ok = Invoke-RestoreFromOneDrive -OneDriveTarget $curTarget -StatusLabel $lblStatus `
                          -ProgressBar $progressBar -ProgressLabel $lblProgDetail
                if ($ok) {
                    $lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
                    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(16,124,16)
                    $lblStatus.Text = 'Done! Chrome reset and profiles restored. Open Chrome now.'
                    Update-Lists
                    [System.Windows.Forms.MessageBox]::Show(
                        "Chrome has been reset and all profiles restored from your OneDrive backup!" +
                        "`n`nBroken data saved to:`n$bakPath`n`n" +
                        "Open Chrome - all profiles should now appear in the switcher.",
                        'Reset & Restore Complete', 'OK', 'Information') | Out-Null
                }
            } else {
                $progressBar.Value  = 100
                $lblProgDetail.Text = 'Chrome reset - no backup to restore'
                $lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
                $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(16,124,16)
                $lblStatus.Text = 'Done! Chrome reset. Open Chrome to create a new profile.'
                Update-Lists
                [System.Windows.Forms.MessageBox]::Show(
                    "Chrome has been reset to factory defaults." +
                    "`n`nBroken data saved to:`n$bakPath`n`n" +
                    "Open Chrome to set up a fresh profile.",
                    'Reset Complete', 'OK', 'Information') | Out-Null
                Write-Log "Reset complete - no backup to restore."
            }
        } catch {
            $lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
            $lblStatus.Text = "Error: $_"; Write-Log "Reset error: $_" 'ERROR'
        }
        End-Op
    })

    Write-Log "Dialog shown."; $form.ShowDialog() | Out-Null; Write-Log "Dialog closed."
}

# -- Intune Setup mode ---------------------------------------------------------
function Invoke-Setup {
    Write-Log "=== Setup (admin) started ==="
    Write-Log "Scripts dir  : $ScriptsDir"
    Write-Log "Shortcut path: $ShortcutPath"
    New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null
    foreach ($s in @('Install.ps1', 'Uninstall.ps1', 'Detect.ps1')) {
        $src = Join-Path $PSScriptRoot $s
        if (Test-Path $src) { Copy-Item -Path $src -Destination $ScriptsDir -Force; Write-Log "Copied: $s" }
        else { Write-Log "Not found: $src" 'WARN' }
    }
    $psExe  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $psArgs = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptsDir\Install.ps1`""
    $created = $false
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut($ShortcutPath)
        $lnk.TargetPath = $psExe; $lnk.Arguments = $psArgs
        $lnk.WindowStyle = 1; $lnk.Description = 'Backup or restore Chrome profiles via OneDrive'
        $lnk.Save()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
        $created = Test-Path $ShortcutPath
        if ($created) { Write-Log "Shortcut created: $ShortcutPath" }
        else           { Write-Log "WScript.Shell did not create shortcut." 'WARN' }
    } catch { Write-Log "WScript.Shell error: $_" 'WARN' }

    if (-not $created) {
        Write-Log "Trying cscript fallback..."
        $vbs = "Set o=CreateObject(`"WScript.Shell`"):Set l=o.CreateShortcut(`"$ShortcutPath`"):l.TargetPath=`"$psExe`":l.Arguments=`"$psArgs`":l.WindowStyle=1:l.Save()"
        $vbsPath = [System.IO.Path]::GetTempFileName() -replace '\.tmp$','.vbs'
        try {
            Set-Content -Path $vbsPath -Value $vbs -Encoding ASCII
            & "$env:SystemRoot\System32\cscript.exe" //NoLogo $vbsPath 2>&1 | Out-Null
            if (Test-Path $ShortcutPath) { Write-Log "Shortcut created via cscript." } else { Write-Log "Shortcut creation failed." 'ERROR' }
        } catch { Write-Log "cscript error: $_" 'ERROR' }
        finally  { Remove-Item $vbsPath -Force -ErrorAction SilentlyContinue }
    }
    Write-Log "=== Setup complete ==="
}

# -- Entry point ---------------------------------------------------------------
if (-not $Setup) {
    $isSystem = [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
    if ($isSystem) { Write-Log "Running as SYSTEM - switching to Setup mode."; $Setup = $true }
}
Write-Log "=== $AppName v$AppVersion started ($(if ($Setup) { 'Setup' } else { 'UI' })) ==="
if ($Setup) { Invoke-Setup; exit 0 }

Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
Show-MainDialog -OdInfo (Get-OneDrivePath)
