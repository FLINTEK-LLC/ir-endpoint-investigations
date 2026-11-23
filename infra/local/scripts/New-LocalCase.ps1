<#
.SYNOPSIS
    Starts a case on the local VMware Workstation golden VM: reverts it to
    the `golden-clean` snapshot, mounts the case's evidence folder as a
    read-only shared folder, and powers it on.

.DESCRIPTION
    The local-infrastructure equivalent of infra\environments\*-case's
    `terraform apply` - but snapshot-revert rather than create-from-scratch,
    since there is one physical golden VM per Workstation host, not a cloud
    API that can spin up an arbitrary number of them. See
    Local-VmrunHelpers.ps1's header for why clone-per-case was rejected.

    Reverting BEFORE mounting the evidence folder matters: a revert resets
    the VM to its snapshotted .vmx, which does not include shared folders
    added after that snapshot was taken, so attaching the evidence first
    and reverting second would silently drop it.

    Case bookkeeping is written to infra\local\.cases\<CaseId>.json
    (gitignored - same rule as infra\.cases\, see infra\README.md's
    "Accounts, tokens, and secrets" section) so Connect-LocalHost.ps1 and
    Stop-LocalCase.ps1 know which VMX and share this case is using without
    re-prompting.

.PARAMETER CaseId
    Lowercase letters/numbers/hyphens, matching the same shape the cloud
    console enforces on case IDs - also used as the shared-folder name.

.PARAMETER EvidencePath
    Host folder holding this case's evidence (VHD/memdump/KAPE zips/
    collector output) - mounted read-only into the guest. Create it first;
    this script does not create evidence folders, only wires one in.

.PARAMETER VmxPath
    Path to the golden VM's .vmx. Defaults to the path New-GoldenSnapshot.ps1
    reports after a Packer build - see infra\local\README.md.

.PARAMETER SnapshotName
    Defaults to `golden-clean` - the snapshot New-GoldenSnapshot.ps1 takes
    right after the Packer build finishes provisioning.

.PARAMETER Gui
    Starts the VM with its console window visible (vmrun's "gui" mode -
    the default). Pass -Gui:$false for vmrun's "nogui" mode if you intend
    to connect over RDP only (see Connect-LocalHost.ps1) and don't want a
    window on the host's own desktop.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$')]
    [string]$CaseId,

    [Parameter(Mandatory = $true)]
    [string]$EvidencePath,

    [string]$VmxPath = (Join-Path $PSScriptRoot '..\packer\output-ir-golden\ir-golden.vmx'),

    [string]$SnapshotName = 'golden-clean',

    [string]$VmrunPath,

    [bool]$Gui = $true,

    # How long to wait for VMware Tools inside the guest to report an IP
    # after power-on, before giving up (not failing the whole script - the
    # VM is still usable from its own console window either way).
    [int]$GuestIpTimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Local-VmrunHelpers.ps1')

$casesDir = Join-Path (Split-Path -Parent $PSScriptRoot) '.cases'
New-Item -ItemType Directory -Path $casesDir -Force -ErrorAction SilentlyContinue | Out-Null
$casePath = Join-Path $casesDir "$CaseId.json"
if (Test-Path -LiteralPath $casePath) {
    Write-Host "A case record for '$CaseId' already exists at $casePath. Use Stop-LocalCase.ps1 first if you want to restart it, or pick a different -CaseId." -ForegroundColor Yellow
    exit 1
}

$vmrun = Get-VmrunExePath -VmrunPath $VmrunPath
if (-not $vmrun) {
    Write-Host "vmrun.exe not found. Install VMware Workstation, or pass -VmrunPath to the real location (default checked: C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe)." -ForegroundColor Red
    exit 1
}
if (-not (Test-VmxPath -VmxPath $VmxPath)) {
    Write-Host "No golden VM .vmx found at: $VmxPath" -ForegroundColor Red
    Write-Host "Build it first - see infra\local\README.md (Packer golden-image build) - or pass -VmxPath to an existing one." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $EvidencePath)) {
    Write-Host "Evidence path does not exist: $EvidencePath" -ForegroundColor Red
    exit 1
}

$snapshots = Get-SnapshotList -VmrunExe $vmrun -VmxPath $VmxPath
if ($snapshots -notcontains $SnapshotName) {
    Write-Host "Snapshot '$SnapshotName' not found on this VM. Snapshots present:" -ForegroundColor Red
    $snapshots | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "Take it once after the Packer build with New-GoldenSnapshot.ps1 (see infra\local\README.md)." -ForegroundColor Red
    exit 1
}

$state = Get-VmPowerState -VmrunExe $vmrun -VmxPath $VmxPath
if ($state -eq 'running') {
    Write-Host "The golden VM is currently running - stop it first (Stop-LocalCase.ps1, or close its current case) before starting a new one. Only one case can be open on this VM at a time - see Local-VmrunHelpers.ps1's header." -ForegroundColor Red
    exit 1
}

Write-Host "Reverting to snapshot '$SnapshotName' - this discards anything the previous case left on this VM..." -ForegroundColor Cyan
Invoke-Vmrun -VmrunExe $vmrun -Arguments @('revertToSnapshot', $VmxPath, $SnapshotName) | Out-Null
Write-Host "Reverted." -ForegroundColor Green

$shareName = "case-$CaseId"
Write-Host "Mounting '$EvidencePath' into the guest as shared folder '$shareName' (read-only)..." -ForegroundColor Cyan
Add-CaseSharedFolder -VmrunExe $vmrun -VmxPath $VmxPath -ShareName $shareName -HostPath (Resolve-Path -LiteralPath $EvidencePath).Path

Write-Host "Starting the VM ($(if ($Gui) { 'gui' } else { 'nogui' }) mode)..." -ForegroundColor Cyan
Invoke-Vmrun -VmrunExe $vmrun -Arguments @('start', $VmxPath, $(if ($Gui) { 'gui' } else { 'nogui' })) -TimeoutSeconds 60 | Out-Null

Write-Host "Waiting for the guest to report an IP address (VMware Tools)..." -ForegroundColor DarkGray
$guestIp = Wait-ForGuestIp -VmrunExe $vmrun -VmxPath $VmxPath -TimeoutSeconds $GuestIpTimeoutSeconds
if ($guestIp) {
    Write-Host "Guest IP: $guestIp" -ForegroundColor Green
} else {
    Write-Host "Guest did not report an IP within $GuestIpTimeoutSeconds seconds - it may still be booting. Connect-LocalHost.ps1 will retry, or use the VM's own console window." -ForegroundColor Yellow
}

$record = [pscustomobject]@{
    case_id       = $CaseId
    vmx_path      = $VmxPath
    snapshot_name = $SnapshotName
    evidence_path = (Resolve-Path -LiteralPath $EvidencePath).Path
    share_name    = $shareName
    status        = 'active'
    created_utc   = (Get-Date).ToUniversalTime().ToString('o')
    guest_ip      = $guestIp
}
$record | ConvertTo-Json -Depth 5 | Out-File -Encoding utf8 -LiteralPath $casePath

Write-Host ""
Write-Host "Case '$CaseId' is up. Evidence is at \\vmware-host\Shared Folders\$shareName inside the guest." -ForegroundColor Green
Write-Host "Next: Connect-LocalHost.ps1 -CaseId $CaseId to get a Remote Desktop session, or just use the VM's own console window." -ForegroundColor Green
Write-Host "Once this host's own Setup-Workstation.ps1 ran as part of the golden-image build, scripts\Start-IRConsole.ps1 is already on the box - work the case as you normally would." -ForegroundColor DarkGray
