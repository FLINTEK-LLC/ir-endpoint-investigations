<#
.SYNOPSIS
    Creates (or deletes) the shared "tools" storage that investigation hosts
    pull licensed tooling - principally KAPE - from at first boot, and uploads
    a kape.zip into it.

.DESCRIPTION
    KAPE cannot be redistributed, so it is not in this repo and the bootstrap
    script cannot download it from anywhere public. Each organisation stages
    its own copy once, in its own cloud account, and every investigation host
    reads it from there using the identity it already has - no keys, no SAS
    tokens, nothing to expire.

    This storage is shared and long-lived, deliberately outside the per-case
    Terraform: a case is disposable and its storage is destroyed with it, but
    re-uploading a KAPE zip for every case would be absurd. Create this once
    per cloud account and reuse it forever.

    Access is read-only and scoped to this one bucket/account by the case's
    instance profile (AWS) or managed identity (Azure), so a compromised
    investigation host can read the tools it was going to run anyway and
    nothing else.

    Names are globally unique across all of AWS/Azure, so a random suffix is
    appended unless -Name is given explicitly. Storage account names are
    especially unforgiving: 3-24 characters, lowercase letters and digits
    only, no hyphens.

.PARAMETER KapeZipPath
    A local kape.zip to upload after creating the storage. Optional - the
    storage can be created now and filled later.

.PARAMETER Delete
    Delete the tools storage. On AWS this empties the bucket first; on Azure
    it deletes the whole resource group.

.EXAMPLE
    .\New-ToolsStorage.ps1 -CloudProvider Azure -KapeZipPath C:\Tools\kape.zip
    .\New-ToolsStorage.ps1 -CloudProvider AWS -Name ir-tools-acme
    .\New-ToolsStorage.ps1 -CloudProvider AWS -Name ir-tools-acme -Delete
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('AWS', 'Azure')]
    [string]$CloudProvider,

    [string]$Name,
    [string]$KapeZipPath,

    # AWS
    [string]$AwsProfile = 'ir-cloud',
    [string]$Region = 'us-east-1',

    # Azure
    [string]$ResourceGroup = 'rg-ir-tools',
    [string]$Location = 'eastus',
    [string]$ContainerName = 'irtools',

    [switch]$Delete
)

$ErrorActionPreference = 'Stop'

if ($KapeZipPath -and -not (Test-Path -LiteralPath $KapeZipPath)) {
    throw "KapeZipPath not found: $KapeZipPath"
}

function New-NameSuffix {
    # Six hex characters. Enough to clear a global namespace in practice,
    # short enough to keep an Azure storage account inside its 24-char limit.
    -join ((1..6) | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })
}

# ---------------------------------------------------------------------------
if ($CloudProvider -eq 'AWS') {
    if (-not (Get-Command aws -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "aws CLI not found - run infra\scripts\Test-Prerequisites.ps1 (elevated) first."
    }

    function Invoke-Aws {
        # NOT named "Aws": PowerShell resolves command names case-insensitively,
        # so a function called Aws shadows the CLI and `& aws` inside it recurses
        # until PowerShell aborts with "call depth overflow". That was real.
        param([Parameter(ValueFromRemainingArguments)][string[]]$CliArgs)
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $raw = & aws @CliArgs --profile $AwsProfile --region $Region 2>&1
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $prev }
        if ($code -ne 0) { throw "aws $($CliArgs -join ' ') failed: $(($raw | Out-String).Trim())" }
        return ($raw | Out-String).Trim()
    }

    if ($Delete) {
        if (-not $Name) { throw "-Name is required to delete an AWS tools bucket." }
        Write-Host "Emptying and deleting s3://$Name ..." -ForegroundColor Cyan
        # Tools buckets are not versioned, so the simple recursive remove that
        # does NOT work on a case evidence bucket is correct here.
        Invoke-Aws s3 rm "s3://$Name" --recursive | Out-Host
        Invoke-Aws s3 rb "s3://$Name" | Out-Null
        Write-Host "Deleted s3://$Name" -ForegroundColor Green
        return
    }

    if (-not $Name) { $Name = "ir-tools-$(New-NameSuffix)" }
    Write-Host "Creating tools bucket s3://$Name in $Region ..." -ForegroundColor Cyan
    Invoke-Aws s3 mb "s3://$Name" | Out-Null

    # Public access is blocked explicitly rather than relying on the account
    # default. Hosts read this through their instance profile, so nothing here
    # ever needs to be public, and a licensed tool sitting in a world-readable
    # bucket is a licence problem as well as a security one.
    Invoke-Aws s3api put-public-access-block --bucket $Name `
        --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' | Out-Null
    Write-Host "  public access blocked"

    if ($KapeZipPath) {
        Write-Host "  uploading $(Split-Path $KapeZipPath -Leaf) (this can take a minute)..."
        Invoke-Aws s3 cp $KapeZipPath "s3://$Name/kape.zip" | Out-Host
    }

    Write-Host ""
    Write-Host "Done. Use this at [2] Create a new case:" -ForegroundColor Green
    Write-Host "  Tools bucket : $Name"
    if (-not $KapeZipPath) {
        Write-Host ""
        Write-Host "No kape.zip uploaded yet. Hosts will boot without KAPE until you add one." -ForegroundColor Yellow
    }
    return
}

# ---------------------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found - run infra\scripts\Test-Prerequisites.ps1 (elevated) first."
}

function Invoke-Az {
    # Bare `az`, never `az.exe`: the Azure CLI ships as az.cmd on Windows and
    # there is no az.exe to find.
    param([Parameter(ValueFromRemainingArguments)][string[]]$CliArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & az @CliArgs 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { throw "az $($CliArgs -join ' ') failed: $(($raw | Out-String).Trim())" }
    $text = ($raw | Out-String).Trim()
    if (-not $text) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $text }
}

if ($Delete) {
    Write-Host "Deleting resource group $ResourceGroup and everything in it..." -ForegroundColor Cyan
    Invoke-Az group delete --name $ResourceGroup --yes | Out-Null
    Write-Host "Deleted $ResourceGroup." -ForegroundColor Green
    return
}

if (-not $Name) { $Name = "stirtools$(New-NameSuffix)" }
if ($Name -cnotmatch '^[a-z0-9]{3,24}$') {
    throw "Azure storage account name must be 3-24 lowercase letters/digits, no hyphens. Got: $Name"
}

Write-Host "Creating tools storage account $Name in $Location ..." -ForegroundColor Cyan
Invoke-Az group create --name $ResourceGroup --location $Location | Out-Null
Invoke-Az storage account create --name $Name --resource-group $ResourceGroup `
    --location $Location --sku Standard_LRS --min-tls-version TLS1_2 `
    --allow-blob-public-access false | Out-Null
Write-Host "  storage account  $Name"

# --auth-mode login uses the signed-in user's own RBAC rather than an account
# key. Account keys are the thing this whole design is trying not to have, and
# a key that exists is a key that can leak.
Invoke-Az storage container create --name $ContainerName --account-name $Name --auth-mode login | Out-Null
Write-Host "  container        $ContainerName"

if ($KapeZipPath) {
    Write-Host "  uploading $(Split-Path $KapeZipPath -Leaf) (this can take a minute)..."
    Invoke-Az storage blob upload --account-name $Name --container-name $ContainerName `
        --name kape.zip --file $KapeZipPath --auth-mode login --overwrite | Out-Null
}

$accountId = Invoke-Az storage account show --name $Name --resource-group $ResourceGroup --query id -o tsv

Write-Host ""
Write-Host "Done. Use these at [2] Create a new case:" -ForegroundColor Green
Write-Host "  Tools storage account ID : $accountId"
Write-Host "  Tools container          : $ContainerName"
if (-not $KapeZipPath) {
    Write-Host ""
    Write-Host "No kape.zip uploaded yet. Hosts will boot without KAPE until you add one." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "If the container create failed with an authorization error, you need the" -ForegroundColor DarkGray
Write-Host "'Storage Blob Data Contributor' role on the subscription - option [1] checks this." -ForegroundColor DarkGray
