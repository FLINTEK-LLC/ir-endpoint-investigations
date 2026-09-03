<#
.SYNOPSIS
    Creates (or deletes) a minimal AWS test network for the investigation
    host: a VPC with a public subnet, a private subnet, and a NAT Gateway.

.DESCRIPTION
    This is the CLI equivalent of the console's "VPC and more" wizard, which
    is the only fiddly prerequisite for testing the AWS path.

    Why a NAT Gateway is not optional here: the investigation host is created
    with NO public IP by design (see infra/SECURITY.md), so an Internet
    Gateway route does nothing for it - an IGW only carries traffic for
    instances that have a public address. Without a NAT Gateway the host
    boots, never reaches SSM or GitHub, never becomes manageable, and bills
    the whole time. That is the single most common way to waste an afternoon
    on the AWS path.

    Two ordering details this script exists to get right:

      * The NAT Gateway lives in the PUBLIC subnet but serves the PRIVATE
        one. Putting it in the private subnet is a classic mistake and
        produces a network that looks correct and routes nowhere.
      * A NAT Gateway takes a couple of minutes to become available, and the
        private route table's 0.0.0.0/0 route cannot be added until it is.
        This waits (aws ec2 wait nat-gateway-available) instead of racing.

    Everything is tagged Project=ir-endpoint-investigations so -Delete can
    find it again, and so it is obvious in the console what created it.

.PARAMETER Delete
    Tear the network down instead of creating it, in the order AWS requires:
    NAT Gateway (and wait for it to actually go), then its Elastic IP, then
    subnets, route tables, Internet Gateway, and finally the VPC. Deleting
    out of order fails with dependency errors that do not say what depends on
    what.

.EXAMPLE
    .\New-AwsTestNetwork.ps1
    .\New-AwsTestNetwork.ps1 -Delete
#>
[CmdletBinding()]
param(
    [string]$AwsProfile = 'ir-cloud',
    [string]$Region = 'us-east-1',
    [string]$Name = 'ir-test',
    [string]$VpcCidr = '10.30.0.0/16',
    [string]$PublicSubnetCidr = '10.30.0.0/20',
    [string]$PrivateSubnetCidr = '10.30.128.0/20',
    [switch]$Delete
)

$ErrorActionPreference = 'Stop'
$tagFilter = "Name=tag:Project,Values=ir-endpoint-investigations"

function Invoke-Aws {
    # NOT named "Aws": PowerShell command resolution is case-insensitive, so a
    # function called Aws shadows the aws CLI, and `& aws ...` inside it then
    # recurses into itself until PowerShell aborts with "call depth overflow".
    # It also makes Get-Command aws succeed when the CLI is absent, so the
    # prerequisite guard below silently passed. Both were real.
    # Every call goes through here so profile/region/json are consistent and
    # a failure is a real error rather than a silent empty result.
    param([Parameter(ValueFromRemainingArguments)][string[]]$CliArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & aws @CliArgs --profile $AwsProfile --region $Region --output json 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) {
        throw "aws $($CliArgs -join ' ') failed: $(($raw | Out-String).Trim())"
    }
    $text = ($raw | Out-String).Trim()
    if (-not $text) { return $null }
    return ($text | ConvertFrom-Json)
}

function Tag {
    param([string]$ResourceId, [string]$NameTag)
    Invoke-Aws ec2 create-tags --resources $ResourceId --tags "Key=Name,Value=$NameTag" 'Key=Project,Value=ir-endpoint-investigations' | Out-Null
}

if (-not (Get-Command aws -CommandType Application -ErrorAction SilentlyContinue)) {
    throw "aws CLI not found - run infra\scripts\Test-Prerequisites.ps1 (elevated) first."
}

# ---------------------------------------------------------------------------
if ($Delete) {
    Write-Host "Looking for a network tagged Project=ir-endpoint-investigations in $Region..."
    $vpcs = Invoke-Aws ec2 describe-vpcs --filters $tagFilter
    if (-not $vpcs -or @($vpcs.Vpcs | Where-Object { $_ }).Count -eq 0) {
        Write-Host "Nothing to delete." -ForegroundColor Yellow
        return
    }
    foreach ($vpc in $vpcs.Vpcs) {
        $vpcId = $vpc.VpcId
        Write-Host "Deleting $vpcId ($($vpc.CidrBlock))..." -ForegroundColor Cyan

        # 1. NAT Gateways first - a subnet cannot be deleted while one lives
        #    in it, and the Elastic IP cannot be released while it is attached.
        $nats = Invoke-Aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpcId"
        foreach ($nat in @($nats.NatGateways | Where-Object { $_.State -notin @('deleted', 'deleting') })) {
            Write-Host "  deleting NAT Gateway $($nat.NatGatewayId) (this takes a minute or two)..."
            Invoke-Aws ec2 delete-nat-gateway --nat-gateway-id $nat.NatGatewayId | Out-Null
            & aws ec2 wait nat-gateway-deleted --nat-gateway-ids $nat.NatGatewayId --profile $AwsProfile --region $Region 2>$null
        }

        # 2. Release the Elastic IPs those NAT Gateways were holding. This is
        #    the one that silently keeps costing money if it is missed - an
        #    unassociated EIP is billed.
        $eips = Invoke-Aws ec2 describe-addresses --filters $tagFilter
        foreach ($eip in @($eips.Addresses | Where-Object { $_ })) {
            Write-Host "  releasing Elastic IP $($eip.PublicIp)"
            Invoke-Aws ec2 release-address --allocation-id $eip.AllocationId | Out-Null
        }

        # 3. Subnets (this also clears their route-table associations).
        $subnets = Invoke-Aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId"
        foreach ($sn in @($subnets.Subnets | Where-Object { $_ })) {
            Write-Host "  deleting subnet $($sn.SubnetId)"
            Invoke-Aws ec2 delete-subnet --subnet-id $sn.SubnetId | Out-Null
        }

        # 4. Route tables, skipping the VPC's main one which cannot be deleted.
        $rts = Invoke-Aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpcId"
        foreach ($rt in @($rts.RouteTables | Where-Object { $_ })) {
            if (@($rt.Associations | Where-Object { $_.Main }).Count -gt 0) { continue }
            Write-Host "  deleting route table $($rt.RouteTableId)"
            Invoke-Aws ec2 delete-route-table --route-table-id $rt.RouteTableId | Out-Null
        }

        # 5. Internet Gateway - detach before delete.
        $igws = Invoke-Aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpcId"
        foreach ($igw in @($igws.InternetGateways | Where-Object { $_ })) {
            Write-Host "  detaching and deleting $($igw.InternetGatewayId)"
            Invoke-Aws ec2 detach-internet-gateway --internet-gateway-id $igw.InternetGatewayId --vpc-id $vpcId | Out-Null
            Invoke-Aws ec2 delete-internet-gateway --internet-gateway-id $igw.InternetGatewayId | Out-Null
        }

        Invoke-Aws ec2 delete-vpc --vpc-id $vpcId | Out-Null
        Write-Host "  deleted $vpcId" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Confirm nothing is still billing:" -ForegroundColor DarkGray
    Write-Host "  aws ec2 describe-nat-gateways --region $Region --profile $AwsProfile --query \"NatGateways[?State!='deleted'].NatGatewayId\" --output text" -ForegroundColor DarkGray
    Write-Host "  aws ec2 describe-addresses --region $Region --profile $AwsProfile --query 'Addresses[].PublicIp' --output text" -ForegroundColor DarkGray
    return
}

# ---------------------------------------------------------------------------
Write-Host "Creating test network '$Name' in $Region (profile: $AwsProfile)" -ForegroundColor Cyan

$vpcId = (Invoke-Aws ec2 create-vpc --cidr-block $VpcCidr).Vpc.VpcId
Tag $vpcId "$Name-vpc"
# SSM resolves public endpoints by DNS, so both of these need to be on. Only
# enableDnsSupport is on by default for a non-default VPC.
Invoke-Aws ec2 modify-vpc-attribute --vpc-id $vpcId --enable-dns-support | Out-Null
Invoke-Aws ec2 modify-vpc-attribute --vpc-id $vpcId --enable-dns-hostnames | Out-Null
Write-Host "  VPC              $vpcId ($VpcCidr)"

$az = (Invoke-Aws ec2 describe-availability-zones).AvailabilityZones[0].ZoneName

$publicSubnetId = (Invoke-Aws ec2 create-subnet --vpc-id $vpcId --cidr-block $PublicSubnetCidr --availability-zone $az).Subnet.SubnetId
Tag $publicSubnetId "$Name-public"
Write-Host "  public subnet    $publicSubnetId ($PublicSubnetCidr, $az)"

$privateSubnetId = (Invoke-Aws ec2 create-subnet --vpc-id $vpcId --cidr-block $PrivateSubnetCidr --availability-zone $az).Subnet.SubnetId
Tag $privateSubnetId "$Name-private"
Write-Host "  private subnet   $privateSubnetId ($PrivateSubnetCidr, $az)"

$igwId = (Invoke-Aws ec2 create-internet-gateway).InternetGateway.InternetGatewayId
Tag $igwId "$Name-igw"
Invoke-Aws ec2 attach-internet-gateway --internet-gateway-id $igwId --vpc-id $vpcId | Out-Null
Write-Host "  internet gateway $igwId"

# Public route table: 0.0.0.0/0 -> IGW. This subnet exists only to host the
# NAT Gateway; the investigation host never goes here.
$publicRtId = (Invoke-Aws ec2 create-route-table --vpc-id $vpcId).RouteTable.RouteTableId
Tag $publicRtId "$Name-public-rt"
Invoke-Aws ec2 create-route --route-table-id $publicRtId --destination-cidr-block '0.0.0.0/0' --gateway-id $igwId | Out-Null
Invoke-Aws ec2 associate-route-table --route-table-id $publicRtId --subnet-id $publicSubnetId | Out-Null

$allocId = (Invoke-Aws ec2 allocate-address --domain vpc).AllocationId
Tag $allocId "$Name-nat-eip"

# The NAT Gateway goes in the PUBLIC subnet and serves the private one.
Write-Host "  NAT gateway      creating (takes a minute or two)..."
$natId = (Invoke-Aws ec2 create-nat-gateway --subnet-id $publicSubnetId --allocation-id $allocId).NatGateway.NatGatewayId
Tag $natId "$Name-nat"
& aws ec2 wait nat-gateway-available --nat-gateway-ids $natId --profile $AwsProfile --region $Region
if ($LASTEXITCODE -ne 0) { throw "NAT Gateway $natId did not become available." }
Write-Host "  NAT gateway      $natId (available)"

# Private route table: 0.0.0.0/0 -> NAT. This is the subnet the investigation
# host launches into.
$privateRtId = (Invoke-Aws ec2 create-route-table --vpc-id $vpcId).RouteTable.RouteTableId
Tag $privateRtId "$Name-private-rt"
Invoke-Aws ec2 create-route --route-table-id $privateRtId --destination-cidr-block '0.0.0.0/0' --nat-gateway-id $natId | Out-Null
Invoke-Aws ec2 associate-route-table --route-table-id $privateRtId --subnet-id $privateSubnetId | Out-Null

Write-Host ""
Write-Host "Done. Use these at [2] Create a new case:" -ForegroundColor Green
Write-Host "  VPC    : $vpcId"
Write-Host "  Subnet : $privateSubnetId   <- the PRIVATE one, marked 'egress OK' in the picker"
Write-Host ""
Write-Host "The NAT Gateway bills from now (~`$0.045/hr). Tear it all down with:" -ForegroundColor Yellow
Write-Host "  .\New-AwsTestNetwork.ps1 -Delete" -ForegroundColor Yellow
