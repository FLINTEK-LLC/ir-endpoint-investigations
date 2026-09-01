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
$script:AwsEnvDir = Join-Path $InfraRoot 'environments\aws-case'
$script:AzureEnvDir = Join-Path $InfraRoot 'environments\azure-case'
# Shared, per-VNet Azure Bastion - deployed ONCE, not per case, and kept in
# its own state (default workspace). See that environment's main.tf for why
# it can't be per-case, and what it costs per hour.
$script:AzureBastionEnvDir = Join-Path $InfraRoot 'environments\azure-bastion'

# ---------------------------------------------------------------------------
# Same prompt-helper pattern as scripts\Start-IRConsole.ps1
# ---------------------------------------------------------------------------

function Read-Default {
    param([string]$Prompt, [string]$Default)
    $val = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val
}

function Read-Required {
    param([string]$Prompt)
    while ($true) {
        $val = Read-Host "$Prompt (blank to cancel)"
        if ([string]::IsNullOrWhiteSpace($val)) { return $null }
        return $val
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $suffix = if ($Default) { 'Y/n' } else { 'y/N' }
    $val = Read-Host "$Prompt [$suffix]"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val.Trim().ToUpper().StartsWith('Y')
}

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
    while ($true) {
        $val = (Read-Host "Cloud provider - AWS or Azure").Trim()
        if ($val -match '(?i)^aws$') { return 'AWS' }
        if ($val -match '(?i)^azure$') { return 'Azure' }
        Write-Host "Enter 'AWS' or 'Azure'." -ForegroundColor Yellow
    }
}

function Wait-ForEnter {
    Write-Host ""
    Read-Host "Press Enter to return to the menu" | Out-Null
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
        })
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
        $restrictions = @($exact.restrictions)
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
        if (@($sku.restrictions).Count -gt 0) { continue }
        $caps = @{}
        foreach ($c in @($sku.capabilities)) { $caps[$c.name] = $c.value }
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

    return @($candidates |
        Sort-Object HasTempDisk, VCpu, Name |
        Select-Object -First 10)
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
        $vars['retention_mode'] = (Read-Default -Prompt "Retention mode (GOVERNANCE/COMPLIANCE)" -Default 'GOVERNANCE').ToUpper()
    }
    $vars['archive_after_days'] = [int](Read-Default -Prompt "Days before automatic transition to cold storage" -Default '30')

    if ($cloud -eq 'AWS') {
        $envDir = $script:AwsEnvDir
        $vars['region'] = Read-Default -Prompt "AWS region" -Default 'us-east-1'
        $vars['aws_profile'] = Read-Default -Prompt "AWS CLI profile" -Default 'ir-cloud'
        Write-Host "The subnet below needs its own outbound internet route (a NAT Gateway) - the investigation host has no public IP by design. Most existing/default VPCs already have this; see infra/README.md if you need to add one." -ForegroundColor Cyan
        $vpcId = Read-Required -Prompt "VPC ID"
        if (-not $vpcId) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
        $vars['vpc_id'] = $vpcId
        $subnetId = Read-Required -Prompt "Subnet ID (within that VPC, with NAT/internet egress)"
        if (-not $subnetId) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
        $vars['subnet_id'] = $subnetId
        $vars['instance_type'] = Read-Default -Prompt "Instance type" -Default 't3.xlarge'
    } else {
        $envDir = $script:AzureEnvDir
        $vars['location'] = Read-Default -Prompt "Azure region" -Default 'eastus'
        Write-Host "The subnet below needs its own outbound internet route - the investigation host has no public IP by design. Most existing VNets already have this." -ForegroundColor Cyan
        Write-Host "Do NOT use the AzureBastionSubnet here - that subnet is reserved for Bastion and cannot hold other resources." -ForegroundColor Cyan
        $subnetId = Read-Required -Prompt "Subnet resource ID for the investigation host"
        if (-not $subnetId) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
        $vars['subnet_id'] = $subnetId

        Write-Host ""
        Write-Host "How should this case's host be reached?" -ForegroundColor Cyan
        Write-Host "  rdp  - public IP + deny-by-default NSG, opened just-in-time to your own IP" -ForegroundColor Cyan
        Write-Host "         when you connect and closed again after. ~`$0.005/hr, and that IP also" -ForegroundColor Cyan
        Write-Host "         gives the host the outbound internet its bootstrap needs." -ForegroundColor Cyan
        Write-Host "  bastion - no public IP at all; connect via the shared Standard Bastion ([8])." -ForegroundColor Cyan
        Write-Host "         Strongest posture, but ~`$0.29/hr and you must supply your own egress" -ForegroundColor Cyan
        Write-Host "         (NAT Gateway) or the bootstrap cannot download anything." -ForegroundColor Cyan
        $accessChoice = ''
        while ($accessChoice -notin @('rdp-allowlist', 'bastion')) {
            $raw = (Read-Default -Prompt "Access method (rdp/bastion)" -Default 'rdp').Trim().ToLower()
            if ($raw -in @('rdp', 'rdp-allowlist')) { $accessChoice = 'rdp-allowlist' }
            elseif ($raw -eq 'bastion') { $accessChoice = 'bastion' }
            else { Write-Host "Enter 'rdp' or 'bastion'." -ForegroundColor Yellow }
        }
        $vars['access_method'] = $accessChoice

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
        $toolsId = Read-Default -Prompt "Tools storage account resource ID (blank = skip)" -Default ''
        if ($toolsId) {
            $vars['tools_storage_account_id'] = $toolsId
            $vars['tools_container_name'] = Read-Default -Prompt "Tools container name" -Default 'irtools'
        }

        $vars['vm_size'] = Format-AzureVmSize (Read-Default -Prompt "VM size" -Default 'Standard_B4s_v2')
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
        Write-Host "terraform apply failed - see output above. No case record was saved; re-run [2] once the underlying issue (credentials, VPC/subnet, quota, etc.) is fixed." -ForegroundColor Red
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
    Write-Host "Known cases: $(($cases | ForEach-Object { "$($_.case_id) ($($_.cloud), $($_.status))" }) -join ', ')"
    $caseId = Read-Required -Prompt $Prompt
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
# Menu
# ---------------------------------------------------------------------------

function Show-Menu {
    Clear-Host
    Write-Host "=================================================="
    Write-Host " ir-endpoint-investigations - Cloud Console"
    Write-Host "=================================================="
    Write-Host " [1] First-time setup (Terraform/AWS CLI/Azure CLI + auth check)"
    Write-Host " [2] Create a new case"
    Write-Host " [3] Build this case's offline collector"
    Write-Host " [4] Connect to the investigation host"
    Write-Host " [5] Destroy the investigation host (evidence storage kept)"
    Write-Host " [6] Archive this case (force cold storage now, optional immutability lock)"
    Write-Host " [7] List cases"
    Write-Host " [L] Lock down a case's RDP now (remove its just-in-time rule)"
    Write-Host ""
    Write-Host " Azure shared Bastion (one per VNet, bills hourly - see infra/README.md):"
    Write-Host " [8] Deploy/update the shared Azure Bastion"
    Write-Host " [9] Destroy the shared Azure Bastion (stops its hourly billing)"
    Write-Host " [Q] Quit"
    Write-Host ""
}

while ($true) {
    Show-Menu
    $choice = (Read-Host "Choose an option").Trim().ToUpper()

    switch ($choice) {
        '1' { Invoke-FirstTimeSetup; Wait-ForEnter }
        '2' { Invoke-CreateCase; Wait-ForEnter }
        '3' { Invoke-BuildCollector; Wait-ForEnter }
        '4' { Invoke-Connect; Wait-ForEnter }
        '5' { Invoke-DestroyHostMenu; Wait-ForEnter }
        '6' { Invoke-ArchiveCase; Wait-ForEnter }
        '7' { Show-CaseList; Wait-ForEnter }
        'L' { Invoke-LockDownCase; Wait-ForEnter }
        '8' { Invoke-DeploySharedBastion; Wait-ForEnter }
        '9' { Invoke-DestroySharedBastion; Wait-ForEnter }
        { $_ -in @('Q', 'QUIT', 'EXIT') } { return }
        default {
            Write-Host "Not a valid option." -ForegroundColor Yellow
            Start-Sleep -Milliseconds 800
        }
    }
}
