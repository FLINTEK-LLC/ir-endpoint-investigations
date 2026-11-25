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

**Launch VMware Workstation's main application window now, and leave it
running for every `packer build` from here on.** This is a real,
confirmed prerequisite, not a suggestion: `vmrun start <vmx> gui` (which
is what `headless = false` below triggers) can hang indefinitely at
"Powering on virtual machine..." - never reaching VNC or `boot_command`
at all - if Workstation's own app isn't already open when Packer starts
it (a known upstream issue, packer-plugin-vmware#280). This is NOT a
boot_command timing problem and no amount of retuning `boot_wait`/
keystroke spacing fixes it; only having Workstation already running does.

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
then compute its checksum:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath C:\Downloads\Win11_Pro.iso
```

Keep the `.iso` path and the hash - `iso_url` and `iso_checksum` are
required Packer variables with no default. As long as VMware Workstation
is already running (step 1 above), the stock ISO's boot prompt gets
caught automatically by `boot_command` - no ISO modification needed.

**Optional fallback**: if keeping Workstation open still doesn't reliably
catch the boot prompt on your machine, `scripts/New-NoPromptWindowsIso.ps1`
remasters the ISO to skip the prompt entirely (requires the
[Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)'s
Deployment Tools for `oscdimg.exe`):

```powershell
cd ir-endpoint-investigations\infra\local\packer
.\scripts\New-NoPromptWindowsIso.ps1 `
  -SourceIso C:\Downloads\Win11_Pro.iso `
  -OutputIso C:\Downloads\Win11_Pro-noprompt.iso
Get-FileHash -Algorithm SHA256 -LiteralPath C:\Downloads\Win11_Pro-noprompt.iso
```

Use the printed `iso_url`/`iso_checksum` from that output in step 5
instead of the stock ISO's if you go this route. This is a fallback, not
the default path - most builds shouldn't need it.

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
  -var "iso_url=C:\Downloads\Win11_Pro.iso" `
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
`-var "vmware_tools_iso_path=C:\path\to\windows.iso"`. `source_ref`
defaults to `main` - the guest downloads this repo's own
`scripts`/`Modules`/`templates`/`velociraptor` directories directly from
GitHub over HTTPS during the build, rather than Packer uploading them
over WinRM; pass `-var "source_ref=<branch>"` to build against an
unmerged branch instead. KAPE, if supplied, is staged via a temporary
VMware Workstation shared folder rather than a WinRM upload - both of
these replaced an earlier design that uploaded everything over WinRM,
after that repeatedly failed on large-file transfers in real builds.)

**Make sure VMware Workstation's own application window is already open**
(step 1) before running this - see that step's note on why. Expect this
to take the better part of an hour - mostly unattended Windows Setup
time, then `Setup-Workstation.ps1 -Tier All` fetching the full analyst
toolset inside the guest. Watch the VM's own window (this template does
not run headless) - if Windows Setup stalls on a screen rather than
proceeding, `http/autounattend.xml` needs a tweak for the specific ISO
build (see that file's `/IMAGE/NAME` setting, the most common mismatch -
credentials/product key/computer name are templated from Packer
variables now, not hand-edited in this file).

**What to check when it finishes:** Packer reports a build success and
leaves `output-ir-golden\ir-golden.vmx` powered off. If it instead times
out waiting for WinRM, the most common cause is `autounattend.xml`'s
`FirstLogonCommands` WinRM-enable step not having run yet - open the VM's
console window and check whether Windows actually finished OOBE sign-in.

### EFI boot-prompt investigation - resolved

**Resolved.** The actual cause was confirmed by direct testing: `vmrun
start <vmx> gui` (what `headless = false` triggers) hangs indefinitely at
"Powering on virtual machine..." if VMware Workstation's own application
isn't already running when Packer starts it - this matches upstream
[issue #280](https://github.com/vmware/packer-plugin-vmware/issues/280),
where opening Workstation first also resolved it for the original
reporter. It is NOT an EFI-specific keyboard/VNC defect - four different
`boot_wait`/keystroke timing configurations were tried and failed before
this was found, and none of them could ever have worked, since the build
never reached the VNC-connect or `boot_command` steps at all (confirmed
against the pinned [builder source](https://github.com/vmware/packer-plugin-vmware/blob/v2.1.7/builder/vmware/common/step_run.go):
`StepRun` prints "Powering on virtual machine..." and blocks on
`driver.Start()` strictly before `StepVNCConnect` ever runs).

**The fix**: launch VMware Workstation's main window before running
`packer build` (see step 1's note), and leave `headless = false` with a
real `boot_command` as the default - that's the setup in this repo now.
The `headless = true` / `disable_vnc = true` / no-prompt-ISO approach
tried earlier in this investigation was a heavier workaround for a
problem that had a much simpler fix; it's kept as an optional fallback
(`scripts/New-NoPromptWindowsIso.ps1`, step 3) for a machine where even
having Workstation open doesn't help.

### Reverted: moving WinRM bootstrap into specialize caused a new failure

An earlier revision of this file moved the WinRM bootstrap commands
(network profile, PSRemoting, firewall rule, WinRM service/quota config)
out of `FirstLogonCommands` and into the `specialize` pass, after a
Codex review found a real, Microsoft-documented defect: three of those
commands exceeded `RunSynchronousCommand`'s 259-character `Path` limit.
That specific length-limit fix was real and correct on its own, but the
larger redesign it was bundled with was not: running `specialize`
caused a confirmed real build to stall mid-install (Setup's progress
stuck around 58%, with an idle PowerShell window sitting open) -
`Enable-PSRemoting`/`Restart-Service WinRM` apparently don't reliably
complete that early in `specialize`, before the OS is fully settled.

**Reverted back to the proven design**: everything runs in
`FirstLogonCommands` again (the same structure that got WinRM connected
successfully in an earlier real build - it only later failed on an
unrelated VMware Tools provisioner bug, never on this). `specialize`
now only sets the computer name/timezone/RDP firewall group - nothing
that can stall Setup. If `RunSynchronousCommand`'s 259-character limit
ever needs revisiting (e.g. more bootstrap logic gets added later),
stage a real `.ps1` file via `floppy_content` and invoke it with a short
launcher from `FirstLogonCommands`, not from `specialize` - keep the
length fix, don't repeat the phase move that caused the stall.

If `FirstLogonCommands` ever fails outright, before rebuilding, leave
the VM open, press Shift+F10, and check:

```bat
notepad C:\Windows\Panther\setupact.log
notepad C:\Windows\Temp\packer-winrm.log
```

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
