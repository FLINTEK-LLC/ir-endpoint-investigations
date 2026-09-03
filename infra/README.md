# Cloud IR infrastructure

Disposable cloud infrastructure so a case can be worked without a
pre-built physical/VM workstation: a Velociraptor offline collector
uploads straight to cloud storage; a clean investigation VM spins up per
case with that case's storage mounted as its `D:` drive; when the case
closes, the VM is destroyed (storage persists) and the storage is moved
to cold/archive tier.

This idea - collector output landing directly in cloud storage that then
becomes the investigation workstation's evidence drive - stems from work
by **Patterson Cake** (Director of Incident Response at Black Hills
Information Security); see the root [README](../README.md) for more on
his broader Rapid Endpoint Investigations methodology, which this whole
repo draws on.

**Fastest way in:** `.\Start-CloudConsole.ps1` - a menu covering
every action below (setup, create a case, build its collector, connect,
destroy, archive) with no Terraform or cloud CLI flags to remember. See
Quick start below.

Both AWS and Azure are supported, with the same case lifecycle on either
cloud - pick whichever your organization already has an account on. A
Velociraptor *server* (for mass deployment/threat hunting across many
endpoints) is intentionally out of scope here; this covers only the
single-case investigation host + evidence storage workflow.

## Getting around the console

Arrow keys move the selection, Enter chooses, Esc cancels, and typing a
number or a menu's letter key jumps straight to it. The default entry is
marked `(default)` and coloured, so pressing Enter always does the visible
thing.

Where raw key input is unavailable - piped stdin, the ISE, the VS Code
PowerShell host - the menu falls back to the numbered prompt this project
used before, accepting the same input and returning the same values. Both
consoles share `..\scripts\IRPrompt.ps1`; see its header for the details.

## Accounts, tokens, and secrets

This is the actual "getting started" barrier for a new organization using
this template, so it gets its own section up front, not buried in
Terraform variable descriptions.

**What you need before running anything:**

- **AWS**: an AWS account, and an IAM identity (an IAM user with
  programmatic access, or IAM Identity Center/SSO) with permission to
  create S3 buckets, IAM roles, EC2 instances, and security groups.
  `AdministratorAccess` will work but is broader than necessary; a scoped
  policy covering `s3:*`, `iam:*Role*`, `ec2:*`, and `ssm:*` on your
  account is enough for this project's own resources.
- **Azure**: an Azure subscription, and a user account with `Contributor`
  (or a scoped custom role covering resource groups, storage accounts,
  VMs, and Bastion) on it.

**Where credentials actually live - deliberately not a project-specific
secrets file.** `Start-CloudConsole.ps1`'s first-time setup
(`Test-Prerequisites.ps1`) guides you through each cloud's own official
local credential store - the same place your security team already knows
how to find, audit, and rotate:

```powershell
aws configure --profile ir-cloud   # -> stored in your own ~/.aws/credentials
az login                           # -> Azure CLI's own local token cache
```

Terraform's AWS/Azure providers read from these exact same standard
locations by default, so this is a **single setup step** that
authenticates both this console's direct cloud CLI calls (STS
`AssumeRole`, SAS token minting, tunnel/Bastion connections) and Terraform
itself. Neither this project nor its author ever sees or stores your
credentials - nothing here invents its own credential handling.

**What this project stores locally** (in `infra\.cases\<case_id>.json`,
gitignored - see the root [`.gitignore`](../.gitignore)): the case ID,
cloud, the actual Terraform variables used to create it (region/network/
sizing/immutability choices - kept so a later "destroy the host" or
"respin a clean host" doesn't need to re-prompt you), and the resulting
bucket/storage account name. This is bookkeeping, not secrets - no
credential material is ever written here or into any `.tfvars` file. If
you ever need to rebuild a lost `.cases\<case_id>.json` by hand, `terraform
output -json` (after `terraform workspace select <case_id>` in the right
`environments\` folder) gives you back everything but the original input
variables.

## Cost-consciousness

- **VM access is cheap on both clouds and never leaves a port open.** AWS
  uses SSM Session Manager (free beyond the instance). Azure defaults to a
  public IP behind a deny-all NSG, opened just-in-time to your own /32 only
  while you are connected (~$0.005/hr, and that IP doubles as the host's
  outbound egress). A no-public-IP Bastion path is also available per case
  at ~$0.29/hr - see "Connecting on Azure" below for the comparison.
- **Modest VM defaults** - AWS `t3.xlarge` (burstable), Azure
  `Standard_D4s_v5` (general-purpose, *not* burstable - the closest
  equivalent size) - overridable per case at creation if a case needs
  more. If you size the Azure VM down, prefer a `Bsv2`-series size such
  as `Standard_B2s_v2`: those have no local temp disk, whereas the
  original B-series (`Standard_B2s`) does, and Azure presents a local
  temp disk as **`D:`** - the same letter this project mounts case
  evidence on.
- **Ephemeral by design** - `[5] Destroy the investigation host` (evidence
  storage untouched) is a first-class, normal end-of-session menu action,
  not an afterthought, so idle compute doesn't sit there billing.
- **Storage is cheap while working, cheaper once archived** - standard
  tier while a case is active, automatically lifecycle-transitioned to
  Glacier/Archive after `archive_after_days` (default 30) even if you
  never touch the menu again, or immediately via `[6] Archive this case`.

  > **Pick `archive_after_days` to outlast your case, not your patience.**
  > Objects in Glacier (AWS) or the Archive tier (Azure) are **not
  > readable in place** - they must be restored/rehydrated first, which
  > takes hours and costs money. The investigation host mounts case
  > storage read-only, so anything that has transitioned mid-case will
  > simply fail to read from `D:` until you rehydrate it. The 30-day
  > default is fine for a fast triage engagement and too aggressive for a
  > long one; set it well beyond the window you actually expect to be
  > working the case.
- **`[7] List cases`** gives quick visibility into what's currently
  provisioned, so a running instance doesn't get forgotten about.

**One real cost/design trade-off worth knowing:** the investigation host
has **no public IP** (a deliberate security choice - see
[SECURITY.md](SECURITY.md)), which means the subnet you point it at must
already have its own outbound internet route (a NAT Gateway on AWS, a NAT
Gateway or equivalent on Azure) for it to reach SSM/Bastion, download its
bootstrap script, and mount cloud storage. Most existing/default VPCs or
VNets already have this if anything in them currently reaches the
internet; if you're building a network from scratch just for this, a NAT
Gateway is itself billed hourly (~$0.045/hr on AWS, similar on Azure) plus
data processing - factor that in, or ask whoever manages your cloud
network for a subnet that already has egress.

## Quick start

**Starting from zero cloud accounts?** Full from-scratch walkthroughs,
account creation through teardown: **[TESTING.md](TESTING.md)** for Azure,
**[TESTING-AWS.md](TESTING-AWS.md)** for AWS.

### First-time setup (once per machine)

```powershell
cd ir-endpoint-investigations\infra
.\Start-CloudConsole.ps1
```

Pick **`[1] First-time setup`** - it checks for (and, if you run an
elevated PowerShell session, installs) Terraform, the AWS CLI, the Azure
CLI, and the AWS Session Manager plugin, then reports whether
`aws configure --profile ir-cloud` / `az login` still need to be run. Do
those two once, and every case from here on just works.

### Working a case

1. **`[2] Create a new case`** - prompts for a case ID, cloud, region, an
   existing VPC/VNet + subnet (see the NAT note above), and a per-case
   immutability choice (see [SECURITY.md](SECURITY.md) for what
   GOVERNANCE vs. COMPLIANCE actually means before picking COMPLIANCE -
   it's irreversible). Runs `terraform apply` for that case's storage +
   investigation host.
2. **`[3] Build this case's offline collector`** - mints a short-lived,
   write-only credential scoped to exactly this case's bucket/container
   (an STS `AssumeRole` session on AWS, a time-limited SAS URL on Azure)
   and bakes it into a Velociraptor collector build via
   `New-CaseCollector.ps1`. Run the resulting collector on the endpoint(s)
   you're triaging - it uploads directly to this case's storage, nothing
   else to configure.
3. **`[4] Connect to the investigation host`** - gets you a Remote Desktop
   session through SSM (AWS) or Bastion (Azure) a few minutes after `[2]`
   finishes, once the bootstrap script completes, printing the generated
   local admin username/password to the console first (fetched fresh from
   Terraform state each time - never written to `infra\.cases\`; see
   [SECURITY.md](SECURITY.md)). Both clouds launch a real `mstsc.exe`
   session - on Azure that requires the shared Standard Bastion from
   `[B]` to be up; see "Connecting on Azure" below. Once inside, the
   case's evidence is mounted as `D:` (the bootstrap falls back to the
   next free letter if `D:` is taken, and records which one it used in
   `C:\ir-case-mount.txt`), and this repo's own
   `scripts\Start-IRConsole.ps1` is already on the box (bootstrap ran
   `Setup-Workstation.ps1` for you) - work the case as you normally would.
4. **`[5] Destroy the investigation host`** when you're done for the
   session (or between sessions) - evidence storage is untouched, and the
   console offers to immediately respin a clean host with the same
   settings if you're not done with the case yet. This is also literally
   what "clean slate on every re-deploy" means here: destroy-then-apply
   always produces a freshly bootstrapped VM, never a host carrying state
   from a previous run.
5. **`[6] Archive this case`** once the case is closed - offers to destroy
   the host (if still up), forces an immediate transition of the case's
   evidence to cold storage rather than waiting for the automatic
   30-day-default lifecycle rule, and (Azure only) offers to lock an
   already-set GOVERNANCE immutability policy into a COMPLIANCE-equivalent
   one now that the case is closing.

`[7] List cases` shows every case this console has created, its cloud,
status, and storage location.

### Shared infrastructure - created once, reused by every case

Networking and tools storage are deliberately **not** part of the per-case
Terraform. A case is disposable; a VNet is not, and most organisations
already have one they want these hosts to live in. Re-uploading a KAPE zip
for every case would be equally absurd. So both are one-time prerequisites,
and both are menu options rather than commands to hand-type:

- **`[8] Case networking`** creates the VNet/VPC and subnet an
  investigation host launches into, and deletes it again. On AWS this also
  creates a **NAT Gateway**, which is not optional: the host has no public
  IP by design, and an Internet Gateway only carries traffic for instances
  that *do*, so without NAT the host boots, never reaches SSM or the
  bootstrap script, and bills the whole time. It costs about $0.045/hr, so
  delete it when you're done. Azure needs no NAT - a VM with no public IP
  still gets outbound access from the platform - and a VNet costs nothing
  idle.
- **`[9] Tools storage`** creates the private bucket/storage account
  holding your licensed `kape.zip`, uploads or replaces that zip, and
  deletes the storage. KAPE can't be redistributed, so it isn't in this
  repo and can't be fetched from anywhere public - each organisation
  stages its own copy once, in its own account, and every host reads it
  read-only using the identity it already has. No keys, nothing to expire.
- **`[B] Azure shared Bastion`** deploys or destroys the per-VNet Bastion
  (see "Connecting on Azure" above). It bills **hourly from creation**
  whether or not anyone connects, which is why destroying it is a
  first-class action rather than a footnote.
- **`[P]`** prints what `[8]`/`[9]` recorded.

What they recorded is saved to `infra\.prereqs.json` (gitignored,
bookkeeping only - never credentials, same rule as `infra\.cases\`) and
offered as the **default** at `[2] Create a new case`. That turns the
subnet resource id and tools account id from things you keep on a sticky
note into a keypress, which is where copy/paste errors used to come from.

### Teardown and cost

- **`[C] Check what is still billing`** sweeps AWS and/or Azure for
  anything that could still be charging, and is worth running after every
  teardown. Checking by eye reliably misses the quiet ones: an EBS volume
  or managed disk bills whether or not it's attached to anything; an
  Elastic IP bills precisely when it is *not* associated; a NAT Gateway
  bills until its state actually reads `deleted`; a Bastion bills by the
  hour whether or not anyone uses it. Free leftovers (VPCs, resource
  groups) are listed separately so they don't look like charges. Answer
  yes to the all-regions/all-subscriptions sweep - something created in a
  region you've since forgotten about is the usual way a "torn down"
  account keeps billing.
- **`[D] Delete a case completely`** destroys the host *and* the evidence,
  removes the Terraform workspace, and deletes the local case record. It
  requires you to type the case ID, because it is irreversible. On AWS it
  empties the S3 bucket first and then lets Terraform delete the empty
  bucket: the module sets no `force_destroy`, on purpose, so a stray
  `terraform destroy` can never take evidence with it - which also means
  Terraform can't remove a bucket with anything in it. If the case's
  storage is under a COMPLIANCE immutability lock, this will *fail*, and
  that is the retention policy working as intended.

Use **`[6] Archive`**, not `[D]`, for a case that might still be needed:
it keeps the evidence and only stops the compute billing.

### Connecting on Azure - two options, pick per case

On **AWS**, `[4]` is settled: an SSM port-forwarding tunnel plus a normal
`mstsc.exe` window. Free, no public IP, no inbound port.

On **Azure** you choose per case at `[2]`, via `access_method`:

| | `rdp-allowlist` (default) | `bastion` |
|---|---|---|
| Cost | **~$0.005/hr** (public IP) | **~$0.29/hr** (Standard Bastion) |
| Public IP on host | Yes | No |
| Inbound port | 3389, open **only to your own /32, only while connected** | None, ever |
| Outbound egress | Provided by the public IP | **You must supply a NAT Gateway** |
| Setup | None | Deploy the shared Bastion once (`[B]`) |

**Why `rdp-allowlist` is the default.** Standard Bastion costs about as
much as the VM it fronts - $0.29/hr against $0.376/hr for the default
`Standard_D4s_v5`, and **3x** the $0.0924/hr of a small `Standard_B2s_v2`.
On top of that, Microsoft is withdrawing default outbound access ("for the
API released after March 31, 2026, new virtual networks default to using
private subnets"), so a host with no public IP now *also* needs a NAT
Gateway (~$0.045/hr) or its bootstrap cannot download anything. That makes
the Bastion path roughly **$0.335/hr of plumbing**, versus **$0.005/hr**
for a public IP that covers both jobs.

**How the allowlist stays honest.** The NSG carries no allow rules of its
own, so Azure's built-in `DenyAllInBound` blocks everything. `[4]` detects
your current public IP, adds a single rule permitting 3389 from that `/32`,
launches `mstsc`, and **removes the rule when the RDP window closes**. The
port is not left open for the life of the case. Use `-KeepOpen` to hold it
across reconnects, and `[L]` (or `-CloseOnly`) to lock it down again - `[L]`
exists because a killed console can't run its own cleanup.

Filtering happens at the Azure platform edge, so traffic from any other
address never reaches the VM. Combined with the generated 24-character
password and a host that only exists for one case, that is a defensible
posture for a single operator. Bastion's real advantages are that there is
no listener at all and no dependence on your IP staying put - if your
address changes often, or policy forbids any internet-facing RDP, choose
`bastion` and budget for the NAT Gateway.

## Architecture

```
infra/
  README.md                       This file
  SECURITY.md                     Trust boundaries, credential handling, retention/
                                   immutability defaults - the "why" behind every
                                   security decision below
  TESTING.md                      Concrete first-test walkthrough (Azure), starting
                                   from zero cloud accounts
  TESTING-AWS.md                  The same for AWS - includes the NAT Gateway the
                                   host needs, and teardown ordering
  Start-CloudConsole.ps1           The TUI - same thin-wrapper pattern as
                                   ..\scripts\Start-IRConsole.ps1
  modules/
    aws/
      case-storage/                S3 bucket: versioning, optional Object Lock +
                                    retention (per-case), SSE-KMS, public access
                                    blocked, lifecycle transition to Glacier
      case-role/                   IAM role: write-only to one case's bucket,
                                    assumable via STS for collector builds
      investigation-host/          EC2 Windows instance: no public IP, SSM-only,
                                    instance profile scoped to one case's bucket,
                                    bootstrap via user_data
    azure/
      case-storage/                Storage account + Blob container: versioning,
                                    optional immutability policy + retention,
                                    encryption, lifecycle to Archive tier
      investigation-host/          Azure VM: no public IP, system-assigned managed
                                    identity scoped to one case's container,
                                    bootstrap via Custom Script Extension. Does NOT
                                    create Bastion - see azure-bastion below.
  environments/
    aws-case/                      Root module: one case = case-storage + case-role
                                    + investigation-host, parameterized by case_id.
                                    Shared across every case - see "Terraform
                                    workspaces" below for how cases stay isolated.
    azure-case/                    Same shape, Azure resources
    azure-bastion/                 Shared, per-VNET Standard Bastion (AzureBastionSubnet
                                    + public IP + host, tunneling enabled). Deployed
                                    ONCE per VNet via [B], destroyed via [B] - not
                                    per case, because Azure allows only one Bastion
                                    per VNet. Its own state, default workspace.
  scripts/
    Test-Prerequisites.ps1         Checks/installs Terraform, AWS CLI, Azure CLI,
                                    the SSM Session Manager plugin, and each cloud's
                                    auth state - what [1] runs
    New-CaseCollector.ps1          Extends ..\..\velociraptor\Build-Collector.ps1:
                                    mints a short-lived credential (STS AssumeRole /
                                    SAS token) and bakes it into that case's offline
                                    collector build, targeting S3/Azure Blob directly
    Connect-InvestigationHost.ps1  Wraps the SSM port-forward / az bastion rdp
                                    tunnel and launches mstsc.exe
    fetch-and-bootstrap.ps1        Tiny first-boot shim (no git dependency): downloads
                                    this repo as a zip, hands off to the script below
    bootstrap-investigation-host.ps1  Installs rclone+WinFsp, mounts the case's
                                    bucket/container as D: (zero stored credentials -
                                    uses the host's own IAM role / managed identity),
                                    runs ..\scripts\Setup-Workstation.ps1, applies
                                    baseline host hardening
    New-AwsTestNetwork.ps1          Creates/deletes the AWS VPC, subnets and NAT
                                    Gateway a host launches into - run from [8]
    New-AzureTestNetwork.ps1        Same for the Azure VNet and subnet - run from [8]
    New-ToolsStorage.ps1            Creates/deletes the private bucket or storage
                                    account holding your licensed kape.zip, and
                                    uploads it - run from [9]
    Test-AwsTeardown.ps1            Reports anything in AWS that could still be
                                    billing after a teardown - run from [C]
    Test-AzureTeardown.ps1          Same for Azure - run from [C]
    Remove-AwsCaseStorage.ps1       Empties (or deletes) a versioned evidence
                                    bucket, which `aws s3 rb --force` cannot -
                                    run from [D]
  .cases/                          Local case bookkeeping (gitignored) - see
                                    "Accounts, tokens, and secrets" above
  .prereqs.json                    Which shared network/tools storage this machine
                                    created, so [2] can offer them as defaults
                                    (gitignored, bookkeeping only)
```

Every one of those scripts is reachable from the console, and none of them
needs to be run by hand - the menu prompts for what they need and passes it
through. They remain directly runnable for scripted teardown or when you
want to pass a non-default flag.

## Getting KAPE onto the host

The investigation host installs almost everything itself, but **not
KAPE** - Kroll gates it behind licence acceptance, so there is no
unattended download. Without it `Setup-Workstation.ps1` skips
`Deploy-Module.ps1` and `Manage-Tools.ps1` entirely, which is the whole
*parsing* toolchain: EZ Tools CLI parsers, Hayabusa, Chainsaw, Hindsight,
RegRipper. The bootstrap says so explicitly at the end of its run and
records it in `C:\ir-case-mount.txt`, rather than exiting 0 and letting
you discover it mid-case.

Everything else is automatic: the .NET 9 Desktop Runtime (EZ Tools are
net9 builds and Windows Server ships no .NET runtime), the EZ Tools GUI
suite, Sysinternals, and Autopsy.

### Recommended: a private tools container, separate from evidence

Stage your licensed KAPE once in a small, long-lived private container in
your own subscription, and every case's host pulls it automatically using
its own managed identity - no key, no SAS, nothing written to disk. A
~50 MB zip costs on the order of **two cents a month**.

**Use a separate storage account, not the case's evidence container.**
The evidence container is already mounted and the host already has read
access, which makes it tempting - but tooling staged there muddies chain
of custody, inherits any WORM retention you set on the case, gets
lifecycle-archived to cold tier out from under you, and has to be
re-uploaded per case.

One-time setup (pick your own account name - it must be globally unique):

```bash
az group create --name rg-ir-tools --location eastus
az storage account create --name stirtools$RANDOM --resource-group rg-ir-tools --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access false
az storage container create --name irtools --account-name <the-name-you-just-used> --auth-mode login
az storage blob upload --account-name <the-name-you-just-used> --container-name irtools --name kape.zip --file C:\path	o\your\kape.zip --auth-mode login
az storage account show --name <the-name-you-just-used> --query id -o tsv
```

Give that last resource ID to `[2] Create a new case` when it asks for
"Tools storage account resource ID" (blank skips the whole thing).
Terraform then grants that case's host `Storage Blob Data Reader` on the
tools account only, and the bootstrap extracts `kape.zip` to
`C:\Tools\kape` before `Setup-Workstation.ps1` runs - so it finds
`kape.exe` and installs the full toolchain.

**Distributing this to partner orgs:** each org stages *their own*
licensed KAPE in *their own* storage account. Nothing licensed is ever
redistributed by this repo, and no org needs access to another's storage.
Check your own KAPE licence terms before staging it anywhere shared
beyond your organisation.

### Can I just use OneDrive?

You can, and there's now a `tools_zip_url` variable for exactly that - but
it is the weaker option, and the reason is specific to *this* machine
rather than a general dislike of OneDrive.

Every authenticated route to OneDrive puts a broad, long-lived credential
on the investigation host:

- **rclone's OneDrive backend** completes an interactive OAuth flow and
  then stores a **refresh token** in `rclone.conf` on the VM. Per rclone's
  own documentation that token also expires after 90 days of disuse and
  needs reconnecting. It is scoped to your OneDrive - not to one zip.
- **Microsoft Graph app-only** access needs `Files.Read.All`, which is
  tenant-wide read of every file the app can see - an enormous blast
  radius to hand a box whose entire job is handling attacker artifacts.
  (`Sites.Selected` can scope to a single SharePoint site, but not to a
  personal OneDrive, and adds real setup complexity.)

That directly contradicts the design's central property: the host holds
**no credentials at all**, and the one identity it has is read-only on
exactly one container.

The unauthenticated route - an "Anyone with the link" share - avoids the
credential problem but makes a **licensed binary downloadable by anyone
who obtains the URL**, relies on an undocumented direct-download URL
format, and is blocked outright by policy in many business tenants.

**The good compromise: keep OneDrive as your master copy, and use the blob
container purely as the distribution point.** Manage and version KAPE
wherever you like, and push it to the tools container when it changes:

```bash
az storage blob upload --account-name <name> --container-name irtools --name kape.zip --file "C:\Users\you\OneDrive - Contoso\Tools\kape.zip" --auth-mode login --overwrite
```

You already pay for the Azure subscription this runs in, and a 50 MB blob
costs on the order of two cents a month - so the saving from reusing
OneDrive is negligible, while the security difference is not.

If you still want the direct route, set `tools_zip_url` to a share link
with `&download=1` appended (so it returns the file rather than an HTML
preview page). Treat that URL as a secret: it lands in Terraform state,
and the bootstrap deliberately never writes it to the host's log.

### Alternatives

- **Copy it over the RDP session** once per host. Zero setup, but manual
  every time you respin - which defeats the "clean slate on every
  redeploy" model.
- **Bake a custom image** (Azure Compute Gallery) with KAPE and the
  toolkit preinstalled. Fastest boots and no per-host setup, at the cost
  of an image to patch and re-harden. Worth it at high volume.
- **Your existing artifact repo** (Azure Artifacts, an internal file
  server) if you already have one - the same bootstrap hook works, it
  just needs its own auth.

## Terraform workspaces - how multiple cases share one set of folders

`environments\aws-case` and `environments\azure-case` are **shared root
modules** - the same folder is reused for every case, parameterized by
`-var case_id=...`. Running `terraform apply` for a second case in the
same Terraform *state* would destroy the first case's resources.

**Terraform workspaces** solve this: `terraform workspace new/select
<case_id>` gives each case its own state file
(`terraform.tfstate.d\<case_id>\terraform.tfstate`) within that same
shared folder, so cases never collide. Every Terraform-calling action in
`Start-CloudConsole.ps1` (and in `New-CaseCollector.ps1` and
`Connect-InvestigationHost.ps1`, which only *read* a case's state) selects
or creates the right workspace first, automatically - **if you ever run
`terraform` by hand in one of these folders, do the same** (`terraform
workspace select <case_id>` before `plan`/`apply`/`destroy`/`output`), or
you'll be operating on the wrong case's state (or the shared `default`
workspace, which should stay empty).

State stays **local** (each `environments\*-case` folder's own state
directory), not a shared remote backend - a case is a single-operator,
short-lived resource, and a new organization trying this template
shouldn't also need to stand up shared state infrastructure just to try
it. If you outgrow this (a team sharing cases, wanting state locking),
migrating to a remote backend (S3+DynamoDB, or an Azure Storage backend)
is a standard Terraform operation (`terraform init -migrate-state` after
adding a `backend` block) - not done here by default.

## Reuse - nothing here duplicates the root project's logic

- `..\scripts\Setup-Workstation.ps1` - called by
  `bootstrap-investigation-host.ps1` exactly as-is, to install the
  KAPE/EZ Tools/etc. toolkit on the fresh investigation VM.
- `..\velociraptor\Build-Collector.ps1` - `New-CaseCollector.ps1` extends
  this rather than reimplementing it: same argv-escaping function, same
  `Server.Utils.CreateCollector` invocation, same base artifact list -
  only the credential minting and the S3/Azure Blob `target`/`target_args`
  are new.
- `..\velociraptor\malware-drop-locations.csv`,
  `Custom.Windows.Hash.RecentExecutables.yaml` - used as-is by
  `New-CaseCollector.ps1`'s default artifact set.
- `..\scripts\Start-IRConsole.ps1`'s menu/helper-function pattern
  (`Read-Default`, `Read-Required`, `Read-YesNo`, thin-wrapper
  `Invoke-*` calls to separate script processes) is the direct template
  `Start-CloudConsole.ps1` follows.

## Verification

Every Terraform module here has been checked with `terraform fmt -diff`
and `terraform validate` (`terraform init -backend=false` first, since no
live cloud credentials are available in the environment this was
authored in), and every PowerShell script with
`[System.Management.Automation.Language.Parser]::ParseFile` plus
non-privileged dry runs of its pure logic. **No live `terraform apply`,
cloud login, or credential minting has been run against a real account as
part of building this** - the first real end-to-end run (an actual `[2]
Create a new case` against your own AWS/Azure account) is yours to do and
report back any issue with, the same working pattern used throughout this
project's own development.
