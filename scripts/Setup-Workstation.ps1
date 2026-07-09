[CmdletBinding()]
param(
    [string]$ToolsRoot = 'C:\Tools',
    [ValidateSet('Setup', 'Update')]
    [string]$Mode = 'Setup'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Headers = @{ 'User-Agent' = 'Setup-Workstation.ps1' }

New-Item -ItemType Directory -Path $ToolsRoot -Force -ErrorAction SilentlyContinue | Out-Null

$KapePath = Join-Path $ToolsRoot 'kape'
$results = @()

function Add-Result {
    param([string]$Component, [string]$Status, [string]$Detail)
    $script:results += [pscustomobject]@{ Component = $Component; Status = $Status; Detail = $Detail }
}

function Get-LatestReleaseAsset {
    param([string]$Repo, [string]$Pattern)
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $Headers
    $asset = $release.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    return [pscustomobject]@{ Tag = $release.tag_name; Asset = $asset }
}

# --- KAPE itself ---
# KAPE requires accepting Kroll's license/registration at https://www.kroll.com/kape - it
# is not available as a plain public download, so this is a manual prerequisite, exactly
# like Forensic_Collector.exe. This script only checks for it and deploys the
# ir-endpoint-investigations module on top once it's present.
Write-Host "=== KAPE core ==="
if (-not (Test-Path (Join-Path $KapePath 'kape.exe'))) {
    Add-Result 'KAPE' 'MANUAL' "kape.exe not found at $KapePath. Download from https://www.kroll.com/kape (requires accepting Kroll's terms) and extract to $KapePath before running this script again."
    Write-Host "kape.exe not found - see manual step in summary." -ForegroundColor Yellow
} else {
    Write-Host "kape.exe found at $KapePath"

    # Deploy this project's own module + scripts onto the KAPE install. Delegates to
    # Deploy-Module.ps1 (a small standalone script) rather than duplicating the copy
    # logic here - run that script directly for a fast redeploy without the rest of
    # this script's slower tool-fetching steps.
    $binDest = Join-Path $KapePath 'Modules\bin'
    $localDest = Join-Path $KapePath 'Modules\!Local'
    try {
        & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File (Join-Path $PSScriptRoot 'Deploy-Module.ps1') -KapePath $KapePath
        if ($LASTEXITCODE -eq 0) {
            Add-Result 'ir-endpoint-investigations module' 'OK' "Deployed Manage-Tools.ps1 / Run-IRParse.ps1 to $binDest and IR_00_ToolVerify.mkape / IR_Compound_Full.mkape to $localDest"
        } else {
            Add-Result 'ir-endpoint-investigations module' 'FAILED' "Deploy-Module.ps1 exited $LASTEXITCODE"
        }
    } catch {
        Add-Result 'ir-endpoint-investigations module' 'FAILED' $_.Exception.Message
    }

    try {
        $manageToolsMode = if ($Mode -eq 'Update') { 'Update' } else { 'Setup' }
        & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File (Join-Path $binDest 'Manage-Tools.ps1') -KapePath $KapePath -Mode $manageToolsMode
        if ($LASTEXITCODE -eq 0) {
            Add-Result 'KAPE toolchain (EZ Tools/Hayabusa/Chainsaw/Hindsight/RegRipper)' 'OK' "Manage-Tools.ps1 -Mode $manageToolsMode succeeded"
        } else {
            Add-Result 'KAPE toolchain (EZ Tools/Hayabusa/Chainsaw/Hindsight/RegRipper)' 'FAILED' "Manage-Tools.ps1 -Mode $manageToolsMode exited $LASTEXITCODE - see its own output above"
        }
    } catch {
        Add-Result 'KAPE toolchain (EZ Tools/Hayabusa/Chainsaw/Hindsight/RegRipper)' 'FAILED' $_.Exception.Message
    }
}

# --- EZ Tools GUI suite (Timeline Explorer, Registry Explorer, EZViewer, etc.) ---
# These are analyst-facing GUI apps, not KAPE processors, so they don't belong in
# Modules\bin - Get-ZimmermanTools.ps1 fetches the whole EZ Tools catalog (GUI + CLI)
# and is idempotent (tracks what it already has in a CSV manifest in $Dest).
Write-Host ""
Write-Host "=== EZ Tools GUI suite (Timeline Explorer, Registry Explorer, EZViewer, ...) ==="
try {
    $guiDest = Join-Path $ToolsRoot 'EZTools-GUI'
    New-Item -ItemType Directory -Path $guiDest -Force -ErrorAction SilentlyContinue | Out-Null
    $getZT = Join-Path $guiDest 'Get-ZimmermanTools.ps1'
    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/EricZimmerman/Get-ZimmermanTools/master/Get-ZimmermanTools.ps1' -Headers $Headers -OutFile $getZT
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File $getZT -Dest $guiDest -NetVersion 9
    Add-Result 'EZ Tools GUI suite' 'OK' "Fetched to $guiDest (Timeline Explorer, Registry Explorer, EZViewer, etc.)"
} catch {
    Add-Result 'EZ Tools GUI suite' 'FAILED' $_.Exception.Message
}

# --- Sysinternals Suite ---
Write-Host ""
Write-Host "=== Sysinternals Suite ==="
try {
    $sysDest = Join-Path $ToolsRoot 'SysinternalsSuite'
    $sysZip = Join-Path $env:TEMP 'SysinternalsSuite.zip'
    Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/SysinternalsSuite.zip' -Headers $Headers -OutFile $sysZip
    New-Item -ItemType Directory -Path $sysDest -Force -ErrorAction SilentlyContinue | Out-Null
    Expand-Archive -LiteralPath $sysZip -DestinationPath $sysDest -Force
    Remove-Item -LiteralPath $sysZip -Force -ErrorAction SilentlyContinue
    Add-Result 'Sysinternals Suite' 'OK' "Extracted to $sysDest"
} catch {
    Add-Result 'Sysinternals Suite' 'FAILED' $_.Exception.Message
}

# --- Autopsy ---
Write-Host ""
Write-Host "=== Autopsy ==="
try {
    $rel = Get-LatestReleaseAsset -Repo 'sleuthkit/autopsy' -Pattern '64bit\.msi$'
    if (-not $rel.Asset) { throw "No 64-bit MSI asset found in latest Autopsy release ($($rel.Tag))" }

    $installedVersion = $null
    $uninstallKeys = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $installed = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Autopsy*' } | Select-Object -First 1
    if ($installed) { $installedVersion = $installed.DisplayVersion }

    if ($Mode -eq 'Update' -and $installedVersion -and ($rel.Tag -match [regex]::Escape($installedVersion))) {
        Add-Result 'Autopsy' 'OK' "Already at latest version ($installedVersion)"
    } else {
        $msiPath = Join-Path $env:TEMP $rel.Asset.name
        Invoke-WebRequest -Uri $rel.Asset.browser_download_url -Headers $Headers -OutFile $msiPath
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msiPath`" /quiet /norestart" -Wait -PassThru
        Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
        if ($p.ExitCode -eq 0) {
            Add-Result 'Autopsy' 'OK' "Installed $($rel.Tag) silently (was: $(if ($installedVersion) { $installedVersion } else { 'not installed' }))"
        } else {
            Add-Result 'Autopsy' 'FAILED' "msiexec exited $($p.ExitCode)"
        }
    }
} catch {
    Add-Result 'Autopsy' 'FAILED' $_.Exception.Message
}

# --- Arsenal Image Mounter ---
# No public GitHub releases - distributed from arsenalrecon.com/downloads via a MEGA
# link that changes every version, so this cannot be scripted reliably. Manual step,
# same handling as KAPE itself.
Write-Host ""
Write-Host "=== Arsenal Image Mounter ==="
Add-Result 'Arsenal Image Mounter' 'MANUAL' 'No scriptable public download (distributed via a MEGA link on https://arsenalrecon.com/downloads that changes per release). Download and extract manually, then launch it once interactively to install its mount driver.'

# --- Summary ---
Write-Host ""
Write-Host "=== Setup-Workstation summary ($Mode) ==="
foreach ($r in $results) {
    $color = switch ($r.Status) { 'OK' { 'Green' }; 'MANUAL' { 'Yellow' }; default { 'Red' } }
    Write-Host ("{0,-55} {1,-7} {2}" -f $r.Component, $r.Status, $r.Detail) -ForegroundColor $color
}

if ($results | Where-Object { $_.Status -eq 'FAILED' }) { exit 1 } else { exit 0 }
