# Testing the local VMware module from zero

A concrete, from-scratch walkthrough: no VMware Workstation, no Packer, no
Windows ISO yet, through a full case cycle and cleanup. Mirrors
[`../TESTING.md`](../TESTING.md)'s style for the cloud module. Every step
below is something to actually run and check the output of - this is not
a narrative, it's the test procedure.

**What this covers that CI does not.** `.github/workflows/selftest.yml`
syntax-checks every script here and runs `packer fmt`/`packer validate` on
`golden-image.pkr.hcl` with no credentials and no VM - the same "no live
apply" policy the cloud module's CI uses for Terraform. It cannot build a
real VM, because that needs VMware Workstation installed and a real
Windows ISO, neither of which exist in a CI runner (or in the environment
this module was authored in - see [`../README.md`](../README.md)'s
Verification section). Everything below is accordingly a **manual**
procedure for you to run once on your own machine.

## 1. Install VMware Workstation Pro

Download and install from [vmware.com](https://www.vmware.com/products/workstation-pro.html)
(licensed - this is your own purchase/trial, not something this project
can provide). Confirm `vmrun.exe` exists:

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

## 3. Get a Windows 11 Enterprise evaluation ISO

Download from
[microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise)
(web form, no scriptable download - see `golden-image.pkr.hcl`'s header
comment for why). Then compute its checksum:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath C:\Downloads\Win11_Enterprise_Eval.iso
```

Keep the `.iso` path and the hash - both are required Packer variables
with no default.

## 4. (Optional) Stage your licensed KAPE zip

If you already have `kape.zip` from [kroll.com/kape](https://www.kroll.com/kape),
keep its path handy for `-var kape_zip_path=...` below. Skipping this is
fine for a first infrastructure test - the golden image comes up with
everything except the KAPE-coupled parsing toolchain, and
`Setup-Workstation.ps1`'s own output says so explicitly.

## 5. Build the golden image

```powershell
cd ir-endpoint-investigations\infra\local\packer
packer build `
  -var "iso_url=C:\Downloads\Win11_Enterprise_Eval.iso" `
  -var "iso_checksum=sha256:<the hash from step 3>" `
  -var "winrm_password=<something you will remember>" `
  -var "kape_zip_path=C:\Downloads\kape.zip" `
  golden-image.pkr.hcl
```

Expect this to take the better part of an hour - mostly unattended
Windows Setup time, then `Setup-Workstation.ps1 -Tier All` fetching the
full analyst toolset inside the guest. Watch the VM's own window (this
template does not run headless) - if Windows Setup stalls on a screen
rather than proceeding, `http/autounattend.xml` needs a tweak for your
specific ISO build (see that file's header comment on the `/IMAGE/INDEX`
value, the most common mismatch).

**What to check when it finishes:** Packer reports a build success and
leaves `output-ir-golden\ir-golden.vmx` powered off. If it instead times
out waiting for WinRM, the most common cause is `autounattend.xml`'s
`FirstLogonCommands` WinRM-enable step not having run yet - open the VM's
console window and check whether Windows actually finished OOBE sign-in.

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
# Drop anything you'd normally hand an analyst into C:\Cases\TEST-0001 -
# a KAPE collection zip, a sample memory image, whatever you have on hand.

.\scripts\New-LocalCase.ps1 -CaseId test-0001 -EvidencePath C:\Cases\TEST-0001 `
  -VmxPath .\packer\output-ir-golden\ir-golden.vmx
```

**Check:** the VM's console window appears, Windows boots from a clean
snapshot, and the script prints a guest IP once VMware Tools reports one.

```powershell
.\scripts\Connect-LocalHost.ps1 -CaseId test-0001 -Method Rdp
```

**Check:** `mstsc.exe` opens and you can log in with the `ir-analyst`
account and the password you set at `-var winrm_password`. Inside the
guest, confirm the evidence folder is visible:

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
  the local case bookkeeping if you don't want `[4] List cases` to keep
  showing your test case.
- `Remove-Item -Recurse C:\Cases\TEST-0001` once you're done with the test
  evidence - it was never touched by the guest, but it is still disk
  space on the host.
- The golden VM itself (`packer\output-ir-golden\`) is meant to be kept
  long-term and reused by every future case - there is nothing to tear
  down there unless you are abandoning the module entirely, in which case
  delete the VM through VMware Workstation's own library (Remove from
  Library + delete files), not by hand-deleting the folder (Workstation's
  own inventory can get confused by files disappearing out from under
  it).

## What still needs a real run on your own machine

Everything in this document, in full - this module was authored with no
VMware Workstation available (see `../README.md`'s Verification section),
so every `packer build`, `vmrun` call, RDP session and shared-folder
mount above is unexercised beyond PowerShell/HCL syntax checking. Report
back anything that doesn't match this walkthrough, the same working
pattern the rest of this project's own development used.
