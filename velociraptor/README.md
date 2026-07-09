# Velociraptor collection notes

`IR_Compound_Full.mkape` only parses what a file-based collection captures
(`Windows.KapeFiles.Targets` or equivalent) - files on disk. It has nothing
to say about process/network/persistence state at the moment of collection,
because that state is gone by the time KAPE runs against the extracted
files. If the collector is still live when you run it, add the artifacts
below to the same collection to capture that too.

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
