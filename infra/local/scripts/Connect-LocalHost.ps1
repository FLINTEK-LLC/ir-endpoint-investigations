<#
.SYNOPSIS
    Connects to a local case's investigation host - either a real RDP
    session over the VM's own network interface, or just the Workstation
    console window, your choice per call.

.DESCRIPTION
    The local equivalent of infra\scripts\Connect-InvestigationHost.ps1,
    and the same two-options-pick-per-case shape the cloud module's
    README documents for Azure (rdp-allowlist vs Bastion) - see
    infra\local\README.md's "Connecting to the local host" section for
    the full trade-off writeup. Short version:

      -Method Console (default)  The VM's own Workstation window -
                                  always works, needs no guest network
                                  config, but it is one fixed-size window
                                  tied to this physical machine's desktop
                                  session, with no clipboard/drive
                                  redirection beyond what VMware Tools
                                  itself provides.
      -Method Rdp                A real mstsc.exe session to the guest's
                                  IP - resizable, clipboard works both
                                  ways, and you can disconnect/reconnect
                                  without touching the VM. Needs the
                                  guest's firewall to allow RDP (the
                                  golden image's autounattend.xml enables
                                  it) and VMware Workstation's virtual
                                  network to actually reach the guest
                                  (NAT - the default - works out of the
                                  box; Bridged needs the host's own LAN to
                                  hand out an address the host can reach).

    Unlike the cloud module, there is no broker here (no SSM, no
    Bastion) - VMware Workstation's NAT/bridged networking is already a
    private, host-only-reachable network by default, so this never opens
    a port to the internet. The RDP path is only as exposed as your own
    LAN/NAT setup already is.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CaseId,

    [ValidateSet('Console', 'Rdp')]
    [string]$Method = 'Console',

    [string]$VmrunPath,

    [int]$GuestIpTimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Local-VmrunHelpers.ps1')

$casesDir = Join-Path (Split-Path -Parent $PSScriptRoot) '.cases'
$casePath = Join-Path $casesDir "$CaseId.json"
if (-not (Test-Path -LiteralPath $casePath)) {
    Write-Host "No local case record for '$CaseId' at $casePath - run New-LocalCase.ps1 first." -ForegroundColor Red
    exit 1
}
$record = Get-Content -Raw -LiteralPath $casePath | ConvertFrom-Json

$vmrun = Get-VmrunExePath -VmrunPath $VmrunPath
if (-not $vmrun) {
    Write-Host "vmrun.exe not found - pass -VmrunPath, or install VMware Workstation." -ForegroundColor Red
    exit 1
}

$state = Get-VmPowerState -VmrunExe $vmrun -VmxPath $record.vmx_path
if ($state -ne 'running') {
    Write-Host "Case '$CaseId''s VM is not running (state: $state). Run New-LocalCase.ps1 again, or vmrun start it directly, before connecting." -ForegroundColor Red
    exit 1
}

if ($Method -eq 'Console') {
    # vmrun itself has no "focus this window" subcommand - starting the VM
    # with -Gui (New-LocalCase.ps1's default) already leaves its console
    # window open on the host desktop. This path is mostly documentation:
    # confirm it's running and point the operator at it, rather than
    # pretending there is more automation possible here than vmrun offers.
    Write-Host "Case '$CaseId' is running. Its console window should already be open (New-LocalCase.ps1 starts VMs in gui mode by default)." -ForegroundColor Green
    Write-Host "If you don't see it, open VMware Workstation and switch to the 'ir-golden' tab, or re-run with -Method Rdp for a Remote Desktop session instead." -ForegroundColor DarkGray
    exit 0
}

Write-Host "Looking up the guest's IP address..." -ForegroundColor Cyan
$guestIp = Wait-ForGuestIp -VmrunExe $vmrun -VmxPath $record.vmx_path -TimeoutSeconds $GuestIpTimeoutSeconds
if (-not $guestIp) {
    Write-Host "Could not get a guest IP within $GuestIpTimeoutSeconds seconds. VMware Tools may not be running yet, or the guest network may be down - check the VM's own console window." -ForegroundColor Red
    exit 1
}

Write-Host "Launching Remote Desktop to $guestIp..." -ForegroundColor Green
Write-Host "Sign in with whatever local account the golden image's autounattend.xml created (see infra\local\README.md) - this script does not know or store that password." -ForegroundColor DarkGray
Start-Process -FilePath 'mstsc.exe' -ArgumentList @("/v:$guestIp")
