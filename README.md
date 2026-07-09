# IR Endpoint Investigations

A KAPE-based toolkit for triaging Windows endpoint forensic collections. Point
it at a collection, get back a parsed, organized set of timelines, registry
artifacts, event log detections, and browser history - ready to review in
standard DFIR tooling.

It's built as a [KAPE](https://www.kroll.com/kape) Compound Module: one module
you select in gKAPE (or pass on the command line) that runs KAPE's own
official parsing modules for every artifact this project's target collection
format contains. There's very little custom code here on purpose - almost
everything is a reference to modules KAPE already ships, wired together and
kept up to date by two support scripts.

The overall approach - Velociraptor for collection, KAPE for parsing, Hayabusa
for detection - draws heavily on
[secure-cake/rapid-endpoint-investigations](https://github.com/secure-cake/rapid-endpoint-investigations),
a great reference for this style of rapid tactical triage. This project
focuses specifically on the KAPE parsing side as a Compound Module; see the
Roadmap section below for ideas borrowed from their broader workflow that
aren't implemented here yet.

## What it collects and parses

| Artifact | Tool(s) |
|---|---|
| `$MFT`, `$J` (USN journal), `$Boot`, `$SDS` | MFTECmd |
| Registry ASEPs, persistence, user activity (13 batches) + full hive autorip (SAM/SECURITY/SOFTWARE/SYSTEM/NTUSER/UsrClass, machine + every per-user hive) | RECmd, RegRipper |
| Shellbags | SBECmd |
| Shimcache | AppCompatCacheParser |
| Amcache | AmcacheParser |
| Prefetch | PECmd |
| LNK files, jump lists, Windows Timeline | LECmd, JLECmd, WxTCmd |
| SRUM / SUM | SrumECmd, SumECmd |
| Recycle Bin | RBCmd |
| Windows Event Logs - parsed three independent ways | EvtxECmd (structured CSV), Chainsaw (built-in + Sigma rule hunting), Hayabusa (Sigma timeline) |
| Browser history (all profiles, all browsers, all users, in one pass) | Hindsight |
| Broader browser coverage - history and downloads for non-Chromium browsers (Firefox, legacy Edge/IE) alongside Chromium ones | NirSoft BrowsingHistoryView, BrowserDownloadsView |

## Prerequisites

- **Windows**, with PowerShell 5.1+ and administrator rights (KAPE itself
  requires elevation, even just to parse).
- **[KAPE](https://www.kroll.com/kape)**, installed separately. KAPE is free
  but requires accepting Kroll's terms on their site - it isn't a plain public
  download, so it can't be fetched by a script. Install it to `C:\Tools\KAPE`
  (or anywhere - just point `-KapePath` at it).
- **git**, on your `PATH`. Used by the setup script to fetch a couple of
  rule sets whose GitHub release packaging doesn't include everything needed
  (see `scripts/Manage-Tools.ps1` comments if you're curious why).
- A collection to parse - see "Collection format" below for what this
  currently expects.

Everything else (EZ Tools, Hayabusa, Chainsaw, Hindsight, RegRipper, the
NirSoft browser tools, and optionally a broader analyst toolset) is fetched automatically by the setup
scripts below, straight from each tool's own official source. This repo does
not bundle or redistribute any third-party binaries - **review each tool's own
license before using it**; this project just automates fetching and wiring
them together.

## Quick start

**1. Set up your workstation once:**

```powershell
git clone https://github.com/FLINTEK-LLC/ir-endpoint-investigations.git
cd ir-endpoint-investigations
.\scripts\Setup-Workstation.ps1 -ToolsRoot C:\Tools -Mode Setup
```

This deploys the module onto your KAPE install and fetches the full toolchain:
EZ Tools, Hayabusa, Chainsaw, Hindsight, RegRipper, NirSoft's
BrowsingHistoryView/BrowserDownloadsView (via `Manage-Tools.ps1`),
plus a broader analyst kit - the EZ Tools GUI suite (Timeline Explorer,
Registry Explorer, etc.), Sysinternals Suite, and Autopsy. Two extras -
[Arsenal Image Mounter](https://arsenalrecon.com/downloads) and KAPE itself -
have no scriptable public download and will print a link if missing; grab
those manually.

**2. Parse a collection:**

```powershell
.\scripts\Run-IRParse.ps1 -CollectionRoot "D:\Cases\HOST01\collection"
```

That's it. Output lands in `<CollectionRoot>\results\`. See "Using it" below
for what the collection needs to look like, what happens under the hood, and
how to drive it from the KAPE GUI instead.

**3. Keep it current:**

```powershell
.\scripts\Manage-Tools.ps1 -Mode Update      # fast - Hayabusa/Chainsaw rule refresh
.\scripts\Setup-Workstation.ps1 -Mode Update # slower - refreshes the broader toolset
```

Run the first one before any significant investigation - detection rules are
a living data set and meaningfully improve between cases.

## Using it

### Collection format

This module is built for a specific, common collection layout: a
[Velociraptor](https://docs.velociraptor.app/) offline collector (or any
collector using Velociraptor's `Windows.KapeFiles.Targets` artifact) produces
a container with an `uploads\` folder holding two accessor trees -
`uploads\ntfs\...` (raw NTFS artifacts like `$MFT`) and `uploads\auto\...`
(everything else - registry, event logs, prefetch, user profiles). Extract
that container to a folder and that folder is your `-CollectionRoot`.

If your collector produces a different layout, the module itself doesn't
care - see "How it works" below for why - but `Run-IRParse.ps1`'s validation
check (which confirms an `uploads\` folder exists) and default output
location assume this layout specifically. Adjust `-OutputPath` if yours
differs.

### Script or GUI - pick one, they do the same thing

**Script:**

```powershell
.\scripts\Run-IRParse.ps1 -CollectionRoot <path> [-OutputPath <path>] [-KapePath <path>]
```

- `-CollectionRoot` (required) - the extracted collection folder.
- `-OutputPath` (optional) - defaults to `<CollectionRoot>\results`.
- `-KapePath` (optional) - defaults to auto-detecting from the script's own
  location, falling back to `C:\KAPE`.

It verifies every required tool is present first and aborts cleanly (with a
PASS/FAIL table) if anything's missing, rather than failing partway through a
20+ minute run.

**GUI:** Open `gkape.exe`. Set the module source to `<CollectionRoot>\uploads`,
the destination to `<CollectionRoot>\results`, pick `IR_Compound_Full` from
the module list, and run. No prep step - the script above is just this same
`kape.exe --module IR_Compound_Full` call with a tool-verify check wrapped
around it.

Either way, expect roughly 20-25 minutes for a full run - Chainsaw and
Hayabusa's rule matching across hundreds of event logs, plus RegRipper's
autorip across every user hive on the system, dominate the runtime.

### Reading the output

Output is organized by KAPE's own artifact categories under
`<OutputPath>\`:

| Folder | Contents |
|---|---|
| `IR\` | Tool verification result (`ToolVerify.txt`) |
| `FileSystem\` | MFT, USN journal, `$Boot`, `$SDS` CSVs |
| `Registry\` | RECmd batch output + RegRipper text reports (machine hives + every per-user hive) |
| `FileFolderAccess\` | Shellbags, LNK files, jump lists, Windows Timeline |
| `ProgramExecution\` | Shimcache, Amcache, Prefetch |
| `SRUMDatabase\` / `SUMDatabase\` | SRUM / SUM (SUM is typically empty on non-Server SKUs) |
| `FileDeletion\` | Recycle Bin |
| `EventLogs\` | EvtxECmd CSV, Chainsaw hunt output (rule + Sigma hits), Hayabusa Sigma timeline, plus `EvtxTriage.csv` (see below) |
| `WebBrowsers\` | Hindsight browser history/artifacts (xlsx), plus NirSoft BrowsingHistoryView/BrowserDownloadsView CSVs for non-Chromium coverage (see below) |

`Run-IRParse.ps1` also runs five fast triage steps automatically after every
parse (skip all of them with `-SkipTriagePostProcessing`, or run any one
standalone against existing results):

- **`FileSystem\InterestingFiles.csv`** ([`Get-InterestingFiles.ps1`](scripts/Get-InterestingFiles.ps1)) -
  MFT rows for high-signal extensions (`.exe`, `.ps1`, `.dll`, `.vbs`, `.zip`,
  etc.) created in the last 30 days, with common dev/package-manager noise
  (`node_modules`, `.git`, `WinSxS`, and similar) excluded by default. Tune
  `-DaysBack` and `-ExcludePathPattern` for your case.
- **`EventLogs\EvtxTriage.csv`** ([`Get-EvtxTriage.ps1`](scripts/Get-EvtxTriage.ps1)) -
  EvtxECmd rows for a curated set of high-value Event IDs (logons, account
  changes, scheduled tasks, PowerShell script block logging, audit log
  clearing) within the last 15 days by default. This is a starting point, not
  a replacement for the full EvtxECmd/Chainsaw/Hayabusa output - tune
  `-EventIds` for your environment.
- **`WebBrowsers\BrowsingHistory.csv` / `BrowserDownloadsView.csv`** ([`Get-BroaderBrowserHistory.ps1`](scripts/Get-BroaderBrowserHistory.ps1)) -
  runs NirSoft's BrowsingHistoryView and BrowserDownloadsView against the raw
  collection for browser coverage Hindsight doesn't provide (Firefox, legacy
  Edge/IE, and other non-Chromium browsers alongside Chromium ones). Unlike
  the other triage steps this reads the raw `uploads\` tree directly rather
  than KAPE's parsed output, since it needs to locate the actual `Users`
  folder first.
- **`ReviewWorkbook.xlsx`** ([`New-ReviewWorkbook.ps1`](scripts/New-ReviewWorkbook.ps1)) -
  the files above, plus Hayabusa, Chainsaw, Amcache, Prefetch, Shimcache,
  LNK, and Recycle Bin output, merged into **one workbook, one worksheet per
  artifact**, each sorted chronologically. This is the actual fix for
  tab-switching between output folders during first-pass review. Requires
  Excel installed on the workstation running the parse (uses COM automation);
  skips itself with a clear message otherwise.
- **`Review\`** ([`New-ReviewBundle.ps1`](scripts/New-ReviewBundle.ps1)) - the
  same set of files as the workbook, copied (not merged) into one folder with
  clear filenames. Always runs regardless of whether Excel is installed, as a
  portable fallback.

All five are extension/keyword-based first passes, not a substitute for the
full timeline/registry/event-log review - treat them as "start here," not
"this is everything."

For deeper review, load the CSVs into **Timeline Explorer** for the
MFT/USN/Prefetch/LNK/JumpList data, **Registry Explorer** for anything beyond
what the automated RECmd/RegRipper pass already pulled, and check the
Chainsaw and Hayabusa outputs side by side - they use different rule sets
against the same logs, so cross-referencing both catches more than either
alone. Both are included in the EZ Tools GUI suite fetched by
`Setup-Workstation.ps1`.

## How it works

KAPE has an official "Compound Module" mechanism: a `.mkape` file can list
other `.mkape` files as its processors instead of an executable, and KAPE
resolves and runs each one recursively. `Modules\!IR\IR_Compound_Full.mkape`
uses this to reference KAPE's own stock modules (`MFTECmd.mkape`,
`RegRipper.mkape`, `Chainsaw.mkape`, and so on - several of which are
themselves compounds) plus one small custom module,
`IR_00_ToolVerify.mkape`, which runs `Manage-Tools.ps1 -Mode Verify` and
writes the result to `IR\ToolVerify.txt`. This is the entirety of what's
custom in this repo - everything else is KAPE's own tooling, referenced by
filename.

Every referenced module either uses KAPE's built-in `FileMask`/`%sourceFile%`
mechanism (finds a given filename recursively under the module source,
regardless of how deep it's nested) or a tool's own recursive directory scan.
Neither needs to know anything about the specific folder structure a given
collector produces beyond "point me at the right starting folder" - which is
exactly why `-CollectionRoot\uploads` works as a single, fixed source
directory for the whole run.

## Case-level / multi-host use

`Run-IRParse.ps1` handles one host at a time. For an engagement spanning
multiple endpoints, [`Start-CaseParse.ps1`](scripts/Start-CaseParse.ps1) runs
it against every host collection under one case folder and rolls up the
fast-triage output across hosts:

```powershell
.\scripts\Start-CaseParse.ps1 -CaseRoot "D:\Cases\2026-07-INC1234"
```

Lay out the case folder with one subfolder per host, each an extracted
collection with its own `uploads\` folder (name each subfolder after the
actual hostname - that name becomes the label in the rollup):

```
D:\Cases\2026-07-INC1234\
  HOST01\uploads\...
  HOST02\uploads\...
  HOST03\uploads\...
```

After every host finishes, it writes `CaseRollup\All-Hosts-EvtxTriage.csv`
and `CaseRollup\All-Hosts-InterestingFiles.csv` - each host's fast-triage
output combined into one chronologically-sorted, case-wide view with a
`SourceHost` column, for spotting the same activity landing on multiple
endpoints (a scheduled task or account change appearing around the same time
on several hosts, for example). This intentionally only rolls up the
already-curated triage CSVs, not the full per-host output - that would be
enormous across many hosts - so it's still worth reviewing each host's own
`ReviewWorkbook.xlsx`/`Review\` individually.

## Repository layout

```
Modules/!IR/
  IR_00_ToolVerify.mkape     Custom - runs Manage-Tools.ps1 -Mode Verify
  IR_Compound_Full.mkape     The module you actually select in gKAPE - references
                              stock KAPE modules + IR_00_ToolVerify
scripts/
  Manage-Tools.ps1           Verify / Setup / Update the KAPE toolchain (EZ Tools,
                              Hayabusa, Chainsaw, Hindsight, RegRipper, NirSoft
                              browser tools)
  Setup-Workstation.ps1      Full workstation provisioning: deploys the module,
                              runs Manage-Tools.ps1, plus a broader analyst toolset
  Deploy-Module.ps1          Just (re)deploys the module files onto a KAPE install -
                              no tool-fetching. Called by Setup-Workstation.ps1
                              internally; run it directly for a fast redeploy
  Run-IRParse.ps1            Parses one collection, then runs the five triage
                              scripts below automatically
  Get-InterestingFiles.ps1   Fast triage: recent high-signal files from the MFT
  Get-EvtxTriage.ps1         Fast triage: curated Event IDs within a date window
  Get-BroaderBrowserHistory.ps1  Fast triage: NirSoft browser history/downloads for
                              non-Chromium browsers, against the raw uploads\ tree
  New-ReviewWorkbook.ps1     Merges the triage + highest-signal outputs into one
                              ReviewWorkbook.xlsx (one worksheet per artifact) -
                              requires Excel installed (COM automation)
  New-ReviewBundle.ps1       Same outputs as above, copied into one Review\ folder
                              instead of merged - no Excel required, always runs
  Start-CaseParse.ps1        Runs Run-IRParse.ps1 across every host under one case
                              folder, then rolls up fast-triage output across hosts
```

## Updating and maintaining this module

- `Manage-Tools.ps1 -Mode Verify` - fast, no network calls, safe to run
  anytime. Checks every required tool is present.
- `Manage-Tools.ps1 -Mode Setup` - fetches whatever `Verify` found missing.
- `Manage-Tools.ps1 -Mode Update` - refreshes Hayabusa and Chainsaw's rule
  sets, and re-syncs EZ Tools. **Hindsight, RegRipper, and the NirSoft
  browser tools have no automated update mechanism** - re-run `-Mode Setup`
  to update those. Note this
  also triggers KAPE's own upstream sync process, which can reorganize
  `Modules\`/`Targets\` on the install - see the comments in
  `Manage-Tools.ps1` if you're extending this and land a custom module
  somewhere unexpected afterward.
- `Setup-Workstation.ps1 -Mode Update` - refreshes the broader toolset
  (EZ Tools GUI suite, Sysinternals, Autopsy).

## Extending this

Adding a new artifact type is usually just adding one more entry to
`IR_Compound_Full.mkape`'s `Processors:` list, referencing an existing stock
KAPE module by filename (check `Modules\EZTools\`, `Modules\Compound\`, and
`Modules\Apps\` in your KAPE install first - there's a good chance the tool
you want is already covered). Only reach for a custom module if nothing stock
fits. A few things worth knowing if you do:

- KAPE only runs the **first** processor tied to any given `Executable` value
  across an entire run - if two processors (even in different modules)
  reference the identical executable string, the second is silently dropped.
  Give each genuinely distinct invocation its own module file.
- `.mkape` files require non-empty `Id` (a GUID - KAPE can generate one for
  you via `kape.exe --guid`), `Version`, and `Author` fields.
- Compound Module references resolve recursively, so nesting stock compounds
  inside your own compound works fine.

## Roadmap

Ideas for where this could go next, several inspired by
[secure-cake/rapid-endpoint-investigations](https://github.com/secure-cake/rapid-endpoint-investigations)'s
broader workflow:

- ~~A consolidated per-host review workbook~~ - done, see
  [`New-ReviewWorkbook.ps1`](scripts/New-ReviewWorkbook.ps1). A first attempt
  used the `ImportExcel` PowerShell module specifically to avoid requiring
  Excel on the analyst workstation, but hit a reproducible bug in the bundled
  EPPlus 4.5.3.2 (worksheet writes failed deterministically after the 5th
  sheet, regardless of row count, data content, or retries). Rebuilt on Excel
  COM automation instead - the same approach
  [secure-cake/rapid-endpoint-investigations](https://github.com/secure-cake/rapid-endpoint-investigations)'s
  `rtw-script` uses - with prompts suppressed programmatically instead of
  needing a click-through, and explicit COM object cleanup so it doesn't
  leave orphaned `EXCEL.EXE` processes behind. Requires Excel installed;
  [`New-ReviewBundle.ps1`](scripts/New-ReviewBundle.ps1) (a folder of the same
  CSVs, no merge) remains as a dependency-free fallback and always runs
  regardless of whether Excel is present.
- **Live system state at collection time, not just file artifacts.** This
  project's `IR_Compound_Full.mkape` only parses what a
  `Windows.KapeFiles.Targets`-style collection captures - files on disk.
  Pairing the collector with Velociraptor's `Windows.Network.NetstatEnriched`,
  `Windows.System.Pslist`, `Windows.Sysinternals.Autoruns`,
  `Windows.System.Services`, and `Windows.System.DNSCache` artifacts would
  capture running-process/network/persistence state that file-based triage
  alone misses, if the collector is still live when it runs.
- **A "recently modified executable" hunt at collection time.** A custom
  Velociraptor artifact that hashes recently-modified executables in common
  writable directories (`Users`, `ProgramData`, `Windows\Temp`) is a cheap,
  high-value way to surface likely droppers before deep analysis even starts.
- ~~Broader browser coverage~~ - done, see
  [`Get-BroaderBrowserHistory.ps1`](scripts/Get-BroaderBrowserHistory.ps1).
  Hindsight only covers Chromium-based browsers; this adds NirSoft's
  BrowsingHistoryView/BrowserDownloadsView for Firefox, legacy Edge/IE, and
  other non-Chromium coverage. Neither tool supports an arbitrary-depth
  recursive folder search - both need `/HistorySourceFolder`/`/SourceFolder`
  pointed directly at the folder containing user profiles - so this runs as a
  standalone step against the raw `uploads\` tree (locating the actual
  `Users` folder itself) rather than as a KAPE module processor, keeping
  `IR_Compound_Full.mkape`'s device-root-agnostic `msource` convention intact.
- ~~A fast, noise-reduced EVTX triage pass~~ - done, see `Get-EvtxTriage.ps1`.
- ~~An "interesting files" MFT view~~ - done, see `Get-InterestingFiles.ps1`.
- ~~Multi-host / case-level orchestration~~ - done, see
  [`Start-CaseParse.ps1`](scripts/Start-CaseParse.ps1) and "Case-level /
  multi-host use" above.
- **A short investigation-methodology guide.** This README documents how to
  run the tooling; it doesn't yet document how to actually work a case with
  the output - where to look first, how to pivot from a high-confidence
  Hayabusa/Chainsaw hit into surrounding MFT/Registry/Amcache/Prefetch
  activity to scope what happened. Worth adding once the workflow above
  stabilizes.

## Contributing

Issues and pull requests welcome. This reflects one team's current endpoint
investigation methodology and will keep evolving - if you adapt it for a
different collector, endpoint type, or artifact set, a PR is welcome.

## License

[MIT](LICENSE) for the scripts and module files in this repository. The
third-party tools this project fetches and orchestrates (KAPE, the EZ Tools
suite, Hayabusa, Chainsaw, Hindsight, RegRipper, and the others pulled in by
`Setup-Workstation.ps1`) are each under their own separate licenses - this
project does not redistribute them, only automates fetching them from their
official sources.
