<#
.SYNOPSIS
    Runs Run-IRParse.ps1 against every host collection under one case
    folder, then builds a cross-host rollup of the fast-triage output for
    spotting patterns across multiple endpoints (e.g. the same scheduled
    task or account change landing on several hosts around the same time).

.DESCRIPTION
    Point this at a folder containing one subfolder per host - each
    subfolder should itself be an extracted Velociraptor collection (i.e.
    contains its own `uploads\` folder), the same thing you'd otherwise pass
    to Run-IRParse.ps1 -CollectionRoot one at a time:

        D:\Cases\2026-07-INC1234\
          HOST01\uploads\...
          HOST02\uploads\...
          HOST03\uploads\...

    Each host subfolder's name is used as its label in the rollup - name
    them after the actual hostnames.

.PARAMETER CaseRoot
    Folder containing one subfolder per host collection.

.PARAMETER KapePath
    Passed through to Run-IRParse.ps1 for each host. Defaults to
    auto-detection there if not specified.

.PARAMETER SkipTriagePostProcessing
    Passed through to Run-IRParse.ps1 for each host. If set, the cross-host
    rollup at the end will have nothing to work with (it reads each host's
    EvtxTriage.csv/InterestingFiles.csv) and is skipped with a note.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CaseRoot,

    [string]$KapePath,

    [switch]$SkipTriagePostProcessing
)

$ErrorActionPreference = 'Stop'

$CaseRoot = (Resolve-Path -LiteralPath $CaseRoot).Path
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$hostDirs = Get-ChildItem -LiteralPath $CaseRoot -Directory | Where-Object {
    Test-Path -LiteralPath (Join-Path $_.FullName 'uploads') -PathType Container
}

if (-not $hostDirs) {
    Write-Host "No host collections found under $CaseRoot - expected one subfolder per host, each containing its own uploads\ folder." -ForegroundColor Red
    exit 1
}

Write-Host "Found $($hostDirs.Count) host collection(s) under $CaseRoot`:"
$hostDirs | ForEach-Object { Write-Host "  $($_.Name)" }

$results = @()
foreach ($hostDir in $hostDirs) {
    Write-Host ""
    Write-Host "=== $($hostDir.Name) ==="
    $argList = @('-ExecutionPolicy', 'Bypass', '-NonInteractive', '-File', (Join-Path $scriptDir 'Run-IRParse.ps1'), '-CollectionRoot', $hostDir.FullName)
    if ($KapePath) { $argList += @('-KapePath', $KapePath) }
    if ($SkipTriagePostProcessing) { $argList += '-SkipTriagePostProcessing' }

    # Spawned as a separate process per host, same reasoning as elsewhere in this
    # project - Run-IRParse.ps1's own `exit` must not terminate this wrapper.
    & powershell.exe @argList
    $exitCode = $LASTEXITCODE
    $results += [pscustomobject]@{
        Host   = $hostDir.Name
        Status = if ($exitCode -eq 0) { 'OK' } else { 'FAILED' }
        Exit   = $exitCode
    }
}

Write-Host ""
Write-Host "=== Case summary: $CaseRoot ==="
foreach ($r in $results) {
    $color = if ($r.Status -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host ("{0,-20} {1,-8} (exit {2})" -f $r.Host, $r.Status, $r.Exit) -ForegroundColor $color
}

# --- Cross-host rollup ---
# Combines each host's already-curated fast-triage CSVs (not the full raw output - that
# would be enormous across many hosts) into one case-wide, chronologically sorted view
# with a SourceHost column, for spotting the same activity landing on multiple endpoints.
if (-not $SkipTriagePostProcessing) {
    Write-Host ""
    Write-Host "=== Cross-host rollup ==="
    $rollupDir = Join-Path $CaseRoot 'CaseRollup'
    New-Item -ItemType Directory -Path $rollupDir -Force | Out-Null

    $rollupSpecs = @(
        @{ Name = 'All-Hosts-EvtxTriage.csv';      RelPath = 'results\EventLogs\EvtxTriage.csv';         SortCol = 'TimeCreated' }
        @{ Name = 'All-Hosts-InterestingFiles.csv'; RelPath = 'results\FileSystem\InterestingFiles.csv'; SortCol = 'Created0x10' }
    )

    foreach ($spec in $rollupSpecs) {
        $combined = foreach ($hostDir in $hostDirs) {
            $csvPath = Join-Path $hostDir.FullName $spec.RelPath
            if (Test-Path -LiteralPath $csvPath) {
                Import-Csv -LiteralPath $csvPath | Select-Object @{ Name = 'SourceHost'; Expression = { $hostDir.Name } }, *
            }
        }
        if ($combined) {
            $combined = $combined | Sort-Object $spec.SortCol
            $combined | Export-Csv -LiteralPath (Join-Path $rollupDir $spec.Name) -NoTypeInformation
            Write-Host "Wrote $($combined.Count) row(s) across $($hostDirs.Count) host(s) to $($spec.Name)"
        } else {
            Write-Host "No data found for $($spec.Name) - skipping"
        }
    }
}

if ($results | Where-Object { $_.Status -eq 'FAILED' }) { exit 1 } else { exit 0 }
