# Velociraptor collection notes

`IR_Compound_Full.mkape` only parses what a file-based collection captures
(`Windows.Triage.Targets`, formerly `Windows.KapeFiles.Targets` - see
"Building a custom offline collector" below for why the name changed - or
equivalent) - files on disk. It has nothing to say about process/network/
persistence state at the moment of collection, because that state is gone
by the time KAPE runs against the extracted files. If the collector is
still live when you run it, add the artifacts below to the same collection
to capture that too.

The Velociraptor collector configuration itself (which artifacts your
collector binary ships with, how it's built/signed/distributed) is
deliberately out of scope for this repo - every environment's collector
setup differs too much for one config to fit all of them. What's here is
guidance and one adapted custom artifact, not a drop-in collector profile.

## Recommended built-in artifacts

Add these alongside your file-collection artifact when building/updating
your Velociraptor collector, if collection-time live state matters for your
case (it usually does for anything that looks like active or recent
intrusion, less so for a purely historical/scoping pull):

| Artifact | Captures | Why it matters |
|---|---|---|
| `Windows.Network.NetstatEnriched` | Active TCP/UDP connections, enriched with owning process | C2 callbacks and active lateral-movement connections that won't show up anywhere in a file-based collection - this is your only shot at seeing them, since they're gone the moment the process exits or the box reboots |
| `Windows.System.Pslist` | Running process list (PID, PPID, path, command line, user) | Ground truth for what was actually executing, to cross-reference against Prefetch/Amcache/Shimcache's "ran at some point" evidence |
| `Windows.Sysinternals.Autoruns` | Persistence mechanisms (run keys, services, scheduled tasks, WMI subscriptions, etc.) | Sysinternals' own enumeration is broader than what RegRipper/RECmd's batch plugins cover alone - good to have both |
| `Windows.System.Services` | Installed services, their state, and binary path | Cross-reference against Autoruns and EvtxECmd's service-related event IDs (7045 is already in `Get-EvtxTriage.ps1`'s default filter) |
| `Windows.System.DNSCache` | Locally cached DNS resolutions | Domains a host actually resolved, including ones with no corresponding browser history - useful for non-browser C2/malware traffic |

All five are built into Velociraptor - no custom artifact needed, just add
them to the collector's artifact list.

## Custom artifact: recently-modified executable hashing

[`Custom.Windows.Hash.RecentExecutables.yaml`](Custom.Windows.Hash.RecentExecutables.yaml)
hashes (SHA1) recently-modified executable-ish files (`.exe`, `.dll`, `.ps1`,
`.bat`, `.cmd`, `.vbs`, `.scr`, `.json`, plus two configurable extra
extensions) in the most common user-writable directories (`C:\Users`,
`C:\ProgramData`, `C:\Windows\Temp`). It's a cheap, high-value way to surface
likely droppers before deep analysis even starts - a handful of unfamiliar
hashes in a writable directory, modified in the last few days, is often the
fastest path to a first lead.

Adapted from
[secure-cake/rapid-endpoint-investigations](https://github.com/secure-cake/rapid-endpoint-investigations)'s
`vr-win-hash-executables-artifact-rev2.yaml` - same underlying PowerShell/VQL
approach, renamed with the `Custom.` prefix Velociraptor's own convention
recommends for user-added artifacts (so an artifact-pack update never
silently overwrites it).

To use it: import the YAML into your Velociraptor server (Artifacts →
Manage custom artifacts → paste/upload) or drop it into your collector
build's custom artifact folder, then add `Custom.Windows.Hash.RecentExecutables`
to the collector's artifact list. Its output lands in the collection like any
other artifact - it isn't parsed by `IR_Compound_Full.mkape` (there's nothing
for KAPE to do with a hash list), review it directly from the collection.

Parameters (all have defaults, override at collection build time if needed):

- `DaysSinceModified` (default `5`) - recency window.
- `AddFileExtension1` / `AddFileExtension2` (default `.vhd` / `.iso`) - two
  extra extensions on top of the built-in list, for anything specific to
  your environment.

## Broader dropper-location file collection

The hashing artifact above only covers `C:\Users`, `C:\ProgramData`, and
`C:\Windows\Temp`. [`malware-drop-locations.csv`](malware-drop-locations.csv)
is a glob list for Velociraptor's own built-in **`Generic.Collectors.File`**
artifact (`collectionSpec` parameter - a CSV with a `Glob` column) that
actually collects the file content, not just a hash, from a wider set of
locations threat actors commonly use to stage droppers and payloads -
compiled from real-world IR engagement experience, not just guesswork:

- User-writable staging spots beyond the obvious: `C:\Intel`, `C:\PerfLogs`,
  `C:\ProgramData`, `C:\Users\Public`
- Executables/scripts dropped directly in a user's profile root, or hidden
  under Pictures/Music/Videos (a real technique - AV/EDR attention skews
  toward `Downloads`/`Desktop`/`AppData`, less toward media folders)
- `.ssh` (key/config theft, not just droppers)
- `AppData\Local`/`AppData\Roaming` (shallow, top level only - most of the
  deeper coverage there already comes from `Windows.Triage.Targets`
  itself; this is a supplementary catch-all, not a replacement)

No custom artifact needed - `Generic.Collectors.File` ships with
Velociraptor. Add it to your collector's artifact list alongside
`Windows.Triage.Targets`, and set its `collectionSpec` parameter to this
CSV's content (`Root=C:`, `Accessor=auto` match the artifact's own
defaults - no reason to need raw NTFS access for these paths, they're
ordinary unlocked, user-writable files). Files it collects land in the same
`uploads\` tree as everything else, so `IR_Compound_Full.mkape` picks them
up automatically - nothing to change on the KAPE side.

## Building a custom offline collector (CLI)

[`Build-Collector.ps1`](Build-Collector.ps1) builds a self-contained
Velociraptor offline collector - the artifacts above (this project's
recommended set), the custom hashing artifact, and the dropper-location file
collection - from the command line, no GUI/server required. Run it in an
**elevated** PowerShell window pointed at a plain Velociraptor binary (not
an already-repacked collector - every Velociraptor binary, plain or
repacked, refuses to run at all without elevation, confirmed directly):

```powershell
.\Build-Collector.ps1 -VeloExe C:\Tools\velociraptor.exe
```

It uses `Server.Utils.CreateCollector` - the same server artifact the GUI's
"Offline Collector Builder" calls internally - rather than the simpler
`config repack` trick, specifically because `config repack` does not
reliably carry a required artifact's bundled third-party tool (e.g.
Autoruns' `autorunsc.exe`) into the new binary, which would silently break
that artifact at collection time.

Getting this working surfaced four real, non-obvious problems, each
confirmed by directly triggering and diagnosing it rather than guessed -
worth knowing if you're extending this further:

1. **`Windows.KapeFiles.Targets` is not built into current Velociraptor
   releases.** Confirmed directly: "Loaded 421 built in artifacts" is
   identical whether or not the artifact is expected to be present. It was
   split out of the main binary into a separate "Triage Artifacts" project
   ([triage.velocidex.com](https://triage.velocidex.com/); see
   [Velocidex/velociraptor discussion #4481](https://github.com/Velocidex/velociraptor/discussions/4481),
   *"I miss you, KAPE"*). The current artifact is **`Windows.Triage.Targets`**
   - the script downloads its YAML definition directly from that project and
   loads it via `--definitions`. Its actual parameter is `HighLevelTargets`
   (confirmed from the artifact's own declared schema - `type: multichoice`,
   `default: "[]"`), a JSON array *encoded as a string*, not a bare
   `_SANS_Triage: Y` key.
2. **`Server.Utils.CreateCollector` needs the base client binary registered
   as a named tool first.** Without it: `Tool VelociraptorWindows not
   declared in inventory`. Fixed with `inventory_add()`, pointing at the
   same binary running the script.
3. **PowerShell does not correctly pass embedded double quotes to a native
   executable.** Handing a JSON string containing `"` characters to a
   native exe via PowerShell can silently corrupt it, and *how* depends on
   the exact backslash count already preceding each quote - confirmed by
   deliberately triggering the corruption and reading the real rule
   (Windows' own `CommandLineToArgvW` argv-parsing convention) off the
   result: a run of *N* backslashes immediately before a literal quote
   becomes *N/2* literal backslashes if *N* is even (the quote itself is
   consumed as a delimiter, never appearing in the output), or *(N-1)/2*
   backslashes plus one literal quote if *N* is odd. `ConvertTo-NativeArg`
   in the script implements this correctly so nothing needs hand-escaped
   JSON strings.
4. **`Get-Content -Raw` doesn't return a plain string.** It returns a string
   *decorated* with filesystem note properties (`PSPath`, `PSDrive`,
   `PSProvider`, etc.). `ConvertTo-Json` beyond `-Depth 2` serializes those
   note properties instead of the plain text - and since `PSDrive`/
   `PSProvider` nest further, the output size explodes exponentially with
   `-Depth` (confirmed directly: 815 bytes at `-Depth 2`, 2.2MB at
   `-Depth 6`, effectively hung well before `-Depth 10` - this is what a
   "the script just hangs" symptom actually was). A plain `[string]` cast
   discards the decoration and fixes both the correctness bug and the
   blowup, at any depth.

The script fetches `Windows.Triage.Targets.yaml` into `-DefinitionsFolder`
automatically if not already present, so it stays current with whatever
that project currently ships rather than being committed here stale.
