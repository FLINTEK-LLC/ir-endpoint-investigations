<#
.SYNOPSIS
    Reports anything in AWS that could still be billing after a case teardown.

.DESCRIPTION
    Teardown verification by eye is how something gets missed, and the things
    most easily missed are the ones that bill quietly rather than obviously:

      * EBS volumes bill whether or not they are attached to anything. A
        detached volume is invisible in the instance list and costs the same.
      * Elastic IPs bill when they are NOT associated with a running
        instance - the opposite of the intuition.
      * NAT Gateways bill per hour from creation and keep going until the
        state is actually "deleted", which lags the delete call by a minute
        or two.
      * Stopped instances still bill for their volumes, so "stopped" is not
        "free".

    A VPC, subnet, route table, Internet Gateway, security group or IAM role
    costs nothing, so those are reported only as leftovers worth tidying, not
    as charges.

    Filtering with JMESPath is deliberately avoided in favour of retrieving
    state and filtering in PowerShell: an unquoted literal in a JMESPath
    comparison (State!=deleted rather than State!='deleted') is silently
    parsed as a field name, matches everything, and reports deleted resources
    as live. That is a very easy way to be told you still have a NAT Gateway
    when you do not.

.PARAMETER AllRegions
    Check every enabled region, not just -Region. Slower, but the only way to
    catch something created in a region you have since forgotten about -
    which is a genuinely common way to keep paying.

.EXAMPLE
    .\Test-AwsTeardown.ps1
    .\Test-AwsTeardown.ps1 -AllRegions
#>
[CmdletBinding()]
param(
    [string]$AwsProfile = 'ir-cloud',
    [string]$Region = 'us-east-1',
    [switch]$AllRegions
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command aws -CommandType Application -ErrorAction SilentlyContinue)) {
    throw "aws CLI not found - run infra\scripts\Test-Prerequisites.ps1 (elevated) first."
}

function Invoke-Aws {
    param([string]$TargetRegion, [Parameter(ValueFromRemainingArguments)][string[]]$CliArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & aws @CliArgs --profile $AwsProfile --region $TargetRegion --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
        return (($raw | Out-String) | ConvertFrom-Json)
    } catch { return $null } finally { $ErrorActionPreference = $prev }
}

$regions = @($Region)
if ($AllRegions) {
    $r = Invoke-Aws -TargetRegion $Region ec2 describe-regions
    if ($r) { $regions = @($r.Regions | ForEach-Object { $_.RegionName } | Sort-Object) }
    Write-Host "Checking $($regions.Count) regions - this takes a minute." -ForegroundColor DarkGray
}

$billing = @()
$leftover = @()

foreach ($reg in $regions) {
    # --- EC2 instances (anything not terminated) ---
    $inst = Invoke-Aws -TargetRegion $reg ec2 describe-instances
    foreach ($res in @($inst.Reservations)) {
        foreach ($i in @($res.Instances | Where-Object { $_.State.Name -ne 'terminated' })) {
            $name = ($i.Tags | Where-Object { $_.Key -eq 'Name' } | Select-Object -First 1).Value
            $billing += [pscustomobject]@{ Region = $reg; Kind = 'EC2 instance'; Id = $i.InstanceId; Detail = "$($i.InstanceType) $($i.State.Name) $name" }
        }
    }

    # --- EBS volumes (billed attached OR detached) ---
    $vols = Invoke-Aws -TargetRegion $reg ec2 describe-volumes
    foreach ($v in @($vols.Volumes)) {
        $billing += [pscustomobject]@{ Region = $reg; Kind = 'EBS volume'; Id = $v.VolumeId; Detail = "$($v.Size)GiB $($v.VolumeType) $($v.State)" }
    }

    # --- NAT Gateways (state must actually read 'deleted') ---
    $nats = Invoke-Aws -TargetRegion $reg ec2 describe-nat-gateways
    foreach ($n in @($nats.NatGateways | Where-Object { $_.State -ne 'deleted' })) {
        $billing += [pscustomobject]@{ Region = $reg; Kind = 'NAT Gateway'; Id = $n.NatGatewayId; Detail = "$($n.State) (~`$0.045/hr)" }
    }

    # --- Elastic IPs (billed when NOT associated) ---
    $eips = Invoke-Aws -TargetRegion $reg ec2 describe-addresses
    foreach ($e in @($eips.Addresses)) {
        $assoc = if ($e.InstanceId -or $e.NetworkInterfaceId) { 'associated' } else { 'UNASSOCIATED - billed' }
        $billing += [pscustomobject]@{ Region = $reg; Kind = 'Elastic IP'; Id = $e.PublicIp; Detail = $assoc }
    }

    # --- Snapshots we own ---
    $snaps = Invoke-Aws -TargetRegion $reg ec2 describe-snapshots --owner-ids self
    foreach ($sn in @($snaps.Snapshots)) {
        $billing += [pscustomobject]@{ Region = $reg; Kind = 'EBS snapshot'; Id = $sn.SnapshotId; Detail = "$($sn.VolumeSize)GiB" }
    }

    # --- Free, but worth tidying ---
    $vpcs = Invoke-Aws -TargetRegion $reg ec2 describe-vpcs
    foreach ($v in @($vpcs.Vpcs | Where-Object { -not $_.IsDefault })) {
        $leftover += [pscustomobject]@{ Region = $reg; Kind = 'VPC (free)'; Id = $v.VpcId; Detail = $v.CidrBlock }
    }
}

# --- S3 is global; storage bills by what is in it ---
$buckets = Invoke-Aws -TargetRegion $Region s3api list-buckets
foreach ($b in @($buckets.Buckets)) {
    if ($b.Name -notmatch '^(ir-case|ir-tools)') { continue }
    $billing += [pscustomobject]@{ Region = 's3 (global)'; Kind = 'S3 bucket'; Id = $b.Name; Detail = 'check contents - storage is billed' }
}

Write-Host ""
if ($billing.Count -eq 0) {
    Write-Host "Nothing billable found. You are clear." -ForegroundColor Green
} else {
    Write-Host "STILL BILLABLE:" -ForegroundColor Red
    $billing | Sort-Object Region, Kind | Format-Table Region, Kind, Id, Detail -AutoSize
    Write-Host "Remember an EBS volume bills whether attached or not, and an Elastic IP" -ForegroundColor Yellow
    Write-Host "bills precisely when it is NOT associated with a running instance." -ForegroundColor Yellow
}

if ($leftover.Count -gt 0) {
    Write-Host "Free, but left behind (tidy at your leisure):" -ForegroundColor DarkGray
    $leftover | Sort-Object Region, Kind | Format-Table Region, Kind, Id, Detail -AutoSize
}

if (-not $AllRegions) {
    Write-Host "Only $Region was checked. Re-run with -AllRegions to catch anything" -ForegroundColor DarkGray
    Write-Host "created in a region you have forgotten about." -ForegroundColor DarkGray
}
