#requires -Version 5.1
<#
================================================================================
  SafeToFormat.ps1  -  Version 1.2
  Know your camera cards are backed up before you wipe them.
================================================================================

  WHAT IT DOES
    - Detects every SD / CF / CFexpress card plugged in (including readers that
      Windows reports as "fixed disks", which trips up most simple scripts).
    - Searches ALL year folders under your backup root (or the whole root when
      $UseYearFolders is off) so footage from any year is found in one pass.
    - Tells you, card by card, whether every video file is backed up.
    - Offers to COPY anything missing, routing each file into the year folder that
      matches its shoot date (e.g. <FootageRoot>\2025\) - confirming each date
      and asking you to name it.
    - Verifies every copy with a SHA-256 hash before it ever calls a card safe.
    - Offers to safely eject each card that passed.

    It NEVER deletes or formats anything. It only reads, copies, and verifies.
    You do the formatting yourself, once you trust the green "SAFE TO FORMAT".

  SETUP (one time)
    1. Open the CONFIG section below and set $FootageRoot to your backup folder.
    2. Save this file somewhere permanent.
    3. Right-click the file -> Properties -> tick "Unblock" at the bottom -> OK.
       (Windows blocks downloaded scripts until you do this. Once only.)

  HOW TO RUN
    - In the folder, hold Shift + right-click -> "Open PowerShell window here",
      then type:   .\SafeToFormat.ps1
    - Or make a desktop shortcut (target):
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\SafeToFormat.ps1"
      then just double-click it.

  HANDY OPTIONS
    .\SafeToFormat.ps1                 Check every card, search all year folders
    .\SafeToFormat.ps1 -Drives E,F,G   Check only these drive letters
    .\SafeToFormat.ps1 -CardPath E:\   Check one specific drive or folder
    .\SafeToFormat.ps1 -Verify         Hash-verify existing copies too (slower, certain)
    .\SafeToFormat.ps1 -Year 2025      Narrow the search to the 2025 year folder only
    .\SafeToFormat.ps1 -NoCopy         Read-only check, don't offer to copy
    .\SafeToFormat.ps1 -NoEject        Don't offer to eject cards
    .\SafeToFormat.ps1 -ReportPath out.csv   Save a full CSV report

  Built collaboratively with Claude. Free to use and adapt. No warranty - test it
  on a card you can afford to be wrong about before you trust it with the keepers.
================================================================================
#>

[CmdletBinding()]
param(
    [string[]]$Drives,                    # e.g. -Drives E,F,G  (limit to these letters)
    [string]$CardPath,                    # a single explicit path/folder to check
    [int]$Year = 0,                       # 0 = search all years; pass e.g. -Year 2025 to narrow
    [string]$DestRoot,                    # full override of the destination folder
    [switch]$Verify,                      # also SHA-256 verify existing copies (slower, certain)
    [switch]$IncludeAll,                  # check ALL files, not just the media types below
    [switch]$NoEject,                     # skip the "eject this card?" prompts
    [switch]$NoCopy,                      # skip the "copy missing files?" prompts
    [string]$ReportPath                   # optional .csv report path
)

# ==============================================================================
#  CONFIG  --  the things you'll want to change for your own setup
# ==============================================================================

# 1) WHERE YOUR FOOTAGE LIVES.
#    Set this to the root folder you back up to: a NAS share, an external drive,
#    a local folder, whatever. The script indexes everything under this folder.
#    Examples:  'S:\Footage'   |   '\\NAS\media\Footage'   |   'D:\Backups\Video'
$FootageRoot = 'D:\Footage'              # <-- CHANGE THIS to your backup root

# 2) YEAR FOLDER LAYOUT.
#    Set $true if you organize footage as <FootageRoot>\<Year>\<dated folders>
#    (e.g. D:\Footage\2026\2026-06-04 - Zion). The script will search all year
#    folders and route new copies into the year folder matching each file's date.
#    Set $false if your dated folders sit directly under $FootageRoot (no year level).
$UseYearFolders = $true                  # <-- CHANGE THIS if you don't use year subfolders

# 3) WHICH FILE TYPES COUNT.
#    Only these extensions are checked and copied. Everything else (thumbnails,
#    proxies, telemetry, sidecars) is ignored so it doesn't cause false alarms.
#    Add to this list if you also back up stills/RAW (e.g. '.nef','.dng','.jpg').
$MediaExtensions = @(
    '.mov','.mp4'                        # <-- ADD types here if you want more checked
    # ,'.mxf','.mts','.m2ts','.m4v','.avi'   # other common video containers
    # ,'.braw','.r3d','.ari'                  # cinema camera raw (BRAW, RED, ARRI)
    # ,'.nef','.cr3','.dng','.jpg','.heic'    # stills / RAW
)

# ==============================================================================
#  You shouldn't need to edit anything below this line.
# ==============================================================================

$ErrorActionPreference = 'Stop'

# --- Copies one set of files into a target folder, verifying each by hash -----
function Copy-FileSet {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$Target
    )
    if (-not (Test-Path -LiteralPath $Target)) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }
    $copied = 0; $failed = 0
    foreach ($f in $Files) {
        $destFile = Join-Path $Target $f.Name
        # Never overwrite - if the name already exists, append _1, _2, ...
        if (Test-Path -LiteralPath $destFile) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            $ext  = $f.Extension
            $n = 1
            do { $destFile = Join-Path $Target ('{0}_{1}{2}' -f $base, $n, $ext); $n++ } while (Test-Path -LiteralPath $destFile)
        }
        try {
            Copy-Item -LiteralPath $f.FullName -Destination $destFile -ErrorAction Stop
            # Verify the copy by hash before we ever call this card safe
            $srcHash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            $dstHash = (Get-FileHash -LiteralPath $destFile     -Algorithm SHA256).Hash
            if ($srcHash -eq $dstHash) {
                $copied++
                Write-Host ("    copied + verified: {0}" -f $f.Name) -ForegroundColor Green
                # Update the in-memory index so later cards in this run see this file
                $key = '{0}|{1}' -f (Split-Path $destFile -Leaf).ToLower(), (Get-Item -LiteralPath $destFile).Length
                if (-not $script:index.ContainsKey($key)) { $script:index[$key] = New-Object System.Collections.Generic.List[string] }
                $script:index[$key].Add($destFile)
            }
            else {
                $failed++
                Write-Host ("    HASH MISMATCH after copy: {0} (NOT verified)" -f $f.Name) -ForegroundColor Red
            }
        }
        catch {
            $failed++
            Write-Host ("    FAILED: {0} - {1}" -f $f.Name, $_.Exception.Message) -ForegroundColor Red
        }
    }
    Write-Host ("  Copied {0} of {1} file(s)." -f $copied, $Files.Count) -ForegroundColor $(if ($failed) { 'Yellow' } else { 'Green' })
    return ($failed -eq 0 -and $copied -eq $Files.Count)
}

# --- Groups uncopied files by shoot date, then prompts + copies per date ------
function Copy-CardFiles {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$CopyRoot,            # $FootageRoot - base for year-routed copies
        [bool]$UseYears,              # $UseYearFolders - whether to route by year
        [string]$ExplicitDest         # explicit -DestRoot value, or '' if not passed
    )

    # Group by the file's modified date - the moment the camera finished writing
    # it, which is the shoot date you see in Explorer's "Date" column. Oldest first.
    $groups = @($Files | Group-Object { $_.LastWriteTime.ToString('yyyy-MM-dd') } | Sort-Object Name)

    if ($groups.Count -gt 1) {
        Write-Host ("  This card has footage from {0} different dates - I'll take them one at a time." -f $groups.Count) -ForegroundColor Cyan
    }

    $allOk = $true
    foreach ($g in $groups) {
        $groupFiles = @($g.Group)
        $sample     = $groupFiles[0].LastWriteTime
        $iso        = $sample.ToString('yyyy-MM-dd')
        $friendly   = $sample.ToString('dddd, MMM d')

        Write-Host ""
        Write-Host ("  I see {0} file(s) dated {1} ({2})." -f $groupFiles.Count, $iso, $friendly) -ForegroundColor Cyan
        $ans = Read-Host "  Is that date correct? (y/n)"
        if ($ans -match '^(y|yes)$') {
            $useDate = $iso
        }
        else {
            do {
                $useDate = (Read-Host "  Enter the correct date (YYYY-MM-DD)").Trim()
                $parsed = [datetime]::MinValue
                $okFmt = [datetime]::TryParseExact($useDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)
                if (-not $okFmt) { Write-Host "  Use the format YYYY-MM-DD (e.g. 2026-06-04)." -ForegroundColor Yellow }
            } until ($okFmt)
        }

        do {
            $loc = (Read-Host "  Location / activity for this date").Trim()
            if (-not $loc) { Write-Host "  A name is required." -ForegroundColor Yellow }
        } until ($loc)

        # Strip characters Windows won't allow in a folder name
        $invalid = [System.IO.Path]::GetInvalidFileNameChars()
        $clean   = -join ($loc.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '-' } else { $_ } })

        # Route the copy to the right base folder:
        #   explicit -DestRoot -> use it directly (no year routing)
        #   $UseYearFolders on -> <FootageRoot>\<year from the confirmed date>
        #   $UseYearFolders off -> <FootageRoot> itself
        if ($ExplicitDest) {
            $base = $ExplicitDest
        } elseif ($UseYears) {
            $base = Join-Path $CopyRoot $useDate.Substring(0, 4)
        } else {
            $base = $CopyRoot
        }

        # FOLDER NAME PATTERN: "YYYY-MM-DD - Name". Edit the next line to change it.
        $folder  = '{0} - {1}' -f $useDate, $clean.Trim()
        $target  = Join-Path $base $folder

        Write-Host ("  -> {0}" -f $target) -ForegroundColor Cyan
        if (-not (Copy-FileSet -Files $groupFiles -Target $target)) { $allOk = $false }
    }

    return $allOk
}

# --- Determine the search root (what to index) --------------------------------
#     -DestRoot explicit  -> search only that folder
#     -Year explicit      -> search <FootageRoot>\<Year> (narrow for speed)
#     default             -> search all of $FootageRoot (finds every year)
if ($DestRoot) {
    $SearchRoot = $DestRoot
} elseif ($Year -ne 0) {
    $SearchRoot = Join-Path $FootageRoot "$Year"
} else {
    $SearchRoot = $FootageRoot
}
if (-not (Test-Path -LiteralPath $SearchRoot)) {
    Write-Host "Search root not found: $SearchRoot" -ForegroundColor Red
    Write-Host "Edit `$FootageRoot in the CONFIG section, check -Year, or pass -DestRoot." -ForegroundColor Red
    [void](Read-Host "`nPress Enter to close")
    exit 1
}

# --- Decide which card roots to check -----------------------------------------
$cardRoots = @()
$sysDrive  = ($env:SystemDrive -replace '[^A-Za-z]','').ToUpper()
$destDrive = ([System.IO.Path]::GetPathRoot($(if ($DestRoot) { $DestRoot } else { $FootageRoot })) -replace '[^A-Za-z]','').ToUpper()

if ($CardPath) {
    # Explicit path always wins - scan it no matter how Windows classifies the drive
    $cardRoots = @($CardPath)
}
elseif ($Drives) {
    # Explicitly named letters are trusted directly (works even for fixed-disk readers)
    $cardRoots = @($Drives | ForEach-Object {
        $l = ($_ -replace '[^A-Za-z]','').ToUpper()
        if ($l) { $l + ':\' }
    } | Where-Object { $_ })
    if ($cardRoots.Count -eq 0) { Write-Host "No valid drive letters in -Drives." -ForegroundColor Red; exit 1 }
}
else {
    # Auto-detect. Include removable (DriveType 2) AND fixed (DriveType 3) disks,
    # because most CFexpress / CF card readers present the card as a FIXED disk.
    # Guards: never the Windows drive, never the backup destination, and a fixed
    # disk only counts as a card if it actually contains a DCIM folder (so internal
    # SSDs are ignored). Removable disks are listed as-is.
    $disks = @(
        Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
            Where-Object { $_.DeviceID -and ($_.DriveType -eq 2 -or $_.DriveType -eq 3) }
    )

    $cards = @()
    foreach ($d in $disks) {
        $letter = ($d.DeviceID -replace '[^A-Za-z]','').ToUpper()
        if ($letter -eq $sysDrive)  { continue }   # never the Windows drive
        if ($letter -eq $destDrive) { continue }   # never the backup destination
        if ($d.DriveType -eq 3) {
            # Fixed disk: only treat as a card if it looks like one
            if (-not (Test-Path -LiteralPath (Join-Path ($d.DeviceID + '\') 'DCIM'))) { continue }
        }
        $cards += $d
    }

    if ($cards.Count -eq 0) {
        $manual = Read-Host 'No cards detected. Enter a card path (e.g. E:\) or leave blank to cancel'
        if ($manual) { $cardRoots = @($manual) } else { exit 0 }
    }
    else {
        Write-Host "Card drives detected:" -ForegroundColor Cyan
        foreach ($vol in $cards) {
            $label = if ($vol.VolumeName) { $vol.VolumeName } else { '(no label)' }
            $size  = if ($vol.Size) { '{0:N0} GB' -f ($vol.Size / 1GB) } else { '?' }
            $kind  = if ($vol.DriveType -eq 2) { 'removable' } else { 'fixed/reader' }
            Write-Host ("   {0}\  {1}  ({2}, {3})" -f $vol.DeviceID, $label, $size, $kind)
        }
        $cardRoots = @($cards | ForEach-Object { $_.DeviceID + '\' })
    }
}

# --- Index the search root ONCE (filename+size -> list of full paths) ---------
Write-Host "`nIndexing $SearchRoot (this can take a moment over a network)..." -ForegroundColor Cyan
$script:index = @{}
$indexed = 0
Get-ChildItem -LiteralPath $SearchRoot -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    $key = '{0}|{1}' -f $_.Name.ToLower(), $_.Length
    if (-not $script:index.ContainsKey($key)) {
        $script:index[$key] = New-Object System.Collections.Generic.List[string]
    }
    $script:index[$key].Add($_.FullName)
    $indexed++
}
Write-Host ("Indexed {0} files in the destination." -f $indexed)
if ($Verify) { Write-Host "Verify mode ON - SHA-256 checking existing copies (slow, certain)." -ForegroundColor Cyan }

# --- Check each card root -----------------------------------------------------
$allResults   = New-Object System.Collections.Generic.List[object]
$cardVerdicts = New-Object System.Collections.Generic.List[object]

foreach ($root in $cardRoots) {

    Write-Host ""
    Write-Host ('=' * 64)
    Write-Host (" CARD: {0}" -f $root) -ForegroundColor Cyan
    Write-Host ('=' * 64)

    if (-not (Test-Path -LiteralPath $root)) {
        Write-Host "  Path not found - skipping." -ForegroundColor Yellow
        $cardVerdicts.Add([pscustomobject]@{ Drive=$root; Verdict='NOT FOUND' })
        continue
    }

    $scanErrors = @()
    $cardFiles = @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue -ErrorVariable scanErrors)

    $seriousErrors = @($scanErrors | Where-Object {
        $p = "$($_.TargetObject)"
        -not ($p -match 'System Volume Information' -or $p -match '\$RECYCLE\.BIN')
    })
    if ($seriousErrors.Count -gt 0) {
        Write-Host ("  READ ERROR - {0} item(s) on this card could not be read." -f $seriousErrors.Count) -ForegroundColor White -BackgroundColor Red
        Write-Host  "  The card may be failing or corrupt. DO NOT format it." -ForegroundColor Red
        $seriousErrors | Select-Object -First 5 | ForEach-Object { Write-Host ("     {0}" -f $_.Exception.Message) -ForegroundColor Red }
        $cardVerdicts.Add([pscustomobject]@{ Drive=$root; Verdict='READ ERROR - DO NOT FORMAT' })
        continue
    }

    if (-not $IncludeAll) {
        $cardFiles = @($cardFiles | Where-Object { $MediaExtensions -contains $_.Extension.ToLower() })
    }

    if ($cardFiles.Count -eq 0) {
        Write-Host "  No media files found - likely empty or device internal storage. Nothing to back up." -ForegroundColor Yellow
        $cardVerdicts.Add([pscustomobject]@{ Drive=$root; Verdict='EMPTY / NO MEDIA' })
        continue
    }

    $results = New-Object System.Collections.Generic.List[object]
    $toCopy  = New-Object System.Collections.Generic.List[object]
    foreach ($f in $cardFiles) {
        $key     = '{0}|{1}' -f $f.Name.ToLower(), $f.Length
        $status  = 'NOT COPIED'
        $foundAt = ''
        if ($script:index.ContainsKey($key)) {
            if ($Verify) {
                $srcHash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
                foreach ($dest in $script:index[$key]) {
                    if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -eq $srcHash) {
                        $status = 'OK'; $foundAt = $dest; break
                    }
                }
                if ($status -ne 'OK') { $status = 'CONTENT DIFFERS' }
            }
            else {
                $status = 'OK'; $foundAt = $script:index[$key][0]
            }
        }
        if ($status -eq 'NOT COPIED') { $toCopy.Add($f) }
        $row = [pscustomobject]@{
            Drive    = $root
            Status   = $status
            File     = $f.Name
            SizeMB   = [math]::Round($f.Length / 1MB, 1)
            CardPath = $f.FullName
            FoundAt  = $foundAt
        }
        $results.Add($row)
        $allResults.Add($row)
    }

    $okCount  = @($results | Where-Object Status -eq 'OK').Count
    $missing  = @($results | Where-Object Status -eq 'NOT COPIED')
    $diff     = @($results | Where-Object Status -eq 'CONTENT DIFFERS')
    $problems = $missing.Count + $diff.Count

    Write-Host (" Media files: {0}   Backed up: {1}   NOT copied: {2}" -f $cardFiles.Count, $okCount, $missing.Count)
    if ($Verify -and $diff.Count -gt 0) {
        Write-Host (" Content differs: {0}" -f $diff.Count) -ForegroundColor Yellow
    }
    Write-Host ""

    if ($problems -eq 0) {
        Write-Host "  ALL FILES BACKED UP - safe to format this card.  " -ForegroundColor Black -BackgroundColor Green
        if (-not $Verify) {
            Write-Host "  (matched by name + size; run with -Verify for byte-level certainty)" -ForegroundColor DarkGray
        }
        $verdict = 'SAFE TO FORMAT'
    }
    else {
        Write-Host "  $problems FILE(S) NOT BACKED UP - DO NOT format this card.  " -ForegroundColor White -BackgroundColor Red
        if ($missing.Count) {
            Write-Host "`n  Not found in $SearchRoot :" -ForegroundColor Red
            $missing | ForEach-Object { Write-Host ("     {0}" -f $_.CardPath) }
        }
        if ($diff.Count) {
            Write-Host "`n  Name+size matched but content differs (verify these!):" -ForegroundColor Yellow
            $diff | ForEach-Object { Write-Host ("     {0}" -f $_.CardPath) }
        }
        $verdict = "$problems NOT BACKED UP"

        # Offer to copy the uncopied files into a new dated/named folder
        if (-not $NoCopy -and $toCopy.Count -gt 0) {
            Write-Host ""
            $doCopy = Read-Host ("  Copy the {0} uncopied file(s) to a new folder? (y/n)" -f $toCopy.Count)
            if ($doCopy -match '^(y|yes)$') {
                $allOk = Copy-CardFiles -Files $toCopy.ToArray() -CopyRoot $FootageRoot -UseYears $UseYearFolders -ExplicitDest $DestRoot
                if ($allOk -and $diff.Count -eq 0) {
                    Write-Host "`n  All files now backed up + verified - safe to format this card." -ForegroundColor Green
                    $verdict = 'SAFE TO FORMAT'
                }
                else {
                    Write-Host "`n  Copy finished with issues - re-run the check before formatting." -ForegroundColor Yellow
                    $verdict = 'COPY INCOMPLETE - RECHECK'
                }
            }
        }
    }
    $cardVerdicts.Add([pscustomobject]@{ Drive=$root; Verdict=$verdict })
}

# --- Combined summary ---------------------------------------------------------
Write-Host ""
Write-Host ('=' * 64)
Write-Host " SUMMARY" -ForegroundColor Cyan
Write-Host ('=' * 64)
foreach ($v in $cardVerdicts) {
    $color = if ($v.Verdict -eq 'SAFE TO FORMAT') { 'Green' }
             elseif ($v.Verdict -like '*NOT BACKED UP*' -or $v.Verdict -like '*DO NOT FORMAT*') { 'Red' }
             else { 'Yellow' }
    Write-Host ("   {0,-8}  {1}" -f $v.Drive, $v.Verdict) -ForegroundColor $color
}

# --- Optional CSV -------------------------------------------------------------
if ($ReportPath) {
    $allResults | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8
    Write-Host "`nFull report saved to $ReportPath" -ForegroundColor Cyan
}

# --- Offer to eject cards that passed -----------------------------------------
if (-not $NoEject) {
    $safe = @($cardVerdicts | Where-Object { $_.Verdict -eq 'SAFE TO FORMAT' })
    if ($safe.Count -gt 0) {
        Write-Host ""
        foreach ($s in $safe) {
            $rootDrive = [System.IO.Path]::GetPathRoot($s.Drive)        # e.g. "E:\"
            $letter    = ($rootDrive -replace '[^A-Za-z]','').ToUpper()
            if (-not $letter) { continue }

            # Allow eject for removable drives and fixed-disk card readers,
            # but never the Windows drive.
            $sysLetter = ($env:SystemDrive -replace '[^A-Za-z]','').ToUpper()
            if ($letter -eq $sysLetter) { continue }
            $dt = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($letter):'" -ErrorAction SilentlyContinue).DriveType
            if ($dt -ne 2 -and $dt -ne 3) { continue }

            $ans = Read-Host ("Eject {0} now? (y/n)" -f $rootDrive)
            if ($ans -match '^(y|yes)$') {
                try {
                    $shell = New-Object -ComObject Shell.Application
                    $item  = $shell.Namespace(17).ParseName($rootDrive)
                    if (-not $item) { $item = $shell.Namespace(17).ParseName(($letter + ':')) }
                    if ($item) {
                        $item.InvokeVerb('Eject')
                        Start-Sleep -Milliseconds 700
                        Write-Host ("  Ejected {0} - you can pull the card." -f $rootDrive) -ForegroundColor Green
                    }
                    else {
                        Write-Host ("  Couldn't grab {0} to eject - use the taskbar 'Safely Remove' icon, or just pull it (writes are done)." -f $rootDrive) -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Host ("  Couldn't eject {0} automatically ({1}). Some card readers can't be ejected this way - use the taskbar 'Safely Remove' icon." -f $rootDrive, $_.Exception.Message) -ForegroundColor Yellow
                }
            }
        }
    }
}

[void](Read-Host "`nDone. Press Enter to close")