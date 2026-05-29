# Chrome Profile Sync - Intune Win32 App

Interactive tool that lets users backup their Chrome profiles to OneDrive and
restore them on a new machine. Profiles are copied directly to local disk on
restore - Chrome reads 100% local files with no OneDrive dependency.

Installed system-wide (Program Files) by Intune with admin rights.
Users run the tool from the Start Menu with their own user rights.

---

## Version history

| Version | Date       | Changes                                                                                      |
|---------|------------|----------------------------------------------------------------------------------------------|
| 5.0     | 2026-05-29 | Copy-based backup/restore (no junctions); Reset & Restore button; Local State repair; smart backup exclusions via robocopy /XD; Browse button for manual OneDrive selection; DPAPI credential note in restore popup |
| 4.x     | 2026-05-28 | Junction-based approach (superseded - junctions incompatible with managed Chrome environments) |
| 3.x     | 2026-05-28 | Automatic logon repair via Run key / startup folder (superseded)                             |

---

## How it works

```
Intune (System/admin) installs to:
  C:\Program Files\ChromeProfileSync\        <- Install.ps1, Uninstall.ps1, Detect.ps1
  All-users Start Menu shortcut              <- Chrome Profile Sync.lnk

User opens Chrome Profile Sync from Start Menu (runs as user, no admin needed):
  - Dialog shows LOCAL PROFILES and ONEDRIVE BACKUP side by side
  - Real account names shown (gaia_name / email from Preferences JSON)
  - System Profile and Guest Profile are hidden

  [Backup to OneDrive]      [Restore from OneDrive]     [Reset & Restore]
  Copy local profiles to    Copy profiles from OneDrive  Rename broken User Data,
  OneDrive\ChromeProfileBackup\  directly to local disk.  then restore from backup.
  Local Chrome untouched.   Chrome reads 100% locally.

Per-user data (no admin needed at runtime):
  %LOCALAPPDATA%\ChromeProfileSync\config.json   <- saved OneDrive account selection
  %LOCALAPPDATA%\Logs\ChromeProfileSync\         <- activity logs
  %LOCALAPPDATA%\Google\Chrome\User Data         <- local Chrome profiles (unchanged by tool)
  OneDrive\ChromeProfileBackup\                  <- backup folder in OneDrive
```

---

## Files

| File                        | Purpose                                              |
|-----------------------------|------------------------------------------------------|
| Install.ps1                 | Main tool (UI) + Setup mode for Intune deployment    |
| Uninstall.ps1               | Removes Program Files folder and Start Menu shortcut |
| Detect.ps1                  | Intune detection - checks Program Files and shortcut |
| chrome-profile-sync-logo.svg | App icon (512x512 SVG, for Intune app branding)     |

---

## Step 1 - Package with IntuneWinAppUtil

1. Download **IntuneWinAppUtil.exe** from Microsoft:
   https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases

2. Place the three scripts in a folder, e.g. `C:\Packaging\ChromeProfileSync\scripts\`

3. Run:
   ```cmd
   IntuneWinAppUtil.exe -c "C:\Packaging\ChromeProfileSync\scripts" -s Install.ps1 -o "C:\Packaging\ChromeProfileSync\output"
   ```
   This produces `Install.intunewin`.

---

## Step 2 - Create the Win32 App in Intune

Go to: **Intune portal > Apps > Windows > Add > Windows app (Win32)**

Upload `Install.intunewin` when prompted.

### App information tab

| Field       | Value                                                                      |
|-------------|----------------------------------------------------------------------------|
| Name        | Chrome Profile Sync                                                        |
| Description | Backup and restore Chrome profiles via OneDrive. Opens from Start Menu.    |
| Publisher   | Hulsman Systems                                                            |
| Version     | 5.0                                                                        |
| Category    | Productivity                                                               |
| Logo        | Upload `chrome-profile-sync-logo.svg`                                      |

### Program tab

| Field                   | Value                                                                                        |
|-------------------------|----------------------------------------------------------------------------------------------|
| Install command         | `powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File Install.ps1 -Setup` |
| Uninstall command       | `powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -Command "& (Join-Path $Env:ProgramFiles 'ChromeProfileSync\Uninstall.ps1')"` |
| Install behavior        | **System** (admin rights needed for Program Files and all-users shortcut)                    |
| Device restart behavior | No specific action                                                                           |

> The install command includes `-Setup` which runs in silent mode. The tool
> also auto-detects SYSTEM context and switches to Setup mode automatically,
> so the UI never appears during Intune deployment.

### Requirements tab

| Field           | Value                   |
|-----------------|-------------------------|
| OS architecture | 64-bit                  |
| Minimum OS      | Windows 10 21H1 (19043) |

### Detection rules tab

| Field                          | Value                         |
|--------------------------------|-------------------------------|
| Rules format                   | Use a custom detection script |
| Script file                    | Upload `Detect.ps1`           |
| Run script as 32-bit process   | No                            |
| Enforce script signature check | No                            |

Detection checks that `Install.ps1` exists in `C:\Program Files\ChromeProfileSync\`
and that the all-users Start Menu shortcut is present. No user-specific paths are checked.

### Assignments tab

| Field                          | Value                                                       |
|--------------------------------|-------------------------------------------------------------|
| Required                       | Assign to device group for automatic deployment             |
| Available for enrolled devices | Or assign to user group for self-service via Company Portal |

---

## Step 3 - User experience

1. Intune installs silently (System context, no UI shown, no restart)
2. User finds **Chrome Profile Sync** in the Start Menu
3. Opens the tool - dialog shows local profiles and OneDrive backup side by side

### Three-button reference

| Button | Colour | When to use |
|---|---|---|
| **Backup to OneDrive** | Blue | On the current/old machine before replacing or decommissioning it |
| **Restore from OneDrive** | Green | On a new or reinstalled machine after OneDrive has finished syncing |
| **Reset & Restore** | Orange | When Chrome is broken or corrupted on the current machine |

### On the old machine

1. Open **Chrome Profile Sync** from Start Menu
2. Click **Backup to OneDrive**
3. Chrome closes automatically; caches are cleared; profiles are copied to `OneDrive\ChromeProfileBackup\`
4. Local Chrome profiles are **not moved or deleted** - Chrome keeps working normally
5. Wait for the OneDrive taskbar icon to show a green checkmark before restoring elsewhere

### On the new machine

1. Open **Chrome Profile Sync** from Start Menu
2. The right panel shows profiles already in OneDrive (if synced)
3. Click **Restore from OneDrive**
4. Chrome closes; profiles are copied from OneDrive **directly to local disk**
5. Local State is repaired so Chrome recognises all profiles
6. Open Chrome - all profiles appear in the profile switcher immediately

### When Chrome is broken

1. Open **Chrome Profile Sync** from Start Menu
2. Click **Reset & Restore**
3. The broken `User Data` folder is renamed to `User Data.broken_<timestamp>` (not deleted)
4. If an OneDrive backup exists it is restored immediately
5. If no backup exists Chrome starts fresh - run Backup first on a working machine

---

## What gets backed up

Backup uses robocopy with a comprehensive exclusion list so only meaningful
profile data is copied - not regeneratable temp files.

### Always included
Bookmarks, History, Passwords (Login Data), Cookies, Preferences, Extensions,
Local Storage, IndexedDB, Sync Data, Web Data (autofill), Favicons, and all
other profile data Chrome needs to function.

### Excluded from backup (regenerate automatically)

| Folder | Reason |
|---|---|
| Cache, Code Cache, GPUCache, ShaderCache | Main browser cache - cleared before backup too |
| DawnCache | WebGPU shader cache |
| CacheStorage | Service Worker response cache |
| ScriptCache | Compiled Service Worker scripts |
| blob_storage | Temporary blob storage |
| Safe Browsing | Safety database - 200-400 MB, regenerates on launch |
| Thumbnails | Page thumbnail cache |
| Crash Reports, crashpad | Crash reporter data - not needed after restore |
| VideoDecodeStats | Video performance statistics |
| optimization_guide_hint_cache_leveldb | Optimisation hints cache |
| BudgetDatabase, Feature Engagement Tracker | Usage tracking data |
| GCM Store | Google Cloud Messaging store |

---

## Important notes

**Profile names:** The tool reads `profile.gaia_name` and `account_info[].email`
from each profile's `Preferences` file. If a profile has no synced Google account
it shows the folder name (`Profile 14`, `Default`, etc.) instead of the generic
"Person 1" label. Chrome's Local State is repaired during restore to ensure all
profiles are registered and named correctly.

**Saved passwords and cookies (DPAPI limitation):**
Chrome encrypts credentials using Windows DPAPI - a key tied to the Windows
user account on a specific machine.

| Scenario | Credentials |
|---|---|
| Restore on the **same machine** | Passwords and cookies should work |
| Restore on a **new machine** | Cannot be transferred - you must log in to websites again |
| Restore after **Windows reinstall** | Cannot be transferred - new DPAPI key |

Bookmarks, extensions, history, and settings restore correctly in all scenarios.

**OneDrive must be signed in** before using the tool. The correct OneDrive account
is resolved by matching the user's UPN against connected accounts in the registry.
When multiple OneDrives are connected and no UPN match is found, a selector dialog
appears. Use the **Browse...** button if automatic selection picks the wrong folder.

**System Profile and Guest Profile** are hidden from both lists in the dialog.

**Per-user data:** Each Windows user account has its own config and logs under
`%LOCALAPPDATA%\ChromeProfileSync\`. Admin profiles (e.g. `b.hulsman-adm@...`)
need the tool run while logged in as that user.

**Uninstall** (via Intune or Company Portal) removes only:
- `C:\Program Files\ChromeProfileSync\`
- The all-users Start Menu shortcut

Chrome profiles and the OneDrive backup folder are **not touched**.

**DiskCacheSize policy (recommended):** Set via Intune Settings Catalog >
Google Chrome to cap future cache growth per profile:

| Policy        | Value       | Effect              |
|---------------|-------------|---------------------|
| DiskCacheSize | `268435456` | 256 MB cap per profile |

---

## Logs

| Log | Location |
|---|---|
| User activity (backup, restore, reset) | `%LOCALAPPDATA%\Logs\ChromeProfileSync\ChromeProfileSync_<timestamp>.log` |
| Robocopy backup detail | `%LOCALAPPDATA%\Logs\ChromeProfileSync\robocopy_backup_<timestamp>.log` |
| Robocopy restore detail | `%LOCALAPPDATA%\Logs\ChromeProfileSync\robocopy_restore_<timestamp>.log` |
| Uninstall (system context) | `C:\ProgramData\Logs\ChromeProfileSync\Uninstall_<timestamp>.log` |

The activity log records: OneDrive account resolution, each profile measured and
copied, Local State repair results (how many profiles were added or renamed), and
any errors with full exception details.
