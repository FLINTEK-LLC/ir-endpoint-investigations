<#
.SYNOPSIS
    Runs Run-IRParse.ps1 against every host collection under one case
    folder, then builds a cross-host rollup of the fast-triage output for
    spotting patterns across multiple endpoints (e.g. the same scheduled
    task or account change landing on several hosts around the same time).

.DESCRIPTION
    Point this at a folder containing one host collection per entry - each
    entry is either a subfolder that's itself an extracted Velociraptor
    collection (contains its own `uploads\` folder), or a collection `.zip`
    straight off the collector, the same either way you'd otherwise pass to
    Run-IRParse.ps1 -CollectionRoot one at a time. Drop zips in as you
    receive them - no need to extract each one yourself first:

        D:\Cases\2026-07-INC1234\
          HOST01\uploads\...
          HOST02.zip
          HOST03.zip

    A zip is extracted next to itself (same as Run-IRParse.ps1's own
    default), reused on later runs, and its label in the rollup/case summary
    is its filename without `.zip`. An already-extracted subfolder's label is
    just its folder name - name folders after the actual hostnames.

.PARAMETER CaseRoot
    Folder containing one host collection per entry - an extracted-collection
    subfolder, a collection .zip, or a mix of both.

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

function Resolve-HostCollectionRoot {
    # Mirrors Run-IRParse.ps1's own default zip-extraction path/flatten resolution,
    # so the rollup step below can find <extracted>\results\... for a zip-based host
    # without re-extracting or having Run-IRParse.ps1 report its resolved path back.
    param([string]$Path)
    if ((Get-Item -LiteralPath $Path).PSIsContainer) { return $Path }
    $extractPath = Join-Path (Split-Path -Parent $Path) ([IO.Path]::GetFileNameWithoutExtension($Path))
    if (Test-Path -LiteralPath (Join-Path $extractPath 'uploads') -PathType Container) { return $extractPath }
    $wrapper = Get-ChildItem -LiteralPath $extractPath -Directory -ErrorAction SilentlyContinue
    if ($wrapper.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $wrapper[0].FullName 'uploads') -PathType Container)) { return $wrapper[0].FullName }
    return $extractPath
}

$hostZips = @(Get-ChildItem -LiteralPath $CaseRoot -File -Filter '*.zip' | ForEach-Object {
    [pscustomobject]@{ Name = [IO.Path]::GetFileNameWithoutExtension($_.Name); SourcePath = $_.FullName }
})
$zipBaseNames = @($hostZips | ForEach-Object { $_.Name })

# A folder whose name exactly matches a zip's own name (minus .zip) is that zip's
# default extraction destination (Run-IRParse.ps1's -ExtractPath default), not an
# independently-provided host - excluded here so re-running against the same case
# folder after a zip has already been extracted once doesn't double-count that host.
$hostDirs = @(Get-ChildItem -LiteralPath $CaseRoot -Directory | Where-Object {
    (Test-Path -LiteralPath (Join-Path $_.FullName 'uploads') -PathType Container) -and
    ($_.Name -notin $zipBaseNames)
} | ForEach-Object { [pscustomobject]@{ Name = $_.Name; SourcePath = $_.FullName } })
$hostItems = @($hostDirs) + @($hostZips)

if (-not $hostItems) {
    Write-Host "No host collections found under $CaseRoot - expected one subfolder per host (each with its own uploads\ folder) or one collection .zip per host." -ForegroundColor Red
    exit 1
}

Write-Host "Found $($hostItems.Count) host collection(s) under $CaseRoot`:"
$hostItems | ForEach-Object { Write-Host "  $($_.Name)" }

$results = @()
foreach ($item in $hostItems) {
    Write-Host ""
    Write-Host "=== $($item.Name) ==="
    $argList = @('-ExecutionPolicy', 'Bypass', '-NonInteractive', '-File', (Join-Path $scriptDir 'Run-IRParse.ps1'), '-CollectionRoot', $item.SourcePath)
    if ($KapePath) { $argList += @('-KapePath', $KapePath) }
    if ($SkipTriagePostProcessing) { $argList += '-SkipTriagePostProcessing' }

    # Spawned as a separate process per host, same reasoning as elsewhere in this
    # project - Run-IRParse.ps1's own `exit` must not terminate this wrapper. Also
    # where a .zip host gets extracted, via Run-IRParse.ps1's own -CollectionRoot
    # handling - nothing extraction-specific needed in this wrapper.
    & powershell.exe @argList
    $exitCode = $LASTEXITCODE
    $results += [pscustomobject]@{
        Host         = $item.Name
        Status       = if ($exitCode -eq 0) { 'OK' } else { 'FAILED' }
        Exit         = $exitCode
        ResolvedRoot = Resolve-HostCollectionRoot -Path $item.SourcePath
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
        $combined = foreach ($r in $results) {
            $csvPath = Join-Path $r.ResolvedRoot $spec.RelPath
            if (Test-Path -LiteralPath $csvPath) {
                Import-Csv -LiteralPath $csvPath | Select-Object @{ Name = 'SourceHost'; Expression = { $r.Host } }, *
            }
        }
        if ($combined) {
            $combined = $combined | Sort-Object $spec.SortCol
            $combined | Export-Csv -LiteralPath (Join-Path $rollupDir $spec.Name) -NoTypeInformation
            Write-Host "Wrote $($combined.Count) row(s) across $($hostItems.Count) host(s) to $($spec.Name)"
        } else {
            Write-Host "No data found for $($spec.Name) - skipping"
        }
    }
}

if ($results | Where-Object { $_.Status -eq 'FAILED' }) { exit 1 } else { exit 0 }
