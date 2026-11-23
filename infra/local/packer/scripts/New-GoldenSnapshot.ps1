<#
.SYNOPSIS
    Takes the `golden-clean` snapshot a freshly Packer-built VM needs
    before New-LocalCase.ps1 can use it. Run this once, right after
    `packer build` finishes.

.DESCRIPTION
    Packer's vmware-iso builder has no concept of a named VMware snapshot -
    it leaves the finished VM powered off and registered (a local
    Workstation build needs no keep_registered option - see
    golden-image.pkr.hcl's comment on why that option only applies to a
    remote/ESXi build), and that's where its own job ends. Snapshotting is
    this module's own case-lifecycle concern, not a generic image-build
    one, so it's a tiny standalone script rather than something bolted
    onto the Packer template with a shell-out post-processor.

.PARAMETER VmxPath
    Defaults to Packer's own output_directory/vm_name convention from
    golden-image.pkr.hcl's defaults. Pass -VmxPath explicitly if you
    changed either variable at build time.
#>
[CmdletBinding()]
param(
    [string]$VmxPath = (Join-Path $PSScriptRoot '..\output-ir-golden\ir-golden.vmx'),
    [string]$SnapshotName = 'golden-clean',
    [string]$VmrunPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) '..\scripts\Local-VmrunHelpers.ps1')

if (-not (Test-VmxPath -VmxPath $VmxPath)) {
    Write-Host "No .vmx found at $VmxPath - pass -VmxPath to wherever Packer actually wrote it (check golden-image.pkr.hcl's output_directory/vm_name variables if you overrode them)." -ForegroundColor Red
    exit 1
}

$vmrun = Get-VmrunExePath -VmrunPath $VmrunPath
if (-not $vmrun) {
    Write-Host "vmrun.exe not found - pass -VmrunPath, or install VMware Workstation." -ForegroundColor Red
    exit 1
}

$existing = Get-SnapshotList -VmrunExe $vmrun -VmxPath $VmxPath
if ($existing -contains $SnapshotName) {
    Write-Host "Snapshot '$SnapshotName' already exists on this VM - nothing to do. Delete it first (vmrun deleteSnapshot) if you want to re-snapshot after rebuilding." -ForegroundColor Yellow
    exit 0
}

$state = Get-VmPowerState -VmrunExe $vmrun -VmxPath $VmxPath
if ($state -eq 'running') {
    Write-Host "VM is running - Packer's shutdown_command should have powered it off. Stopping it (soft) before snapshotting, so 'golden-clean' is a clean power-off state, not a running one." -ForegroundColor Yellow
    Invoke-Vmrun -VmrunExe $vmrun -Arguments @('stop', $VmxPath, 'soft') -TimeoutSeconds 90 | Out-Null
}

Write-Host "Taking snapshot '$SnapshotName' of $VmxPath..." -ForegroundColor Cyan
Invoke-Vmrun -VmrunExe $vmrun -Arguments @('snapshot', $VmxPath, $SnapshotName) | Out-Null
Write-Host "Done. New-LocalCase.ps1's default -VmxPath points here: $VmxPath" -ForegroundColor Green
