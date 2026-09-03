<#
.SYNOPSIS
    Creates (or deletes) the Azure VNet and subnet an investigation host
    launches into.

.DESCRIPTION
    The per-case Terraform deliberately does NOT create networking. A case is
    disposable; a network is not. Partner organisations generally already have
    a VNet they want these hosts to live in, and having each case create and
    destroy its own would make that impossible - as well as making a failed
    destroy strand a VNet nobody recognises.

    So networking is a one-time prerequisite, and this script is it. Run once
    per Azure subscription, then reuse the subnet id it prints for every case.

    Unlike the AWS equivalent there is no NAT Gateway here, and that asymmetry
    is real rather than an oversight: an Azure VM with no public IP still gets
    outbound internet through the platform's default outbound access, so it
    reaches the bootstrap script and Azure Storage without one. The AWS host
    genuinely cannot - an Internet Gateway only carries traffic for instances
    that have a public address - which is why the AWS path pays for a NAT
    Gateway and this one does not.

    Default outbound access is on its way out for new Azure deployments, so if
    a host ever boots and never reaches the bootstrap script, an explicit NAT
    Gateway on this subnet is the first thing to add.

.PARAMETER Delete
    Delete the resource group and everything in it.

.EXAMPLE
    .\New-AzureTestNetwork.ps1
    .\New-AzureTestNetwork.ps1 -Delete
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-ir-network',
    [string]$Location = 'eastus',
    [string]$VnetName = 'vnet-ir',
    [string]$SubnetName = 'subnet-ir',
    [string]$VnetCidr = '10.20.0.0/16',
    [string]$SubnetCidr = '10.20.1.0/24',
    [switch]$Delete
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found - run infra\scripts\Test-Prerequisites.ps1 (elevated) first."
}

function Invoke-Az {
    # Bare `az`, never `az.exe`: the Azure CLI ships as az.cmd on Windows and
    # there is no az.exe to find. Every call funnels through here so a failure
    # is a real error rather than a silent empty result.
    param([Parameter(ValueFromRemainingArguments)][string[]]$CliArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & az @CliArgs 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) {
        throw "az $($CliArgs -join ' ') failed: $(($raw | Out-String).Trim())"
    }
    $text = ($raw | Out-String).Trim()
    if (-not $text) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $text }
}

if ($Delete) {
    Write-Host "Deleting resource group $ResourceGroup and everything in it..." -ForegroundColor Cyan
    Write-Host "Any case still using this subnet will lose its network." -ForegroundColor Yellow
    Invoke-Az group delete --name $ResourceGroup --yes | Out-Null
    Write-Host "Deleted $ResourceGroup." -ForegroundColor Green
    return
}

Write-Host "Creating network '$VnetName' in $Location..." -ForegroundColor Cyan

Invoke-Az group create --name $ResourceGroup --location $Location | Out-Null
Write-Host "  resource group   $ResourceGroup"

Invoke-Az network vnet create --resource-group $ResourceGroup --name $VnetName `
    --address-prefix $VnetCidr --subnet-name $SubnetName --subnet-prefix $SubnetCidr | Out-Null
Write-Host "  vnet             $VnetName ($VnetCidr)"
Write-Host "  subnet           $SubnetName ($SubnetCidr)"

# The subnet's full ARM resource id, which is what Terraform wants - not the
# short name. Fetched rather than string-built so it is right even if the
# subscription or naming ever changes.
$subnetId = Invoke-Az network vnet subnet show --resource-group $ResourceGroup `
    --vnet-name $VnetName --name $SubnetName --query id -o tsv

Write-Host ""
Write-Host "Done. Use this at [2] Create a new case:" -ForegroundColor Green
Write-Host "  Subnet ID : $subnetId"
Write-Host ""
Write-Host "A VNet and subnet cost nothing while idle - only the VMs in them bill." -ForegroundColor DarkGray
Write-Host "Tear it down with:  .\New-AzureTestNetwork.ps1 -Delete" -ForegroundColor DarkGray
