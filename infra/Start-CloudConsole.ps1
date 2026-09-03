<#
.SYNOPSIS
    Menu-driven front end for the cloud IR infrastructure in this folder -
    same thin-wrapper philosophy as ..\scripts\Start-IRConsole.ps1: prompts
    collect the same inputs you'd otherwise hand-type as Terraform
    -var flags or cloud CLI arguments, then this console runs the real
    tool (terraform, aws, az) itself. No logic here that isn't also
    reachable by hand from the command line - see infra/README.md.

.DESCRIPTION
    Case lifecycle, all through this menu:
      [1] First-time setup   - checks/installs Terraform + AWS/Azure CLI +
                                the SSM Session Manager plugin, and reports
                                whether `aws configure`/`az login` is done.
      [2] Create a new case  - prompts case ID, cloud, region/network,
                                per-case immutability choice, then runs
                                `terraform apply` in that case's own
                                Terraform *workspace* (see the note below).
      [3] Build the case's collector - hands off to New-CaseCollector.ps1.
      [4] Connect to the investigation host - hands off to
                                Connect-InvestigationHost.ps1.
      [5] Destroy the investigation host - `terraform destroy
                                -target=module.investigation_host` for that
                                case's workspace. Evidence storage is
                                untouched; offers to immediately respin a
                                clean host afterwards.
      [6] Archive this case  - forces an immediate cold-storage tier
                                transition (rather than waiting for the
                                normal archive_after_days lifecycle rule),
                                and optionally locks an Azure immutability
                                policy now that the case is closing.
      [7] List cases         - reads the local bookkeeping file for every
                                case this console has created.

    Why Terraform *workspaces*: environments\aws-case and
    environments\azure-case are shared root modules - the same folder is
    reused for every case, parameterized by -var case_id=... A second
    case's `terraform apply` in the SAME state would therefore destroy the
    first case's resources. `terraform workspace new/select <case_id>`
    gives each case its own state file (terraform.tfstate.d\<case_id>\...)
    within that same shared folder, so cases never collide. Every
    Terraform-calling action in this console goes through
    Invoke-CaseTerraform below, which always selects (or creates) the
    right workspace first - never call terraform directly in these folders
    without doing the same.

    Local bookkeeping only, never secrets: case records live in
    infra\.cases\<case_id>.json (gitignored) - case ID, cloud, the actual
    Terraform variables used (region/network/sizing/immutability choices,
    so a later destroy or respin can reuse them without re-prompting), and
    the resulting bucket/storage account name. No credential material is
    ever written here - see infra/README.md's "Accounts, tokens, and
    secrets" section for where those actually live (each cloud's own CLI
    credential store).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:InfraRoot = $PSScriptRoot
$script:ScriptsDir = Join-Path $InfraRoot 'scripts'
$script:CasesDir = Join-Path $InfraRoot '.cases'
# Shared prerequisite infrastructure (network, tools storage) that every case
# reuses. Deliberately NOT inside .cases\ - Get-AllCaseRecords globs *.json
# there, so a file living in that folder would be enumerated as a phantom case
# with a blank id.
$script:PrereqPath = Join-Path $InfraRoot '.prereqs.json'
$script:AwsEnvDir = Join-Path $InfraRoot 'environments\aws-case'
$script:AzureEnvDir = Join-Path $InfraRoot 'environments\azure-case'
# Shared, per-VNet Azure Bastion - deployed ONCE, not per case, and kept in
# its own state (default workspace). See that environment's main.tf for why
# it can't be per-case, and what it costs per hour.
$script:AzureBastionEnvDir = Join-Path $InfraRoot 'environments\azure-bastion'

# Prompt helpers live in one place for both consoles - see that file's header
# for why arrow-key selection falls back to a numbered list. Dot-sourced rather
# than duplicated: the two consoles' private copies had already drifted.
. (Join-Path (Split-Path -Parent $InfraRoot) 'scripts\IRPrompt.ps1')

# ---------------------------------------------------------------------------
# Same prompt-helper pattern as scripts\Start-IRConsole.ps1
# ---------------------------------------------------------------------------

# Regions offered in the picker. Not exhaustive - "Something else" covers the
# rest - just the ones people actually reach for, so the common path is a
# keypress rather than a spelling test.
$script:AzureRegions = @(
    'eastus', 'eastus2', 'centralus', 'westus2', 'westus3',
    'northeurope', 'westeurope', 'uksouth', 'canadacentral', 'australiaeast'
)
$script:AwsRegions = @(
    'us-east-1', 'us-east-2', 'us-west-2', 'eu-west-1', 'eu-west-2',
    'eu-central-1', 'ca-central-1', 'ap-southeast-2'
)

function Read-CaseId {
    param([string]$Prompt = "Case ID (lowercase letters/numbers/hyphens, 3-42 chars)")
    while ($true) {
        $val = Read-Host "$Prompt (blank to cancel)"
        if ([string]::IsNullOrWhiteSpace($val)) { return $null }
        if ($val -cmatch '^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$') { return $val }
        Write-Host "Must be 3-42 chars, lowercase letters/numbers/hyphens only, not starting or ending with a hyphen (same rule Terraform itself enforces on case_id)." -ForegroundColor Yellow
    }
}

function Read-CloudChoice {
    return Read-Choice -Prompt "Cloud provider:" -Items @('Azure', 'AWS') -Default 'Azure'
}

# ---------------------------------------------------------------------------
# Case bookkeeping (infra\.cases\<case_id>.json) - see header comment
# ---------------------------------------------------------------------------

function Get-CaseRecordPath {
    param([string]$CaseId)
    if (-not (Test-Path -LiteralPath $script:CasesDir)) {
        New-Item -ItemType Directory -Path $script:CasesDir -Force | Out-Null
    }
    return Join-Path $script:CasesDir "$CaseId.json"
}

function Save-CaseRecord {
    param([pscustomobject]$Record)
    $path = Get-CaseRecordPath -CaseId $Record.case_id
    $Record | ConvertTo-Json -Depth 10 | Out-File -Encoding utf8 -LiteralPath $path
}

function Get-CaseRecord {
    param([string]$CaseId)
    $path = Get-CaseRecordPath -CaseId $CaseId
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
}

function Get-AllCaseRecords {
    # Write-Output -NoEnumerate is load-bearing, not @(...) alone: with
    # exactly one case.json, a function's `return @(oneItem)` still gets
    # flattened back to a bare PSCustomObject by PowerShell's own output
    # pipeline - confirmed directly, @() only guarantees the VALUE is an
    # array, it does not survive being written to the pipeline as a single
    # item. -NoEnumerate forces the whole array through as one object
    # regardless of element count (confirmed directly for 0/1/many), which
    # callers' .Count checks (e.g. Show-CaseList's "no cases found"
    # branch) depend on.
    $items = @()
    if (Test-Path -LiteralPath $script:CasesDir) {
        $items = @(Get-ChildItem -LiteralPath $script:CasesDir -Filter '*.json' | ForEach-Object {
            Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json
        } | Where-Object { $_ -and $_.case_id })
    }
    Write-Output -NoEnumerate $items
}

function ConvertTo-Hashtable {
    # A case record loaded back from JSON has .vars as a PSCustomObject,
    # not a Hashtable - ConvertFrom-Json has no -AsHashtable option on
    # Windows PowerShell 5.1 (only PS7+), and a bare [hashtable] cast on a
    # PSCustomObject fails outright - confirmed directly. This is the
    # PS5.1-compatible replacement, used everywhere a saved record's .vars
    # needs to become terraform -var args again (destroy/respin/archive).
    param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [hashtable]) { return $InputObject }
        $result = @{}
        foreach ($prop in $InputObject.PSObject.Properties) { $result[$prop.Name] = $prop.Value }
        return $result
    }
}

# ---------------------------------------------------------------------------
# Terraform plumbing
# ---------------------------------------------------------------------------

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

function ConvertTo-TerraformVarArgs {
    # Builds -var=key=value CLI args from a plain hashtable. Booleans need
    # to be literal lowercase true/false on the CLI, not PowerShell's
    # $True/$False ToString() output.
    param([hashtable]$Vars)
    $result = @()
    foreach ($key in $Vars.Keys) {
        $val = $Vars[$key]
        if ($val -is [bool]) { $val = $(if ($val) { 'true' } else { 'false' }) }
        $result += "-var=$key=$val"
    }
    return $result
}

function Invoke-CaseTerraform {
    # Always selects-or-creates the case's own workspace before running any
    # terraform subcommand, in $EnvDir (aws-case or azure-case) - see the
    # header comment for why this is load-bearing, not optional.
    param(
        [string]$EnvDir,
        [string]$CaseId,
        [string[]]$TerraformArgs
    )
    $tf = Get-TerraformExe
    if (-not $tf) {
        Write-Host "terraform not found on PATH or in C:\Tools\terraform - run [1] First-time setup first." -ForegroundColor Red
        return $false
    }
    Push-Location $EnvDir
    try {
        Write-Host "terraform init..." -ForegroundColor DarkGray
        & $tf init -input=false | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Host "terraform init failed in $EnvDir." -ForegroundColor Red; return $false }

        # NOT redirecting stderr with 2>&1 here - see New-CaseCollector.ps1's
        # Get-CaseTerraformOutput for why that turns a normal "workspace
        # does not exist" message into an uncatchable terminating error.
        & $tf workspace select $CaseId | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Creating new terraform workspace '$CaseId'..." -ForegroundColor DarkGray
            & $tf workspace new $CaseId | Out-Host
            if ($LASTEXITCODE -ne 0) { Write-Host "Could not select or create workspace '$CaseId'." -ForegroundColor Red; return $false }
        }

        # | Out-Host is load-bearing, not cosmetic. Without it, terraform's
        # stdout becomes part of THIS FUNCTION'S return value: callers doing
        # `$ok = Invoke-CaseTerraform ...` get an Object[] of output lines
        # with the boolean appended, and `if (-not $ok)` is then always
        # false because a populated array is truthy - so a FAILED apply or
        # destroy was reported as success (confirmed directly). Out-Host
        # writes straight to the console instead, which also means the
        # operator actually sees apply/destroy progress rather than having
        # it silently swallowed into a variable.
        & $tf @TerraformArgs | Out-Host
        return ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
}

function Get-CaseTerraformOutputs {
    param([string]$EnvDir, [string]$CaseId)
    $tf = Get-TerraformExe
    if (-not $tf) { return $null }
    Push-Location $EnvDir
    try {
        & $tf workspace select $CaseId | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        $json = & $tf output -json
        if ($LASTEXITCODE -ne 0) { return $null }
        $raw = $json | ConvertFrom-Json
        $result = [ordered]@{}
        foreach ($prop in $raw.PSObject.Properties) { $result[$prop.Name] = $prop.Value.value }
        return [pscustomobject]$result
    } finally {
        Pop-Location
    }
}

function Invoke-BastionTerraform {
    # The shared Bastion is NOT per-case, so unlike Invoke-CaseTerraform this
    # deliberately stays in the default workspace - there is one Bastion per
    # VNet, not one per case.
    param([string[]]$TerraformArgs)
    $tf = Get-TerraformExe
    if (-not $tf) { Write-Host "terraform not found - run [1] First-time setup first." -ForegroundColor Red; return $false }
    Push-Location $script:AzureBastionEnvDir
    try {
        Write-Host "terraform init..." -ForegroundColor DarkGray
        & $tf init -input=false | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Host "terraform init failed in $script:AzureBastionEnvDir." -ForegroundColor Red; return $false }
        & $tf @TerraformArgs | Out-Host
        return ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
}

function Get-SharedBastionOutputs {
    # Reads the shared Bastion's outputs so [2] can pre-fill the case prompts
    # instead of making the operator copy/paste names by hand. Returns $null
    # if the Bastion hasn't been deployed yet.
    if (-not (Test-Path -LiteralPath (Join-Path $script:AzureBastionEnvDir '.terraform'))) { return $null }
    $tf = Get-TerraformExe
    if (-not $tf) { return $null }
    Push-Location $script:AzureBastionEnvDir
    try {
        $json = & $tf output -json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
        $raw = $json | ConvertFrom-Json
        if (-not $raw.bastion_name) { return $null }
        return [pscustomobject]@{
            Name          = $raw.bastion_name.value
            ResourceGroup = $raw.bastion_resource_group_name.value
        }
    } catch {
        return $null
    } finally {
        Pop-Location
    }
}

function Invoke-DeploySharedBastion {
    Write-Host "Deploys ONE Azure Bastion (Standard SKU) for a virtual network. Every case whose host lives in that VNet connects through it." -ForegroundColor Cyan
    Write-Host "Azure allows only one Bastion per VNet, so this is deliberately not per-case." -ForegroundColor Cyan
    Write-Host ""
    # Single-quoted: a literal '$' in a double-quoted PowerShell string needs
    # a backtick escape, and "\$0.29" (backslash, as in most other languages)
    # renders as "\.29" - the backslash stays and $0 expands to nothing.
    Write-Host 'COST: Standard Bastion bills hourly whether or not anyone is connected - about $0.29/hr in eastus' -ForegroundColor Yellow
    Write-Host '      (~$7/day, ~$212/month if left running). Destroy it with [9] when the engagement is over.' -ForegroundColor Yellow
    Write-Host "      The free Developer SKU is cheaper but cannot do native RDP - see infra/README.md." -ForegroundColor Yellow
    Write-Host ""

    $vnetId = Read-Required -Prompt "Virtual network resource ID the Bastion should serve"
    if (-not $vnetId) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
    $location = Read-Default -Prompt "Azure region (should match the VNet's)" -Default 'eastus'
    Write-Host "Bastion needs its own dedicated subnet named AzureBastionSubnet, /26 or larger, in free space inside that VNet." -ForegroundColor Cyan
    $prefix = Read-Required -Prompt "CIDR for that subnet (e.g. 10.20.2.0/26)"
    if (-not $prefix) { Write-Host "Cancelled." -ForegroundColor Yellow; return }

    if (-not (Read-YesNo -Prompt "Deploy it now (takes ~10 minutes)?" -Default $false)) {
        Write-Host "Cancelled." -ForegroundColor Yellow; return
    }

    # Persist the inputs as terraform.tfvars rather than passing -var flags.
    # virtual_network_id and bastion_subnet_prefix are REQUIRED variables with
    # no defaults, so a later `terraform destroy` (option [9], or by hand)
    # would otherwise sit there prompting for them. Terraform auto-loads
    # terraform.tfvars, so every subsequent command in this directory just
    # works. Gitignored - it's local environment detail, not shared config.
    $tfvarsPath = Join-Path $script:AzureBastionEnvDir 'terraform.tfvars'
    @(
        "# Written by Start-CloudConsole.ps1 option [8]. Local only - gitignored."
        "virtual_network_id    = `"$vnetId`""
        "bastion_subnet_prefix = `"$prefix`""
        "location              = `"$location`""
    ) | Out-File -LiteralPath $tfvarsPath -Encoding utf8

    $ok = Invoke-BastionTerraform -TerraformArgs @('apply', '-auto-approve')
    if ($ok) {
        $b = Get-SharedBastionOutputs
        Write-Host ""
        Write-Host "Shared Bastion deployed: $($b.Name) (resource group $($b.ResourceGroup))" -ForegroundColor Green
        Write-Host "[2] will offer these automatically when you create an Azure case." -ForegroundColor Green
        Write-Host "Remember [9] to tear it down when you're done - it bills hourly." -ForegroundColor Yellow
    } else {
        Write-Host "Bastion deployment failed - see output above." -ForegroundColor Red
    }
}

function Invoke-DestroySharedBastion {
    $b = Get-SharedBastionOutputs
    if (-not $b) {
        Write-Host "No shared Bastion found in $script:AzureBastionEnvDir - nothing to destroy." -ForegroundColor Yellow
        return
    }
    Write-Host "This destroys the shared Bastion '$($b.Name)' and its AzureBastionSubnet + public IP." -ForegroundColor Cyan
    Write-Host "Any Azure case still using it will lose its [4] Connect path until you redeploy with [8]." -ForegroundColor Yellow
    Write-Host "Evidence storage and investigation hosts are NOT touched." -ForegroundColor Cyan
    if (-not (Read-YesNo -Prompt "Continue?" -Default $false)) { Write-Host "Cancelled." -ForegroundColor Yellow; return }

    # The required variables come from the terraform.tfvars that [8] wrote,
    # which Terraform auto-loads - no -var flags and no interactive prompt.
    $ok = Invoke-BastionTerraform -TerraformArgs @('destroy', '-auto-approve')
    if ($ok) {
        Write-Host "Shared Bastion destroyed - hourly billing for it has stopped." -ForegroundColor Green
        Write-Host "Redeploy any time with [8]; your cases' evidence and hosts were not touched." -ForegroundColor DarkGray
    } else {
        Write-Host "terraform destroy failed - see output above. If it reports missing variables, terraform.tfvars in $script:AzureBastionEnvDir is missing or incomplete; recreate it (or re-run [8]) and retry." -ForegroundColor Red
    }
}

function Invoke-ScriptFile {
    # Runs one of the sibling scripts\*.ps1 as its own process, same
    # separate-process pattern Start-IRConsole.ps1 uses - that script's own
    # `exit`/throw only ends that process, never this console.
    param([string]$Name, [string[]]$ScriptArgs = @())
    $target = Join-Path $script:ScriptsDir $Name
    Write-Host ""
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File $target @ScriptArgs
    Write-Host ""
    Write-Host "(exit code $LASTEXITCODE)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Menu actions
# ---------------------------------------------------------------------------

function Invoke-FirstTimeSetup {
    Invoke-ScriptFile 'Test-Prerequisites.ps1'
}

function Test-BootstrapScriptReachable {
    # The investigation host does not receive its bootstrap from this machine -
    # it downloads it from the PUBLIC repo at first boot. So any local change
    # you have not pushed simply does not exist as far as the VM is concerned,
    # and an unpushed infra/ folder means the Custom Script Extension 404s
    # about fifteen minutes into a deploy, after you have already paid for the
    # VM. A single HEAD request up front turns that into an instant, obvious
    # message.
    param(
        [string]$RepoGitUrl = 'https://github.com/FLINTEK-LLC/ir-endpoint-investigations.git',
        [string]$Branch = 'main'
    )
    $base = ($RepoGitUrl -replace '\.git$', '') -replace 'github\.com', 'raw.githubusercontent.com'
    $url = "$base/$Branch/infra/scripts/fetch-and-bootstrap.ps1"
    $result = @{ Url = $url; Reachable = $false; Checked = $false; StatusCode = 0 }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 15
        $result.Checked = $true
        $result.StatusCode = [int]$resp.StatusCode
        $result.Reachable = ($result.StatusCode -eq 200)
    } catch {
        $result.Checked = $true
        if ($_.Exception.Response) { $result.StatusCode = [int]$_.Exception.Response.StatusCode }
    }
    return $result
}

function Format-AzureVmSize {
    # Accept "B4s_v2" as well as "Standard_B4s_v2". Azure's portal and docs
    # routinely show the size without its tier prefix, so typing the short form
    # is a natural mistake - and the API rejects it with a 900-line list of
    # valid names rather than saying "you left off Standard_".
    param([string]$Size)
    $s = "$Size".Trim()
    if ($s -and $s -notmatch '^(Standard|Basic)_') { return "Standard_$s" }
    return $s
}

function Invoke-AwsJson {
    # Small wrapper so an aws CLI failure never throws out of a preflight -
    # a diagnostic that cannot run must not block a deploy.
    param([string[]]$CliArgs, [string]$AwsProfile)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & aws @CliArgs --profile $AwsProfile --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null } finally { $ErrorActionPreference = $prev }
}

function Test-AwsAmiParameter {
    # The Windows AMI comes from an AWS-managed SSM public parameter. If that
    # name does not exist in the region the apply dies on a data source, which
    # is a slow and cryptic way to learn you asked for an image AWS does not
    # publish there. Windows Server 2025 in particular could not be confirmed
    # from documentation, so check it rather than hope.
    param([string]$Region, [string]$AwsProfile, [string]$ParameterName)
    $r = Invoke-AwsJson -AwsProfile $AwsProfile -CliArgs @('ssm', 'get-parameters', '--names', $ParameterName, '--region', $Region)
    if (-not $r) { return @{ Checked = $false; Ok = $true } }
    # Filtered, like every other cloud-API enumeration in this project: a
    # response that omits the key entirely yields $null, and @($null) is a
    # ONE-element array, which would report a nonexistent AMI parameter as
    # found and then index [0] into nothing.
    $found = @($r.Parameters | Where-Object { $_ }).Count -gt 0
    return @{ Checked = $true; Ok = $found; Value = $(if ($found) { $r.Parameters[0].Value } else { $null }) }
}

function Test-AwsSubnetEgress {
    # THE AWS failure mode. This host gets no public IP by design, so its
    # subnet needs its own route to the internet - a NAT Gateway, or a
    # transit/NVA route. A subnet whose route table only has the local CIDR
    # will happily launch an instance that can never reach SSM, GitHub or S3,
    # and the symptom is a host that boots and then simply never becomes
    # manageable. Cheaper to detect here.
    param([string]$SubnetId, [string]$Region, [string]$AwsProfile)

    $rt = Invoke-AwsJson -AwsProfile $AwsProfile -CliArgs @(
        'ec2', 'describe-route-tables', '--region', $Region,
        '--filters', "Name=association.subnet-id,Values=$SubnetId")
    if (-not $rt) { return @{ Checked = $false; HasEgress = $true; Via = 'unknown' } }

    # A subnet with no explicit association uses the VPC main route table.
    if (@($rt.RouteTables | Where-Object { $_ }).Count -eq 0) {
        $sn = Invoke-AwsJson -AwsProfile $AwsProfile -CliArgs @('ec2', 'describe-subnets', '--region', $Region, '--subnet-ids', $SubnetId)
        if (-not $sn) { return @{ Checked = $false; HasEgress = $true; Via = 'unknown' } }
        $vpcId = $sn.Subnets[0].VpcId
        $rt = Invoke-AwsJson -AwsProfile $AwsProfile -CliArgs @(
            'ec2', 'describe-route-tables', '--region', $Region,
            '--filters', "Name=vpc-id,Values=$vpcId", 'Name=association.main,Values=true')
        if (-not $rt) { return @{ Checked = $false; HasEgress = $true; Via = 'unknown' } }
    }

    foreach ($table in $rt.RouteTables) {
        foreach ($route in $table.Routes) {
            if ($route.DestinationCidrBlock -ne '0.0.0.0/0') { continue }
            if ($route.NatGatewayId) { return @{ Checked = $true; HasEgress = $true; Via = "NAT Gateway $($route.NatGatewayId)" } }
            if ($route.TransitGatewayId) { return @{ Checked = $true; HasEgress = $true; Via = "Transit Gateway $($route.TransitGatewayId)" } }
            if ($route.NetworkInterfaceId -or $route.InstanceId) { return @{ Checked = $true; HasEgress = $true; Via = 'an appliance/NVA route' } }
            if ($route.GatewayId -and $route.GatewayId -like 'igw-*') {
                # An IGW route only helps an instance that HAS a public IP.
                # This one deliberately does not, so this is a public subnet
                # and the host will still have no path out.
                return @{ Checked = $true; HasEgress = $false; Via = "an Internet Gateway ($($route.GatewayId)) - which does NOT work for a host with no public IP" }
            }
        }
    }
    return @{ Checked = $true; HasEgress = $false; Via = 'no 0.0.0.0/0 route at all' }
}

function Test-VmSizeAvailable {
    # Azure will happily plan a VM size your subscription cannot actually get,
    # then fail two minutes into apply with
    # "SkuNotAvailable ... Capacity Restrictions". That is a slow, confusing way
    # to learn something the API can answer instantly, so check before applying.
    #
    # Returns a hashtable: Checked (did the lookup work at all), Available,
    # Reason, Alternatives. A failed lookup is NOT treated as unavailable -
    # never block a deploy because a diagnostic call failed.
    param([string]$Location, [string]$Size)

    $result = @{ Checked = $false; Available = $true; Reason = ''; Alternatives = @() }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return $result }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # --output json and parse here rather than --query: a JMESPath filter
        # with parens/braces and no spaces reaches cmd.exe unquoted through
        # az.cmd and breaks. See infra/TESTING.md's Windows quoting note.
        $raw = & az vm list-skus --location $Location --resource-type virtualMachines --size $Size --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $result }
        $skus = $raw | ConvertFrom-Json
    } catch {
        return $result
    } finally {
        $ErrorActionPreference = $prevEap
    }

    $exact = $skus | Where-Object { $_.name -eq $Size } | Select-Object -First 1
    if (-not $exact) {
        $result.Checked = $true
        $result.Available = $false
        $result.Reason = "size '$Size' does not exist in $Location"
    } else {
        $result.Checked = $true
        $restrictions = @($exact.restrictions | Where-Object { $_ })
        if ($restrictions.Count -gt 0) {
            $result.Available = $false
            $result.Reason = "your subscription is capacity-restricted for '$Size' in $Location"
        }
    }
    return $result
}

function Get-AvailableVmSizes {
    # Suggest sizes this subscription can ACTUALLY deploy in this region,
    # with their specs, so the operator can choose knowingly.
    #
    # The first version of this only looked at "Standard_B" and returned an
    # empty list on subscriptions where no B-series is offered at all - which
    # is exactly when the operator most needs a suggestion. Availability varies
    # by subscription, region and quota, so filter on capabilities (vCPU/RAM)
    # rather than assuming any particular family exists.
    param([string]$Location, [int]$MinVCpu = 2, [int]$MaxVCpu = 8, [int]$MinMemoryGb = 8)

    # `az vm list-skus` for one region takes five to fifteen seconds and returns
    # several megabytes. Case creation is retried often enough - a bad subnet, a
    # quota error, a typo - that paying that on every attempt is the single
    # most noticeable delay in the console. The answer cannot change while the
    # console is open in any way that matters, so cache it per region for the
    # life of the process. Restarting the console re-queries.
    if (-not $script:VmSizeCache) { $script:VmSizeCache = @{} }
    if ($script:VmSizeCache.ContainsKey($Location)) {
        return $script:VmSizeCache[$Location]
    }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & az vm list-skus --location $Location --resource-type virtualMachines --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
        $skus = $raw | ConvertFrom-Json
    } catch {
        return @()
    } finally {
        $ErrorActionPreference = $prevEap
    }

    $candidates = foreach ($sku in $skus) {
        # Both filtered. Unfiltered, a SKU whose restrictions property is
        # absent rather than empty counts as 1 and gets skipped - which
        # would silently drop EVERY size and leave the picker empty, the
        # failure that previously sent Azure a hand-typed size.
        if (@($sku.restrictions | Where-Object { $_ }).Count -gt 0) { continue }
        $caps = @{}
        foreach ($c in @($sku.capabilities | Where-Object { $_ })) { $caps[$c.name] = $c.value }
        $vcpu = 0; $mem = 0.0
        [void][int]::TryParse($caps['vCPUs'], [ref]$vcpu)
        [void][double]::TryParse($caps['MemoryGB'], [ref]$mem)
        if ($vcpu -lt $MinVCpu -or $vcpu -gt $MaxVCpu -or $mem -lt $MinMemoryGb) { continue }
        # Confidential/GPU/HPC families are wrong for this workload and often
        # carry extra prerequisites - keep the suggestions boring.
        if ($sku.name -match '^Standard_(N|H|M|DC|EC)') { continue }
        [pscustomobject]@{
            Name    = $sku.name
            VCpu    = $vcpu
            MemoryGb = $mem
            # "d" before the trailing "s" means a local temp disk, which lands
            # on D: and collides with the evidence mount. Deprioritise those.
            HasTempDisk = [bool]($caps['MaxResourceVolumeMB'] -and [int]$caps['MaxResourceVolumeMB'] -gt 0)
        }
    }

    # Cached only on a successful lookup - the early `return @()` paths above
    # deliberately bypass this, so a transient az failure is retried next time
    # rather than remembered as "no sizes available in this region".
    $result = @($candidates |
            Sort-Object HasTempDisk, VCpu, Name |
            Select-Object -First 10)
    $script:VmSizeCache[$Location] = $result
    return $result
}

function Invoke-CreateCase {
    $caseId = Read-CaseId
    if (-not $caseId) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
    if (Get-CaseRecord -CaseId $caseId) {
        Write-Host "A case record for '$caseId' already exists (infra\.cases\$caseId.json). Use a different case ID, or delete that file first if this was abandoned." -ForegroundColor Yellow
        return
    }

    $cloud = Read-CloudChoice
    $vars = [ordered]@{ case_id = $caseId }

    Write-Host ""
    Write-Host "Immutability (WORM) locks evidence against modification/deletion for a retention period - decide per case; there is no safe default that fits every case." -ForegroundColor Cyan
    $enableImmutability = Read-YesNo -Prompt "Enable immutability for this case?" -Default $false
    $vars['enable_immutability'] = $enableImmutability
    if ($enableImmutability) {
        $vars['retention_days'] = [int](Read-Default -Prompt "Retention period (days)" -Default '90')
        Write-Host "GOVERNANCE = recoverable if you lock yourself out. COMPLIANCE = irreversible once the grace period elapses. See infra/SECURITY.md before choosing COMPLIANCE." -ForegroundColor Cyan
        $vars['retention_mode'] = Read-Choice -Prompt "Retention mode:" -Default 'GOVERNANCE' -Items @(
            [pscustomobject]@{ Label = 'GOVERNANCE - recoverable; an authorised principal can still lift it'; Value = 'GOVERNANCE' }
            [pscustomobject]@{ Label = 'COMPLIANCE - IRREVERSIBLE until retention expires; nobody can lift it'; Value = 'COMPLIANCE' }
        ) -DisplayProperty Label -ValueProperty Value
    }
    $vars['archive_after_days'] = [int](Read-Default -Prompt "Days before automatic transition to cold storage" -Default '30')

    if ($cloud -eq 'AWS') {
        $envDir = $script:AwsEnvDir
        # Defaults come from whatever [8]/[9] recorded, so the common path is
        # "press Enter four times" rather than re-entering ids that were
        # printed to the screen twenty minutes ago. $prereq is empty on a
        # first run, and every lookup below falls back to the same literal
        # that used to be hardcoded here.
        $prereq = Get-Prereqs -Cloud 'AWS'
        $vars['region'] = Read-Choice -Prompt "AWS region:" -Items $script:AwsRegions -Default $(if ($prereq['region']) { $prereq['region'] } else { 'us-east-1' }) -AllowCustom -CustomPrompt 'AWS region'
        $vars['aws_profile'] = Read-Default -Prompt "AWS CLI profile" -Default $(if ($prereq['aws_profile']) { $prereq['aws_profile'] } else { 'ir-cloud' })
        Write-Host "The subnet below needs its own outbound internet route (a NAT Gateway) - the investigation host has no public IP by design. Most existing/default VPCs already have this; see infra/README.md if you need to add one." -ForegroundColor Cyan
        # List real VPCs/subnets rather than asking for pasted IDs, and mark
        # which subnets actually have egress - the host has no public IP, so a
        # subnet without a NAT route produces an instance that boots and then
        # never becomes reachable.
        Write-Host ""
        Write-Host "Looking up VPCs in $($vars['region'])..." -ForegroundColor DarkGray
        $vpcData = Invoke-AwsJson -AwsProfile $vars['aws_profile'] -CliArgs @('ec2', 'describe-vpcs', '--region', $vars['region'])
        if ($vpcData -and @($vpcData.Vpcs | Where-Object { $_ }).Count -gt 0) {
            $vpcItems = $vpcData.Vpcs | ForEach-Object {
                $nameTag = ($_.Tags | Where-Object { $_.Key -eq 'Name' } | Select-Object -First 1).Value
                [pscustomobject]@{
                    Label = ('{0,-24} {1,-18} {2}' -f $_.VpcId, $_.CidrBlock, $(if ($_.IsDefault) { '(default VPC)' } else { $nameTag }))
                    Value = $_.VpcId
                }
            }
            $vars['vpc_id'] = Read-Choice -Prompt "VPC:" -Items $vpcItems -DisplayProperty Label -ValueProperty Value -AllowCustom -CustomPrompt 'VPC ID'
        } else {
            Write-Host "Could not list VPCs (is the AWS profile configured?) - enter the ID by hand." -ForegroundColor Yellow
            $vpcId = Read-Required -Prompt "VPC ID"
            if (-not $vpcId) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
            $vars['vpc_id'] = $vpcId
        }

        Write-Host "Looking up subnets and checking which have internet egress..." -ForegroundColor DarkGray
        $subnetData = Invoke-AwsJson -AwsProfile $vars['aws_profile'] -CliArgs @(
            'ec2', 'describe-subnets', '--region', $vars['region'],
            '--filters', "Name=vpc-id,Values=$($vars['vpc_id'])")
        if ($subnetData -and @($subnetData.Subnets | Where-Object { $_ }).Count -gt 0) {
            $subnetItems = $subnetData.Subnets | ForEach-Object {
                $e = Test-AwsSubnetEgress -SubnetId $_.SubnetId -Region $vars['region'] -AwsProfile $vars['aws_profile']
                $mark = if (-not $e.Checked) { '?' } elseif ($e.HasEgress) { 'egress OK' } else { 'NO EGRESS' }
                [pscustomobject]@{
                    Label = ('{0,-26} {1,-18} {2,-16} {3}' -f $_.SubnetId, $_.CidrBlock, $_.AvailabilityZone, $mark)
                    Value = $_.SubnetId
                }
            }
            $vars['subnet_id'] = Read-Choice -Prompt "Subnet for the investigation host:" -Items $subnetItems -DisplayProperty Label -ValueProperty Value -Default $prereq['subnet_id'] -AllowCustom -CustomPrompt 'Subnet ID'
        } else {
            $subnetId = Read-Default -Prompt "Subnet ID (must have NAT/internet egress)" -Default $prereq['subnet_id']
            if (-not $subnetId) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
            $vars['subnet_id'] = $subnetId
        }

        $vars['instance_type'] = Read-Choice -Prompt "Instance type:" -Default 't3.xlarge' -AllowCustom -CustomPrompt 'Instance type' -Items @(
            [pscustomobject]@{ Label = 't3.xlarge     4 vCPU, 16 GiB  burstable - the default'; Value = 't3.xlarge' }
            [pscustomobject]@{ Label = 't3.large      2 vCPU,  8 GiB  burstable - cheaper plumbing test'; Value = 't3.large' }
            [pscustomobject]@{ Label = 'm5.xlarge     4 vCPU, 16 GiB  fixed performance'; Value = 'm5.xlarge' }
            [pscustomobject]@{ Label = 'm5.2xlarge    8 vCPU, 32 GiB  large collections'; Value = 'm5.2xlarge' }
        ) -DisplayProperty Label -ValueProperty Value

        Write-Host ""
        Write-Host "OPTIONAL: an S3 bucket holding your licensed KAPE (kape.zip). Without it the" -ForegroundColor Cyan
        Write-Host "host comes up with no KAPE and no parsing toolchain. Must NOT be this case's" -ForegroundColor Cyan
        Write-Host "evidence bucket - see infra/README.md's \"Getting KAPE onto the host\"." -ForegroundColor Cyan
        if ($prereq['tools_bucket_name']) {
            Write-Host "Using the bucket recorded by [9] Tools storage - press Enter to accept." -ForegroundColor DarkGray
        }
        $toolsBucket = Read-Default -Prompt "Tools S3 bucket name (blank = skip)" -Default $prereq['tools_bucket_name']
        if ($toolsBucket) { $vars['tools_bucket_name'] = $toolsBucket }
    } else {
        $envDir = $script:AzureEnvDir
        # As on the AWS branch: defaults come from what [8]/[9] recorded.
        $prereq = Get-Prereqs -Cloud 'Azure'
        $vars['location'] = Read-Choice -Prompt "Azure region:" -Items $script:AzureRegions -Default $(if ($prereq['location']) { $prereq['location'] } else { 'eastus' }) -AllowCustom -CustomPrompt 'Azure region'
        Write-Host "The subnet below needs its own outbound internet route - the investigation host has no public IP by design. Most existing VNets already have this." -ForegroundColor Cyan
        Write-Host "Do NOT use the AzureBastionSubnet here - that subnet is reserved for Bastion and cannot hold other resources." -ForegroundColor Cyan
        if ($prereq['subnet_id']) {
            Write-Host "Using the subnet recorded by [8] Case networking - press Enter to accept." -ForegroundColor DarkGray
        } else {
            Write-Host "No subnet recorded yet - [8] Case networking creates one and remembers it." -ForegroundColor DarkGray
        }
        $subnetId = Read-Default -Prompt "Subnet resource ID for the investigation host" -Default $prereq['subnet_id']
        if (-not $subnetId) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
        $vars['subnet_id'] = $subnetId

        Write-Host ""
        $vars['access_method'] = Read-Choice -Prompt "How should this case's host be reached?" -Default 'rdp-allowlist' -Items @(
            [pscustomobject]@{ Label = 'RDP allowlist - public IP behind a deny-all NSG, opened just-in-time to your own IP. ~$0.005/hr, and that IP also gives the host its outbound internet.'; Value = 'rdp-allowlist' }
            [pscustomobject]@{ Label = 'Bastion - no public IP at all; connect via the shared Standard Bastion ([8]). Strongest posture, ~$0.29/hr, and you must supply your own egress (NAT Gateway).'; Value = 'bastion' }
        ) -DisplayProperty Label -ValueProperty Value
        $accessChoice = $vars['access_method']

        # Bastion is shared per-VNet, deployed by [8]. Pre-fill from its state
        # when it exists so this is a confirm-and-continue rather than a
        # copy/paste-two-resource-names step. Only needed for the bastion path.
        $sharedBastion = if ($accessChoice -eq 'bastion') { Get-SharedBastionOutputs } else { $null }
        if ($accessChoice -ne 'bastion') {
            # no Bastion inputs required
        } elseif ($sharedBastion) {
            Write-Host "Found shared Bastion '$($sharedBastion.Name)' in resource group '$($sharedBastion.ResourceGroup)'." -ForegroundColor Green
            $vars['bastion_name'] = Read-Default -Prompt "Bastion name" -Default $sharedBastion.Name
            $vars['bastion_resource_group_name'] = Read-Default -Prompt "Bastion resource group" -Default $sharedBastion.ResourceGroup
        } else {
            Write-Host "No shared Bastion has been deployed from this machine yet - option [8] creates one (and it's what makes [4] Connect give you a real mstsc session)." -ForegroundColor Yellow
            Write-Host "If one already exists in your subscription, enter its details; otherwise cancel, run [8], and come back." -ForegroundColor Yellow
            $bName = Read-Required -Prompt "Bastion name"
            if (-not $bName) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
            $vars['bastion_name'] = $bName
            $bRg = Read-Required -Prompt "Bastion resource group (the VNet's resource group)"
            if (-not $bRg) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
            $vars['bastion_resource_group_name'] = $bRg
        }

        Write-Host ""
        Write-Host "OPTIONAL: a private storage account holding your licensed KAPE (kape.zip)." -ForegroundColor Cyan
        Write-Host "Without it the host comes up with no KAPE and no parsing toolchain - fine for" -ForegroundColor Cyan
        Write-Host "an infrastructure test. Must NOT be this case's evidence account. See" -ForegroundColor Cyan
        Write-Host "infra/README.md's "Getting KAPE onto the host" for the one-time setup." -ForegroundColor Cyan
        if ($prereq['tools_storage_account_id']) {
            Write-Host "Using the storage account recorded by [9] Tools storage - press Enter to accept." -ForegroundColor DarkGray
        }
        $toolsId = Read-Default -Prompt "Tools storage account resource ID (blank = skip)" -Default $prereq['tools_storage_account_id']
        if ($toolsId) {
            $vars['tools_storage_account_id'] = $toolsId
            $vars['tools_container_name'] = Read-Default -Prompt "Tools container name" -Default $(if ($prereq['tools_container_name']) { $prereq['tools_container_name'] } else { 'irtools' })
        }

        # Offer only sizes this subscription can actually deploy in this region.
        # Typing a size by hand is how we ended up sending Azure "B4s_v2"
        # (prefix stripped) and "Standard_D4s_v5" (capacity-restricted); a list
        # built from live availability removes both failure modes.
        Write-Host ""
        Write-Host "Looking up VM sizes available to you in $($vars['location'])..." -ForegroundColor DarkGray
        $sizeOptions = Get-AvailableVmSizes -Location $vars['location']
        if ($sizeOptions.Count -gt 0) {
            $sizeItems = $sizeOptions | ForEach-Object {
                $note = if ($_.HasTempDisk) { '  - has a local temp disk, may take D:' } else { '' }
                [pscustomobject]@{
                    Label = ('{0,-24} {1} vCPU, {2} GiB{3}' -f $_.Name, $_.VCpu, $_.MemoryGb, $note)
                    Value = $_.Name
                }
            }
            $vars['vm_size'] = Format-AzureVmSize (Read-Choice -Prompt "VM size (available in $($vars['location'])):" `
                -Items $sizeItems -DisplayProperty Label -ValueProperty Value `
                -AllowCustom -CustomPrompt 'VM size')
        } else {
            Write-Host "Could not list sizes (is 'az login' active?) - falling back to typing one." -ForegroundColor Yellow
            $vars['vm_size'] = Format-AzureVmSize (Read-Default -Prompt "VM size" -Default 'Standard_B4s_v2')
        }
    }

    if ($cloud -eq 'Azure') {
        Write-Host ""
        Write-Host "Checking that $($vars['vm_size']) is actually available to you in $($vars['location'])..." -ForegroundColor DarkGray
        $sizeCheck = Test-VmSizeAvailable -Location $vars['location'] -Size $vars['vm_size']
        if ($sizeCheck.Checked -and -not $sizeCheck.Available) {
            Write-Host ""
            Write-Host "That size will not deploy: $($sizeCheck.Reason)." -ForegroundColor Red
            $alts = Get-AvailableVmSizes -Location $vars['location']
            if ($alts.Count -gt 0) {
                Write-Host "Sizes your subscription CAN deploy there right now:" -ForegroundColor Yellow
                foreach ($a in $alts) {
                    $note = if ($a.HasTempDisk) { '  (has a local temp disk - may take D:)' } else { '' }
                    Write-Host ("  {0,-24} {1} vCPU, {2} GiB{3}" -f $a.Name, $a.VCpu, $a.MemoryGb, $note) -ForegroundColor Yellow
                }
                Write-Host "Copy a name EXACTLY as shown, including the Standard_ prefix." -ForegroundColor DarkGray
            } else {
                Write-Host "Try another region, or: az vm list-skus --location $($vars['location']) --resource-type virtualMachines --output table" -ForegroundColor Yellow
            }
            $newSize = Read-Default -Prompt "VM size to use instead (blank to cancel)" -Default ''
            if (-not $newSize) { Write-Host "Cancelled - nothing was created." -ForegroundColor Yellow; return }
            $vars['vm_size'] = Format-AzureVmSize $newSize
        } elseif ($sizeCheck.Checked) {
            Write-Host "$($vars['vm_size']) is available in $($vars['location'])." -ForegroundColor Green
        }
    }

    if ($cloud -eq 'AWS') {
        Write-Host ""
        Write-Host "Checking the Windows Server AMI parameter exists in $($vars['region'])..." -ForegroundColor DarkGray
        $amiParam = '/aws/service/ami-windows-latest/Windows_Server-2025-English-Full-Base'
        $ami = Test-AwsAmiParameter -Region $vars['region'] -AwsProfile $vars['aws_profile'] -ParameterName $amiParam
        if ($ami.Checked -and -not $ami.Ok) {
            Write-Host "That AMI parameter does not exist in $($vars['region']):" -ForegroundColor Red
            Write-Host "  $amiParam" -ForegroundColor Red
            Write-Host "Windows Server 2025 may not be published there yet. List what is available with:" -ForegroundColor Yellow
            Write-Host "  aws ssm get-parameters-by-path --path /aws/service/ami-windows-latest --region $($vars['region']) --query \"Parameters[].Name\" --output text | Select-String English-Full-Base" -ForegroundColor Yellow
            Write-Host "then set windows_ami_ssm_parameter in modules/aws/investigation-host/variables.tf." -ForegroundColor Yellow
            if (-not (Read-YesNo -Prompt "Continue anyway?" -Default $false)) { Write-Host "Cancelled - nothing was created." -ForegroundColor Yellow; return }
        } elseif ($ami.Checked) {
            Write-Host "AMI parameter resolves to $($ami.Value)." -ForegroundColor Green
        }

        Write-Host "Checking the subnet has internet egress..." -ForegroundColor DarkGray
        $egress = Test-AwsSubnetEgress -SubnetId $vars['subnet_id'] -Region $vars['region'] -AwsProfile $vars['aws_profile']
        if ($egress.Checked -and -not $egress.HasEgress) {
            Write-Host ""
            Write-Host "That subnet has no usable outbound route: $($egress.Via)." -ForegroundColor Red
            Write-Host "This host gets NO public IP by design, so it needs a NAT Gateway (or equivalent)." -ForegroundColor Yellow
            Write-Host "Without one it will boot, fail to reach SSM and GitHub, and never become" -ForegroundColor Yellow
            Write-Host "manageable - while still billing. See infra/TESTING-AWS.md for creating one." -ForegroundColor Yellow
            if (-not (Read-YesNo -Prompt "Continue anyway (the host will almost certainly be unreachable)?" -Default $false)) {
                Write-Host "Cancelled - nothing was created." -ForegroundColor Yellow; return
            }
        } elseif ($egress.Checked) {
            Write-Host "Subnet egress OK via $($egress.Via)." -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "Checking the investigation host will be able to fetch its bootstrap script..." -ForegroundColor DarkGray
    $bootstrapCheck = Test-BootstrapScriptReachable
    if ($bootstrapCheck.Checked -and -not $bootstrapCheck.Reachable) {
        Write-Host ""
        Write-Host "The host bootstrap script is NOT reachable (HTTP $($bootstrapCheck.StatusCode)):" -ForegroundColor Red
        Write-Host "  $($bootstrapCheck.Url)" -ForegroundColor Red
        Write-Host ""
        Write-Host "The VM downloads this from the PUBLIC repo at first boot - it never sees your" -ForegroundColor Yellow
        Write-Host "local working copy. If infra/ is not committed and pushed, the deploy will fail" -ForegroundColor Yellow
        Write-Host "at the Custom Script Extension after the VM is already created and billing." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Push it first:" -ForegroundColor Yellow
        Write-Host "  git add infra .gitignore README.md scripts/Manage-Tools.ps1" -ForegroundColor Yellow
        Write-Host "  git commit -m 'Add cloud IR infrastructure'" -ForegroundColor Yellow
        Write-Host "  git push origin main" -ForegroundColor Yellow
        Write-Host ""
        if (-not (Read-YesNo -Prompt "Continue anyway (the bootstrap WILL fail)?" -Default $false)) {
            Write-Host "Cancelled - nothing was created." -ForegroundColor Yellow
            return
        }
    } elseif ($bootstrapCheck.Reachable) {
        Write-Host "Bootstrap script is reachable." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "About to create case '$caseId' on $cloud - this provisions real, billable cloud resources (a small VM + storage; see infra/README.md's cost-consciousness section)." -ForegroundColor Cyan
    if (-not (Read-YesNo -Prompt "Run terraform apply now?" -Default $false)) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }

    $varArgs = ConvertTo-TerraformVarArgs -Vars $vars
    $ok = Invoke-CaseTerraform -EnvDir $envDir -CaseId $caseId -TerraformArgs (@('apply', '-auto-approve') + $varArgs)
    if (-not $ok) {
        Write-Host "terraform apply failed - see output above. No case record was saved." -ForegroundColor Red
        Write-Host ""
        Write-Host "If the error said a resource 'already exists - to be managed via Terraform this" -ForegroundColor Yellow
        Write-Host "resource needs to be imported into the State', that is an orphan from a PREVIOUS" -ForegroundColor Yellow
        Write-Host "failed apply: Azure created the resource, but the errored apply never recorded it" -ForegroundColor Yellow
        Write-Host "in state. The bootstrap extension is the usual one, because it is created first" -ForegroundColor Yellow
        Write-Host "and then fails while running. Delete it and re-run [2]:" -ForegroundColor Yellow
        Write-Host "  az vm extension delete --resource-group rg-ir-case-$caseId --vm-name ir-case-$caseId --name bootstrap-investigation-host" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Otherwise fix the underlying issue (credentials, subnet, quota, VM size) and re-run [2]." -ForegroundColor Yellow
        return
    }

    $outputs = Get-CaseTerraformOutputs -EnvDir $envDir -CaseId $caseId
    # admin_password (and, on Azure, admin_username - not secret on its own,
    # but kept alongside its password rather than split across two places)
    # is deliberately excluded from what gets persisted here - see
    # infra/SECURITY.md. Connect-InvestigationHost.ps1 fetches it fresh
    # from Terraform state itself each time instead of reading it back from
    # this bookkeeping file.
    $outputsForRecord = $outputs | Select-Object -Property * -ExcludeProperty admin_password
    $record = [pscustomobject]@{
        case_id      = $caseId
        cloud        = $cloud
        status       = 'active'
        created_utc  = (Get-Date).ToUniversalTime().ToString('o')
        archived_utc = $null
        vars         = $vars
        outputs      = $outputsForRecord
    }
    Save-CaseRecord -Record $record
    Write-Host ""
    Write-Host "Case '$caseId' created. Next: [3] to build its collector, [4] to connect once bootstrap finishes (a few minutes after apply)." -ForegroundColor Green
}

function Select-ExistingCase {
    param([string]$Prompt = "Case ID")
    $cases = Get-AllCaseRecords
    if ($cases.Count -eq 0) {
        Write-Host "No cases found in infra\.cases\ - create one first (option 2)." -ForegroundColor Yellow
        return $null
    }
    $caseItems = $cases | Sort-Object case_id | ForEach-Object {
        [pscustomobject]@{
            Label = ('{0,-20} {1,-6} {2}' -f $_.case_id, $_.cloud, $_.status)
            Value = $_.case_id
        }
    }
    $caseId = Read-Choice -Prompt "$($Prompt):" -Items $caseItems -DisplayProperty Label -ValueProperty Value `
        -AllowCustom -CustomPrompt 'Case ID (one not listed here)'
    if (-not $caseId) { return $null }
    $record = Get-CaseRecord -CaseId $caseId
    if (-not $record) {
        Write-Host "No local record for '$caseId'. It may still exist as a terraform workspace if it was created outside this console - the other menu options will still try that workspace directly." -ForegroundColor Yellow
    }
    return @{ CaseId = $caseId; Record = $record }
}

function Invoke-BuildCollector {
    $sel = Select-ExistingCase -Prompt "Case ID to build a collector for"
    if (-not $sel) { return }
    $cloud = if ($sel.Record) { $sel.Record.cloud } else { Read-CloudChoice }
    $veloExe = Read-Required -Prompt "Path to a plain Velociraptor binary (velociraptor.exe)"
    if (-not $veloExe) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
    Invoke-ScriptFile 'New-CaseCollector.ps1' @('-CaseId', $sel.CaseId, '-CloudProvider', $cloud, '-VeloExe', $veloExe)
}

function Invoke-LockDownCase {
    # Safety net for the rdp-allowlist access method: [4] normally removes the
    # just-in-time rule when the RDP window closes, but that cannot happen if
    # the console was killed mid-session or -KeepOpen was used. This closes it
    # on demand so nobody has to remember an az command.
    $sel = Select-ExistingCase -Prompt "Case ID to lock down"
    if (-not $sel) { return }
    $cloud = if ($sel.Record) { $sel.Record.cloud } else { Read-CloudChoice }
    if ($cloud -ne 'Azure') {
        Write-Host "Only Azure cases using the rdp-allowlist access method have a JIT rule to remove. AWS uses SSM, which opens no port at all." -ForegroundColor Yellow
        return
    }
    Invoke-ScriptFile 'Connect-InvestigationHost.ps1' @('-CaseId', $sel.CaseId, '-CloudProvider', 'Azure', '-CloseOnly')
}

function Invoke-Connect {
    $sel = Select-ExistingCase -Prompt "Case ID to connect to"
    if (-not $sel) { return }
    $cloud = if ($sel.Record) { $sel.Record.cloud } else { Read-CloudChoice }
    Invoke-ScriptFile 'Connect-InvestigationHost.ps1' @('-CaseId', $sel.CaseId, '-CloudProvider', $cloud)
}

function Invoke-DestroyHost {
    param([string]$CaseIdOverride, [switch]$Silent)

    $caseId = $CaseIdOverride
    $record = $null
    if ($caseId) {
        $record = Get-CaseRecord -CaseId $caseId
    } else {
        $sel = Select-ExistingCase -Prompt "Case ID whose investigation host should be destroyed"
        if (-not $sel) { return $false }
        $caseId = $sel.CaseId
        $record = $sel.Record
    }
    if (-not $record) {
        Write-Host "No local record for '$caseId' - cannot reconstruct the variables terraform needs for a targeted destroy. Run this from the same machine/checkout that created the case, or recreate infra\.cases\$caseId.json by hand (see infra/README.md)." -ForegroundColor Red
        return $false
    }

    if (-not $Silent) {
        Write-Host "This destroys the investigation host (compute) for case '$caseId'. Evidence storage is left untouched." -ForegroundColor Cyan
        if (-not (Read-YesNo -Prompt "Continue?" -Default $false)) { Write-Host "Cancelled." -ForegroundColor Yellow; return $false }
    }

    $envDir = if ($record.cloud -eq 'AWS') { $script:AwsEnvDir } else { $script:AzureEnvDir }
    $varArgs = ConvertTo-TerraformVarArgs -Vars (ConvertTo-Hashtable $record.vars)
    $ok = Invoke-CaseTerraform -EnvDir $envDir -CaseId $caseId `
        -TerraformArgs (@('destroy', '-auto-approve', '-target=module.investigation_host') + $varArgs)
    if ($ok) {
        Write-Host "Investigation host destroyed for case '$caseId'." -ForegroundColor Green
    } else {
        Write-Host "terraform destroy failed - see output above." -ForegroundColor Red
    }
    return $ok
}

function Invoke-DestroyHostMenu {
    $sel = Select-ExistingCase -Prompt "Case ID whose investigation host should be destroyed"
    if (-not $sel) { return }
    $ok = Invoke-DestroyHost -CaseIdOverride $sel.CaseId
    if ($ok -and (Read-YesNo -Prompt "Respin a clean investigation host for this case now?" -Default $false)) {
        $record = Get-CaseRecord -CaseId $sel.CaseId
        $envDir = if ($record.cloud -eq 'AWS') { $script:AwsEnvDir } else { $script:AzureEnvDir }
        $varArgs = ConvertTo-TerraformVarArgs -Vars (ConvertTo-Hashtable $record.vars)
        Invoke-CaseTerraform -EnvDir $envDir -CaseId $sel.CaseId -TerraformArgs (@('apply', '-auto-approve') + $varArgs) | Out-Null
    }
}

function Invoke-ArchiveCase {
    $sel = Select-ExistingCase -Prompt "Case ID to archive"
    if (-not $sel) { return }
    $caseId = $sel.CaseId
    $record = $sel.Record
    if (-not $record) {
        Write-Host "No local record for '$caseId' - cannot look up its storage details." -ForegroundColor Red
        return
    }
    if ($record.status -eq 'archived') {
        Write-Host "Case '$caseId' is already marked archived (as of $($record.archived_utc))." -ForegroundColor Yellow
        return
    }

    if (Read-YesNo -Prompt "Destroy the investigation host as part of archiving this case (recommended - stop paying for idle compute)?" -Default $true) {
        Invoke-DestroyHost -CaseIdOverride $caseId -Silent | Out-Null
    }

    Write-Host "Forcing an immediate transition of this case's evidence to cold/archive storage (rather than waiting for the normal $($record.vars.archive_after_days)-day lifecycle rule)..." -ForegroundColor Cyan
    if (-not (Read-YesNo -Prompt "Continue?" -Default $true)) { Write-Host "Cancelled." -ForegroundColor Yellow; return }

    $outputs = $record.outputs
    if ($record.cloud -eq 'AWS') {
        $bucket = $outputs.bucket_name
        # NOT named $profile - that's a PowerShell automatic variable (the
        # profile script path); shadowing it inside a function is legal but
        # actively confusing to anyone debugging this later.
        $awsProfileName = $record.vars.aws_profile
        # A same-key server-side copy is the usual way to change an existing
        # object's storage class immediately: it writes a NEW current version
        # at the requested class, leaving the prior version untouched (so it
        # can't violate an Object Lock retention already in force).
        #
        # That "leaving the prior version untouched" property has a real
        # cost consequence on this bucket, which is versioned by default:
        # every object is now stored TWICE - the old STANDARD version plus
        # the new GLACIER one - and if Object Lock is on, the old version
        # cannot be deleted until its retention expires. The bucket's own
        # lifecycle rule does eventually transition noncurrent versions to
        # Glacier too, which limits the damage, but this is still strictly
        # more expensive than simply letting the lifecycle rule run.
        # Objects already in Glacier will also fail to copy (they must be
        # restored first), so re-running this on an archived case is noisy.
        Write-Host "NOTE: this rewrites every object, creating a second (Glacier) version alongside the existing one." -ForegroundColor Yellow
        Write-Host "      On a versioned bucket that temporarily increases stored bytes. Letting the $($record.vars.archive_after_days)-day" -ForegroundColor Yellow
        Write-Host "      lifecycle rule transition them on its own is cheaper if you are not in a hurry." -ForegroundColor Yellow
        if (-not (Read-YesNo -Prompt "Force the immediate rewrite anyway?" -Default $false)) {
            Write-Host "Skipped the immediate rewrite - the lifecycle rule will still archive this evidence on schedule." -ForegroundColor Yellow
            $record.status = 'archived'
            $record.archived_utc = (Get-Date).ToUniversalTime().ToString('o')
            Save-CaseRecord -Record $record
            Write-Host "Case '$caseId' marked archived." -ForegroundColor Green
            return
        }
        Write-Host "aws s3 cp --recursive --storage-class GLACIER on s3://$bucket ..."
        & aws s3 cp "s3://$bucket" "s3://$bucket" --recursive --storage-class GLACIER --profile $awsProfileName | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Host "aws s3 cp reported errors - see output above; evidence is unaffected either way (this only changes storage class)." -ForegroundColor Yellow }
    } else {
        $account = $outputs.storage_account_name
        $container = $outputs.container_name
        Write-Host "Listing blobs in $account/$container to move to the Archive tier..."
        $blobNames = & az storage blob list --account-name $account --container-name $container --auth-mode login --query '[].name' -o tsv
        if ($LASTEXITCODE -eq 0 -and $blobNames) {
            # Split on \r?\n and trim, not on \n alone: az emits CRLF on
            # Windows, so a bare -split "`n" leaves a trailing CR on every
            # name except the last, and `set-tier --name "blob.zip<CR>"`
            # then fails for all of them (confirmed directly).
            foreach ($blob in ($blobNames -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                & az storage blob set-tier --account-name $account --container-name $container --name $blob --tier Archive --auth-mode login | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Host "  Failed to tier: $blob (continuing)" -ForegroundColor Yellow }
            }
        } else {
            Write-Host "No blobs found or listing failed - nothing to tier." -ForegroundColor Yellow
        }

        if ($record.vars.enable_immutability -and $record.vars.retention_mode -eq 'GOVERNANCE') {
            if (Read-YesNo -Prompt "Lock this case's immutability policy now (GOVERNANCE -> COMPLIANCE-equivalent, IRREVERSIBLE)? Skip if unsure - see infra/SECURITY.md." -Default $false) {
                # NOTE: immutability-policy show/lock are MANAGEMENT-plane
                # (ARM) commands and do NOT accept --auth-mode - verified
                # against their own az CLI reference, which lists only
                # --account-name/--container-name/--if-match/--resource-group.
                # Passing --auth-mode login here made the CLI fail with
                # "unrecognized arguments". They authenticate off the plain
                # `az login` context. --resource-group is passed explicitly
                # so the CLI doesn't have to resolve the account by search.
                $resourceGroup = $outputs.resource_group_name
                $policyJson = & az storage container immutability-policy show --account-name $account --container-name $container --resource-group $resourceGroup
                if ($LASTEXITCODE -eq 0) {
                    $etag = ($policyJson | ConvertFrom-Json).etag
                    & az storage container immutability-policy lock --account-name $account --container-name $container --resource-group $resourceGroup --if-match $etag | Out-Host
                    if ($LASTEXITCODE -eq 0) { Write-Host "Immutability policy locked." -ForegroundColor Green } else { Write-Host "Lock failed - see output above." -ForegroundColor Red }
                } else {
                    Write-Host "Could not read the existing immutability policy - see output above." -ForegroundColor Red
                }
            }
        }
    }

    $record.status = 'archived'
    $record.archived_utc = (Get-Date).ToUniversalTime().ToString('o')
    Save-CaseRecord -Record $record
    Write-Host "Case '$caseId' marked archived." -ForegroundColor Green
}

function Show-CaseList {
    $cases = Get-AllCaseRecords
    if ($cases.Count -eq 0) {
        Write-Host "No cases found in infra\.cases\." -ForegroundColor Yellow
        return
    }
    $cases | Sort-Object case_id | ForEach-Object {
        $storage = if ($_.cloud -eq 'AWS') { $_.outputs.bucket_name } else { "$($_.outputs.storage_account_name)/$($_.outputs.container_name)" }
        [pscustomobject]@{
            CaseId  = $_.case_id
            Cloud   = $_.cloud
            Status  = $_.status
            Storage = $storage
            Created = $_.created_utc
        }
    } | Format-Table -AutoSize
}


# ---------------------------------------------------------------------------
# Shared prerequisite infrastructure (.prereqs.json)
#
# Networking and tools storage are created once per cloud account and reused by
# every case, so they sit outside the per-case Terraform. Remembering what was
# created means [2] can offer it as a default instead of asking the operator to
# keep a subnet resource id on a sticky note - which is where copy/paste errors
# come from. Same bookkeeping-not-secrets rule as .cases\: nothing here is
# credential material.
# ---------------------------------------------------------------------------

function Get-Prereqs {
    param([string]$Cloud)
    if (-not (Test-Path -LiteralPath $script:PrereqPath)) { return @{} }
    try {
        $all = Get-Content -Raw -LiteralPath $script:PrereqPath | ConvertFrom-Json
    } catch {
        Write-Host "Could not read $($script:PrereqPath) - ignoring saved defaults." -ForegroundColor Yellow
        return @{}
    }
    if (-not $Cloud) { return (ConvertTo-Hashtable $all) }
    if (-not $all.PSObject.Properties[$Cloud]) { return @{} }
    return (ConvertTo-Hashtable $all.$Cloud)
}

function Save-Prereq {
    param([string]$Cloud, [hashtable]$Values)
    $all = Get-Prereqs
    if (-not $all.ContainsKey($Cloud)) { $all[$Cloud] = @{} }
    $section = ConvertTo-Hashtable $all[$Cloud]
    foreach ($k in $Values.Keys) { $section[$k] = $Values[$k] }
    $all[$Cloud] = $section
    ($all | ConvertTo-Json -Depth 10) | Out-File -Encoding utf8 -LiteralPath $script:PrereqPath
}

function Show-Prereqs {
    $all = Get-Prereqs
    if ($all.Count -eq 0) {
        Write-Host "No shared infrastructure has been created from this machine yet." -ForegroundColor Yellow
        Write-Host "Options [8] and [9] create it; [2] then offers it as a default." -ForegroundColor Yellow
        return
    }
    foreach ($cloud in $all.Keys) {
        Write-Host ""
        Write-Host "$cloud" -ForegroundColor Cyan
        $section = ConvertTo-Hashtable $all[$cloud]
        foreach ($k in ($section.Keys | Sort-Object)) {
            Write-Host ("  {0,-28} {1}" -f $k, $section[$k])
        }
    }
}

# ---------------------------------------------------------------------------
# [8] Case networking
# ---------------------------------------------------------------------------

function Invoke-NetworkMenu {
    $cloud = Read-CloudChoice
    if (-not $cloud) { return }
    $saved = Get-Prereqs -Cloud $cloud

    Write-Host ""
    if ($saved['subnet_id']) {
        Write-Host "Currently recorded subnet for $($cloud): $($saved['subnet_id'])" -ForegroundColor DarkGray
    }
    $action = Read-Choice -Prompt "Case networking ($cloud):" -Items @(
        [pscustomobject]@{ Label = 'Create it - one VNet/VPC and subnet, reused by every case'; Value = 'create' }
        [pscustomobject]@{ Label = 'Delete it - only when no case is still using it'; Value = 'delete' }
    ) -DisplayProperty Label -ValueProperty Value

    if ($cloud -eq 'AWS') {
        $region = Read-Choice -Prompt "AWS region:" -Items $script:AwsRegions -Default $(if ($saved['region']) { $saved['region'] } else { 'us-east-1' }) -AllowCustom -CustomPrompt 'AWS region'
        $awsProfile = Read-Default -Prompt "AWS CLI profile" -Default ($(if ($saved['aws_profile']) { $saved['aws_profile'] } else { 'ir-cloud' }))

        if ($action -eq 'delete') {
            Write-Host ""
            Write-Host "This deletes the VPC, its subnets, the NAT Gateway and its Elastic IP in $region." -ForegroundColor Red
            Write-Host "Any case whose host still lives in that subnet will lose its network." -ForegroundColor Red
            if (-not (Read-YesNo -Prompt "Continue?" -Default $false)) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
            Invoke-ScriptFile 'New-AwsTestNetwork.ps1' @('-Delete', '-Region', $region, '-AwsProfile', $awsProfile)
            return
        }

        Write-Host ""
        Write-Host "This creates a VPC, a public and a private subnet, and a NAT Gateway." -ForegroundColor Cyan
        Write-Host "The NAT Gateway is what gives the investigation host outbound internet -" -ForegroundColor Cyan
        Write-Host "it has no public IP by design, so without one it never reaches SSM or the" -ForegroundColor Cyan
        Write-Host "bootstrap script. It bills about `$0.045/hr from creation, so [8] Delete it" -ForegroundColor Cyan
        Write-Host "when you are done testing." -ForegroundColor Cyan
        if (-not (Read-YesNo -Prompt "Create it now?" -Default $true)) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
        Invoke-ScriptFile 'New-AwsTestNetwork.ps1' @('-Region', $region, '-AwsProfile', $awsProfile)

        # The script prints the ids; capturing its stdout would mean giving up
        # the live progress output, so this asks the operator to confirm the
        # private subnet id instead. Saved once here, offered as the default
        # for every case afterwards.
        Write-Host ""
        Write-Host "Copy the PRIVATE subnet id printed above so [2] can offer it as a default." -ForegroundColor Cyan
        $subnetId = Read-Default -Prompt "Private subnet ID (blank = don't remember)" -Default ''
        $vpcId = Read-Default -Prompt "VPC ID (blank = don't remember)" -Default ''
        $toSave = @{ region = $region; aws_profile = $awsProfile }
        if ($subnetId) { $toSave['subnet_id'] = $subnetId }
        if ($vpcId) { $toSave['vpc_id'] = $vpcId }
        Save-Prereq -Cloud 'AWS' -Values $toSave
        Write-Host "Remembered for next time." -ForegroundColor Green
        return
    }

    # --- Azure ---
    $rg = Read-Default -Prompt "Resource group for the network" -Default ($(if ($saved['network_resource_group']) { $saved['network_resource_group'] } else { 'rg-ir-network' }))

    if ($action -eq 'delete') {
        Write-Host ""
        Write-Host "This deletes resource group '$rg' and everything in it." -ForegroundColor Red
        Write-Host "Any case whose host still lives in that VNet will lose its network." -ForegroundColor Red
        if (-not (Read-YesNo -Prompt "Continue?" -Default $false)) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
        Invoke-ScriptFile 'New-AzureTestNetwork.ps1' @('-Delete', '-ResourceGroup', $rg)
        return
    }

    $location = Read-Choice -Prompt "Azure region:" -Items $script:AzureRegions -Default ($(if ($saved['location']) { $saved['location'] } else { 'eastus' })) -AllowCustom -CustomPrompt 'Azure region'
    Write-Host ""
    Write-Host "This creates a VNet and subnet the investigation hosts launch into." -ForegroundColor Cyan
    Write-Host "A VNet costs nothing while idle - only the VMs inside it bill." -ForegroundColor Cyan
    if (-not (Read-YesNo -Prompt "Create it now?" -Default $true)) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
    Invoke-ScriptFile 'New-AzureTestNetwork.ps1' @('-ResourceGroup', $rg, '-Location', $location)

    Write-Host ""
    Write-Host "Copy the Subnet ID printed above so [2] can offer it as a default." -ForegroundColor Cyan
    $subnetId = Read-Default -Prompt "Subnet resource ID (blank = don't remember)" -Default ''
    $toSave = @{ location = $location; network_resource_group = $rg }
    if ($subnetId) { $toSave['subnet_id'] = $subnetId }
    Save-Prereq -Cloud 'Azure' -Values $toSave
    Write-Host "Remembered for next time." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# [9] Tools storage (licensed KAPE)
# ---------------------------------------------------------------------------

function Invoke-ToolsStorageMenu {
    $cloud = Read-CloudChoice
    if (-not $cloud) { return }
    $saved = Get-Prereqs -Cloud $cloud

    Write-Host ""
    Write-Host "Investigation hosts pull licensed tooling (KAPE) from a private bucket or" -ForegroundColor Cyan
    Write-Host "storage account in your own account, read-only, using the identity they" -ForegroundColor Cyan
    Write-Host "already have. Created once and reused by every case." -ForegroundColor Cyan
    if ($cloud -eq 'AWS' -and $saved['tools_bucket_name']) {
        Write-Host "Currently recorded: $($saved['tools_bucket_name'])" -ForegroundColor DarkGray
    } elseif ($cloud -eq 'Azure' -and $saved['tools_storage_account_id']) {
        Write-Host "Currently recorded: $($saved['tools_storage_account_id'])" -ForegroundColor DarkGray
    }

    $action = Read-Choice -Prompt "Tools storage ($cloud):" -Items @(
        [pscustomobject]@{ Label = 'Create it (optionally uploading a kape.zip now)'; Value = 'create' }
        [pscustomobject]@{ Label = 'Upload/replace kape.zip in storage that already exists'; Value = 'upload' }
        [pscustomobject]@{ Label = 'Delete it'; Value = 'delete' }
    ) -DisplayProperty Label -ValueProperty Value

    $scriptArgs = @('-CloudProvider', $cloud)

    if ($cloud -eq 'AWS') {
        $region = $(if ($saved['region']) { $saved['region'] } else { 'us-east-1' })
        $awsProfile = $(if ($saved['aws_profile']) { $saved['aws_profile'] } else { 'ir-cloud' })
        $scriptArgs += @('-Region', $region, '-AwsProfile', $awsProfile)
    } else {
        $rg = Read-Default -Prompt "Resource group for tools storage" -Default ($(if ($saved['tools_resource_group']) { $saved['tools_resource_group'] } else { 'rg-ir-tools' }))
        $location = $(if ($saved['location']) { $saved['location'] } else { 'eastus' })
        $scriptArgs += @('-ResourceGroup', $rg, '-Location', $location)
    }

    if ($action -eq 'delete') {
        Write-Host ""
        Write-Host "This deletes the tools storage. Your KAPE zip goes with it - you would have" -ForegroundColor Red
        Write-Host "to re-upload it before the next case can install KAPE." -ForegroundColor Red
        if (-not (Read-YesNo -Prompt "Continue?" -Default $false)) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
        if ($cloud -eq 'AWS') {
            $name = Read-Default -Prompt "Tools bucket name" -Default ($saved['tools_bucket_name'])
            if (-not $name) { Write-Host "Cancelled - no bucket name." -ForegroundColor Yellow; return }
            $scriptArgs += @('-Name', $name)
        }
        Invoke-ScriptFile 'New-ToolsStorage.ps1' ($scriptArgs + @('-Delete'))
        return
    }

    # A kape.zip is optional at create time but is the entire point of the
    # upload action, so it is required there.
    $kapeZip = Read-Default -Prompt "Path to your licensed kape.zip (blank = skip the upload)" -Default ''
    if ($action -eq 'upload' -and -not $kapeZip) {
        Write-Host "Nothing to upload - cancelled." -ForegroundColor Yellow
        return
    }
    if ($kapeZip -and -not (Test-Path -LiteralPath $kapeZip)) {
        Write-Host "No file at: $kapeZip" -ForegroundColor Red
        return
    }
    if ($kapeZip) { $scriptArgs += @('-KapeZipPath', $kapeZip) }

    if ($action -eq 'upload') {
        # Reuse the existing storage rather than making a second one.
        if ($cloud -eq 'AWS') {
            $name = Read-Default -Prompt "Existing tools bucket name" -Default ($saved['tools_bucket_name'])
            if (-not $name) { Write-Host "Cancelled - no bucket name." -ForegroundColor Yellow; return }
            Write-Host ""
            Write-Host "Uploading to s3://$name/kape.zip ..." -ForegroundColor Cyan
            & aws s3 cp $kapeZip "s3://$name/kape.zip" --profile $(if ($saved['aws_profile']) { $saved['aws_profile'] } else { 'ir-cloud' }) | Out-Host
            if ($LASTEXITCODE -eq 0) { Write-Host "Uploaded." -ForegroundColor Green } else { Write-Host "Upload failed - see output above." -ForegroundColor Red }
        } else {
            $account = Read-Default -Prompt "Existing tools storage account NAME (not the resource id)" -Default ''
            if (-not $account) { Write-Host "Cancelled - no account name." -ForegroundColor Yellow; return }
            $container = Read-Default -Prompt "Container name" -Default ($(if ($saved['tools_container_name']) { $saved['tools_container_name'] } else { 'irtools' }))
            Write-Host ""
            Write-Host "Uploading to $account/$container/kape.zip ..." -ForegroundColor Cyan
            & az storage blob upload --account-name $account --container-name $container --name kape.zip --file $kapeZip --auth-mode login --overwrite | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Host "Uploaded." -ForegroundColor Green } else { Write-Host "Upload failed - see output above." -ForegroundColor Red }
        }
        return
    }

    Invoke-ScriptFile 'New-ToolsStorage.ps1' $scriptArgs

    Write-Host ""
    Write-Host "Copy the identifier printed above so [2] can offer it as a default." -ForegroundColor Cyan
    if ($cloud -eq 'AWS') {
        $name = Read-Default -Prompt "Tools bucket name (blank = don't remember)" -Default ''
        if ($name) { Save-Prereq -Cloud 'AWS' -Values @{ tools_bucket_name = $name }; Write-Host "Remembered for next time." -ForegroundColor Green }
    } else {
        $id = Read-Default -Prompt "Tools storage account resource ID (blank = don't remember)" -Default ''
        if ($id) {
            $container = Read-Default -Prompt "Tools container name" -Default 'irtools'
            Save-Prereq -Cloud 'Azure' -Values @{ tools_storage_account_id = $id; tools_container_name = $container; tools_resource_group = $rg }
            Write-Host "Remembered for next time." -ForegroundColor Green
        }
    }
}

# ---------------------------------------------------------------------------
# [B] Azure shared Bastion - the existing deploy/destroy pair, behind one entry
# ---------------------------------------------------------------------------

function Invoke-BastionMenu {
    Write-Host ""
    Write-Host "A Bastion is shared per-VNet, not per case, and bills by the hour from the" -ForegroundColor Cyan
    Write-Host "moment it exists - roughly `$0.29/hr for the Standard SKU needed for a real" -ForegroundColor Cyan
    Write-Host "mstsc session. It is the most expensive thing this project can leave running." -ForegroundColor Cyan
    $action = Read-Choice -Prompt "Azure shared Bastion:" -Items @(
        [pscustomobject]@{ Label = 'Deploy or update it'; Value = 'deploy' }
        [pscustomobject]@{ Label = 'Destroy it (stops the hourly billing)'; Value = 'destroy' }
    ) -DisplayProperty Label -ValueProperty Value
    if ($action -eq 'deploy') { Invoke-DeploySharedBastion } else { Invoke-DestroySharedBastion }
}

# ---------------------------------------------------------------------------
# [C] What is still billing
# ---------------------------------------------------------------------------

function Invoke-CostCheck {
    $cloud = Read-Choice -Prompt "Check which cloud?" -Items @(
        [pscustomobject]@{ Label = 'Both'; Value = 'Both' }
        [pscustomobject]@{ Label = 'AWS only'; Value = 'AWS' }
        [pscustomobject]@{ Label = 'Azure only'; Value = 'Azure' }
    ) -DisplayProperty Label -ValueProperty Value -Default 'Both'

    $wide = Read-YesNo -Prompt "Sweep every region/subscription (slower, but the only way to catch something you have forgotten about)?" -Default $true

    if ($cloud -in @('Both', 'AWS')) {
        Write-Host ""
        Write-Host "=== AWS ===" -ForegroundColor Cyan
        $saved = Get-Prereqs -Cloud 'AWS'
        $awsArgs = @(
            '-AwsProfile', $(if ($saved['aws_profile']) { $saved['aws_profile'] } else { 'ir-cloud' })
            '-Region', $(if ($saved['region']) { $saved['region'] } else { 'us-east-1' })
        )
        if ($wide) { $awsArgs += '-AllRegions' }
        Invoke-ScriptFile 'Test-AwsTeardown.ps1' $awsArgs
    }

    if ($cloud -in @('Both', 'Azure')) {
        Write-Host ""
        Write-Host "=== Azure ===" -ForegroundColor Cyan
        $azArgs = @()
        if ($wide) { $azArgs += '-AllSubscriptions' }
        Invoke-ScriptFile 'Test-AzureTeardown.ps1' $azArgs
    }
}

# ---------------------------------------------------------------------------
# [D] Delete a case completely
# ---------------------------------------------------------------------------

function Invoke-DeleteCaseCompletely {
    $sel = Select-ExistingCase -Prompt "Case ID to delete completely"
    if (-not $sel) { return }
    $caseId = $sel.CaseId
    $record = $sel.Record
    if (-not $record) {
        Write-Host "No local record for '$caseId' - cannot reconstruct the variables terraform needs to destroy it. Run this from the machine that created the case." -ForegroundColor Red
        return
    }

    $storage = if ($record.cloud -eq 'AWS') { "s3://$($record.outputs.bucket_name)" } else { "$($record.outputs.storage_account_name)/$($record.outputs.container_name)" }

    Write-Host ""
    Write-Host "This destroys EVERYTHING for case '$caseId':" -ForegroundColor Red
    Write-Host "  - the investigation host and its disks" -ForegroundColor Red
    Write-Host "  - the evidence storage and every collection in it: $storage" -ForegroundColor Red
    Write-Host "  - its terraform workspace and local case record" -ForegroundColor Red
    Write-Host ""
    Write-Host "The evidence is not recoverable afterwards. If this case might still be" -ForegroundColor Yellow
    Write-Host "needed, use [6] Archive instead - that keeps the evidence and only stops" -ForegroundColor Yellow
    Write-Host "the compute billing." -ForegroundColor Yellow
    Write-Host ""
    $typed = Read-Host "Type the case ID to confirm"
    if ($typed -ne $caseId) {
        Write-Host "Case ID did not match - nothing was deleted." -ForegroundColor Yellow
        return
    }

    $envDir = if ($record.cloud -eq 'AWS') { $script:AwsEnvDir } else { $script:AzureEnvDir }

    if ($record.cloud -eq 'AWS') {
        # The S3 bucket is Terraform-managed but the module sets no
        # force_destroy - deliberately, so a stray `terraform destroy` can
        # never take evidence with it. That means terraform cannot delete a
        # bucket with anything in it. Emptying it first (and letting terraform
        # delete the empty bucket) keeps state consistent; deleting the bucket
        # out from under terraform would leave a resource in state that no
        # longer exists.
        $bucket = $record.outputs.bucket_name
        if ($bucket) {
            Write-Host ""
            Write-Host "Emptying s3://$bucket so terraform can remove it..." -ForegroundColor Cyan
            Invoke-ScriptFile 'Remove-AwsCaseStorage.ps1' @(
                '-BucketName', $bucket, '-EmptyOnly', '-Force',
                '-AwsProfile', $record.vars.aws_profile, '-Region', $record.vars.region
            )
        }
    }

    Write-Host ""
    Write-Host "Destroying all remaining resources for '$caseId'..." -ForegroundColor Cyan
    $varArgs = ConvertTo-TerraformVarArgs -Vars (ConvertTo-Hashtable $record.vars)
    $ok = Invoke-CaseTerraform -EnvDir $envDir -CaseId $caseId -TerraformArgs (@('destroy', '-auto-approve') + $varArgs)
    if (-not $ok) {
        Write-Host ""
        Write-Host "terraform destroy failed - see output above. Nothing was removed locally, so" -ForegroundColor Red
        Write-Host "you can fix the cause and re-run this option." -ForegroundColor Red
        Write-Host ""
        Write-Host "If it failed on immutable storage, that is the retention policy working as" -ForegroundColor Yellow
        Write-Host "intended - evidence under a COMPLIANCE lock cannot be deleted early by" -ForegroundColor Yellow
        Write-Host "anyone, including you. Wait for the retention to expire." -ForegroundColor Yellow
        return
    }

    # Only now clean up the local bookkeeping - if destroy failed above, the
    # record is what makes a retry possible.
    $tf = Get-TerraformExe
    if ($tf) {
        Push-Location $envDir
        try {
            & $tf workspace select default | Out-Null
            & $tf workspace delete $caseId | Out-Null
        } finally { Pop-Location }
    }

    $recordPath = Get-CaseRecordPath -CaseId $caseId
    if (Test-Path -LiteralPath $recordPath) { Remove-Item -LiteralPath $recordPath -Force }

    Write-Host ""
    Write-Host "Case '$caseId' is completely gone." -ForegroundColor Green
    Write-Host "Confirm nothing is still billing with [C]." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------

# The menu is a Read-Choice list rather than a printed block plus Read-Host,
# so it gets arrow-key navigation for free. Values are the same keys the
# dispatch switch already used ('1'..'9', 'B', 'C', 'D', 'L', 'Q'), so typing
# a number still works, scripted/piped input is unchanged, and the numbered
# fallback on a non-interactive host is byte-for-byte the old behaviour.
$script:MenuItems = @(
    [pscustomobject]@{ Separator = 'Case workflow' }
    [pscustomobject]@{ Value = '1'; Label = 'First-time setup (Terraform/AWS CLI/Azure CLI + auth check)' }
    [pscustomobject]@{ Value = '2'; Label = 'Create a new case' }
    [pscustomobject]@{ Value = '3'; Label = "Build this case's offline collector" }
    [pscustomobject]@{ Value = '4'; Label = 'Connect to the investigation host' }
    [pscustomobject]@{ Value = '5'; Label = 'Destroy the investigation host (evidence storage kept)' }
    [pscustomobject]@{ Value = '6'; Label = 'Archive this case (force cold storage now, optional immutability lock)' }
    [pscustomobject]@{ Value = '7'; Label = 'List cases' }
    [pscustomobject]@{ Separator = 'Shared infrastructure (create once per cloud account, reused by every case)' }
    [pscustomobject]@{ Value = '8'; Label = 'Case networking (VNet/VPC + subnet)' }
    [pscustomobject]@{ Value = '9'; Label = 'Tools storage (your licensed KAPE)' }
    [pscustomobject]@{ Value = 'B'; Label = 'Azure shared Bastion (bills hourly - deploy/destroy)' }
    [pscustomobject]@{ Value = 'P'; Label = 'Show what shared infrastructure is recorded' }
    [pscustomobject]@{ Separator = 'Teardown and cost' }
    [pscustomobject]@{ Value = 'C'; Label = 'Check what is still billing (AWS/Azure)' }
    [pscustomobject]@{ Value = 'D'; Label = 'Delete a case completely (host AND evidence - irreversible)' }
    [pscustomobject]@{ Value = 'L'; Label = "Lock down a case's RDP now (remove its just-in-time rule)" }
    [pscustomobject]@{ Value = 'Q'; Label = 'Quit' }
)

function Show-MenuHeader {
    Clear-Host
    Write-Host "=================================================="
    Write-Host " ir-endpoint-investigations - Cloud Console"
    Write-Host "=================================================="
}

while ($true) {
    Show-MenuHeader
    $choice = Read-Choice -Prompt 'Choose an option:' -Items $script:MenuItems `
        -DisplayProperty Label -ValueProperty Value
    # Escape cancels the picker; at the top level there is nothing to cancel
    # back to, so treat it as "show the menu again" rather than quitting -
    # quitting on Esc would make a stray keypress destroy an operator's place.
    if (-not $choice) { continue }

    switch ($choice) {
        '1' { Invoke-FirstTimeSetup; Wait-ForEnter }
        '2' { Invoke-CreateCase; Wait-ForEnter }
        '3' { Invoke-BuildCollector; Wait-ForEnter }
        '4' { Invoke-Connect; Wait-ForEnter }
        '5' { Invoke-DestroyHostMenu; Wait-ForEnter }
        '6' { Invoke-ArchiveCase; Wait-ForEnter }
        '7' { Show-CaseList; Wait-ForEnter }
        '8' { Invoke-NetworkMenu; Wait-ForEnter }
        '9' { Invoke-ToolsStorageMenu; Wait-ForEnter }
        'B' { Invoke-BastionMenu; Wait-ForEnter }
        'P' { Show-Prereqs; Wait-ForEnter }
        'C' { Invoke-CostCheck; Wait-ForEnter }
        'D' { Invoke-DeleteCaseCompletely; Wait-ForEnter }
        'L' { Invoke-LockDownCase; Wait-ForEnter }
        { $_ -in @('Q', 'QUIT', 'EXIT') } { return }
        default {
            Write-Host "Not a valid option." -ForegroundColor Yellow
            Start-Sleep -Milliseconds 800
        }
    }
}
