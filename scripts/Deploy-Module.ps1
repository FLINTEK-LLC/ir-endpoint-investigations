[CmdletBinding()]
param(
    [string]$KapePath = 'C:\Tools\KAPE'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path (Join-Path $KapePath 'kape.exe'))) {
    Write-Host "kape.exe not found at $KapePath. Install KAPE there first (https://www.kroll.com/kape, requires accepting Kroll's terms), then re-run this script." -ForegroundColor Red
    exit 1
}

# Modules go to !Local rather than !IR since that's the folder KAPE's own sync
# preserves (Manage-Tools.ps1 -Mode Update moves unrecognized custom .mkape files
# there automatically) - see README.md "How it works" / "Update cadence" for why.
# Everything under Modules\!IR\ is ours (IR_Compound_Full plus a small, growing set
# of custom modules it references - IR_00_ToolVerify, and any stock module this
# project has had to replace) - IR_Compound_Full references KAPE's own stock modules
# by filename otherwise, so there is nothing to patch per-collection.
$projectRoot = Split-Path -Parent $PSScriptRoot
$binDest = Join-Path $KapePath 'Modules\bin'
$localDest = Join-Path $KapePath 'Modules\!Local'
New-Item -ItemType Directory -Path $binDest -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $localDest -Force -ErrorAction SilentlyContinue | Out-Null

# Every script in this folder except Setup-Workstation.ps1, Start-IRConsole.ps1, and
# this script itself runs on the KAPE install, not just the analyst's checkout -
# deployed in bulk so a new script added here doesn't also require a matching edit here.
$deployedScripts = Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' |
    Where-Object { $_.Name -notin @('Deploy-Module.ps1', 'Setup-Workstation.ps1', 'Start-IRConsole.ps1') }
$deployedScripts | Copy-Item -Destination $binDest -Force
$deployedModules = Get-ChildItem -LiteralPath (Join-Path $projectRoot 'Modules\!IR') -Filter 'IR_*.mkape'
$deployedModules | Copy-Item -Destination $localDest -Force

Write-Host "Deployed $($deployedScripts.Name -join ', ') to $binDest"
Write-Host "Deployed $($deployedModules.Name -join ', ') to $localDest"
