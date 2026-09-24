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

[`..\scripts\Add-EvidenceToWorkbook.ps1`](../scripts/Add-EvidenceToWorkbook.ps1)
fills the Evidence Log from a manifest written by
[`..\scripts\Get-EvidenceManifest.ps1`](../scripts/Get-EvidenceManifest.ps1),
so a SHA-256 never has to be retyped:

```powershell
.\scripts\Add-EvidenceToWorkbook.ps1 `
    -ManifestPath D:\Cases\INC1234\HOST01\evidence-manifest.csv `
    -WorkbookPath D:\Cases\INC1234\INC1234-tracking.xlsx `
    -SourceHost HOST01 -CollectedBy 'D. Flinton'
```

By default it writes **one row for the whole collection**, and the hash it
records is the hash of the manifest. A triage collection is tens of thousands
of files and an evidence log with tens of thousands of rows is not an evidence
log; it records evidence items. Since the manifest lists every file's own
SHA-256, pinning the manifest pins the set, and
`Get-EvidenceManifest.ps1 -Verify` checks the files themselves.

`-Mode PerFile` writes a row per file, for the small targeted collections where
that is what you actually want. Re-running skips anything already logged by
hash, and `-CollectionMethod` is checked against the workbook's own `Lists`
values before anything is written.

`Artifact Source` on the Event Timeline carries entries like `EV 4624` and
`EV 4625`, which is the same vocabulary
[`..\scripts\Get-EvtxTriage.ps1`](../scripts/Get-EvtxTriage.ps1) produces.

## Appending rows

Every table sheet is a real Excel Table, so a row added at the bottom joins the
table and inherits its formulas, formatting and dropdowns. The `#` column is
`=ROW()-3` rather than typed numbers, so it renumbers itself.

Two sheets are deliberately not Tables. `Containment & Remediation` is three
stacked sections with their own header rows, and `Case Overview` is a form.

`Financial Impact` is a Table ending at row 33 with a TOTALS row at 34 just
below it. Insert rows inside the table rather than typing past it, and the
totals follow.
