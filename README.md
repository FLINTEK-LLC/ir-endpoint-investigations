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

Everything else (EZ Tools, Hayabusa, Chainsaw, Hindsight, RegRipper, and
optionally a broader analyst toolset) is fetched automatically by the setup
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
EZ Tools, Hayabusa, Chainsaw, Hindsight, RegRipper (via `Manage-Tools.ps1`),
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
| `EventLogs\` | EvtxECmd CSV, Chainsaw hunt output (rule + Sigma hits), Hayabusa Sigma timeline |
| `WebBrowsers\` | Hindsight browser history/artifacts (xlsx) |

For review, load the CSVs into **Timeline Explorer** for the
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

## Repository layout

```
Modules/!IR/
  IR_00_ToolVerify.mkape     Custom - runs Manage-Tools.ps1 -Mode Verify
  IR_Compound_Full.mkape     The module you actually select in gKAPE - references
                              stock KAPE modules + IR_00_ToolVerify
scripts/
  Manage-Tools.ps1           Verify / Setup / Update the KAPE toolchain (EZ Tools,
                              Hayabusa, Chainsaw, Hindsight, RegRipper)
  Setup-Workstation.ps1      Full workstation provisioning: deploys the module,
                              runs Manage-Tools.ps1, plus a broader analyst toolset
  Deploy-Module.ps1          Just (re)deploys the module files onto a KAPE install -
                              no tool-fetching. Called by Setup-Workstation.ps1
                              internally; run it directly for a fast redeploy
  Run-IRParse.ps1            Parses one collection
```

## Updating and maintaining this module

- `Manage-Tools.ps1 -Mode Verify` - fast, no network calls, safe to run
  anytime. Checks every required tool is present.
- `Manage-Tools.ps1 -Mode Setup` - fetches whatever `Verify` found missing.
- `Manage-Tools.ps1 -Mode Update` - refreshes Hayabusa and Chainsaw's rule
  sets, and re-syncs EZ Tools. **Hindsight and RegRipper have no automated
  update mechanism** - re-run `-Mode Setup` to update those two. Note this
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

- **A consolidated per-host review workbook.** Right now output is a pile of
  CSVs across ten category folders. A post-processing script that merges the
  highest-signal outputs (Hayabusa/Chainsaw hits, EvtxECmd, Amcache, Prefetch,
  browser history) into a single timestamp-sorted workbook per host would cut
  down a lot of tab-switching during initial review.
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
- **Broader browser coverage.** Hindsight only covers Chromium-based browsers.
  Adding NirSoft's BrowsingHistoryView/WebBrowserDownloads (or an equivalent)
  would pick up Firefox and legacy Edge/IE history too.
- **A fast, noise-reduced EVTX triage pass.** In addition to the full
  EvtxECmd/Chainsaw/Hayabusa output, a lightweight first-pass filter (a
  configurable date window plus a curated set of high-value event IDs -
  logons, account changes, scheduled tasks, service installs, PowerShell
  execution) would give analysts something to start with immediately, before
  digging into the full parsed output.
- **An "interesting files" MFT view.** A quick post-processing step that pulls
  just the MFT rows matching high-signal extensions (`.exe`, `.ps1`, `.dll`,
  `.vbs`, `.zip`, `.7z`, etc.) would surface likely-dropped files fast, ahead
  of a full timeline review.
- **Multi-host / case-level orchestration.** `Run-IRParse.ps1` handles one
  collection at a time. A wrapper that iterates every host collected under a
  case folder (prompting for a case name, running the module against each,
  and optionally rolling results up for cross-host comparison) would help on
  larger engagements.
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
