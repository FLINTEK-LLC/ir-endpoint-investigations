# Case tracking template

`IR_Investigation_Template.xlsx` is a blank case workbook: somewhere to record
what happened, what you found, and what you did about it, while the parsing
side of this repo handles the artifacts.

Copy it per case. Do not work in the copy that lives here.

```powershell
Copy-Item templates\IR_Investigation_Template.xlsx D:\Cases\INC1234\INC1234-tracking.xlsx
```

## What is in it

Fourteen sheets. The first is a form; the rest are tables you append to.

| Sheet | For |
|---|---|
| Case Overview | Client, engagement, classification, key timestamps, rollup counts |
| Event Timeline | The master chronology, one row per event, MITRE ATT&CK per row |
| IOC Tracker | Hashes, addresses and domains, with first/last seen and status |
| Accounts | Every account involved, its privilege, and what was done about it |
| Sign-In Analysis | Entra/M365 sign-ins: IP, ASN, geo, MFA, conditional access, verdict |
| Mailbox & Tenant Changes | Inbox rules, delegations, app consents, tenant config |
| Email Analysis | Headers, SPF/DKIM/DMARC, attachments, recipient actions, purge state |
| Data Access & Exposure | What was reached, by whom, and how much of it |
| Attacker Tooling | Binaries found, where, hashes, whether they ran |
| Evidence Log | Chain of custody: item, collection method, SHA-256, storage location |
| Financial Impact | Wire/ACH fraud detail, recall status, net loss (calculated) |
| Containment & Remediation | Starter checklist of ~68 actions, pre-populated |
| Notifications & Comms | Who must be told, by when, and whether they were |
| Lists | Dropdown sources. Edit here to change every dropdown at once |

The shape leans toward business email compromise and M365 incidents while
still covering on-prem endpoint work, which matches what the rest of this
repo parses.

## The dropdowns are meant to be edited

Every dropdown reads from a named range over a column on `Lists`, defined with
`OFFSET`/`COUNTA` so the list grows automatically. Add a value to the bottom of
a column on `Lists` and it appears in the corresponding dropdown with no
further edits. `L_IncidentType`, `L_ArtifactSource` and friends are the names.

## Where it meets the rest of the repo

The Evidence Log's `Hash (SHA256)`, `Collected (UTC)` and `Collection Method`
columns line up with what [`..\scripts\Get-EvidenceManifest.ps1`](../scripts/Get-EvidenceManifest.ps1)
writes, and `Collection Method` already lists "Velociraptor Offline Collector",
"KAPE" and "FTK Imager (Disk Image)". Hash a collection on arrival and the
manifest gives you the evidence rows rather than transcribing them by hand.

`Artifact Source` on the Event Timeline carries entries like `EV 4624` and
`EV 4625`, which is the same vocabulary
[`..\scripts\Get-EvtxTriage.ps1`](../scripts/Get-EvtxTriage.ps1) produces.

## Known limits

The sheets are pre-built to a fixed number of rows, and the rollup formulas on
Case Overview read fixed ranges. Appending past the last pre-built row works,
but those rows fall outside the dropdowns and outside the counts. See the
repository README for the specifics if you plan to run a large case through it.
