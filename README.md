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
- Searches **all year folders** under your backup root in a single pass, so footage from any year is found automatically. Pass `-Year 2025` to narrow the search to one year for speed.
- Reports each card: backed up, or not — and lists exactly which files are missing.
- **Guards against failing cards**: if any files on a card can't be read during the scan, it flags the card `READ ERROR - DO NOT FORMAT` rather than silently skipping unreadable files and calling the card safe.
- Offers to **copy** missing files into a `YYYY-MM-DD - Name` folder routed to the **year folder matching each file's shoot date** (e.g. `D:\Footage\2025\2025-06-04 - Zion`), prompting for the date and location.
- **Verifies every copy with a SHA-256 hash** before marking a card safe.
- Only looks at the file types you choose (video by default) — thumbnails, proxies, and sidecars are ignored so they don't cause false alarms.
- Offers to safely eject each card that passed.
- **Loops automatically**: after each round it prompts you to insert the next card and press Enter to scan again. The backup index is built **once** per session, so only the first round walks the NAS — subsequent rounds are fast.
- Optional `-Verify` mode re-hashes files that are *already* backed up, for total certainty.
- `-NoLoop` disables the rescan prompt for single-shot or scripted use.

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
   Do the same for `Run SafeToFormat.bat` if you'll use the double-click launcher.
   *(Windows blocks downloaded files until you do this. Once only.)*

### Folder layout

The default layout has a year level between the backup root and the dated folders:

```
D:\Footage\
  2025\
    2025-10-14 - Fall Colors\
  2026\
    2026-05-31 - Zion Narrows\
    2026-06-02 - Snow Canyon\
```

By default the script indexes **all year folders** under `$FootageRoot`, so a card with footage from both 2025 and 2026 is handled correctly in one run. Copies are routed to the year folder that matches each file's shoot date automatically. Pass `-Year 2026` to narrow the index to a single year (faster on large archives).

**No year level?** Set `$UseYearFolders = $false` in the CONFIG section. The script will search and copy directly under `$FootageRoot`.

You can also pass `-DestRoot "X:\path"` to point at an exact folder, bypassing year handling entirely.

---

## Running it

**Easiest — double-click.** Run `Run SafeToFormat.bat`. It launches the script from the same folder and keeps the window open so you can read the results. Keep the `.bat` and `.ps1` together.

**From PowerShell.** In the folder, hold **Shift + right-click → "Open PowerShell window here"**, then:

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
| *(none)* | Check cards in a loop (insert, scan, eject, repeat), all year folders |
| `-Drives E,F,G` | Check only these drive letters |
| `-CardPath E:\` | Check one specific drive or folder |
| `-Verify` | Also hash-verify files that are already backed up (slower, certain) |
| `-Year 2025` | Narrow the search index to the 2025 year folder (faster on large archives) |
| `-NoCopy` | Read-only check; don't offer to copy missing files |
| `-NoEject` | Don't offer to eject cards |
| `-NoLoop` | Exit after one round instead of prompting to scan more cards |
| `-IncludeAll` | Check every file, not just the configured media types |
| `-DestRoot "X:\path"` | Search and copy into this exact folder, bypassing all year routing |
| `-ReportPath out.csv` | Save a full CSV report of every file and its status (all rounds combined) |

---

## How matching works

By default, files are matched by **filename + exact byte size** — fast and reliable for camera-original files. When a card passes, a note reminds you that this match is name+size only; run with `-Verify` if you want byte-level certainty before formatting something irreplaceable. Two caveats worth knowing:

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
