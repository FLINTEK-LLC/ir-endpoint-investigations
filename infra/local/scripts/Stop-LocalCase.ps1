<#
.SYNOPSIS
    Ends a local case's session on the investigation host: stops the VM
    and reverts it to the `golden-clean` snapshot. The local equivalent of
    infra\Start-CloudConsole.ps1's "[5] Destroy the investigation host" -
    there is no cloud resource to delete, so "destroy" here means "put the
    one physical VM back to a clean state and release the case's shared
    folder."

.DESCRIPTION
    Evidence is never touched - -EvidencePath from New-LocalCase.ps1 is a
    HOST folder the guest only ever saw read-only; stopping/reverting the
    VM has no effect on it, same "destroy compute, keep storage" split the
    cloud module documents.

    The case record (infra\local\.cases\<CaseId>.json) is removed only
    when -DeleteRecord is passed - by default it's kept (with status set
    to 'closed') so a case's history (which evidence path, when it ran) is
    still visible after the session ends, mirroring how the cloud module
    treats [5] Destroy (compute gone, bookkeeping stays) versus [D] Delete
    a case completely (removes the record outright).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CaseId,

    [string]$VmrunPath,

    # vmrun's own stop modes: 'soft' asks the guest OS to shut down (needs
    # VMware Tools running inside it); 'hard' is the power-cord-pull
    # equivalent. Soft is the default because a hard stop on a machine
    # that may have an open RegRipper/KAPE run or an Excel COM session can
    # leave file handles in an inconsistent state - the exact kind of
    # thing this project's own New-ReviewWorkbook.ps1 comments warn about
    # for orphaned EXCEL.EXE processes.
    [ValidateSet('soft', 'hard')]
    [string]$StopMode = 'soft',

    [switch]$DeleteRecord
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Local-VmrunHelpers.ps1')

$casesDir = Join-Path (Split-Path -Parent $PSScriptRoot) '.cases'
$casePath = Join-Path $casesDir "$CaseId.json"
if (-not (Test-Path -LiteralPath $casePath)) {
    Write-Host "No local case record for '$CaseId' at $casePath." -ForegroundColor Red
    exit 1
}
$record = Get-Content -Raw -LiteralPath $casePath | ConvertFrom-Json

$vmrun = Get-VmrunExePath -VmrunPath $VmrunPath
if (-not $vmrun) {
    Write-Host "vmrun.exe not found - pass -VmrunPath, or install VMware Workstation." -ForegroundColor Red
    exit 1
}

$state = Get-VmPowerState -VmrunExe $vmrun -VmxPath $record.vmx_path
if ($state -eq 'running') {
    Write-Host "Stopping the VM ($StopMode)..." -ForegroundColor Cyan
    try {
        Invoke-Vmrun -VmrunExe $vmrun -Arguments @('stop', $record.vmx_path, $StopMode) -TimeoutSeconds 90 | Out-Null
    } catch {
        if ($StopMode -eq 'soft') {
            Write-Host "Soft stop failed ($($_.Exception.Message)) - falling back to a hard stop." -ForegroundColor Yellow
            Invoke-Vmrun -VmrunExe $vmrun -Arguments @('stop', $record.vmx_path, 'hard') -TimeoutSeconds 60 | Out-Null
        } else {
            throw
        }
    }
} else {
    Write-Host "VM was already stopped (state: $state)." -ForegroundColor DarkGray
}

Write-Host "Removing this case's shared folder ('$($record.share_name)')..." -ForegroundColor Cyan
Remove-CaseSharedFolder -VmrunExe $vmrun -VmxPath $record.vmx_path -ShareName $record.share_name

Write-Host "Reverting to snapshot '$($record.snapshot_name)' - this discards everything done inside the guest this session..." -ForegroundColor Cyan
Invoke-Vmrun -VmrunExe $vmrun -Arguments @('revertToSnapshot', $record.vmx_path, $record.snapshot_name) | Out-Null
Write-Host "Reverted. The VM is clean and stopped - evidence at $($record.evidence_path) is untouched." -ForegroundColor Green

if ($DeleteRecord) {
    Remove-Item -LiteralPath $casePath -Force
    Write-Host "Removed the local case record for '$CaseId'." -ForegroundColor Green
} else {
    $record.status = 'closed'
    $record.closed_utc = (Get-Date).ToUniversalTime().ToString('o')
    $record | ConvertTo-Json -Depth 5 | Out-File -Encoding utf8 -LiteralPath $casePath
    Write-Host "Case '$CaseId' marked closed (record kept at $casePath - pass -DeleteRecord to remove it)." -ForegroundColor Green
}
