# Working a case with this output

The [README](README.md) covers how to run the tooling. This is about what to
actually do with what comes out of it - where to start, and how to pivot
from a first lead into a real timeline of what happened on a host. It's a
starting framework, not a checklist to follow mechanically - every case is
different, and experience will move you off this path fast. That's fine.

## Start with detections, not the full timeline

Don't start by scrolling the full MFT or EVTX output - it's too much to
absorb without a lead to chase. Start with `ReviewWorkbook.xlsx` (or
`Review\` if Excel isn't available) and work these sheets first, in roughly
this order:

1. **Chainsaw-Sigma / Hayabusa** - Sigma rule hits. These are the highest
   signal-to-noise artifacts in the whole output; they're expressing "this
   specific pattern is suspicious," not just "this happened." Chainsaw and
   Hayabusa run different rule sets against the same logs, so a hit in one
   but not the other is still worth a look, not just the overlap.
2. **Triage-EVTX** - the curated Event ID window (logons, account changes,
   scheduled tasks, PowerShell script block logging, audit log clearing).
   No rule engine behind this one - it's just "these IDs, this window,"
   which will catch some things Sigma rules miss.
3. **Triage-Files** - recently created high-signal-extension files. Good for
   spotting a dropped payload even before you have an alert to explain it.
4. **BrowserHistory / BrowserDownloads / Hindsight's own output** - worth a
   scan for a likely delivery vector (a download immediately preceding
   suspicious activity is a strong link) even before you have a specific
   hit to explain.

Treat a hit in any of these as a **pivot point**, not a conclusion. The goal
of this first pass is to generate a short list of timestamps and
files/hosts/accounts worth digging into, not to decide what happened yet.

## Pivoting from a hit to a timeline

Once you have a timestamp and something concrete (a filename, a process, an
account, a scheduled task name) from a detection, the same basic move
applies every time: **use the timestamp as an anchor and look at every other
artifact in a window around it.**

- **Program execution evidence** - Amcache, Prefetch, Shimcache. Did the
  file/process the alert names actually run, and when? These three
  artifacts have different semantics and different reliability - Amcache
  and Prefetch are generally stronger evidence of actual execution than
  Shimcache (which can be populated without execution under some
  conditions) - so treat a hit in only one of them with more caution than a
  hit across all three.
- **File system evidence** - the full MFT output (not just
  `InterestingFiles.csv`, which is filtered and time-windowed) for the exact
  file named in the alert, and anything else created/modified in the same
  folder around the same time. `Created0x10`/`LastModified0x10` timestamps
  are attacker-controllable (MACB timestomping is a real thing) - if a
  timeline looks *too* clean, that's itself a signal.
- **Persistence** - RECmd batch output and RegRipper reports (Run keys,
  services, scheduled tasks) for anything referencing the file/path/account
  from the alert. Cross-reference against the live-state Autoruns/Services
  artifacts if you [collected them](velociraptor/README.md).
- **User interaction evidence** - LNK files, jump lists, shellbags,
  Windows Timeline (WxTCmd). Did a user actually open/navigate to the
  file or folder, or does everything point to non-interactive execution
  (scheduled task, service, remote exec)? This matters for figuring out
  whether you're looking at a phishing/user-driven compromise or something
  that came in another way.
- **Account/logon context** - EvtxECmd's full output for the account
  involved: where did it log on from (4624's logon type - RDP vs console vs
  network matters), around what other activity.
- **Cleanup/anti-forensics** - Recycle Bin (RBCmd). A file that was created,
  ran, and was then deleted within minutes is a stronger signal than one
  that just sat there - check whether anything relevant was deleted shortly
  after the activity you're investigating.
- **SRUM/SUM** - resource/network usage tied to the process, and (on
  systems where it's populated) some account-usage history. Useful for
  scoping how long something ran or how much data moved, less useful as a
  first lead.

You won't need all of these for every hit - which ones matter depends on
what you're chasing. A suspicious scheduled task points you straight at
persistence and account context; a suspicious download points you at
program execution and user interaction evidence instead.

## If you don't have a hit yet

Sometimes nothing lights up Chainsaw/Hayabusa and there's no obvious lead.
A few places worth checking even without a starting point:

- Prefetch/Amcache entries for LOLBins (`powershell.exe`, `wscript.exe`,
  `mshta.exe`, `certutil.exe`, `rundll32.exe`, and similar) with unusual
  command lines or parent processes - the full EvtxECmd output (event ID
  4688/1 if command-line auditing is enabled) has the command line itself.
- Recently modified executables in writable directories - if you
  [collected the custom hashing artifact](velociraptor/README.md), that
  output is exactly this: a short list of hashes worth a quick VirusTotal
  or internal-allowlist check.
- Scheduled task creation (event ID 4698) or new service installation
  (7045) outside business hours or from an unexpected account.
- `netstat`/`pslist`/`dnscache` live-state output (if collected) for
  connections to unfamiliar external addresses or domains, especially from
  processes that have no obvious reason to be making network connections.

## Multi-host cases

If you're working [`Start-CaseParse.ps1`](README.md#case-level--multi-host-use)
output, start with `CaseRollup\All-Hosts-EvtxTriage.csv` and
`All-Hosts-InterestingFiles.csv` sorted chronologically - the same activity
(a scheduled task name, an account, a file hash) appearing on multiple hosts
within a short window is usually the fastest way to establish scope and
spread, before you've fully worked any single host's own `ReviewWorkbook.xlsx`
in depth.

## A note on confidence

Every artifact here has known gaps and known ways to be wrong - Shimcache
without corresponding Amcache/Prefetch evidence, MFT timestamps under
timestomping, Sigma rules that fire on legitimate admin tooling. Don't
build a case on a single artifact type. The pattern that actually holds up
is the same one this whole workflow is built around: a detection gives you
a timestamp, and the timestamp lets you pull the same story from several
independent artifacts. When they agree, you have a finding. When they
don't, that disagreement is itself worth understanding before you write
anything down.
