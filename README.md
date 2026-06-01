# SafeToFormat

**Know your camera cards are backed up before you wipe them.**

A small PowerShell script for photographers and video creators who offload SD / CF / CFexpress cards to a backup drive and want certainty — not hope — before formatting.

Drop every card you've got into readers, run it, and it tells you card by card whether the footage is already backed up. Anything missing, it offers to copy into a tidy dated folder and verifies the copy with a hash before it ever calls a card safe.

> **It never deletes or formats anything.** It only reads, copies, and verifies. You do the formatting yourself, once you trust the green `SAFE TO FORMAT`.

---

## Why it exists

Cards pile up on the desk. You *think* you copied Tuesday's footage, but did you grab Wednesday's? SafeToFormat replaces that nagging doubt with a clear per-card verdict.

It also handles a gotcha that breaks most quick scripts: **CFexpress and many CF card readers present the card to Windows as a "fixed disk,"** the same category as your internal SSD. A naive "find removable drives" approach skips them entirely. SafeToFormat detects them anyway (and still refuses to touch your system drive or your backup destination).

---

## What it does

- Detects every card plugged in — removable **and** fixed-disk readers (CFexpress/CF).
- Scans your backup folder and **all** its subfolders to see what's already there.
- Reports each card: backed up, or not — and lists exactly which files are missing.
- Offers to **copy** missing files into a new `YYYY-MM-DD - Name` folder, prompting for the date and location.
- **Verifies every copy with a SHA-256 hash** before marking a card safe.
- Only looks at the file types you choose (video by default) — thumbnails, proxies, and sidecars are ignored so they don't cause false alarms.
- Offers to safely eject each card that passed.
- Optional `-Verify` mode re-hashes files that are *already* backed up, for total certainty.

---

## Requirements

- Windows 10 or 11 (uses Windows PowerShell 5.1, which ships with both).
- A backup location: NAS share, external drive, or local folder.

---

## Setup (one time)

1. Download `SafeToFormat.ps1`.
2. Open it in any text editor and edit the **CONFIG** section near the top:
   ```powershell
   $FootageRoot = 'D:\Footage'        # your backup root
   $MediaExtensions = @('.mov','.mp4') # file types to check
   ```
3. Save it somewhere permanent.
4. Right-click the file → **Properties** → tick **Unblock** at the bottom → **OK**.
   *(Windows blocks downloaded scripts until you do this. Once only.)*

### Folder layout

By default the script looks inside `<FootageRoot>\<Year>\` and every subfolder beneath it, e.g.:

```
D:\Footage\
  2026\
    2026-05-31 - Zion Narrows\
    2026-06-02 - Snow Canyon\
```

If you don't organize by year, point `$FootageRoot` straight at the folder that holds your dated folders and run with `-DestRoot` (see options below).

---

## Running it

In the folder, hold **Shift + right-click → "Open PowerShell window here"**, then:

```powershell
.\SafeToFormat.ps1
```

Or make a desktop shortcut so you can double-click it. Shortcut target:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\SafeToFormat.ps1"
```

---

## Options

| Option | What it does |
| --- | --- |
| *(none)* | Check every card found, against the current year's folder |
| `-Drives E,F,G` | Check only these drive letters |
| `-CardPath E:\` | Check one specific drive or folder |
| `-Verify` | Also hash-verify files that are already backed up (slower, certain) |
| `-Year 2025` | Use a different year subfolder |
| `-NoCopy` | Read-only check; don't offer to copy missing files |
| `-NoEject` | Don't offer to eject cards |
| `-IncludeAll` | Check every file, not just the configured media types |
| `-DestRoot "X:\path"` | Point at an exact destination folder, skipping year handling |
| `-ReportPath out.csv` | Save a full CSV report of every file and its status |

---

## How matching works

Files are matched by **filename + exact byte size**, which is fast and reliable for camera-original files. Two caveats worth knowing:

- If your import process **renames** files, name-matching won't recognize them. SafeToFormat works best when your backup keeps the camera's original filenames.
- In rare cases two different clips can share a name *and* a byte size by coincidence. Use `-Verify` when you want byte-level certainty before formatting something irreplaceable.

Copies made by the script are always hash-verified regardless, because "the file exists" isn't the same as "the file is intact."

---

## A word of caution

This is a community tool, shared freely. **Test it on a card you can afford to be wrong about before you trust it with the keepers.** Verify the results match reality on your own setup, then make it part of your routine. The author and contributors aren't responsible for lost footage.

---

## License

MIT — see [LICENSE](LICENSE). Free to use, adapt, and share.

Built collaboratively with Claude.
