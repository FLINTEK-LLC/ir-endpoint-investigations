<#
.SYNOPSIS
    Opens a Remote Desktop session to a case's investigation host, through
    the free, portless broker for that cloud - no open inbound port, no
    public IP, ever.

.DESCRIPTION
    AWS: starts an SSM Session Manager port-forwarding session (the
    AWS-StartPortForwardingSessionToRemoteHost document) from a random local
    port to the instance's own RDP port, then launches mstsc.exe against
    that local port. The forwarding session runs as a background job for as
    long as mstsc is open; closing mstsc (or Ctrl+C in this console) tears
    the tunnel down.

    Azure: depends on the case's access_method.
      rdp-allowlist (default) - the host has a public IP behind an NSG that
        denies all inbound. This detects your current public IP, opens 3389
        to that /32 alone, launches mstsc, then removes the rule again when
        the RDP window closes. Just-in-time, so the port is not left open
        for the life of the case.
      bastion - no public IP on the host; connects through the shared
        Standard Bastion via `az network bastion rdp`.

    Requires the case's infrastructure to already exist (via Terraform, in
    its own workspace) - this script only reads that state, same as
    New-CaseCollector.ps1.

.PARAMETER CaseId
    Case identifier - must match the terraform workspace name used when
    the case's infrastructure was created (see infra/README.md).

.PARAMETER CloudProvider
    AWS or Azure.

.PARAMETER InfraRoot
    Path to the infra/ folder. Defaults to this script's own parent's
    parent (infra/scripts/.. = infra/).

.PARAMETER AwsProfile
    AWS CLI profile to authenticate with.

.PARAMETER LocalPort
    AWS only - local TCP port the tunnel listens on. Defaults to 13389 so
    it never collides with a real local RDP listener on 3389.

.PARAMETER KeepOpen
    Azure rdp-allowlist only - leave the just-in-time NSG rule in place after
    the RDP window closes, instead of removing it. Use when you expect to
    reconnect repeatedly; close it afterwards with -CloseOnly.

.PARAMETER CloseOnly
    Azure rdp-allowlist only - remove the just-in-time NSG rule and exit
    without connecting. The "lock it back down" half of -KeepOpen.

.EXAMPLE
    .\Connect-InvestigationHost.ps1 -CaseId acme-2026-001 -CloudProvider AWS

.EXAMPLE
    .\Connect-InvestigationHost.ps1 -CaseId acme-2026-001 -CloudProvider Azure
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$')]
    [string]$CaseId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('AWS', 'Azure')]
    [string]$CloudProvider,

    [string]$InfraRoot = '',

    [string]$AwsProfile = 'ir-cloud',

    [int]$LocalPort = 13389,

    [switch]$KeepOpen,

    [switch]$CloseOnly,

    # Distinctive so it is obvious in the portal what created it, and so
    # Remove-JitRule never deletes a rule someone else added by hand.
    [string]$JitRuleName = 'ir-jit-rdp'
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

function Remove-JitRule {
    # Best-effort teardown of the just-in-time RDP rule. Deliberately does not
    # throw: failing to connect is recoverable, but leaving the port open
    # silently is the thing worth shouting about, so a failure here prints a
    # copy-pasteable command rather than an exception the caller might swallow.
    param([string]$ResourceGroup, [string]$NsgName)
    Write-Host "Removing JIT RDP rule '$JitRuleName' from NSG '$NsgName'..." -ForegroundColor DarkGray
    & az network nsg rule delete --resource-group $ResourceGroup --nsg-name $NsgName --name $JitRuleName --output none
    if ($LASTEXITCODE -eq 0) {
        Write-Host "RDP is closed again - the NSG now denies all inbound." -ForegroundColor Green
    } else {
        Write-Host "WARNING: could not remove the JIT rule. THE RDP PORT MAY STILL BE OPEN." -ForegroundColor Red
        Write-Host "  az network nsg rule delete -g $ResourceGroup --nsg-name $NsgName -n $JitRuleName" -ForegroundColor Red
    }
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
    # Identical to New-CaseCollector.ps1's function of the same name - see
    # that script for why stderr is deliberately NOT redirected with 2>&1
    # here (it turns a normal "workspace does not exist" message into an
    # uncatchable terminating error under $ErrorActionPreference = 'Stop').
    # Duplicated rather than dot-sourced so each script has no hard
    # dependency on the other's file layout.
    param([string]$EnvDir, [string]$CaseId)
    $tf = Get-TerraformExe
    if (-not $tf) { throw "terraform not found on PATH or in C:\Tools\terraform - run infra\scripts\Test-Prerequisites.ps1 first." }
    Push-Location $EnvDir
    try {
        & $tf workspace select $CaseId | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "No case found with ID '$CaseId' in $EnvDir (terraform workspace select failed - see Terraform's own message above). Create the case's infrastructure first - see infra/README.md."
        }
        $json = & $tf output -json
        if ($LASTEXITCODE -ne 0) {
            throw "terraform output failed for case '$CaseId' in $EnvDir. Has 'terraform apply' completed successfully for this case?"
        }
        $raw = $json | ConvertFrom-Json
        $result = [ordered]@{}
        foreach ($prop in $raw.PSObject.Properties) { $result[$prop.Name] = $prop.Value.value }
        return [pscustomobject]$result
    } finally {
        Pop-Location
    }
}

if ($CloudProvider -eq 'AWS') {
    $envDir = Join-Path $InfraRoot 'environments\aws-case'
    $tfOut = Get-CaseTerraformOutput -EnvDir $envDir -CaseId $CaseId
    $instanceId = $tfOut.instance_id
    $region = $tfOut.region
    $adminPassword = $tfOut.admin_password
    if (-not $instanceId) {
        throw "Missing expected Terraform output (instance_id) for case '$CaseId'."
    }

    if (-not (Get-Command session-manager-plugin.exe -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath "$env:ProgramFiles\Amazon\SessionManagerPlugin\bin\session-manager-plugin.exe")) {
        throw "AWS Session Manager Plugin not found - run infra\scripts\Test-Prerequisites.ps1 (elevated) first."
    }

    Write-Host "Starting SSM port-forwarding tunnel: localhost:$LocalPort -> $instanceId`:3389 ..."

    # Parameters go as AWS CLI SHORTHAND, not JSON. Start-Process delivers
    # -ArgumentList by joining it into one command line and strips embedded
    # double quotes on the way - confirmed directly, the JSON arrived as
    # {host:[localhost],portNumber:[3389]} with every quote gone, which the
    # CLI rejects with exit code 252 (invalid parameters). Shorthand has no
    # quotes or braces to lose.
    #
    # AWS-StartPortForwardingSession (not ...ToRemoteHost) is the right
    # document here: we are forwarding a port ON the instance, not through
    # it to some third host, so it needs no host parameter at all.
    $tunnelArgs = @(
        'ssm', 'start-session',
        '--target', $instanceId,
        '--document-name', 'AWS-StartPortForwardingSession',
        '--parameters', "portNumber=3389,localPortNumber=$LocalPort",
        '--profile', $AwsProfile,
        '--region', $region
    )

    # Capture the tunnel output. Previously this ran in its own window which
    # closed the instant it failed, so the actual error was unreadable and
    # all the operator saw was an exit code.
    $tunnelOut = Join-Path $env:TEMP "ssm-tunnel-$CaseId.out.log"
    $tunnelErr = Join-Path $env:TEMP "ssm-tunnel-$CaseId.err.log"
    $tunnelProcess = Start-Process -FilePath 'aws' -ArgumentList $tunnelArgs -PassThru `
        -RedirectStandardOutput $tunnelOut -RedirectStandardError $tunnelErr
    Write-Host "Tunnel starting (PID $($tunnelProcess.Id))..."
    Start-Sleep -Seconds 5

    if ($tunnelProcess.HasExited) {
        Write-Host ""
        Write-Host "The SSM tunnel exited immediately (code $($tunnelProcess.ExitCode))." -ForegroundColor Red
        foreach ($logPath in @($tunnelErr, $tunnelOut)) {
            $text = (Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue)
            if ($text -and $text.Trim()) {
                Write-Host "--- $(Split-Path $logPath -Leaf) ---" -ForegroundColor DarkGray
                Write-Host $text.Trim()
            }
        }
        Write-Host ""
        Write-Host "Most likely causes, in order:" -ForegroundColor Yellow
        Write-Host "  * The instance is not registered with SSM yet. Check with:" -ForegroundColor Yellow
        Write-Host "      aws ssm describe-instance-information --region $region --profile $AwsProfile --query \"InstanceInformationList[].InstanceId\" --output text" -ForegroundColor Yellow
        Write-Host "    If your instance never appears, its subnet has no route out - see infra/TESTING-AWS.md Step 5." -ForegroundColor Yellow
        Write-Host "  * The Session Manager plugin is missing - re-run [1] elevated." -ForegroundColor Yellow
        throw "SSM tunnel failed to start - see above."
    }

    Write-Host "Launching Remote Desktop against localhost:$LocalPort ..."
    if ($adminPassword) {
        Write-Host ""
        Write-Host "Sign in as: Administrator" -ForegroundColor Cyan
        Write-Host "Password:   $adminPassword" -ForegroundColor Cyan
        Write-Host "(fetched fresh from Terraform state - never stored in infra\.cases\ bookkeeping. Clear your terminal scrollback after signing in if this session is shared/recorded.)" -ForegroundColor DarkGray
    } else {
        Write-Host "Sign in with the local Administrator account or a domain/AD credential valid on this host - Bastion/SSM only broker the network path, not authentication."
    }
    Start-Process -FilePath 'mstsc.exe' -ArgumentList "/v:localhost:$LocalPort"

    Write-Host ""
    Write-Host "Close the 'aws ssm start-session' window (PID $($tunnelProcess.Id)) when you're done to tear down the tunnel." -ForegroundColor Yellow
} else {
    $envDir = Join-Path $InfraRoot 'environments\azure-case'
    $tfOut = Get-CaseTerraformOutput -EnvDir $envDir -CaseId $CaseId
    $vmId = $tfOut.vm_id
    $adminPassword = $tfOut.admin_password
    $adminUsername = $tfOut.admin_username
    $accessMethod = $tfOut.access_method
    $resourceGroup = $tfOut.resource_group_name

    if ($adminPassword) {
        Write-Host ""
        Write-Host "Sign in as: $adminUsername" -ForegroundColor Cyan
        Write-Host "Password:   $adminPassword" -ForegroundColor Cyan
        Write-Host "(fetched fresh from Terraform state - never stored in infra\.cases\ bookkeeping. Clear your terminal scrollback after signing in if this session is shared/recorded.)" -ForegroundColor DarkGray
        Write-Host ""
    }

    if ($accessMethod -eq 'rdp-allowlist') {
        $publicIp = $tfOut.public_ip_address
        $nsgName = $tfOut.nsg_name
        if (-not $publicIp -or -not $nsgName) {
            throw "Case '$CaseId' uses rdp-allowlist but is missing public_ip_address/nsg_name outputs. Re-run [2], or confirm 'terraform apply' completed."
        }

        if ($CloseOnly) {
            Remove-JitRule -ResourceGroup $resourceGroup -NsgName $nsgName
            return
        }

        # Just-in-time access. The NSG carries no allow rules of its own, so
        # Azure's built-in DenyAllInBound (priority 65500) blocks everything.
        # This adds ONE rule permitting 3389 from this machine's current public
        # address only, and removes it when the RDP window closes - the port is
        # not left open for the life of the case. Done with `az` rather than
        # Terraform because the module deliberately manages no security_rule
        # entries (the provider only clears inline rules when explicitly set to
        # an empty slice), so nothing drifts.
        Write-Host "Detecting this machine's public IP..."
        $myIp = $null
        foreach ($svc in 'https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com') {
            try {
                $candidate = (Invoke-RestMethod -Uri $svc -TimeoutSec 10 | Out-String).Trim()
                if ($candidate -match '^\d{1,3}(\.\d{1,3}){3}$') { $myIp = $candidate; break }
            } catch { }
        }
        if (-not $myIp) {
            throw "Could not determine this machine's public IP from any lookup service. Open the port by hand, then re-run with -SkipJit:`n  az network nsg rule create -g $resourceGroup --nsg-name $nsgName -n $JitRuleName --priority 100 --access Allow --protocol Tcp --direction Inbound --destination-port-ranges 3389 --source-address-prefixes <your-ip>/32"
        }
        Write-Host "Your public IP is $myIp - opening RDP to $myIp/32 only." -ForegroundColor Cyan

        # create fails if the rule already exists (e.g. a previous session left
        # it, or your IP changed) - fall back to updating it rather than dying.
        & az network nsg rule create `
            --resource-group $resourceGroup --nsg-name $nsgName --name $JitRuleName `
            --priority 100 --access Allow --protocol Tcp --direction Inbound `
            --destination-port-ranges 3389 --source-address-prefixes "$myIp/32" `
            --output none
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Rule '$JitRuleName' already present - updating it to your current IP..." -ForegroundColor DarkGray
            & az network nsg rule update `
                --resource-group $resourceGroup --nsg-name $nsgName --name $JitRuleName `
                --source-address-prefixes "$myIp/32" --output none
            if ($LASTEXITCODE -ne 0) {
                throw "Could not create or update the JIT RDP rule on NSG '$nsgName' in resource group '$resourceGroup'. Confirm 'az login' is active and your account can modify this NSG."
            }
        }

        Write-Host "Launching Remote Desktop to $publicIp ..." -ForegroundColor Cyan
        $rdp = Start-Process -FilePath 'mstsc.exe' -ArgumentList "/v:$publicIp" -PassThru

        Write-Host ""
        if ($KeepOpen) {
            Write-Host "RDP left OPEN to $myIp/32 (-KeepOpen). Close it when finished with:" -ForegroundColor Yellow
            Write-Host "  .\Connect-InvestigationHost.ps1 -CaseId $CaseId -CloudProvider Azure -CloseOnly" -ForegroundColor Yellow
        } else {
            Write-Host "RDP open to $myIp/32. Waiting for the Remote Desktop window to close, then locking it back down..." -ForegroundColor DarkGray
            if ($rdp) { $rdp.WaitForExit() }
            Remove-JitRule -ResourceGroup $resourceGroup -NsgName $nsgName
        }
    } else {
        $bastionName = $tfOut.bastion_name
        $bastionResourceGroup = $tfOut.bastion_resource_group_name
        $bastionSku = $tfOut.bastion_sku
        if (-not $vmId -or -not $bastionName -or -not $bastionResourceGroup) {
            throw "Case '$CaseId' uses access_method 'bastion' but bastion_name/bastion_resource_group_name are missing. Deploy the shared Bastion (option [8]) and re-run [2]."
        }
        if ($bastionSku -eq 'Developer') {
            $portalUrl = "https://portal.azure.com/#@/resource$vmId/bastion"
            Write-Host "This Bastion is the free Developer SKU - browser connection only." -ForegroundColor Yellow
            Write-Host "  $portalUrl" -ForegroundColor Cyan
            try { Start-Process $portalUrl | Out-Null } catch { }
            return
        }
        Write-Host "Launching Remote Desktop via Azure Bastion ('$bastionName' in $bastionResourceGroup)..."
        & az network bastion rdp `
            --name $bastionName --resource-group $bastionResourceGroup --target-resource-id $vmId
        if ($LASTEXITCODE -ne 0) {
            throw "az network bastion rdp failed. Check: 'az login' is active; the shared Bastion exists and is Standard SKU with tunneling enabled (option [8]); the VM is running in the VNet that Bastion serves. See infra/README.md."
        }
    }
}
