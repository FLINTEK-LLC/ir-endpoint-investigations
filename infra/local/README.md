# Local IR infrastructure (VMware Workstation)

An alternative to [`infra/`](../README.md)'s cloud module for when there is
no cloud account to provision into, or a case needs to stay entirely
on-premises: one golden analyst VM, built once with
[Packer](https://www.packer.io/), that every case reverts to a clean
snapshot of rather than destroying and recreating. `vmrun` (VMware
Workstation's own CLI) drives the whole lifecycle - there is no Terraform
provider for Workstation worth depending on here, and none is used.

**Fastest way in:** `.\Start-LocalConsole.ps1` - a menu covering every
action below, same arrow-key/numbered-fallback UX as
[`..\Start-CloudConsole.ps1`](../README.md#getting-around-the-console) and
[`..\..\scripts\Start-IRConsole.ps1`](../../README.md#getting-around-the-console)
(all three share [`..\..\scripts\IRPrompt.ps1`](../../scripts/IRPrompt.ps1)).

## Why this is a different shape from the cloud module

The cloud module's case lifecycle is **destroy-then-recreate**: AWS/Azure
can spin up an arbitrary number of investigation hosts, so a case gets its
own host, destroyed and (if needed) rebuilt from scratch on every
redeploy. A single VMware Workstation installation is one physical
machine with (practically) one golden VM - there is no API call that
conjures a second one for free, and cloning the golden VM per case would
multiply disk usage by the golden image's size (tens of GB) for every
case open, with no cheap cold-storage tier to archive the unused ones to
afterwards (the entire point of the cloud module's archive-to-Glacier/
Archive-tier step).

So this module is **snapshot-revert, not clone-per-case**: one golden VM,
reverted to its `golden-clean` snapshot before every case starts. That
gives the same guarantee the cloud module's "destroy then re-apply" does -
a case never sees anything a previous one left behind - at a fixed disk
cost instead of a linear one. The real trade-off: **only one case can be
open on a given Workstation host at a time**, because there is only one
VM. Two investigators working two cases simultaneously on the same
physical machine need two separate golden VMs (build a second one under a
different `-vm_name`/output directory) or two separate machines, not two
case folders the way the cloud module's Terraform workspaces allow.

## Prerequisites and one-time setup cost

Unlike the cloud module (ongoing per-hour cloud billing, see
[`../README.md`](../README.md)'s cost-consciousness section), this module
has no ongoing cost once built. What it costs instead is a one-time setup:

1. **[VMware Workstation Pro](https://www.vmware.com/products/workstation-pro.html)**,
   installed on the machine that will host cases - free for personal/
   non-commercial use under Broadcom's current licensing. `vmrun.exe`
   ships inside the install
   (`C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe` by
   default) - nothing separate to install for the automation itself.
2. **[Packer](https://developer.hashicorp.com/packer/install)**, to build
   the golden image. One download, no license.
3. **A Windows 11 Pro ISO**, downloaded by hand from
   [Microsoft's official download page](https://www.microsoft.com/software-download/windows11) -
   the same user-supplied-asset shape as this repo's own KAPE licensing
   gate (see root [README.md](../../README.md)'s Prerequisites). No
   product key required to get started: `product_key` defaults to
   Microsoft's own public, non-activating generic KMS client setup key
   for Pro (desktop watermark only, no functional restriction); supply a
   real key later for a permanently-activated build.
4. **A licensed KAPE zip** - same gate as everywhere else in this repo
   (see root README.md and [`../README.md`](../README.md)'s "Getting
   KAPE onto the host"). Point `golden-image.pkr.hcl`'s `kape_zip_path`
   variable at it, or skip it and install KAPE by hand on the golden VM
   before taking the `golden-clean` snapshot.

Building the golden image is a one-time, roughly hour-long step (mostly
unattended Windows Setup time) - see [TESTING.md](TESTING.md) for the
full from-zero walkthrough. Every case after that is a snapshot revert,
which takes seconds to low tens of seconds, not another full OS install.

## Architecture

```
infra/local/
  README.md                 This file
  TESTING.md                 From-zero walkthrough: install Workstation +
                              Packer, get the ISO, build the golden image,
                              run a case end to end, clean up
  Start-LocalConsole.ps1      The TUI - same thin-wrapper pattern as
                              ..\Start-CloudConsole.ps1 and
                              ..\..\scripts\Start-IRConsole.ps1
  packer/
    golden-image.pkr.hcl      Packer vmware-iso template: builds Windows from
                              your own ISO via autounattend.xml, stages your
                              licensed kape.zip (optional), runs this repo's
                              own scripts\Setup-Workstation.ps1 -Tier All
                              inside the guest, leaves the VM powered off
                              and registered
    http/
      autounattend.xml        Unattended Windows Setup answer file - creates
                              the ir-analyst account, enables RDP + WinRM
                              (WinRM so Packer's own provisioners can connect)
    scripts/
      provision-setup-workstation.ps1  Packer provisioner - runs the repo's
                              Setup-Workstation.ps1 inside the guest, reused
                              rather than reimplemented
      New-GoldenSnapshot.ps1  Run once, right after `packer build` finishes -
                              Packer itself has no concept of a named VMware
                              snapshot, so taking `golden-clean` is this
                              module's own step, not Packer's
  scripts/
    Local-VmrunHelpers.ps1    Shared vmrun wrapper functions - dot-sourced by
                              every script below and by Start-LocalConsole.ps1
    New-LocalCase.ps1         Revert to golden-clean, mount the case's
                              evidence folder read-only, power the VM on
    Connect-LocalHost.ps1     Console window, or a real RDP session to the
                              guest's IP - see "Connecting to the local
                              host" below
    Stop-LocalCase.ps1        Power off + revert to golden-clean - the
                              "destroy" analog; evidence is untouched
  .cases/                     Local case bookkeeping (gitignored) - case ID,
                              vmx path, evidence path, shared-folder name,
                              guest IP last seen. Never contains credential
                              material - same rule as infra\.cases\
```

## Quick start

### First-time setup (once per machine)

See [TESTING.md](TESTING.md) for the full walkthrough. Summary:

1. Install VMware Workstation Pro, Packer, and get a Windows 11 Pro ISO
   plus product key (links above).
2. Create an EFI no-prompt ISO with `packer\scripts\New-NoPromptWindowsIso.ps1`
   (Windows ADK Deployment Tools required; see [TESTING.md step 3](TESTING.md#3-get-a-windows-11-pro-iso)).
   Use its path and new SHA256 in `packer build -var iso_url=... -var iso_checksum=sha256:... -var winrm_password=... -var product_key=... [-var kape_zip_path=...] infra\local\packer\golden-image.pkr.hcl`
3. `.\packer\scripts\New-GoldenSnapshot.ps1` - takes the `golden-clean`
   snapshot the rest of this module reverts to.

### Working a case

1. **`[1] Start a case`** - prompts for a case ID and the host folder
   holding that case's evidence (VHD, memory dump, KAPE collection zips -
   whatever would otherwise be copied onto a physical analyst workstation by
   hand). Reverts the golden VM to `golden-clean`, mounts that folder
   read-only as a VMware shared folder, and powers the VM on.
2. **`[2] Connect`** - either the VM's own Workstation console window, or
   a real RDP session to the guest's IP (see below for the trade-off).
   Once inside, `scripts\Start-IRConsole.ps1` is already on the box
   (the golden-image build ran `Setup-Workstation.ps1` already) - work the
   case as normal, same as the cloud module's host.
3. **`[3] Stop a case`** when done - powers the VM off and reverts it to
   `golden-clean`. Evidence (the host folder from step 1) is never
   touched; only the VM's own disk state is discarded.

`[4] List cases` shows every case this console has started, its status,
and its evidence path.

## Connecting to the local host - two options, pick per session

Unlike the cloud module, there is no broker to choose here (no SSM, no
Bastion) - VMware Workstation's own virtual networking (NAT by default) is
already private and not reachable from outside the host machine/LAN, so
neither option below opens anything to the internet the way the cloud
module's `SECURITY.md` has to carefully avoid.

| | `Console` (default) | `Rdp` |
|---|---|---|
| Setup | None - the VM already has a window | None beyond what the golden image's `autounattend.xml` enables |
| Window | Fixed to the Workstation app on this machine's own desktop | Resizable `mstsc.exe` window, reconnectable |
| Clipboard/drive redirection | Whatever VMware Tools itself provides | Normal RDP redirection |
| Dependency | None - works even with networking fully down inside the guest | Needs the guest's VMware Tools running and its virtual NIC up |

**Why `Console` is the default.** It always works, with zero moving
parts beyond the VM itself being on - useful for the first case after a
fresh golden-image build, before guest network/Tools are confirmed
working. `Rdp` is the better day-to-day choice once connectivity is
confirmed - the same `mstsc.exe` launch pattern the cloud module's
`Connect-InvestigationHost.ps1` uses, just against the VM's local-network
IP instead of through SSM/Bastion.

## Evidence delivery: VMware shared folders, not a mounted drive letter

The cloud module mounts a case's cloud storage as a fixed drive letter
(`D:`, falling back to the next free one) using `rclone` and the host's
own cloud identity. There is no cloud identity here, and `vmrun` has no
subcommand to force a specific guest drive letter for a shared folder -
only to add/remove/enable one. `New-LocalCase.ps1` therefore uses
`vmrun addSharedFolder` (no manual Workstation GUI step, no hand-editing
the `.vmx` - automated the same way every other per-case action in this
module is) to mount the case's evidence **read-only** at
`\\vmware-host\Shared Folders\case-<CaseId>` inside the guest. Windows
usually also surfaces it under its own drive letter automatically once
it's noticed, but if a case genuinely needs a fixed letter, map it once
inside the guest after connecting:

```powershell
net use Z: "\\vmware-host\Shared Folders\case-<CaseId>" /persistent:no
```

Read-only is deliberate, for the identical reason the cloud module's
investigation-host role is read-only on the case bucket/container (see
[`../SECURITY.md`](../SECURITY.md)): this host's job is to parse evidence,
never to modify it.

## Tool manifest additions

[`../../scripts/workstation-tools.json`](../../scripts/workstation-tools.json)
gained four entries used by this module's golden-image build (and equally
usable on the cloud module's hosts - the manifest is shared, not
local-specific): **Volatility 3** (memory forensics, installed into its
own venv rather than as a prebuilt binary - see that file's `$comment` on
the entry for why), **MemProcFS** (memory forensics, a real GitHub-release
binary zip), **HashMyFiles** (NirSoft, direct-URL like this project's
existing NirSoft entries), and **ImHex** (hex editor, MIT-licensed GitHub
releases - chosen over HxD specifically because HxD's license does not
clearly permit the kind of automated redistribution-adjacent fetching this
manifest does for everything else; see that entry's `Why` field).

## Reuse - nothing here duplicates the root project's logic

- `..\..\scripts\Setup-Workstation.ps1` - run by
  `packer\scripts\provision-setup-workstation.ps1` inside the Packer build,
  exactly as-is, with `-Tier All` (a reusable golden image is the "build it
  once with everything" case, unlike the cloud module's disposable host).
- `..\..\scripts\IRPrompt.ps1` - dot-sourced by `Start-LocalConsole.ps1`,
  same as the other two consoles.
- `..\Start-CloudConsole.ps1`'s menu/helper pattern (`Read-Default`,
  `Read-Required`, `Read-YesNo`, thin-wrapper `Invoke-*` calls to separate
  script processes, `-NoEnumerate` case-list bookkeeping) is the direct
  template `Start-LocalConsole.ps1` follows.

## Verification

Every PowerShell script here has been checked with
`[System.Management.Automation.Language.Parser]::ParseFile` (via
[`Invoke-SelfTest.ps1`](../../scripts/Invoke-SelfTest.ps1), which globs
every `.ps1` in the repo), and `golden-image.pkr.hcl` with `packer fmt
-check` and `packer validate` in CI (see
[`.github/workflows/selftest.yml`](../../.github/workflows/selftest.yml)) -
no live cloud/network calls needed for either. No live `packer build`,
`vmrun` call, or VMware Workstation install was exercised as part of
building this module - there is no VMware Workstation in the environment
it was authored in, the same "no live cloud credentials" constraint the
cloud module's own [`../README.md`](../README.md)'s Verification section
documents. The first real build (`packer build ...` against a real
Windows ISO and product key, followed by a real case start/connect/stop
cycle) and any issue it surfaces are covered step by step in
[TESTING.md](TESTING.md).
