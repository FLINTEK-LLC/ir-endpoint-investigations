# Security model

This is a forensic workset - evidence integrity and chain-of-custody
concerns shaped every design choice below, not just "don't get hacked."
This document is the "why" behind each one, so a partner organization
adopting this template understands the trust boundaries before they
change anything.

## Threat model, briefly

Two things this design specifically defends against:

1. **The investigation host itself gets compromised** (it's actively
   handling attacker-produced files during triage - that's the job). A
   compromise here must not: leak long-lived cloud credentials, let an
   attacker read/tamper with *other* cases' evidence, or let an attacker
   silently alter *this* case's evidence in a way that survives review.
2. **The collector's upload credential is exposed** (it runs on a
   possibly-compromised endpoint, by definition - it's collecting
   forensic evidence from a system under investigation). Exposure here
   must not grant read access, list access, or any access beyond writing
   new objects to exactly one case's storage, and must expire quickly on
   its own.

Out of scope: physical security of wherever you run `Start-CloudConsole.ps1`
from, and compromise of your AWS/Azure account itself (IAM/root account
hygiene is your organization's responsibility, not this project's).

## Credential handling

**Nothing in this project stores a long-lived cloud credential anywhere.**

- **Operator credentials**: `aws configure --profile ir-cloud` / `az
  login` - each cloud's own official local credential store, not
  something this project invents. See `README.md`'s "Accounts, tokens,
  and secrets" section.
- **Investigation host credentials**: an AWS IAM instance role / Azure
  system-assigned managed identity, scoped to **read-only on exactly one
  case's bucket/container** (`s3:GetObject`/`s3:ListBucket` on one ARN;
  the "Storage Blob Data Reader" role on one storage account). `rclone`
  mounts the case's storage as `D:` using **ambient identity** -
  `env_auth=true` on AWS (pulls from the instance role via IMDS),
  `use_msi=true` on Azure (pulls from the managed identity) - meaning
  **zero credentials are ever written to disk** on the investigation
  host. A full host compromise exposes only that one case's evidence,
  read-only, for as long as the host exists - which you control directly
  via `[5] Destroy the investigation host`.
- **Collector upload credentials**: minted fresh by `New-CaseCollector.ps1`
  at build time, **write-only** (`s3:PutObject` only; a SAS URL with `cw`
  - create+write - permission only, no read/list/delete), scoped to
  exactly one case's bucket/container, and short-lived:
  - AWS: a real STS `AssumeRole` session token (not a static IAM user
    key) - defaults to a 1-hour duration, configurable per build via
    `-DurationSeconds`. Confirmed directly against Velociraptor's own
    source that its S3 upload accessor supports the full 3-part STS
    credential set (access key, secret key, session token), so this is a
    genuine temporary credential, not a long-lived one baked into a
    binary.
  - Azure: a SAS URL with an explicit expiry (`-SasExpiryHours`, default
    4 hours). Azure has no direct `AssumeRole` equivalent for Blob SAS
    minting, so the expiry window is the actual containment here - keep
    it close to how long the collector realistically needs to run and
    upload.
  - Either way: a collector binary carrying this credential, recovered
    from a compromised or seized endpoint, can never read back what it
    uploaded, enumerate other objects, or touch any other case's storage
    - and the credential is expiring or expired by the time anyone would
    realistically be analyzing that endpoint's binaries.

## The initial Windows login itself

Both brokers (SSM, Bastion) only get you to a network path to the host's
RDP port - you still need a real Windows credential once you're there.
Neither cloud's Windows image ships with a knowable password by default
(AWS's is normally retrieved by decrypting it with an EC2 key pair - not
used here, since SSM is the only intended connection path and a key pair
would be unused overhead), so each case's root module generates a random
24-character local Administrator password once, at case creation
(`random_password.admin` in `environments\*-case\main.tf`). It is:

- **Never written to `infra\.cases\<case_id>.json`** -
  `Start-CloudConsole.ps1` explicitly strips `admin_password` from what it
  persists to that bookkeeping file after every `terraform apply`.
- **Fetched fresh from Terraform state, on demand, only by
  `Connect-InvestigationHost.ps1`**, which prints it once right before
  launching the RDP session so you can type it in. It is not logged,
  cached, or written to disk by that script.
- Still present in the case's Terraform **state file** on your own machine
  (`environments\*-case\terraform.tfstate.d\<case_id>\...`) - Terraform
  itself has no way around this for a resource whose value it manages.
  This is exactly why `README.md`'s "What this project does NOT do"
  section already calls out protecting that state directory like any
  other credential-adjacent local file.
- On AWS specifically, restricted to a character set
  (`override_special = "!#%*+,-./:;=?@^_~"`) that deliberately excludes
  a literal quote, backtick, dollar sign, and backslash - the AWS module
  has no key pair to hand the password back through the cloud API the way
  Azure's `azurerm_windows_virtual_machine` resource does, so it's set by
  embedding it literally in a PowerShell string inside `user_data`
  (`net user Administrator "<password>"`); any of those characters could
  break that line outright rather than just failing safely.

## Network exposure

**Zero inbound ports, ever, on the investigation host.** No public IP, a
security group/NSG with no ingress rules at all. Remote access goes
through:

- **AWS SSM Session Manager** - the AWS Systems Manager agent (built into
  the Windows Server AMI used here) makes an *outbound* connection to the
  SSM service; `Connect-InvestigationHost.ps1` starts a port-forwarding
  session through that existing outbound channel and points `mstsc.exe`
  at the resulting local port. No listener is ever opened on the host's
  network interface for RDP.
- **Azure Bastion (Developer SKU)** - reaches the VM over its private IP
  with no public IP on the VM and no inbound rule. Developer SKU runs on
  shared, Microsoft-managed infrastructure and needs no dedicated
  `AzureBastionSubnet` and no public IP of its own (unlike
  Basic/Standard/Premium), though it is still associated with one VNet
  and serves one VM at a time. That shared-infrastructure model is why
  it's free. It is **browser/portal connection only** - native-client RDP
  requires Standard or higher, which is a usability and cost trade-off,
  not a security one; see `README.md`'s "Connecting on Azure" section.

Both brokers authenticate the **network path only** - you still sign in
with a real Windows credential (local Administrator or domain/AD) once
the RDP session reaches the host. Neither broker is a substitute for that.

## Storage: encryption, versioning, immutability

Every case's storage, on both clouds, by default:

- **Encrypted at rest** - SSE-KMS (AWS) / Storage Service Encryption
  (Azure), and TLS-only in transit (the AWS bucket policy explicitly
  denies any non-TLS request via an `aws:SecureTransport` condition;
  Azure storage accounts enforce `TLS1_2` minimum).
- **Versioned** - an overwrite or delete creates a new version rather than
  destroying the prior one, by default, independent of whether
  immutability is enabled.
- **Never publicly accessible** - AWS's four `public_access_block` flags
  are all forced true; Azure storage accounts default to private
  containers (`allow_nested_items_to_be_public = false`).

**One hardening step deliberately left on the table**, because it can't be
verified without a live subscription: the Azure storage account currently
sets `shared_access_key_enabled = true`. The collector's upload SAS does
**not** need it - `New-CaseCollector.ps1` mints a *user-delegation* SAS
(`--auth-mode login --as-user`), which is signed with an Entra ID key
rather than the account key - so setting this to `false` would remove the
account-key credential from the account entirely. It is left enabled only
because disabling shared keys can break Terraform's own management of the
container and management policy depending on provider version and the
operator's data-plane role assignments. Flip it to `false` and re-run
`terraform apply` once you have a working deployment to test against; if
apply still succeeds, leave it off.

**Immutability (WORM - Write Once, Read Many) is an explicit per-case
choice, not a global default**, because it has real, occasionally
irreversible consequences and there's no single retention policy that
fits every case:

- **Why per-case, not a project-wide default**: AWS S3 Object Lock can
  only be enabled **at bucket creation** - it cannot be retroactively
  turned on for an existing bucket. This is a real AWS constraint, not a
  design choice of this project's - which is exactly why
  `Start-CloudConsole.ps1`'s `[2] Create a new case` asks about
  immutability up front and there's no "enable it later" path on AWS.
- **GOVERNANCE vs. COMPLIANCE** (the same two terms on both clouds, though
  Azure calls its equivalent something else internally - named to match
  here for consistency):
  - **GOVERNANCE** (the default this project suggests): an authorized
    principal can still shorten, remove, or override the retention lock.
    Protects evidence against routine/accidental deletion and most
    unauthorized tampering, while leaving you a recovery path if you lock
    yourself out or need to correct a mistake.
  - **COMPLIANCE**: **irreversible** once a short grace period elapses
    (AWS gives none by default at the object level; Azure gives a
    24-hour grace window before a lock is permanent). Nobody - including
    the account owner, including AWS/Microsoft support - can shorten or
    remove it before the retention period expires. Choose this only when
    your chain-of-custody requirements genuinely call for it, and only
    once you're comfortable with what "irreversible" means in practice
    (a mis-set retention period, or a case that needs early access for
    legal reasons, has no override).
  - `[6] Archive this case` offers to **lock** an Azure GOVERNANCE policy
    into a COMPLIANCE-equivalent one at case-close time, once you're
    confident the case is truly done - a deliberate two-step workflow
    (start recoverable, lock down at close) rather than committing to
    COMPLIANCE on day one of a case, where a retention period or scope
    mistake is far more likely.
- **Retention period** (`retention_days`, default 90) - how long objects
  are protected from modification/deletion under either mode, counted
  from each object's own creation/last-modified time.

## Least privilege, by resource, not just "one role"

Every IAM role / managed identity this project creates is scoped to
**exactly one case's storage**, not the account/subscription broadly:

- The investigation host's role: **read-only**, one bucket/container.
- The collector's role: **write-only**, one bucket/container, one Terraform
  workspace's lifetime (the case-role's `max_session_duration` is 1 hour;
  each collector build mints its own fresh session rather than relying on
  a long-lived role session).
- No role or credential in this project is ever scoped to "all cases" or
  "the whole account" - a compromise of one case's credentials (host or
  collector) cannot reach any other case's evidence.

## What this project does NOT do

- It does not manage your AWS/Azure account's own IAM/root hygiene (MFA,
  root account lockdown, org-wide SCPs/policies) - that's your
  organization's responsibility, same as any Terraform-based tooling.
- It does not provide network egress infrastructure (NAT Gateway/VNet) -
  see `README.md`'s cost section. Bring your own subnet with internet
  egress; this project only ever attaches to it, never creates or
  manages the broader network.
- It does not manage a remote Terraform state backend - state is local
  per case by design (see `README.md`), which also means **the machine
  running `Start-CloudConsole.ps1` is a single point of control for
  destroying/recreating your cases' compute** (not storage) - protect
  `infra\.cases\` and the `environments\*-case\terraform.tfstate.d\`
  folders like you would any other credential-adjacent local state
  (they're gitignored - see the root `.gitignore` - but that's not the
  same as backed up; if losing local Terraform state matters to you,
  back that folder up or migrate to a remote backend).
