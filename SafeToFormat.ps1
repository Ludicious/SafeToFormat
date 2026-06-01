#requires -Version 5.1
<#
================================================================================
  SafeToFormat.ps1
  Know your camera cards are backed up before you wipe them.
================================================================================

  WHAT IT DOES
    - Detects every SD / CF / CFexpress card plugged in (including readers that
      Windows reports as "fixed disks", which trips up most simple scripts).
    - Scans your backup folder and ALL its subfolders to see what's already there.
    - Tells you, card by card, whether every video file is backed up.
    - Offers to COPY anything missing into a new dated folder, prompting you for
      the date and a location/name so it lands in a tidy structure.
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
    .\SafeToFormat.ps1                 Check every card found, current year folder
    .\SafeToFormat.ps1 -Drives E,F,G   Check only these drive letters
    .\SafeToFormat.ps1 -CardPath E:\   Check one specific drive or folder
    .\SafeToFormat.ps1 -Verify         Hash-verify existing copies too (slower, certain)
    .\SafeToFormat.ps1 -Year 2025      Use a different year subfolder
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
    [int]$Year = (Get-Date).Year,         # defaults to the current year (rolls over automatically)
    [string]$DestRoot,                    # full override of the destination folder
    [switch]$Verify,                      # also SHA-256 verify existing copies (slower, certain)
    [switch]$IncludeAll,                  # check ALL files, not just the media types below
    [switch]$NoEject,                     # skip the "eject this card?" prompts
    [switch]$NoCopy,                      # skip the "copy missing files?" prompts
    [string]$ReportPath                   # optional .csv report path
)

# ==============================================================================
#  CONFIG  --  the two things you'll want to change for your own setup
# ==============================================================================

# 1) WHERE YOUR FOOTAGE LIVES.
#    Set this to the root folder you back up to: a NAS share, an external drive,
#    a local folder, whatever. The script looks inside <FootageRoot>\<Year>\ and
#    every subfolder beneath it.
#    Examples:  'S:\Footage'   |   '\\NAS\media\Footage'   |   'D:\Backups\Video'
$FootageRoot = 'D:\Footage'              # <-- CHANGE THIS to your backup root

#    NOTE on the year subfolder: by default the script checks <FootageRoot>\<Year>.
#    If you DON'T organize by year, either point $FootageRoot straight at the
#    folder that holds your dated folders and pass -Year matching that folder,
#    or just run with -DestRoot "X:\whatever" to skip year handling entirely.

# 2) WHICH FILE TYPES COUNT.
#    Only these extensions are checked and copied. Everything else (thumbnails,
#    proxies, telemetry, sidecars) is ignored so it doesn't cause false alarms.
#    Add to this list if you also back up stills/RAW (e.g. '.nef','.dng','.jpg').
$MediaExtensions = @(
    '.mov','.mp4'                        # <-- ADD types here if you want more checked
)

# ==============================================================================
#  You shouldn't need to edit anything below this line.
# ==============================================================================

$ErrorActionPreference = 'Stop'

# --- Copy helper: prompt for a dated/named folder and copy + verify -----------
function Copy-CardFiles {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$DestRoot
    )

    # Folder date - defaults to today, must be YYYY-MM-DD
    $today = (Get-Date).ToString('yyyy-MM-dd')
    do {
        $dateIn = Read-Host ("  Folder date (YYYY-MM-DD) [default {0}]" -f $today)
        if (-not $dateIn) { $dateIn = $today }
        $okDate = $dateIn -match '^\d{4}-\d{2}-\d{2}$'
        if (-not $okDate) { Write-Host "  Use the format YYYY-MM-DD." -ForegroundColor Yellow }
    } until ($okDate)

    # Location / activity name - required, free text
    do {
        $loc = (Read-Host "  Location / name for this folder").Trim()
        if (-not $loc) { Write-Host "  A name is required." -ForegroundColor Yellow }
    } until ($loc)

    # Strip characters Windows won't allow in a folder name
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $clean   = -join ($loc.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '-' } else { $_ } })

    # FOLDER NAME PATTERN: "YYYY-MM-DD - Name". Edit the next line to change it.
    $folder  = '{0} - {1}' -f $dateIn, $clean.Trim()

    $target  = Join-Path $DestRoot $folder

    Write-Host ("  Target folder: {0}" -f $target) -ForegroundColor Cyan
    $go = Read-Host "  Copy now? (y/n)"
    if ($go -notmatch '^(y|yes)$') {
        Write-Host "  Copy cancelled." -ForegroundColor Yellow
        return $false
    }

    if (-not (Test-Path -LiteralPath $target)) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
    }

    $copied = 0; $failed = 0
    foreach ($f in $Files) {
        $destFile = Join-Path $target $f.Name
        # Never overwrite - if the name already exists, append _1, _2, ...
        if (Test-Path -LiteralPath $destFile) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            $ext  = $f.Extension
            $n = 1
            do { $destFile = Join-Path $target ('{0}_{1}{2}' -f $base, $n, $ext); $n++ } while (Test-Path -LiteralPath $destFile)
        }
        try {
            Copy-Item -LiteralPath $f.FullName -Destination $destFile -ErrorAction Stop
            # Verify the copy by hash before we ever call this card safe
            $srcHash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            $dstHash = (Get-FileHash -LiteralPath $destFile     -Algorithm SHA256).Hash
            if ($srcHash -eq $dstHash) {
                $copied++
                Write-Host ("    copied + verified: {0}" -f $f.Name) -ForegroundColor Green
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

# --- Resolve the destination folder -------------------------------------------
if (-not $DestRoot) {
    $DestRoot = Join-Path $FootageRoot ("$Year")
}
if (-not (Test-Path -LiteralPath $DestRoot)) {
    Write-Host "Destination not found: $DestRoot" -ForegroundColor Red
    Write-Host "Edit `$FootageRoot in the CONFIG section, check -Year, or pass -DestRoot." -ForegroundColor Red
    [void](Read-Host "`nPress Enter to close")
    exit 1
}

# --- Decide which card roots to check -----------------------------------------
$cardRoots = @()
$sysDrive  = ($env:SystemDrive -replace '[^A-Za-z]','').ToUpper()
$destDrive = ([System.IO.Path]::GetPathRoot($DestRoot) -replace '[^A-Za-z]','').ToUpper()

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

# --- Index the destination tree ONCE (filename+size -> list of full paths) ----
Write-Host "`nIndexing $DestRoot (this can take a moment over a network)..." -ForegroundColor Cyan
$index   = @{}
$indexed = 0
Get-ChildItem -LiteralPath $DestRoot -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    $key = '{0}|{1}' -f $_.Name.ToLower(), $_.Length
    if (-not $index.ContainsKey($key)) {
        $index[$key] = New-Object System.Collections.Generic.List[string]
    }
    $index[$key].Add($_.FullName)
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

    $cardFiles = @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue)
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
        if ($index.ContainsKey($key)) {
            if ($Verify) {
                $srcHash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
                foreach ($dest in $index[$key]) {
                    if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -eq $srcHash) {
                        $status = 'OK'; $foundAt = $dest; break
                    }
                }
                if ($status -ne 'OK') { $status = 'CONTENT DIFFERS' }
            }
            else {
                $status = 'OK'; $foundAt = $index[$key][0]
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
        $verdict = 'SAFE TO FORMAT'
    }
    else {
        Write-Host "  $problems FILE(S) NOT BACKED UP - DO NOT format this card.  " -ForegroundColor White -BackgroundColor Red
        if ($missing.Count) {
            Write-Host "`n  Not found in $DestRoot :" -ForegroundColor Red
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
                $allOk = Copy-CardFiles -Files $toCopy.ToArray() -DestRoot $DestRoot
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
             elseif ($v.Verdict -like '*NOT BACKED UP*') { 'Red' }
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
