# IR Endpoint Investigations

A KAPE-based toolkit for triaging Windows endpoint forensic collections. Point
it at a collection, get back a parsed, organized set of timelines, registry
artifacts, event log detections, and browser history - ready to review in
standard DFIR tooling.

**Fastest way in:** clone the repo and run `.\scripts\Start-IRConsole.ps1` -
a numbered menu that covers every action in this README (setup, parsing a
host or a case, keeping tools updated) with no flags to remember. See Quick
start below.

It's built as a [KAPE](https://www.kroll.com/kape) Compound Module: one module
you select in gKAPE (or pass on the command line) that runs KAPE's own
official parsing modules for every artifact this project's target collection
format contains. There's very little custom code here on purpose - almost
everything is a reference to modules KAPE already ships, wired together and
kept up to date by two support scripts.

This workflow was heavily inspired by **Patterson Cake** (Director of
Incident Response at Black Hills Information Security) and his "Rapid
Endpoint Investigations" methodology - the overall approach here
(Velociraptor for collection, KAPE for parsing, Hayabusa for detection)
draws directly on it. His
[secure-cake/rapid-endpoint-investigations](https://github.com/secure-cake/rapid-endpoint-investigations)
repo is the reference implementation this project's KAPE parsing side was
built from; see the Roadmap section below for ideas borrowed from his
broader workflow that aren't implemented here yet. If you want to go deeper
than this README, his
[Antisyphon Training course on Rapid Endpoint Investigations](https://www.antisyphontraining.com/product/workshop-rapid-endpoint-investigations-with-patterson-cake/)
and the free
[BHIS hands-on IR workshop](https://www.blackhillsinfosec.com/event/4-hour-hands-on-ir-workshop-rapid-windows-endpoint-triage-w-patterson-cake/)
he runs are both worth your time - this repo only covers a slice of what he
teaches.

This README covers running the tooling. For what to actually do with the
output - where to start, how to pivot from a detection into a full timeline
- see [METHODOLOGY.md](METHODOLOGY.md).

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

Just two things you need to get yourself, in order:

1. **Windows**, with PowerShell 5.1+ and administrator rights (KAPE itself
   requires elevation, even just to parse).
2. **[KAPE](https://www.kroll.com/kape)**, downloaded separately - free, but
   gated behind accepting Kroll's terms on their site, so it can't be
   fetched by a script. Extract it to `C:\Tools\KAPE` (every default in this
   repo assumes that path; install it anywhere else and just pass
   `-KapePath` to every script instead).

That's it for manual setup - `git` and `tar.exe` are also used (to fetch a
couple of rule sets and extract collection zips/tool bundles), but both
already ship with any current Windows install, nothing to install yourself.
Everything else - EZ Tools, Hayabusa, Chainsaw, Hindsight, RegRipper, the
NirSoft browser tools, and optionally a broader analyst toolset - is fetched
automatically by the setup step below, straight from each tool's own
official source. This repo does not bundle or redistribute any third-party
binaries - **review each tool's own license before using it**; this project
just automates fetching and wiring them together.

## Quick start

### The easy way: the console

After KAPE is in place (see Prerequisites above), clone the repo and launch
the console:

```powershell
git clone https://github.com/FLINTEK-LLC/ir-endpoint-investigations.git
cd ir-endpoint-investigations
.\scripts\Start-IRConsole.ps1
```

Pick **`[1] Full workstation setup`** the first time - it deploys the module
and fetches the whole toolchain (EZ Tools, Hayabusa, Chainsaw, Hindsight,
RegRipper, NirSoft's browser tools, plus a broader analyst kit: the EZ Tools
GUI suite, Sysinternals Suite, and Autopsy). Two extras -
[Arsenal Image Mounter](https://arsenalrecon.com/downloads) and KAPE itself -
have no scriptable public download and will print a link if missing; grab
those manually. **A single tool failing to fetch here won't block you** - EZ
Tools is the only one Setup genuinely can't proceed without; everything else
is best-effort and reported at the end, and re-running Setup picks up
whatever didn't land the first time.

Then pick **`[6] Parse a single host collection`** (or `[7]` for a case with
several hosts) whenever you have a collection to run, and **`[3]`**/**`[4]`**
periodically to keep detection rules and the broader toolset current. The
menu prompts for whatever each action needs - a collection path, whether to
open the review workbook when done, and so on - so there's nothing to
memorize. It's a thin front end: every option just calls the same script
you'd otherwise run directly, so nothing here is different logic from the
command-line path below.

### Or drive it directly with flags (scripting/automation)

Every console action is also a standalone script. The same three steps as
above, as commands:

```powershell
# 1. Set up your workstation once
.\scripts\Setup-Workstation.ps1 -ToolsRoot C:\Tools -Mode Setup

# 2. Parse a collection - a .zip straight off the collector, or an
#    already-extracted folder, either way
.\scripts\Run-IRParse.ps1 -CollectionRoot "D:\Cases\HOST01.zip"

# 3. Keep it current
.\scripts\Manage-Tools.ps1 -Mode Update      # fast - Hayabusa/Chainsaw rule refresh
.\scripts\Setup-Workstation.ps1 -Mode Update # slower - refreshes the broader toolset
```

Output from step 2 lands next to the collection in `results\`. See "Using
it" below for what the collection needs to look like, what happens under
the hood, and how to drive it from the KAPE GUI instead.

## Using it

### Collection format

This module is built for a specific, common collection layout: a
[Velociraptor](https://docs.velociraptor.app/) offline collector (or any
collector using Velociraptor's `Windows.KapeFiles.Targets` artifact) produces
a container with an `uploads\` folder holding two accessor trees -
`uploads\ntfs\...` (raw NTFS artifacts like `$MFT`) and `uploads\auto\...`
(everything else - registry, event logs, prefetch, user profiles). Point
`-CollectionRoot` at either that container's `.zip` (as downloaded from the
collector) or an already-extracted folder - `Run-IRParse.ps1` extracts a zip
automatically the first time, to a sibling folder next to it, and reuses that
extraction on later runs against the same zip.

If your collector produces a different layout, the module itself doesn't
care - see "How it works" below for why - but `Run-IRParse.ps1`'s validation
check (which confirms an `uploads\` folder exists) and default output
location assume this layout specifically. Adjust `-OutputPath` if yours
differs.

### Script or GUI - pick one, they do the same thing

**Script:**

```powershell
.\scripts\Run-IRParse.ps1 -CollectionRoot <path> [-OutputPath <path>] [-KapePath <path>] [-ExtractPath <path>]
```

- `-CollectionRoot` (required) - a collection `.zip`, or an already-extracted
  collection folder.
- `-OutputPath` (optional) - defaults to `<CollectionRoot>\results` (using
  the resolved/extracted folder if `-CollectionRoot` was a zip).
- `-KapePath` (optional) - defaults to auto-detecting from the script's own
  location, falling back to `C:\KAPE`.
- `-ExtractPath` (optional) - where a `.zip` `-CollectionRoot` gets extracted.
  Defaults to a sibling folder next to the zip, named after it (minus
  `.zip`). Ignored if `-CollectionRoot` is already a folder.

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
- **`<Host>_<Date>_ReviewWorkbook.xlsx`** ([`New-ReviewWorkbook.ps1`](scripts/New-ReviewWorkbook.ps1)) -
  the files above, plus Hayabusa, Chainsaw, Amcache, Prefetch, Shimcache,
  LNK, and Recycle Bin output, merged into **one workbook, one worksheet per
  artifact**, each sorted chronologically, with AutoFilter on, the header row
  frozen, and columns autofit - every sheet is immediately filterable, no
  manual setup step. This is the actual fix for tab-switching between output
  folders during first-pass review. Requires Excel installed on the
  workstation running the parse (uses COM automation); skips itself with a
  clear message otherwise. `<Host>` comes from the hostname Velociraptor
  itself recorded at collection time (`client_info.json`), not the collection
  folder's name, so it's accurate even if an analyst renamed the folder -
  this keeps multiple hosts' workbooks distinguishable when several are open
  at once. Pass `-OpenWhenDone` to `Run-IRParse.ps1` to have it open
  automatically when a single-host parse finishes (off by default so
  `Start-CaseParse.ps1` doesn't pop a window per host).
- **`Review\`** ([`New-ReviewBundle.ps1`](scripts/New-ReviewBundle.ps1)) - the
  same set of files as the workbook, copied (not merged) into one folder with
  clear, `<Host>_<Date>_`-prefixed filenames. Always runs regardless of
  whether Excel is installed, as a portable fallback.

All five are extension/keyword-based first passes, not a substitute for the
full timeline/registry/event-log review - treat them as "start here," not
"this is everything."

`Run-IRParse.ps1` finishes with a **triage summary** - row counts for
Chainsaw Sigma hits, Hayabusa hits, curated EVTX rows, interesting files, and
browser history/downloads - printed to the console and appended to
**`RunLog.txt`** alongside the parameters used and start/end timestamps, so
you know how "hot" a host looks before opening the workbook, and have a
record of exactly what was run for case notes. `RunLog.txt` is appended to,
not overwritten, so re-running against the same collection keeps a history.

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
themselves compounds) plus two small custom modules:
`IR_00_ToolVerify.mkape`, which runs `Manage-Tools.ps1 -Mode Verify` and
writes the result to `IR\ToolVerify.txt`, and
`IR_10_Hayabusa_OfflineEventLogs.mkape`, a corrected stand-in for KAPE's own
stock Hayabusa module (stale against Hayabusa 4.0.0+ - see "Updating and
maintaining this module" below). This is the entirety of what's custom in
this repo - everything else is KAPE's own tooling, referenced by filename.

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

Lay out the case folder with one entry per host - either an already-extracted
collection subfolder (with its own `uploads\`) or a collection `.zip` - drop
zips in as you receive them, no need to extract each one yourself first:

```
D:\Cases\2026-07-INC1234\
  HOST01\uploads\...
  HOST02.zip
  HOST03.zip
```

A subfolder's name, or a zip's filename minus `.zip`, becomes that host's
label in the rollup and case summary.

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
  IR_10_Hayabusa_OfflineEventLogs.mkape  Custom - corrected replacement for KAPE's
                              stock Hayabusa module, stale against Hayabusa 4.0.0+
  IR_Compound_Full.mkape     The module you actually select in gKAPE - references
                              stock KAPE modules + the two custom ones above
scripts/
  workstation-tools.json     Declarative analyst-tool list read by Setup-Workstation.ps1 -
                              add/remove/retier a tool by editing this, not the script
  Start-IRConsole.ps1        Menu-driven front end for every script below - prompts
                              for whatever an action needs, no flags to remember
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
velociraptor/
  README.md                  Recommended live-state Velociraptor artifacts to
                              collect alongside file-collection (netstat/pslist/
                              autoruns/services/dnscache), broader dropper-location
                              file collection, and how to build a custom collector
  Custom.Windows.Hash.RecentExecutables.yaml  Custom Velociraptor artifact -
                              hashes recently-modified executables in writable
                              directories at collection time
  malware-drop-locations.csv Glob list for Generic.Collectors.File covering
                              real-world dropper/malware staging locations
  Build-Collector.ps1        Builds a full offline collector from the CLI
                              (Server.Utils.CreateCollector) - no GUI/server needed
infra/
  README.md                  Disposable per-case cloud investigation host + evidence
                              storage (AWS and Azure) - TUI-driven, see
                              "Cloud IR infrastructure" below
```

## Live system state at collection time

`IR_Compound_Full.mkape` only parses what a file-based collection captures -
files on disk, gone by the time KAPE runs. If your collector is still live
when it runs, [`velociraptor/`](velociraptor/) documents the built-in
Velociraptor artifacts worth adding alongside your file collection
(`Windows.Network.NetstatEnriched`, `Windows.System.Pslist`,
`Windows.Sysinternals.Autoruns`, `Windows.System.Services`,
`Windows.System.DNSCache`) plus a custom artifact for hashing recently
modified executables in common writable directories - adapted from
[secure-cake/rapid-endpoint-investigations](https://github.com/secure-cake/rapid-endpoint-investigations).
This is guidance and one adapted artifact, not a drop-in collector config -
a fully general Velociraptor collector build for an arbitrary environment
is still out of scope for this repo, since it varies too much
environment to environment. If you're using this project's own cloud IR
infrastructure (see [`infra/`](infra/) below), though,
`infra/scripts/New-CaseCollector.ps1` *does* build a working, case-scoped
collector for you end to end - that's a narrower, opinionated case than
"support every possible collector configuration."

## Cloud IR infrastructure

Don't have a pre-built physical/VM workstation for a case? [`infra/`](infra/)
provisions one on demand: a Velociraptor offline collector uploads
straight to per-case cloud storage (S3 or Azure Blob), a clean
investigation VM spins up with that storage mounted as its `D:` drive, and
when the case closes the VM is destroyed (storage persists, then archives
to cold tier). TUI-driven end to end, no public IP or open inbound port on
the host ever, and built to be handed to a partner organization to stand
up in their own cloud account - see [`infra/README.md`](infra/README.md)
for accounts/setup and [`infra/SECURITY.md`](infra/SECURITY.md) for the
security model.

## Updating and maintaining this module

- `Manage-Tools.ps1 -Mode Verify` - fast, no network calls, safe to run
  anytime. Checks every required tool is present, split into two tiers:
  **Core** (EZ Tools - the baseline parsers `IR_Compound_Full`'s stock
  modules directly depend on) and **Auxiliary** (Hayabusa, Chainsaw,
  Hindsight, RegRipper, the NirSoft browser tools - each adds real
  detection/enrichment value, but a parse still runs without any one of
  them). Only a missing **Core** tool fails `Verify`/`Setup` and blocks
  `Run-IRParse.ps1` from running KAPE at all; a missing Auxiliary tool is
  reported but doesn't block anything.
- `Manage-Tools.ps1 -Mode Setup` - fetches whatever `Verify` found missing.
  Each tool's installer is independent, so one flaky fetch (a site being
  temporarily unreachable) doesn't stop the others from being attempted -
  re-run `-Mode Setup` to pick up whatever didn't land the first time.
- `Manage-Tools.ps1 -Mode Update` - refreshes Hayabusa and Chainsaw's rule
  sets, and re-syncs EZ Tools. **Hindsight, RegRipper, and the NirSoft
  browser tools have no automated update mechanism** - re-run `-Mode Setup`
  to update those. Note this
  also triggers KAPE's own upstream sync process, which can reorganize
  `Modules\`/`Targets\` on the install - see the comments in
  `Manage-Tools.ps1` if you're extending this and land a custom module
  somewhere unexpected afterward.
- `Setup-Workstation.ps1 -Mode Update` - refreshes the broader analyst
  toolset. **Which tools that is now lives in
  [`scripts/workstation-tools.json`](scripts/workstation-tools.json)**, not in
  the script: each entry names a GitHub release (with an asset regex) or a
  direct URL, how to install it, and how to verify it landed. Adding a tool is
  usually copying the nearest entry and changing two fields.
  - `-Tier Standard` (default) / `-Tier Optional` / `-Tier All`
  - `-Include <name>` forces one in regardless of tier or `Enabled`;
    `-Exclude <name>` always wins. Both take wildcards.
  - `-DryRun` resolves every download and reports what *would* install,
    touching nothing - the cheap way to check a config edit is valid.
  - Downloads run in parallel, installs run serially (Windows Installer takes
    a machine-wide mutex, so concurrent MSIs would collide).
  - Writes `C:\ir-toolkit-manifest.json` recording every tool, its resolved
    version, where it came from and why it is on the box - so "which parser
    version touched this evidence?" has an answer months later.

  The KAPE-coupled toolchain (EZ Tools CLI, Hayabusa, Chainsaw, Hindsight,
  RegRipper, NirSoft) deliberately stays in `Manage-Tools.ps1`: those are tied
  to KAPE's own module layout and each has real per-tool quirks that a generic
  fetcher would express badly.

**A stock KAPE module can go stale when the tool it wraps changes its CLI** -
this happened for real with Hayabusa 4.0.0, which merged `csv-timeline`/
`json-timeline` into a single `dfir-timeline` command and broke KAPE's stock
`hayabusa_OfflineEventLogs.mkape` outright.
[`IR_10_Hayabusa_OfflineEventLogs.mkape`](Modules/!IR/IR_10_Hayabusa_OfflineEventLogs.mkape)
is a corrected replacement (see its own Documentation comment for the exact
flag mapping) - the pattern to follow if this happens again with another
tool: fork just that one module into `Modules/!IR/` with a fixed
`CommandLine`, point `IR_Compound_Full.mkape` at it instead of the stock
one, and leave a comment there explaining why. Switch back to the stock
module once/if an upstream KAPE sync ships a fix.

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

Ideas for where this could go next, several inspired by Patterson Cake's
[secure-cake/rapid-endpoint-investigations](https://github.com/secure-cake/rapid-endpoint-investigations)
and his broader Rapid Endpoint Investigations workflow:

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
- ~~Live system state at collection time, not just file artifacts~~ - done,
  see [`velociraptor/`](velociraptor/) and "Live system state at collection
  time" above: recommended built-in Velociraptor artifacts
  (`Windows.Network.NetstatEnriched`, `Windows.System.Pslist`,
  `Windows.Sysinternals.Autoruns`, `Windows.System.Services`,
  `Windows.System.DNSCache`) plus a custom artifact for recently-modified
  executable hashing, adapted from
  [secure-cake/rapid-endpoint-investigations](https://github.com/secure-cake/rapid-endpoint-investigations)'s
  `vr-win-hash-executables-artifact-rev2.yaml`. Documentation and one adapted
  artifact only - the collector config itself stays out of this repo's
  scope, since it varies too much environment to environment.
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
- ~~A short investigation-methodology guide~~ - done, see
  [METHODOLOGY.md](METHODOLOGY.md): where to start, how to pivot from a
  detection into surrounding MFT/Registry/Amcache/Prefetch/browser activity
  to scope what happened, and what to check when there's no detection to
  start from.
- ~~Disposable cloud infrastructure for cases without a pre-built
  workstation~~ - done, see [`infra/`](infra/): a TUI-driven, per-case
  investigation host (AWS or Azure) with evidence storage mounted as `D:`,
  a case-scoped collector build that uploads straight to it, and
  archival to cold storage on case close. Also inspired by Patterson
  Cake's broader workflow (see `infra/README.md`'s intro) - a
  Velociraptor *server* for mass deployment/threat hunting remains
  out of scope.

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
