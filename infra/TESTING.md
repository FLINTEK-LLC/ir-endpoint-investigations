# Testing this end to end, from scratch

Written for someone starting with **a Microsoft account and nothing else**.
Follow it top to bottom and you will stand up a real case, connect to it,
upload evidence to it, and tear it all down again.

See [README.md](README.md) for the concepts and [SECURITY.md](SECURITY.md)
for why things are built this way. This file is just "do this, then this."

## What this proves, and what it costs

**Proves:** per-case storage, the VM's managed identity, the evidence drive
mount, just-in-time RDP, and the collector's upload path.

**Does not prove:** end-to-end parsing, unless you do the optional KAPE step
(Step 6). KAPE is licence-gated and cannot be downloaded unattended, so a
host without it comes up with no parsing toolchain. That is expected, not a
failure.

**Cost:** roughly **$0.40 for a couple of hours** with the small VM
below (VM ~$0.19/hr, public IP ~$0.005/hr, storage in pennies). A new Azure
account also comes with $200 of credit. Nothing here leaves an hourly charge
running once you finish Step 12.

> **Azure, not AWS, for a first test.** Azure's default `rdp-allowlist`
> gives the host a public IP that doubles as its outbound internet path.
> That matters: Microsoft now states that "for the API released after
> March 31, 2026, new virtual networks default to using private subnets",
> so a no-public-IP VM in a fresh VNet has **no internet egress at all** and
> its bootstrap cannot download anything. AWS needs a NAT Gateway
> (~$0.045/hr) before its no-public-IP host works, making it the more
> involved first run.

---

## Step 1 - Create an Azure subscription

Go to [azure.microsoft.com/free](https://azure.microsoft.com/free) and sign
in with your existing Microsoft account. A card is required for identity
verification; it does not auto-charge without you explicitly upgrading, and
you get $200 of credit for 30 days.

**Wait for the subscription to finish provisioning before moving on**, and
verify it after Step 2's `az login`:

```powershell
az account list --refresh --output table
```

You need at least one row with `State = Enabled`. If the table is **empty**,
or the only row says `N/A(tenant level account)`, you are signed in to a
directory that has no subscription in it - `az account show --query id` then
returns a **tenant** GUID that looks like a subscription but is not one, and
every later command fails with `(SubscriptionNotFound) Subscription <guid>
was not found`. Finish the signup, then:

```powershell
az login
```

If you have more than one subscription, pin the right one explicitly:

```powershell
az account set --subscription "<subscription name or id>"
```

## Step 2 - Local tools

Open PowerShell **as Administrator** (the installers need it):

```powershell
cd C:\Tools\Projects\ir-endpoint-investigations\infra
```

```powershell
.\Start-CloudConsole.ps1
```

Pick **`[1] First-time setup`**. It installs Terraform and the Azure CLI,
then reports what still needs doing. Quit with `Q`, then sign in:

```powershell
az login
```

Re-run `[1]`; you should now see `Azure auth  OK`.

## Step 3 - Grant yourself blob data access

**Do not skip this.** Subscription Owner does *not* grant access to blob
*data*. Microsoft's own wording: built-in roles like Owner "permit a
security principal to manage a storage account, but don't provide access to
the blob data within that account". Without a Storage Blob Data role,
`[3] Build collector` fails minting its SAS and `[6] Archive` fails listing
blobs - both only *after* you have paid for a VM and waited for it to boot.

```powershell
az role assignment create --assignee (az ad signed-in-user show --query id -o tsv) --role "Storage Blob Data Contributor" --scope "/subscriptions/$(az account show --query id -o tsv)"
```

Note the quoting on `--scope`: PowerShell does **not** concatenate a bare
`(...)` onto an adjacent literal - it passes them as two separate arguments,
so `--scope /subscriptions/(az account show ...)` makes az complain
`unrecognized arguments: <guid>`. The `"/subscriptions/$(...)"` form is what
actually joins them.

If you would rather see the values first:

```powershell
$me = az ad signed-in-user show --query id -o tsv
$sub = az account show --query id -o tsv
az role assignment create --assignee $me --role "Storage Blob Data Contributor" --scope "/subscriptions/$sub"
```

Give it a minute to propagate, then re-run `[1]` - it checks this explicitly
now and should report `Azure blob data access  OK`.

## Step 4 - Confirm the Windows Server 2025 image name

The Azure image SKU defaults to `2025-datacenter-g2`, but that exact string
could not be verified without a live subscription. Check it now rather than
discovering it mid-apply:

```powershell
az vm image list-skus --location eastus --publisher MicrosoftWindowsServer --offer WindowsServer --output table | Select-String 2025
```

If `2025-datacenter-g2` is not listed, note one that is (e.g.
`2025-datacenter-azure-edition`) and edit the `image_sku` default in
`modules/azure/investigation-host/variables.tf` before Step 8.

> **Windows quoting hazard, worth knowing for any `az` command you write
> yourself.** `az` on Windows is a *batch file*, so its arguments pass
> through `cmd.exe`. PowerShell only re-quotes a native argument if it
> contains a space - so a JMESPath filter like
> `--query "[?contains(sku,'2025')].{sku:sku}"` (no spaces) arrives at
> cmd.exe unquoted, and cmd chokes on the `(`, `)`, `{`, `}` with
> `].{sku:sku was unexpected at this time`. Filters that happen to contain
> a space are quoted and work fine, which makes this maddeningly
> inconsistent. Easiest fix is to avoid `--query` metacharacters and filter
> with `Select-String`, as above.

## Step 5 - Create a throwaway test network

The per-case Terraform never creates your network - it only attaches to one,
because a case is disposable and a VNet is not. Make a disposable one from the
console:

```powershell
.\Start-CloudConsole.ps1
```

**`[8] Case networking`** > Azure > *Create it*.

That creates a resource group, a VNet (`10.20.0.0/16`) and a subnet
(`10.20.1.0/24`), then prints the subnet **resource ID** that Step 8 needs.

Paste that ID back when `[8]` asks. It is saved to `infra\.prereqs.json` and
offered as the default at Step 8, so you never have to keep it on a sticky
note - which is where copy/paste errors came from.

Unlike AWS there is no NAT Gateway here, and that asymmetry is real rather
than an oversight: an Azure VM with no public IP still gets outbound internet
through the platform's default outbound access. The AWS host genuinely cannot,
which is why that path pays for a NAT Gateway and this one does not.

## Step 6 - (Optional) Stage KAPE so the host can actually parse

Skip if you only want to prove the infrastructure. Do it if you want a host
that can genuinely work a case.

**`[9] Tools storage`** > Azure > *Create it*, giving it the path to your
licensed `kape.zip` when prompted.

That creates a resource group and a storage account with a random suffix
(storage account names are globally unique, and must be 3-24 lowercase
letters and digits with no hyphens - the script enforces this rather than
letting Azure reject it later), creates the container, uploads the zip, and
prints the storage account **resource ID** Step 8 needs. Paste it back when
asked and Step 8 will offer it as the default.

Container creation uses `--auth-mode login`, i.e. your own RBAC rather than an
account key - which is why Step 3 matters. If it fails with an authorization
error, that role assignment has not propagated yet.

To replace the zip later without recreating the account, use `[9]` >
*Upload/replace kape.zip*.

README.md's "Getting KAPE onto the host" explains why this is a separate
account from evidence storage.

## Step 7 - Get a Velociraptor binary

Download the `windows-amd64.exe` asset from the
[latest Velociraptor release](https://github.com/Velocidex/velociraptor/releases)
to something like `C:\Tools\velociraptor.exe`. Step 11 just needs the file.

## Step 7b - Push infra/ to GitHub (REQUIRED)

The investigation host does **not** get its bootstrap from your machine. At
first boot it downloads `infra/scripts/fetch-and-bootstrap.ps1` from the
**public repo** over HTTPS. Anything you have not committed and pushed does
not exist as far as the VM is concerned, and the deploy fails at the Custom
Script Extension with

```
CustomScript failed to download the blob ... Response code: "(404) Not Found"
```

- after the VM has already been created and started billing.

```powershell
git add infra .gitignore README.md scripts/Manage-Tools.ps1
```

```powershell
git commit -m "Add cloud IR infrastructure"
```

```powershell
git push origin main
```

Confirm it is actually live before continuing - this is the exact URL the VM
will request:

```powershell
curl.exe -I https://raw.githubusercontent.com/FLINTEK-LLC/ir-endpoint-investigations/main/infra/scripts/fetch-and-bootstrap.ps1
```

You want `HTTP/1.1 200`. `[2]` now checks this for you and refuses to deploy
if it 404s, but confirming it here saves a round trip.

Note this also means **every later change to the bootstrap scripts must be
pushed before it affects a new host.** Editing them locally and redeploying
will silently keep using whatever is on the branch.

## Step 8 - Create the case

In `Start-CloudConsole.ps1`, pick **`[2] Create a new case`**:

| Prompt | Answer |
|---|---|
| Case ID | `test-001` |
| Cloud provider | `Azure` |
| Enable immutability? | `n` - skip WORM for a throwaway |
| Days before cold storage | Enter (30) |
| Azure region | `eastus` |
| Subnet resource ID | paste from Step 5 |
| Access method | `rdp` (Enter) |
| Tools storage account resource ID | paste from Step 6, or blank to skip |
| Tools container name | `irtools` - only asked if you gave an ID |
| VM size | *Enter* - the default `Standard_B4s_v2` (4 vCPU/16 GiB burstable, ~$0.185/hr). The console verifies it is actually available to you before applying, and offers alternatives if not. |
| Run terraform apply now? | `y` |

Apply takes ~2-4 minutes. **Then wait another 10-15 minutes** before
connecting - the VM still has to boot and run its bootstrap (rclone/WinFsp,
the evidence mount, .NET 9, the toolkit).

## Step 9 - Connect

Pick **`[4] Connect to the investigation host`**. It prints the generated
credentials, detects your current public IP, opens 3389 to **that address
only**, and launches Remote Desktop:

```
Sign in as: iranalyst
Password:   <generated>
Your public IP is a.b.c.d - opening RDP to a.b.c.d/32 only.
```

**Closing the RDP window removes that rule again** - watch for
`RDP is closed again`. If you kill the console first, run `[L]` to lock it
back down.

## Step 10 - Verify on the host

Read this first - the bootstrap writes it:

```powershell
type C:\ir-case-mount.txt
```

It records where evidence is mounted and what tooling installed. Then check:

- `D:\` exists and is your case container. If your VM size had a temp disk on
  `D:`, the bootstrap used the next free letter and says so in that file.
- `C:\ir-repo\ir-endpoint-investigations-main\` exists.
- KAPE present only if you did Step 6; otherwise the file says
  `KAPE: NOT PRESENT` and no parsing toolchain installed - expected.

If the mount is missing, bootstrap may still be running - check
`C:\ir-bootstrap-fetch.log`.

## Step 11 - Build and smoke-test a collector

Pick **`[3] Build this case's offline collector`** and give it the path from
Step 7. It mints a short-lived, write-only SAS and builds
`test-001-collector.zip`.

Unzip it and run the collector exe **elevated** on your own machine as a
smoke test - it collects triage artifacts and uploads straight to the case
container. Storage account and container names are in
`infra\.cases\test-001.json` under `outputs`. Confirm the upload landed:

```powershell
az storage blob list --account-name <account> --container-name <container> --auth-mode login -o table
```

That is the full loop: collector to storage to the host's `D:` drive.

## Step 12 - Tear it all down

Everything below is a console option. Nothing here needs a hand-typed command.

```powershell
.\Start-CloudConsole.ps1
```

### Delete the case (host and evidence)

Use **`[L]`** first to lock down RDP if you left it open, then
**`[D] Delete a case completely`**, pick the case, and type the case ID to
confirm.

That destroys the host and its disks, deletes the evidence storage, removes
the Terraform workspace, and deletes the local case record. It is
irreversible, which is why it asks you to type the ID rather than offering a
single keypress.

If the case's storage is under a **locked** immutability policy, this will
fail - and that is the retention policy working exactly as intended. Evidence
under a COMPLIANCE-equivalent lock cannot be deleted early by anyone,
including you. Wait for the retention to expire.

If you only want to stop paying for compute and keep the evidence, use
**`[5] Destroy the investigation host`** or **`[6] Archive this case`**
instead.

### Delete the shared network and tools storage

- **`[8] Case networking`** > Azure > *Delete it*
- **`[9] Tools storage`** > Azure > *Delete it*

Both are optional if you plan to test again shortly: a VNet costs nothing
idle, and a ~50 MB KAPE zip costs pennies a month. Keeping them saves
repeating Steps 5 and 6.

### Confirm you are not still being billed

**`[C] Check what is still billing`** > Azure (or Both), and say yes to the
all-subscriptions sweep.

That reports the things that bill quietly rather than obviously:

- **Managed disks bill whether or not they are attached.** A VM deleted
  without its disks is the classic Azure surprise - the disk survives, is
  invisible in the VM list, and costs exactly what it did before.
- **A Bastion bills per hour from creation**, whether or not anyone connects.
  It is the most expensive thing this project can leave running.
- **Standard SKU public IPs bill even when associated with nothing.**
- A stopped VM still bills for its disks, and "Stopped" is not the same state
  as "Stopped (deallocated)" - only the latter stops compute charges.

Resource groups, VNets and NSGs cost nothing, so they are listed separately as
leftovers rather than charges. `NetworkWatcherRG` is created automatically by
Azure and is free - seeing it does not mean you missed something.

Clear output is `Nothing billable found. You are clear.`

## Troubleshooting

| Symptom | Cause |
|---|---|
| `AuthorizationPermissionMismatch` on any blob command | Step 3 skipped, or the role has not propagated. Wait a minute, retry. |
| Apply fails with an image error | Step 4 - the 2025 SKU string differs in your region. |
| `SkuNotAvailable` / `Capacity Restrictions` on the VM | The size is not available to your subscription in that region - very common for D-series on new/trial subscriptions. Use `Standard_B2s_v2`, or another region. Check with `az vm list-skus --location eastus --resource-type virtualMachines --size Standard_B --output table` and look at the Restrictions column. |
| `[4]` prints a portal link instead of launching RDP | Case was created with `access_method=bastion` and the Bastion is not Standard/up. |
| RDP refuses the connection | Your public IP changed. Re-run `[4]` - it updates the rule. |
| `D:` missing after 15 minutes | Check `C:\ir-bootstrap-fetch.log` on the host. |
| `D:` shows as a **DVD drive** | Azure attaches a virtual DVD to every Windows image. On a VM size with no local temp disk it claims `D:`. The bootstrap now moves it to `Z:`; on a host built before that fix, run elevated: `Get-CimInstance Win32_Volume -Filter "DriveType=5" \| ForEach-Object { Set-CimInstance -InputObject $_ -Property @{DriveLetter='Z:'} }` then `Start-ScheduledTask -TaskName 'IR-Case-Mount'`. |
| Collector build fails minting the SAS | Step 3 again - user-delegation SAS needs a Storage Blob Data role. |
| `terraform destroy` prompts for variables | Pass the same `-var` values as Step 12. |
| Extension fails: `CustomScript failed to download the blob ... 404` | Step 7b - `infra/` is not pushed to the branch the VM fetches from. |
| `a resource with the ID ... already exists - to be managed via Terraform this resource needs to be imported` | Orphan from a previous failed apply: Azure created the resource but the errored apply never recorded it in state. Almost always the bootstrap extension. Delete it and re-run `[2]`: `az vm extension delete --resource-group rg-ir-case-<id> --vm-name ir-case-<id> --name bootstrap-investigation-host` |
| `SkuNotAvailable` / size not valid | The size is not offered to your subscription in that region. `[2]` now lists what you CAN deploy, with vCPU/RAM. Copy a name exactly, including the `Standard_` prefix. |

## Testing AWS afterwards

See **[TESTING-AWS.md](TESTING-AWS.md)** - a full from-scratch walkthrough for
AWS, including the NAT Gateway the investigation host needs and the ordering
that stops one quietly billing after you finish.
