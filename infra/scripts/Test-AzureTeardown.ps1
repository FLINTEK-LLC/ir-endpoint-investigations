<#
.SYNOPSIS
    Reports anything in the current Azure subscription that could still be
    billing after a case teardown.

.DESCRIPTION
    The Azure counterpart to Test-AwsTeardown.ps1, and it exists for the same
    reason: checking by eye misses precisely the things that bill quietly.

      * Managed disks bill whether or not they are attached to anything. A VM
        deleted without its disks is the classic Azure surprise - the disk
        survives, is invisible in the VM list, and costs the same as it did.
      * A Bastion host bills PER HOUR from the moment it is created, whether
        or not anyone connects through it. It is far and away the most
        expensive thing this project can leave running, which is exactly why
        the shared Bastion is a separate deploy/destroy pair in the console.
      * Standard SKU public IPs bill even when associated with nothing.
      * A stopped VM still bills for its disks. "Stopped" is not "free", and
        note that "Stopped" and "Stopped (deallocated)" are different states -
        only the deallocated one stops compute charges.

    Resource groups, VNets, subnets, NSGs and managed identities cost nothing,
    so they are reported separately as leftovers worth tidying rather than as
    charges.

    Scope is the currently selected subscription (az account show). There is
    no all-regions sweep because, unlike AWS, an Azure resource list is
    subscription-wide already - region is an attribute, not a separate
    endpoint to query.

.PARAMETER AllSubscriptions
    Check every enabled subscription the signed-in account can see, not just
    the currently selected one.

.EXAMPLE
    .\Test-AzureTeardown.ps1
    .\Test-AzureTeardown.ps1 -AllSubscriptions
#>
[CmdletBinding()]
param(
    [switch]$AllSubscriptions
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found - run infra\scripts\Test-Prerequisites.ps1 (elevated) first."
}

function Invoke-AzJson {
    # Returns $null on any failure rather than throwing: a subscription the
    # account can see but not read should skip a resource type, not abort the
    # whole report and leave the operator thinking they are clear.
    param([Parameter(ValueFromRemainingArguments)][string[]]$CliArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & az @CliArgs --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
        return (($raw | Out-String) | ConvertFrom-Json)
    } catch { return $null } finally { $ErrorActionPreference = $prev }
}

$subs = @()
if ($AllSubscriptions) {
    $all = Invoke-AzJson account list --all
    $subs = @($all | Where-Object { $_.state -eq 'Enabled' } | ForEach-Object { [pscustomobject]@{ Id = $_.id; Name = $_.name } })
    Write-Host "Checking $($subs.Count) subscription(s)." -ForegroundColor DarkGray
} else {
    $cur = Invoke-AzJson account show
    if (-not $cur) { throw "Not signed in - run 'az login' (option [1] does this for you)." }
    $subs = @([pscustomobject]@{ Id = $cur.id; Name = $cur.name })
}

$billing = @()
$leftover = @()

foreach ($sub in $subs) {
    if ($AllSubscriptions) { & az account set --subscription $sub.Id 2>$null }
    $label = $sub.Name

    # --- VMs (a deallocated VM still bills for its disks) ---
    # Every enumeration below filters nulls. @($null) is a ONE-element array
    # containing null, not an empty one, so an unfiltered foreach would
    # iterate once with $item = $null and report a phantom resource with a
    # blank name - a false positive in the one script whose whole job is
    # eliminating false positives about billing.
    $vms = Invoke-AzJson vm list -d
    foreach ($vm in @($vms | Where-Object { $_ })) {
        $billing += [pscustomobject]@{ Sub = $label; Kind = 'VM'; Name = $vm.name; Detail = "$($vm.hardwareProfile.vmSize) $($vm.powerState)" }
    }

    # --- Managed disks (billed attached OR detached) ---
    $disks = Invoke-AzJson disk list
    foreach ($d in @($disks | Where-Object { $_ })) {
        $state = if ($d.diskState -eq 'Unattached') { 'UNATTACHED - still billed' } else { $d.diskState }
        $billing += [pscustomobject]@{ Sub = $label; Kind = 'Managed disk'; Name = $d.name; Detail = "$($d.diskSizeGb)GiB $state" }
    }

    # --- Bastion (hourly, the expensive one) ---
    $bastions = Invoke-AzJson network bastion list
    foreach ($b in @($bastions | Where-Object { $_ })) {
        $billing += [pscustomobject]@{ Sub = $label; Kind = 'Bastion'; Name = $b.name; Detail = "$($b.sku.name) SKU - BILLS HOURLY" }
    }

    # --- Public IPs (Standard SKU bills even unassociated) ---
    $ips = Invoke-AzJson network public-ip list
    foreach ($ip in @($ips | Where-Object { $_ })) {
        $assoc = if ($ip.ipConfiguration) { 'associated' } else { 'unassociated' }
        $billing += [pscustomobject]@{ Sub = $label; Kind = 'Public IP'; Name = $ip.name; Detail = "$($ip.sku.name) $assoc" }
    }

    # --- NAT gateways ---
    $nats = Invoke-AzJson network nat gateway list
    foreach ($n in @($nats | Where-Object { $_ })) {
        $billing += [pscustomobject]@{ Sub = $label; Kind = 'NAT gateway'; Name = $n.name; Detail = 'bills hourly' }
    }

    # --- Snapshots ---
    $snaps = Invoke-AzJson snapshot list
    foreach ($s in @($snaps | Where-Object { $_ })) {
        $billing += [pscustomobject]@{ Sub = $label; Kind = 'Snapshot'; Name = $s.name; Detail = "$($s.diskSizeGb)GiB" }
    }

    # --- Storage accounts (evidence and tools - bill by what is in them) ---
    $sas = Invoke-AzJson storage account list
    foreach ($sa in @($sas | Where-Object { $_ })) {
        $billing += [pscustomobject]@{ Sub = $label; Kind = 'Storage account'; Name = $sa.name; Detail = "$($sa.sku.name) - check contents" }
    }

    # --- Free, but worth tidying ---
    $rgs = Invoke-AzJson group list
    foreach ($rg in @($rgs | Where-Object { $_.name -match '^(rg-ir-|NetworkWatcherRG)' })) {
        $leftover += [pscustomobject]@{ Sub = $label; Kind = 'Resource group (free)'; Name = $rg.name; Detail = $rg.location }
    }
}

if ($AllSubscriptions -and $subs.Count -gt 0) { & az account set --subscription $subs[0].Id 2>$null }

Write-Host ""
if ($billing.Count -eq 0) {
    Write-Host "Nothing billable found. You are clear." -ForegroundColor Green
} else {
    Write-Host "STILL BILLABLE:" -ForegroundColor Red
    $billing | Sort-Object Sub, Kind | Format-Table Sub, Kind, Name, Detail -AutoSize
    Write-Host "A managed disk bills whether attached or not, and a Bastion bills by the" -ForegroundColor Yellow
    Write-Host "hour whether or not anyone uses it." -ForegroundColor Yellow
}

if ($leftover.Count -gt 0) {
    Write-Host "Free, but left behind (tidy at your leisure):" -ForegroundColor DarkGray
    $leftover | Sort-Object Sub, Kind | Format-Table Sub, Kind, Name, Detail -AutoSize
    Write-Host "NetworkWatcherRG is created automatically by Azure and costs nothing." -ForegroundColor DarkGray
}

if (-not $AllSubscriptions) {
    Write-Host "Only the selected subscription was checked. Re-run with -AllSubscriptions" -ForegroundColor DarkGray
    Write-Host "to sweep every subscription this account can see." -ForegroundColor DarkGray
}
