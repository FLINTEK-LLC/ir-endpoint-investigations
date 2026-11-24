# Testing the local VMware module from zero

A concrete, from-scratch walkthrough: no VMware Workstation, no Packer, no
Windows ISO yet, through a full case cycle and cleanup. Mirrors
[`../TESTING.md`](../TESTING.md)'s style for the cloud module. Every step
below is something to actually run and check the output of - this is the
test procedure, not a narrative.

**What this covers that CI does not.** `.github/workflows/selftest.yml`
syntax-checks every script here and runs `packer fmt`/`packer validate` on
`golden-image.pkr.hcl` with no credentials and no VM - the same "no live
apply" policy the cloud module's CI uses for Terraform. It cannot build a
real VM, because that needs VMware Workstation installed and a real
Windows ISO, neither of which exist in a CI runner (see
[`../README.md`](../README.md)'s Verification section). Everything below
is a manual procedure to run once on the target machine.

## 1. Install VMware Workstation Pro

Download and install from
[vmware.com](https://www.vmware.com/products/workstation-pro.html) -
free for personal/non-commercial use under Broadcom's current licensing,
so there is no purchase step. Confirm `vmrun.exe` exists:

```powershell
Test-Path 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
```

If it prints `False`, Workstation installed somewhere else - find it and
pass `-VmrunPath` to every script in this module from here on, or add it
to `PATH`.

## 2. Install Packer

```powershell
winget install HashiCorp.Packer
packer version
```

Then install the vmware plugin the template declares:

```powershell
cd ir-endpoint-investigations\infra\local\packer
packer init golden-image.pkr.hcl
```

## 3. Get a Windows 11 Pro ISO

Download the ISO from
[Microsoft's official download page](https://www.microsoft.com/software-download/windows11),
then create an **EFI no-prompt variant** once per downloaded ISO. Install the
[Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
with **Deployment Tools** selected (`oscdimg.exe`). The WinPE add-on is not
needed: the helper uses `efi\microsoft\boot\efisys_noprompt.bin` from your
source ISO, keeping its boot files matched to that Windows release. Run in
Windows PowerShell (elevate if mounting an ISO requires it on your host):

```powershell
cd ir-endpoint-investigations\infra\local\packer
.\scripts\New-NoPromptWindowsIso.ps1 `
  -SourceIso C:\Downloads\Win11_Pro.iso `
  -OutputIso C:\Downloads\Win11_Pro-noprompt.iso
Get-FileHash -Algorithm SHA256 -LiteralPath C:\Downloads\Win11_Pro-noprompt.iso
```

The helper prints `iso_url` and `iso_checksum`; use those **remastered** values
in step 5. It needs free space for one additional ISO, refuses existing output,
and dismounts only a source it mounted itself. Supply `-OscdimgPath` if the ADK
is installed outside its default location. If the source lacks the no-prompt
boot image, it stops; use original Microsoft x64 media containing that image.
The output is EFI-only, with a new El Torito boot catalog referencing the
no-prompt image. Renaming/replacing `efisys.bin` inside an ISO without rebuilding
the boot catalog does not accomplish this. The input ISO is read-only.

Keep the new `.iso` path and hash: `iso_url` and `iso_checksum` are required
Packer variables with no default. Do not use the original download's hash.

No product key needed to get started: `product_key` defaults to
Microsoft's own publicly-documented generic KMS client setup key for
Windows 11 Pro, which selects the edition during setup but does not
activate Windows (desktop watermark, Settings nag, no functional
restriction - fine for a disposable, snapshot-revert analyst VM). Pass
a real key with `-var product_key=...` later for a permanently-activated
build, no other change needed - see `golden-image.pkr.hcl`'s
`product_key` variable comment.

## 4. (Optional) Stage a licensed KAPE zip

If `kape.zip` is already on hand from [kroll.com/kape](https://www.kroll.com/kape),
keep its path handy for `-var kape_zip_path=...` below. Skipping this is
fine for a first infrastructure test - the golden image comes up with
everything except the KAPE-coupled parsing toolchain, and
`Setup-Workstation.ps1`'s own output says so explicitly.

## 5. Build the golden image

```powershell
cd ir-endpoint-investigations\infra\local\packer
packer build `
  -var "iso_url=C:\Downloads\Win11_Pro-noprompt.iso" `
  -var "iso_checksum=sha256:<the hash from step 3>" `
  -var "winrm_password=<at least 12 characters, Windows complexity rules apply>" `
  -var "kape_zip_path=C:\Downloads\kape.zip" `
  golden-image.pkr.hcl
```

(Omit `kape_zip_path` to skip KAPE for now. `product_key` is also
optional - omit it to use Microsoft's generic, non-activating Pro key, or
add `-var "product_key=..."` for a real one. `winrm_password` has no
default and must be 12+ characters - Packer validates this before a
build even starts. VMware Tools gets installed by a dedicated
provisioner from Workstation's own bundled `windows.iso`; if your
Workstation install doesn't ship one, pass
`-var "vmware_tools_iso_path=C:\path\to\windows.iso"`.)

Expect this to take the better part of an hour - mostly unattended
Windows Setup time, then `Setup-Workstation.ps1 -Tier All` fetching the
full analyst toolset inside the guest. Open the running VM in Workstation to inspect its console (the
template starts it headless via `vmrun ... nogui`) - if Windows Setup stalls on a screen
rather than proceeding, `http/autounattend.xml` needs a tweak for the
specific ISO build (see that file's `/IMAGE/NAME` setting, the most
common mismatch - credentials/product key/computer name are templated
from Packer variables now, not hand-edited in this file).

**What to check when it finishes:** Packer reports a build success and
leaves `output-ir-golden\ir-golden.vmx` powered off. If it instead times
out waiting for WinRM, the most common cause is `autounattend.xml`'s
`FirstLogonCommands` WinRM-enable step not having run yet - open the VM's
console window and check whether Windows actually finished OOBE sign-in.

### EFI boot investigation and host acceptance check

The observed regression began when EFI was pinned. Retain EFI and the matching
GPT/ESP/MSR/Windows/Recovery layout in `http/autounattend.xml`; reverting to
BIOS/MBR changes the installation architecture without establishing the cause.
Four key timings failed (2s/four spaces, 5s/eight spaced spaces,
15s/twelve alternating keys, 1s/28 dense keys). This template now requires
no-prompt media, sends no boot keys, and sets `disable_vnc = true` so a VNC
connection failure cannot block unattended Setup. This is an architectural
workaround, not proof that EFI keyboard injection is universally broken.

Evidence and limits:

- The [2.1.7 builder step order](https://github.com/vmware/packer-plugin-vmware/blob/v2.1.7/builder/vmware/iso/builder.go)
  is power-on, VNC connect, boot wait/typing, then communicator connect.
  [`StepRun`](https://github.com/vmware/packer-plugin-vmware/blob/v2.1.7/builder/vmware/common/step_run.go)
  prints `Powering on virtual machine...` before synchronously calling the
  driver. If that remains the last status, Packer has not reached keystroke
  injection or WinRM. Increasing WinRM timeout or changing boot_wait cannot fix it.
- [Issue #280](https://github.com/vmware/packer-plugin-vmware/issues/280)
  reports a `vmrun start ... gui` hang, including a Workstation 17.6 report;
  opening Workstation first worked for the reporter. Maintainers could not
  reproduce it. `headless = true` selects `nogui` in the
  [2.1.7 Workstation driver](https://github.com/vmware/packer-plugin-vmware/blob/v2.1.7/builder/vmware/common/driver_workstation.go),
  avoiding that GUI launch path. Its effectiveness here still needs a host run.
- [Issue #330](https://github.com/vmware/packer-plugin-vmware/issues/330)
  reports boot-command failures after Workstation 17.6; investigation includes
  VNC connection refusal and successful maintainer tests. It does not establish
  an EFI-specific defect or a verified VMX keyboard fix.
- The [builder documentation](https://developer.hashicorp.com/packer/integrations/vmware/vmware/latest/components/builder/iso)
  describes VNC key injection and `disable_vnc`; it provides no EFI-specific
  keyboard remedy. No documented Workstation 17.x VNC removal or EFI keyboard
  restriction was found in the reviewed
  [Workstation 17 documentation/release notes](https://techdocs2-prod.adobecqms.net/content/dam/broadcom/techdocs/us/en/pdf/vmware/desktop-hypervisors/workstation/vmware-workstation-pro-17-0.pdf).
  The bundled 17.6 Player release notes list removal of the Enhanced Keyboard
  driver; they do not identify it as an EFI/VNC fix or regression. Neither that
  removal nor remote-console product changes establish that Packer's local
  VNC channel was removed.
- Microsoft's [Oscdimg reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/oscdimg-command-line-options)
  documents El Torito boot entries, EFI platform ID, UDF and boot-file ordering.
  A [Microsoft-hosted Q&A](https://learn.microsoft.com/en-us/answers/questions/1105230/attempting-to-make-a-noprompt-iso-for-server-2022)
  describes using `efisys_noprompt.bin` to remove the prompt by recreating the ISO.
  The latter is community evidence, not a VMware defect confirmation.

On the actual Workstation host, enable logging before step 5:

```powershell
$env:PACKER_LOG = '1'
$env:PACKER_LOG_PATH = Join-Path $PWD 'packer-efi.log'
```

Verify all of the following without pressing a key:

1. Power-on completes and Packer reaches `Waiting for WinRM` (no VNC connect or
   typing step). If it still hangs at power-on, inspect the logged `vmrun ...
   nogui` invocation and Workstation logs; try starting Workstation first as in
   #280. No-prompt media alone cannot unblock a stuck `vmrun` process.
2. The console goes directly into WinPE/Setup, with no "Press any key" prompt.
   If the prompt remains, verify the selected ISO and its remastered checksum.
3. After Setup's first reboot, Windows Boot Manager on disk takes over instead
   of restarting the no-prompt installer. This depends on Setup's EFI NVRAM boot
   entry and must be checked on the host. If it reboots into Setup, stop the
   build and inspect firmware boot priority; repeated Setup can wipe Disk 0.
4. Setup selects Pro, finishes OOBE, WinRM connects, provisioning completes,
   and the final VM is powered off. In Windows, `Get-Disk 0` reports GPT and
   `Get-Partition -DiskNumber 0` shows the expected EFI/MSR/Windows/Recovery layout.

Logs and answer-file artifacts can contain build credentials; keep them private.
Local format/validation/XML/script checks cannot verify firmware input behavior,
Oscdimg execution, NVRAM boot selection, or a complete Workstation installation.
The strongest conclusion available without that run is that the reported
power-on stall precedes injection; the exact host trigger and EFI correlation
remain unconfirmed.

## 6. Take the `golden-clean` snapshot

```powershell
.\scripts\New-GoldenSnapshot.ps1
```

Confirm it:

```powershell
& 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' -T ws listSnapshots output-ir-golden\ir-golden.vmx
```

Expect `golden-clean` in the output. This is the one-time setup; every
step after this is the repeatable per-case cycle.

## 7. Run a case end to end

```powershell
cd ir-endpoint-investigations\infra\local
New-Item -ItemType Directory -Path C:\Cases\TEST-0001 -Force
# Drop anything normally handed to an analyst into C:\Cases\TEST-0001 -
# a KAPE collection zip, a sample memory image, whatever is on hand.

.\scripts\New-LocalCase.ps1 -CaseId test-0001 -EvidencePath C:\Cases\TEST-0001 `
  -VmxPath .\packer\output-ir-golden\ir-golden.vmx
```

**Check:** the VM's console window appears, Windows boots from a clean
snapshot, and the script prints a guest IP once VMware Tools reports one.

```powershell
.\scripts\Connect-LocalHost.ps1 -CaseId test-0001 -Method Rdp
```

**Check:** `mstsc.exe` opens and login succeeds with the `ir-analyst`
account and the password set at `-var winrm_password`. Inside the guest,
confirm the evidence folder is visible:

```powershell
dir '\\vmware-host\Shared Folders\case-test-0001'
```

and that it is genuinely read-only - try creating a file there and
confirm Windows refuses.

```powershell
.\scripts\Stop-LocalCase.ps1 -CaseId test-0001
```

**Check:** the VM powers off, and a second
`vmrun listSnapshots .\packer\output-ir-golden\ir-golden.vmx` still shows
only `golden-clean` (the revert discarded anything from the session,
exactly as intended).

## 8. Run it again through the console instead

```powershell
.\Start-LocalConsole.ps1
```

Walk `[1] Start a case` -> `[2] Connect` -> `[3] Stop a case` with the
same case ID, and confirm the menu produces identical behaviour to the
direct script calls above - it's a thin wrapper around the exact same
scripts, so any difference is a bug in the console, not expected
variance.

## 9. Cleanup

- `.\scripts\Stop-LocalCase.ps1 -CaseId test-0001 -DeleteRecord` removes
  the local case bookkeeping if `[4] List cases` shouldn't keep showing
  the test case.
- `Remove-Item -Recurse C:\Cases\TEST-0001` once done with the test
  evidence - it was never touched by the guest, but it is still disk
  space on the host.
- The golden VM itself (`packer\output-ir-golden\`) is meant to be kept
  long-term and reused by every future case - there is nothing to tear
  down there unless abandoning the module entirely, in which case delete
  the VM through VMware Workstation's own library (Remove from Library +
  delete files), not by hand-deleting the folder (Workstation's own
  inventory can get confused by files disappearing out from under it).

## What still needs a real run

Everything in this document, in full - this module was authored with no
VMware Workstation available (see `../README.md`'s Verification
section), so every `packer build`, `vmrun` call, RDP session and
shared-folder mount above is unexercised beyond PowerShell/HCL syntax
checking. Report back anything that doesn't match this walkthrough, the
same working pattern the rest of this project's own development used.
