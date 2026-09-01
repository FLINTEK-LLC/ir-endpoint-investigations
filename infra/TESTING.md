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

This project never creates your network - it only attaches to one. Make a
disposable one:

```powershell
az group create --name rg-ir-test-network --location eastus
```

```powershell
az network vnet create --resource-group rg-ir-test-network --name vnet-ir-test --address-prefix 10.20.0.0/16 --subnet-name subnet-ir-test --subnet-prefix 10.20.1.0/24
```

Get the subnet resource ID - Step 8 asks for it:

```powershell
az network vnet subnet show --resource-group rg-ir-test-network --vnet-name vnet-ir-test --name subnet-ir-test --query id -o tsv
```

## Step 6 - (Optional) Stage KAPE so the host can actually parse

Skip if you only want to prove the infrastructure. Do it if you want a host
that can genuinely work a case.

```powershell
az group create --name rg-ir-tools --location eastus
```

```powershell
az storage account create --name stirtools00001 --resource-group rg-ir-tools --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access false
```

Storage account names are globally unique, so change the digits if that one
is taken. Then, using the name you settled on:

```powershell
az storage container create --name irtools --account-name stirtools00001 --auth-mode login
```

```powershell
az storage blob upload --account-name stirtools00001 --container-name irtools --name kape.zip --file C:\path\to\kape.zip --auth-mode login
```

```powershell
az storage account show --name stirtools00001 --query id -o tsv
```

Keep that resource ID for Step 8. README.md's "Getting KAPE onto the host"
explains why this is a separate account from evidence storage.

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

```powershell
.\Start-CloudConsole.ps1
```

Use `[L]` to lock down RDP if you left it open, then `[5]` to destroy the
investigation host - answer **no** to respin.

Then remove the case's storage. The TUI has no one-click "destroy evidence"
button on purpose:

```powershell
cd C:\Tools\Projects\ir-endpoint-investigations\infra\environments\azure-case
```

```powershell
terraform workspace select test-001
```

```powershell
terraform destroy -auto-approve -var="case_id=test-001" -var="location=eastus" -var="subnet_id=<from Step 5>" -var="access_method=rdp-allowlist" -var="enable_immutability=false"
```

Then the resource groups Terraform never owned:

```powershell
az group delete --name rg-ir-test-network --yes
```

```powershell
az group delete --name rg-ir-tools --yes
```

Confirm nothing is left:

```powershell
az resource list --output table
```

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

Same lifecycle, same console. The extra work is networking: AWS's default
VPC gives a no-public-IP instance no internet route, so you need a NAT
Gateway (~$0.045/hr) before the bootstrap can download anything. Also
confirm the 2025 AMI parameter exists in your region:

```powershell
aws ssm get-parameters-by-path --path /aws/service/ami-windows-latest --query "Parameters[].Name" --output text | Select-String 2025-English-Full
```
