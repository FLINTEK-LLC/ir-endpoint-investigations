<#
.SYNOPSIS
    First-boot entry point run by both cloud modules (AWS user_data, Azure's
    Custom Script Extension) - downloads the ir-endpoint-investigations repo
    and hands off to bootstrap-investigation-host.ps1.

.DESCRIPTION
    Kept deliberately tiny and shared between both clouds rather than
    duplicated in each module's own bootstrap mechanism (AWS EC2 user_data,
    Azure's Custom Script Extension) - the actual toolkit/mount/hardening
    logic lives in one place (bootstrap-investigation-host.ps1), not
    forked per cloud.

    Downloads the repo as a plain zip (Invoke-WebRequest + Expand-Archive) -
    no git dependency, since a stock Windows Server image doesn't have git
    installed and this needs to work on a completely clean VM.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CaseId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('AWS', 'Azure')]
    [string]$CloudProvider,

    # S3 bucket name (AWS) or "<storage-account>/<container>" (Azure).
    [Parameter(Mandatory = $true)]
    [string]$StorageIdentifier,

    [Parameter(Mandatory = $true)]
    [string]$Region,

    [string]$RepoZipUrl = 'https://github.com/FLINTEK-LLC/ir-endpoint-investigations/archive/refs/heads/main.zip',

    # Optional "<account>/<container>" holding licensed tooling (KAPE) the
    # host cannot fetch for itself. Empty means "no tools storage configured".
    [string]$ToolsStorageIdentifier = '',

    # Optional plain URL to fetch kape.zip from, used only when
    # ToolsStorageIdentifier is empty. May itself carry authorisation
    # (a share link / SAS), so treat it as a secret.
    [string]$ToolsZipUrl = '',

    # Forwarded straight through to bootstrap-investigation-host.ps1. This
    # script is a pass-through shim, so every parameter the launchers send
    # must be declared here even when it means nothing to this file - an
    # undeclared one is a hard ParameterBindingException that kills the whole
    # bootstrap before it starts.
    [string]$TimeZoneId = 'UTC'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$logFile = 'C:\ir-bootstrap-fetch.log'

function Write-Log {
    param([string]$Message)
    "$(Get-Date -Format 'u')  $Message" | Out-File -FilePath $logFile -Append
}

try {
    Write-Log "Fetching $RepoZipUrl"
    Invoke-WebRequest -Uri $RepoZipUrl -OutFile 'C:\ir-repo.zip'

    Write-Log 'Extracting'
    Expand-Archive -LiteralPath 'C:\ir-repo.zip' -DestinationPath 'C:\ir-repo' -Force
    Remove-Item -LiteralPath 'C:\ir-repo.zip' -Force -ErrorAction SilentlyContinue

    # GitHub's zip wraps everything in one "<repo>-<branch>" folder.
    $repoRoot = Get-ChildItem -LiteralPath 'C:\ir-repo' -Directory | Select-Object -First 1
    if (-not $repoRoot) { throw "No folder found after extracting $RepoZipUrl - unexpected zip layout" }

    $bootstrapScript = Join-Path $repoRoot.FullName 'infra\scripts\bootstrap-investigation-host.ps1'
    if (-not (Test-Path -LiteralPath $bootstrapScript)) {
        throw "bootstrap-investigation-host.ps1 not found at $bootstrapScript"
    }

    Write-Log "Handing off to $bootstrapScript"
    & $bootstrapScript -CaseId $CaseId -CloudProvider $CloudProvider -StorageIdentifier $StorageIdentifier -Region $Region -RepoRoot $repoRoot.FullName -ToolsStorageIdentifier $ToolsStorageIdentifier -ToolsZipUrl $ToolsZipUrl -TimeZoneId $TimeZoneId *>> $logFile

    Write-Log "bootstrap-investigation-host.ps1 exited $LASTEXITCODE"
} catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    throw
}
