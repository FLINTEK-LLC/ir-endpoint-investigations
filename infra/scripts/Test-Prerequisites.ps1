<#
.SYNOPSIS
    Checks - and where possible, installs - the prerequisites for the cloud
    IR infrastructure in this folder: Terraform, AWS CLI, Azure CLI, and each
    cloud's authentication state.

.DESCRIPTION
    This is what Start-CloudConsole.ps1's "First-time setup" menu option
    runs. Terraform is a plain binary (same fetch this project already used
    to validate its own modules with) - installed automatically. AWS CLI and
    Azure CLI have official silent-installable MSIs - installed
    automatically too. Authentication itself is never automated: this script
    only checks whether `aws sts get-caller-identity` / `az account show`
    already succeed, and if not, prints the exact one-line command to run
    (`aws configure --profile ir-cloud` / `az login`). Credentials live in
    each CLI's own standard local profile store - see infra/README.md's
    "Accounts, tokens, and secrets" section for why this project doesn't
    invent its own credential storage.

.PARAMETER ToolsRoot
    Where to install Terraform if it isn't already present. Defaults to
    C:\Tools, matching the rest of this repo's own convention.

.PARAMETER SkipInstall
    Report what's missing without attempting to install anything.
#>
[CmdletBinding()]
param(
    [string]$ToolsRoot = 'C:\Tools',

    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Headers = @{ 'User-Agent' = 'Test-Prerequisites.ps1' }

$results = @()
function Add-Result {
    param([string]$Component, [string]$Status, [string]$Detail)
    $script:results += [pscustomobject]@{ Component = $Component; Status = $Status; Detail = $Detail }
}

# A fresh MSI install updates the machine/user PATH in the registry, but this
# already-running process won't see that until it refreshes its own copy.
function Update-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

# Runs a native CLI probe and returns @{ ExitCode; Output } without ever
# throwing, no matter what the tool writes to stderr.
#
# This exists because of a genuinely nasty interaction: capturing a native
# command's output with `2>&1` while $ErrorActionPreference is 'Stop' (as
# it is for this whole script) makes PowerShell wrap each stderr line in a
# terminating ErrorRecord, which throws BEFORE $LASTEXITCODE can be
# inspected - confirmed directly. Every auth probe below is expected to
# fail-and-report on a fresh machine (`aws sts get-caller-identity` with no
# profile, `az account show` when not logged in, both of which write to
# stderr and exit non-zero), so the old inline `2>&1` form crashed this
# script for exactly the first-time user it exists to serve.
function Invoke-CliProbe {
    param([string]$FilePath, [string[]]$CliArgs)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @CliArgs 2>&1
        # Flatten stderr ErrorRecords back to their plain text. Piping them
        # straight to Out-String would carry PowerShell's positional
        # decoration ("At line:N char:M + $output = & $FilePath ...") into
        # whatever we report to the operator, which is noise from this
        # script's own internals, not from the tool being probed.
        $text = ($output | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { $_ }
            } | Out-String).Trim()
        return @{ ExitCode = $LASTEXITCODE; Output = $text }
    } catch {
        return @{ ExitCode = -1; Output = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# AWS CLI/Azure CLI's MSI installers write to Program Files and modify the
# machine PATH, so they need an elevated session - confirmed directly (a
# non-elevated attempt fails with msiexec exit code 1603, MSI's generic
# fatal-error code, which by itself doesn't say why). Checked once up front
# so a non-elevated run gives one clear, actionable message per tool instead
# of a cryptic exit code after a wasted download.
$isElevated = Test-IsElevated
if (-not $isElevated -and -not $SkipInstall) {
    Write-Host "Not running elevated - AWS CLI/Azure CLI installs need an administrator session. Skipping install attempts; re-run this script as Administrator, or install them yourself and re-run to just verify." -ForegroundColor Yellow
}

# --- Terraform ---
Write-Host "=== Terraform ==="
$terraformDir = Join-Path $ToolsRoot 'terraform'
$existingTerraform = Get-Command terraform.exe -ErrorAction SilentlyContinue
$terraformExe = if ($existingTerraform) { $existingTerraform.Source } else { Join-Path $terraformDir 'terraform.exe' }

# Putting the install directory on PATH is not cosmetic: TESTING.md's teardown
# has you run `terraform destroy` by hand, and anything else that shells out to
# a bare `terraform` needs it resolvable. Installing the binary without this
# left `terraform` unrunnable everywhere except by full path.
function Add-ToPath {
    param([string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory)) { return }
    $scope = if ($isElevated) { 'Machine' } else { 'User' }
    try {
        $existing = [Environment]::GetEnvironmentVariable('Path', $scope)
        if ($existing -notlike "*$Directory*") {
            [Environment]::SetEnvironmentVariable('Path', ($existing.TrimEnd(';') + ";$Directory"), $scope)
            Write-Host "Added $Directory to the $scope PATH (new shells will pick it up)."
        }
    } catch {
        Write-Host "Could not update the $scope PATH: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    # Also update THIS session so the console can use it immediately.
    if ($env:Path -notlike "*$Directory*") { $env:Path = $env:Path.TrimEnd(';') + ";$Directory" }
}

if (Test-Path -LiteralPath $terraformExe) {
    $verLine = & $terraformExe version | Select-Object -First 1
    Add-ToPath -Directory (Split-Path -Parent $terraformExe)
    $onPath = [bool](Get-Command terraform -ErrorAction SilentlyContinue)
    Add-Result 'Terraform' 'OK' "$verLine ($terraformExe)$(if (-not $onPath) { ' - NOT on PATH; open a new shell' })"
} elseif ($SkipInstall) {
    Add-Result 'Terraform' 'MISSING' "Not found. Download from https://developer.hashicorp.com/terraform/downloads and extract to $terraformDir, or re-run without -SkipInstall."
} else {
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/hashicorp/terraform/releases/latest' -Headers $Headers
        $version = $release.tag_name.TrimStart('v')
        $zipFile = Join-Path $env:TEMP 'terraform.zip'
        Invoke-WebRequest -Uri "https://releases.hashicorp.com/terraform/$version/terraform_${version}_windows_amd64.zip" -Headers $Headers -OutFile $zipFile
        New-Item -ItemType Directory -Path $terraformDir -Force -ErrorAction SilentlyContinue | Out-Null
        Expand-Archive -LiteralPath $zipFile -DestinationPath $terraformDir -Force
        Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $terraformExe) {
            Add-ToPath -Directory $terraformDir
            Add-Result 'Terraform' 'OK' "Installed $version to $terraformDir (added to PATH)"
        } else {
            Add-Result 'Terraform' 'FAILED' 'Download succeeded but terraform.exe not found after extraction'
        }
    } catch {
        Add-Result 'Terraform' 'FAILED' $_.Exception.Message
    }
}

# --- AWS CLI ---
Write-Host ""
Write-Host "=== AWS CLI ==="
$awsCmd = Get-Command aws -ErrorAction SilentlyContinue
$awsInstallAttempted = $false
if (-not $awsCmd -and -not $SkipInstall -and $isElevated) {
    $awsInstallAttempted = $true
    try {
        $msiPath = Join-Path $env:TEMP 'AWSCLIV2.msi'
        Invoke-WebRequest -Uri 'https://awscli.amazonaws.com/AWSCLIV2.msi' -Headers $Headers -OutFile $msiPath
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msiPath`" /quiet /norestart" -Wait -PassThru
        Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
        if ($p.ExitCode -ne 0) { throw "msiexec exited $($p.ExitCode)" }
        Update-SessionPath
        $awsCmd = Get-Command aws -ErrorAction SilentlyContinue
    } catch {
        Add-Result 'AWS CLI' 'FAILED' $_.Exception.Message
    }
}
if ($awsCmd) {
    $awsVer = (Invoke-CliProbe -FilePath 'aws' -CliArgs @('--version')).Output
    Add-Result 'AWS CLI' 'OK' "$awsVer"

    $identity = Invoke-CliProbe -FilePath 'aws' -CliArgs @('sts', 'get-caller-identity', '--profile', 'ir-cloud')
    if ($identity.ExitCode -eq 0) {
        Add-Result 'AWS auth (profile: ir-cloud)' 'OK' 'aws sts get-caller-identity succeeded'
    } else {
        Add-Result 'AWS auth (profile: ir-cloud)' 'NOT CONFIGURED' 'Run: aws configure --profile ir-cloud  (stores credentials in your own ~/.aws/credentials - this project never sees or stores them)'
    }
} elseif (-not $awsInstallAttempted) {
    $reason = if (-not $isElevated -and -not $SkipInstall) { 'not running elevated, so install was skipped' } else { 'not installed' }
    Add-Result 'AWS CLI' 'MISSING' "Not found and $reason. Download from https://awscli.amazonaws.com/AWSCLIV2.msi and install, or re-run elevated."
}

# --- AWS Session Manager Plugin ---
# Needed by Connect-InvestigationHost.ps1's AWS path (aws ssm start-session
# --document-name AWS-StartPortForwardingSessionToRemoteHost) - the AWS CLI
# alone cannot start a session, only this separate plugin can. Verified
# directly from the plugin's own install.bat (inside the official zip at
# https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPlugin.zip):
# it is a genuinely silent, scriptable install (no interactive installer UI
# like the EXE wrapper) - copies to Program Files, registers a Windows
# service, and adds its \bin folder to the user PATH - but its own
# "net session" check confirms it also needs an elevated session, same as
# the AWS/Azure CLI MSIs above.
Write-Host ""
Write-Host "=== AWS Session Manager Plugin ==="
$ssmPluginDir = "$env:ProgramFiles\Amazon\SessionManagerPlugin"
$ssmPluginExe = Join-Path $ssmPluginDir 'bin\session-manager-plugin.exe'
$ssmPluginCmd = Get-Command session-manager-plugin.exe -ErrorAction SilentlyContinue
$ssmPluginInstallAttempted = $false
if (-not $ssmPluginCmd -and -not (Test-Path -LiteralPath $ssmPluginExe) -and -not $SkipInstall -and $isElevated) {
    $ssmPluginInstallAttempted = $true
    try {
        $zipPath = Join-Path $env:TEMP 'SessionManagerPlugin.zip'
        $extractDir = Join-Path $env:TEMP 'SessionManagerPlugin'
        Invoke-WebRequest -Uri 'https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPlugin.zip' -Headers $Headers -OutFile $zipPath
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
        $installBat = Join-Path $extractDir 'install.bat'
        $p = Start-Process -FilePath $installBat -WorkingDirectory $extractDir -Wait -PassThru -WindowStyle Hidden
        Remove-Item -LiteralPath $zipPath, $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($p.ExitCode -ne 0) { throw "install.bat exited $($p.ExitCode)" }
        Update-SessionPath
        if (Test-Path -LiteralPath $ssmPluginExe) { $ssmPluginCmd = Get-Item $ssmPluginExe }
    } catch {
        Add-Result 'AWS Session Manager Plugin' 'FAILED' $_.Exception.Message
    }
}
if ($ssmPluginCmd -or (Test-Path -LiteralPath $ssmPluginExe)) {
    Add-Result 'AWS Session Manager Plugin' 'OK' 'Installed'
} elseif (-not $ssmPluginInstallAttempted) {
    $reason = if (-not $isElevated -and -not $SkipInstall) { 'not running elevated, so install was skipped' } else { 'not installed' }
    Add-Result 'AWS Session Manager Plugin' 'MISSING' "Not found and $reason. Download from https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPlugin.zip, extract, and run install.bat as Administrator, or re-run this script elevated."
}

# --- Azure CLI ---
Write-Host ""
Write-Host "=== Azure CLI ==="
$azCmd = Get-Command az -ErrorAction SilentlyContinue -CommandType Application
$azInstallAttempted = $false
if (-not $azCmd -and -not $SkipInstall -and $isElevated) {
    $azInstallAttempted = $true
    try {
        $msiPath = Join-Path $env:TEMP 'AzureCLI.msi'
        Invoke-WebRequest -Uri 'https://aka.ms/installazurecliwindows' -Headers $Headers -OutFile $msiPath
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msiPath`" /quiet /norestart" -Wait -PassThru
        Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
        if ($p.ExitCode -ne 0) { throw "msiexec exited $($p.ExitCode)" }
        Update-SessionPath
        $azCmd = Get-Command az -ErrorAction SilentlyContinue -CommandType Application
    } catch {
        Add-Result 'Azure CLI' 'FAILED' $_.Exception.Message
    }
}
if ($azCmd) {
    $azVerProbe = Invoke-CliProbe -FilePath 'az' -CliArgs @('version')
    $azVer = ($azVerProbe.Output | ConvertFrom-Json -ErrorAction SilentlyContinue).'azure-cli'
    Add-Result 'Azure CLI' 'OK' "$(if ($azVer) { "v$azVer" } else { 'installed' })"

    $account = Invoke-CliProbe -FilePath 'az' -CliArgs @('account', 'show')
    if ($account.ExitCode -eq 0) {
        $accountName = ($account.Output | ConvertFrom-Json -ErrorAction SilentlyContinue).name
        Add-Result 'Azure auth' 'OK' "Logged in ($accountName)"

        # Data-plane RBAC is a separate thing from subscription Owner, and this
        # trips people up constantly. Microsoft's own wording: "Built-in roles
        # such as Owner, Contributor, and Storage Account Contributor permit a
        # security principal to manage a storage account, but don't provide
        # access to the blob data within that account." Without a Storage Blob
        # Data role, [3] Build collector fails when it mints a user-delegation
        # SAS, and [6] Archive fails listing blobs - both only AFTER you have
        # already paid for a VM and waited for it to bootstrap. Check up front.
        $me = Invoke-CliProbe -FilePath 'az' -CliArgs @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv')
        if ($me.ExitCode -eq 0 -and $me.Output) {
            $roles = Invoke-CliProbe -FilePath 'az' -CliArgs @(
                'role', 'assignment', 'list', '--assignee', $me.Output.Trim(),
                '--include-inherited', '--all',
                '--query', "[?contains(roleDefinitionName,'Storage Blob Data')].roleDefinitionName",
                '-o', 'tsv')
            if ($roles.ExitCode -eq 0 -and $roles.Output.Trim()) {
                Add-Result 'Azure blob data access' 'OK' ("Has " + (($roles.Output -split '
?
' | Where-Object { $_ } | Select-Object -Unique) -join ', '))
            } else {
                Add-Result 'Azure blob data access' 'NOT CONFIGURED' 'No Storage Blob Data role found. Subscription Owner is NOT enough for blob DATA (Microsoft: Owner "does not provide access to the blob data"). [3] Build collector and [6] Archive will fail. Fix: az role assignment create --assignee <you> --role "Storage Blob Data Contributor" --scope /subscriptions/<sub-id>'
            }
        }
    } else {
        Add-Result 'Azure auth' 'NOT CONFIGURED' 'Run: az login  (uses the Azure CLI''s own local token cache - this project never sees or stores your credentials)'
    }
} elseif (-not $azInstallAttempted) {
    $reason = if (-not $isElevated -and -not $SkipInstall) { 'not running elevated, so install was skipped' } else { 'not installed' }
    Add-Result 'Azure CLI' 'MISSING' "Not found and $reason. Download from https://aka.ms/installazurecliwindows and install, or re-run elevated."
}

# --- Summary ---
Write-Host ""
Write-Host "=== Prerequisites summary ==="
foreach ($r in $results) {
    $color = switch ($r.Status) {
        'OK'             { 'Green' }
        'NOT CONFIGURED' { 'Yellow' }
        'MISSING'        { 'Yellow' }
        default          { 'Red' }
    }
    Write-Host ("{0,-30} {1,-15} {2}" -f $r.Component, $r.Status, $r.Detail) -ForegroundColor $color
}

if ($results | Where-Object { $_.Status -in @('FAILED', 'MISSING') }) { exit 1 } else { exit 0 }
