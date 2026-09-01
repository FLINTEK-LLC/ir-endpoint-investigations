<#
.SYNOPSIS
    Builds a case-specific Velociraptor offline collector that uploads
    straight to that case's cloud storage, using a short-lived, write-only
    credential minted on the spot.

.DESCRIPTION
    Extends velociraptor/Build-Collector.ps1 rather than reimplementing it -
    same ConvertTo-NativeArg escaping, same Server.Utils.CreateCollector
    invocation, same base artifact list. The only things this script adds
    are: (1) reading the case's already-deployed Terraform state to find
    its bucket/container, (2) minting a short-lived credential scoped to
    exactly that case's storage, and (3) setting Server.Utils.CreateCollector's
    `target`/`target_args` so the built collector uploads there directly
    instead of producing a plain ZIP.

    Everything below is confirmed against Velociraptor's own source
    (artifacts/definitions/Server/Utils/CreateCollector.yaml on the
    Velocidex/velociraptor repo), not guessed:

      target=S3, target_args (camelCase, additionalProperties: false):
        bucket (required), credentialsKey, credentialsSecret,
        credentialsToken, region, endpoint, serverSideEncryption,
        kmsEncryptionKey, s3UploadRoot, noverifycert.
      credentialsToken is a real, supported field - this is what makes a
      genuine STS AssumeRole temporary credential (not a long-lived IAM
      user key) usable here.

      target=Azure, target_args:
        sas_url (required, and the ONLY field) - one full blob container
        SAS URL string with write ("w") + create ("c") permission baked in.

    Credential lifetime is deliberately short and single-purpose:
      - AWS: sts assume-role against this case's case-role, duration set
        by -DurationSeconds. The collector never sees the operator's own
        credentials, only this narrow, expiring, write-only session.
      - Azure: az storage container generate-sas against this case's
        container, using the operator's own (already-`az login`'d)
        identity to sign it - Azure has no direct equivalent of
        AssumeRole for blob SAS minting, so the expiry window IS the
        containment here. Keep -SasExpiryHours short for the same reason
        the AWS side keeps -DurationSeconds short.

    Requires the case's infrastructure to already exist (via Terraform, in
    its own workspace - see infra/README.md) before running this. This
    script only reads that state; it never runs terraform apply itself.

.PARAMETER CaseId
    Case identifier - must match the same terraform workspace name used
    when the case's infrastructure was created (see infra/README.md).

.PARAMETER CloudProvider
    AWS or Azure - which case's environment/workspace to read from.

.PARAMETER VeloExe
    Path to a plain (not already-repacked) Velociraptor binary.

.PARAMETER InfraRoot
    Path to the infra/ folder. Defaults to this script's own parent's
    parent (infra/scripts/.. = infra/).

.PARAMETER DurationSeconds
    AWS only - STS session lifetime for the minted upload credential.
    Keep this close to how long the collector will realistically take to
    run and upload; it starts expiring the moment this script mints it.

.PARAMETER SasExpiryHours
    Azure only - how long the generated SAS URL remains valid.

.PARAMETER AwsProfile
    AWS CLI profile to assume the case role with - see
    infra/README.md's "Accounts, tokens, and secrets" section.

.EXAMPLE
    .\New-CaseCollector.ps1 -CaseId acme-2026-001 -CloudProvider AWS -VeloExe C:\Tools\velociraptor.exe

.EXAMPLE
    .\New-CaseCollector.ps1 -CaseId acme-2026-001 -CloudProvider Azure -VeloExe C:\Tools\velociraptor.exe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$')]
    [string]$CaseId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('AWS', 'Azure')]
    [string]$CloudProvider,

    [Parameter(Mandatory = $true)]
    [string]$VeloExe,

    [string]$InfraRoot = '',

    [int]$DurationSeconds = 3600,
    [int]$SasExpiryHours = 4,
    [string]$AwsProfile = 'ir-cloud',

    # Same defaults as velociraptor/Build-Collector.ps1, pointed at that
    # folder so the already-fetched Windows.Triage.Targets.yaml and the
    # project's malware-drop-locations.csv are reused, not duplicated.
    [string]$DefinitionsFolder = '',

    [string[]]$Artifacts = @(
        'Windows.Triage.Targets',
        'Windows.Network.NetstatEnriched',
        'Windows.System.Pslist',
        'Windows.Sysinternals.Autoruns',
        'Windows.System.DNSCache',
        'Windows.System.Services',
        'Custom.Windows.Hash.RecentExecutables',
        'Generic.Collectors.File'
    ),

    [string[]]$HighLevelTargets = @('_SANS_Triage'),

    [string]$GlobsCsv = '',

    [string]$OutputZip,
    [string]$ServerConfig = ".\throwaway-server.config.yaml"
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is EMPTY inside a param-block default when a script has
# [CmdletBinding()] and is launched via `powershell -File` - confirmed
# directly by bisection: it works without CmdletBinding, and works in the
# script BODY either way, but an advanced script binds its parameters before
# $PSScriptRoot is populated. The TUI invokes these scripts with -File, so
# any path default derived from $PSScriptRoot must be resolved here, not in
# the param block.
if (-not $InfraRoot) { $InfraRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not $DefinitionsFolder) { $DefinitionsFolder = (Resolve-Path (Join-Path $InfraRoot '..\velociraptor')).Path }
if (-not $GlobsCsv) { $GlobsCsv = Join-Path $DefinitionsFolder 'malware-drop-locations.csv' }

if (-not $OutputZip) {
    $OutputZip = ".\$CaseId-collector.zip"
}

function ConvertTo-NativeArg {
    # Identical to velociraptor/Build-Collector.ps1's function of the same
    # name - see that script's header comment for the exact rule this
    # implements (Windows CommandLineToArgvW backslash/quote escaping).
    # Duplicated rather than dot-sourced so this script has no hard
    # dependency on the other one's file layout - copy the function, not
    # a require path, if it ever needs to move.
    param([string]$Value)
    $result = New-Object System.Text.StringBuilder
    $i = 0
    $n = $Value.Length
    while ($i -lt $n) {
        $j = $i
        $backslashCount = 0
        while ($j -lt $n -and $Value[$j] -eq '\') { $backslashCount++; $j++ }
        if ($j -eq $n) {
            [void]$result.Append([string]::new('\', $backslashCount))
            $i = $j
        } elseif ($Value[$j] -eq '"') {
            [void]$result.Append([string]::new('\', $backslashCount * 2 + 1))
            [void]$result.Append('"')
            $i = $j + 1
        } else {
            [void]$result.Append([string]::new('\', $backslashCount))
            [void]$result.Append($Value[$j])
            $i = $j + 1
        }
    }
    return $result.ToString()
}

function Get-TerraformExe {
    # Resolve terraform to a FULL PATH rather than relying on the bare name.
    # Test-Prerequisites.ps1 installs it to <ToolsRoot>\terraform\ which is not
    # necessarily on PATH, so `& terraform` used to die with
    # CommandNotFoundException even though the guard that checked for the file
    # had just passed - the check looked in the fallback location, the call did
    # not. Returns $null if it genuinely cannot be found.
    $cmd = Get-Command terraform -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in @(
            (Join-Path $env:SystemDrive 'Tools\terraform\terraform.exe'),
            'C:\Tools\terraform\terraform.exe')) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Get-CaseTerraformOutput {
    # Selects this case's Terraform workspace and returns its outputs as a
    # PSCustomObject. Requires the case to have already been created
    # (terraform workspace new <CaseId> && $tf apply) - this script
    # never provisions infrastructure itself.
    param(
        [string]$EnvDir,
        [string]$CaseId
    )
    $tf = Get-TerraformExe
    if (-not $tf) { throw "terraform not found on PATH or in C:\Tools\terraform - run infra\scripts\Test-Prerequisites.ps1 first." }
    Push-Location $EnvDir
    try {
        # Deliberately NOT redirecting stderr with 2>&1 here: PowerShell
        # wraps each native-command stderr line in a terminating
        # ErrorRecord when $ErrorActionPreference is 'Stop' (as it is for
        # this whole script), which would throw before $LASTEXITCODE is
        # ever checked below - confirmed directly, the first version of
        # this function did exactly that instead of surfacing the clear
        # message below. Letting stderr print straight to the console is
        # also more useful here: Terraform's own "workspace does not
        # exist" message is informative on its own.
        & $tf workspace select $CaseId | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "No case found with ID '$CaseId' in $EnvDir (terraform workspace select failed - see Terraform's own message above). Create the case's infrastructure first - see infra/README.md - before building its collector."
        }
        $json = & $tf output -json
        if ($LASTEXITCODE -ne 0) {
            throw "terraform output failed for case '$CaseId' in $EnvDir. Has 'terraform apply' completed successfully for this case?"
        }
        $raw = $json | ConvertFrom-Json
        $result = [ordered]@{}
        foreach ($prop in $raw.PSObject.Properties) {
            $result[$prop.Name] = $prop.Value.value
        }
        return [pscustomobject]$result
    } finally {
        Pop-Location
    }
}

# 1. Read this case's already-deployed storage details from Terraform state.
if ($CloudProvider -eq 'AWS') {
    $envDir = Join-Path $InfraRoot 'environments\aws-case'
    $tfOut = Get-CaseTerraformOutput -EnvDir $envDir -CaseId $CaseId
    $bucketName = $tfOut.bucket_name
    $region = $tfOut.region
    $roleArn = $tfOut.uploader_role_arn
    if (-not $bucketName -or -not $roleArn) {
        throw "Missing expected Terraform outputs (bucket_name/uploader_role_arn) for case '$CaseId'. Re-check 'terraform apply' completed for this case in $envDir."
    }
} else {
    $envDir = Join-Path $InfraRoot 'environments\azure-case'
    $tfOut = Get-CaseTerraformOutput -EnvDir $envDir -CaseId $CaseId
    $storageAccount = $tfOut.storage_account_name
    $containerName = $tfOut.container_name
    if (-not $storageAccount -or -not $containerName) {
        throw "Missing expected Terraform outputs (storage_account_name/container_name) for case '$CaseId'. Re-check 'terraform apply' completed for this case in $envDir."
    }
}

# 2. Mint a short-lived, write-only credential scoped to exactly this
#    case's storage. Nothing long-lived or broadly-scoped is ever baked
#    into the collector binary.
$targetArgsObj = $null

if ($CloudProvider -eq 'AWS') {
    Write-Host "Assuming $roleArn for $DurationSeconds seconds (profile: $AwsProfile)..."
    $sessionName = "collector-build-$CaseId-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    $stsJson = & aws sts assume-role `
        --role-arn $roleArn `
        --role-session-name $sessionName `
        --duration-seconds $DurationSeconds `
        --profile $AwsProfile `
        --output json
    if ($LASTEXITCODE -ne 0) {
        throw "aws sts assume-role failed - confirm 'aws configure --profile $AwsProfile' is set up and has sts:AssumeRole rights on $roleArn (see infra/README.md)."
    }
    $creds = ($stsJson | ConvertFrom-Json).Credentials

    $targetArgsObj = [ordered]@{
        bucket            = $bucketName
        region            = $region
        credentialsKey    = $creds.AccessKeyId
        credentialsSecret = $creds.SecretAccessKey
        credentialsToken  = $creds.SessionToken
    }
    Write-Host "Credential expires: $($creds.Expiration)"
} else {
    Write-Host "Generating a $SasExpiryHours-hour, write-only SAS URL for $storageAccount/$containerName..."
    $expiry = (Get-Date).ToUniversalTime().AddHours($SasExpiryHours).ToString('yyyy-MM-ddTHH:mmZ')
    # cw = create + write only. No read/list/delete - a collector carrying
    # this SAS can drop evidence in but can never read back, enumerate, or
    # remove anything in the container, mirroring the AWS side's
    # s3:PutObject-only role policy.
    $sasToken = & az storage container generate-sas `
        --account-name $storageAccount `
        --name $containerName `
        --permissions cw `
        --expiry $expiry `
        --https-only `
        --auth-mode login `
        --as-user `
        --output tsv
    if ($LASTEXITCODE -ne 0) {
        throw "az storage container generate-sas failed - confirm 'az login' is active and your account has the 'Storage Blob Data Contributor' role (needed to sign a --as-user SAS) on this case's storage account (see infra/README.md)."
    }
    $sasUrl = "https://$storageAccount.blob.core.windows.net/$containerName`?$sasToken"

    $targetArgsObj = [ordered]@{ sas_url = $sasUrl }
    Write-Host "SAS URL expires: $expiry UTC"
}

# 3. Everything from here mirrors velociraptor/Build-Collector.ps1 - see
#    that script's header comment for why each step exists.
$triageTargetsYaml = Join-Path $DefinitionsFolder 'Windows.Triage.Targets.yaml'
if (-not (Test-Path -LiteralPath $triageTargetsYaml)) {
    $tmpZip = Join-Path $env:TEMP 'Windows.Triage.Targets.zip'
    Invoke-WebRequest -Uri 'https://triage.velocidex.com/docs/windows.triage.targets/Windows.Triage.Targets.zip' -OutFile $tmpZip
    Expand-Archive -LiteralPath $tmpZip -DestinationPath $DefinitionsFolder -Force
    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $ServerConfig)) {
    & $VeloExe config generate | Out-File -Encoding utf8 $ServerConfig
}

$veloFullPath = (Resolve-Path -LiteralPath $VeloExe).Path
$inventoryQuery = 'SELECT inventory_add(tool="VelociraptorWindows", filename="velociraptor.exe", file="' + ($veloFullPath -replace '\\', '\\') + '", serve_locally=TRUE) FROM scope()'
& $VeloExe --config $ServerConfig -v query (ConvertTo-NativeArg -Value $inventoryQuery)

$globsContent = [string](Get-Content -Raw -LiteralPath $GlobsCsv)
$highLevelTargetsValue = ConvertTo-Json -InputObject $HighLevelTargets -Compress

$parametersObj = [ordered]@{
    'Windows.Triage.Targets'  = @{ HighLevelTargets = $highLevelTargetsValue }
    'Generic.Collectors.File' = @{ collectionSpec = $globsContent; Root = 'C:'; Accessor = 'auto' }
}

$artifactsJson   = ConvertTo-Json -InputObject $Artifacts -Compress
$parametersJson  = ConvertTo-Json -InputObject $parametersObj -Compress -Depth 10
$targetArgsJson  = ConvertTo-Json -InputObject $targetArgsObj -Compress

$artifactsArg    = ConvertTo-NativeArg -Value "artifacts=$artifactsJson"
$parametersArg   = ConvertTo-NativeArg -Value "parameters=$parametersJson"
$targetArgsArg   = ConvertTo-NativeArg -Value "target_args=$targetArgsJson"
$targetName      = if ($CloudProvider -eq 'AWS') { 'S3' } else { 'Azure' }

& $VeloExe --config $ServerConfig -v artifacts collect Server.Utils.CreateCollector `
    --args "OS=Windows" `
    --args $artifactsArg `
    --args $parametersArg `
    --args "target=$targetName" `
    --args $targetArgsArg `
    --args "opt_admin=Y" `
    --args "opt_prompt=N" `
    --definitions $DefinitionsFolder `
    --output $OutputZip

$destinationLabel = if ($CloudProvider -eq 'AWS') { $bucketName } else { "$storageAccount/$containerName" }

Write-Host ""
Write-Host "Built $OutputZip for case '$CaseId' - unzip it; the collector exe is under uploads\scope\."
Write-Host "This collector uploads straight to $destinationLabel using the credential minted above - it carries NO long-lived secret, and that credential's validity window has already started."
Write-Host "Verify Windows.Sysinternals.Autoruns actually produces data (not a 'tool not found' error) before trusting this collector."
