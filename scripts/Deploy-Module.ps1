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
# Only IR_00_ToolVerify.mkape and IR_Compound_Full.mkape are ours; IR_Compound_Full
# references KAPE's own stock modules by filename, so there is nothing to patch
# per-collection.
$projectRoot = Split-Path -Parent $PSScriptRoot
$binDest = Join-Path $KapePath 'Modules\bin'
$localDest = Join-Path $KapePath 'Modules\!Local'
New-Item -ItemType Directory -Path $binDest -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $localDest -Force -ErrorAction SilentlyContinue | Out-Null

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Manage-Tools.ps1') -Destination $binDest -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Run-IRParse.ps1') -Destination $binDest -Force
Get-ChildItem -LiteralPath (Join-Path $projectRoot 'Modules\!IR') -Filter 'IR_*.mkape' | Copy-Item -Destination $localDest -Force

Write-Host "Deployed Manage-Tools.ps1 / Run-IRParse.ps1 to $binDest"
Write-Host "Deployed IR_00_ToolVerify.mkape / IR_Compound_Full.mkape to $localDest"
