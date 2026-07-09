<#
.SYNOPSIS
    Gathers the highest-signal parsed outputs for one host into a single
    `Review\` folder, so an analyst can open one place instead of hunting
    across ten category folders for a first look.

.DESCRIPTION
    Copies (not merges) the same curated set of outputs the triage scripts
    already narrow down - EvtxTriage.csv, InterestingFiles.csv, Hayabusa and
    Chainsaw hits, Amcache/Prefetch/Shimcache, LNK, Recycle Bin - into
    <ResultsPath>\Review\, with clear, source-labeled filenames. This is
    deliberately CSV-to-CSV, not a merged workbook: an earlier version of
    this script tried consolidating everything into a single .xlsx via the
    ImportExcel module, but hit a reproducible corruption bug in the bundled
    EPPlus 4.5.3.2 (worksheet writes started failing, deterministically,
    after 5 successful sheet additions, regardless of row count, data
    content, or retry - see project history if picking this back up with a
    newer EPPlus/ImportExcel version). Plain CSVs in one folder achieve the
    same "stop tab-switching" goal without that dependency risk.

    This is meant to cut down on tab-switching during initial review, not to
    replace the full per-category output under <ResultsPath>\. Hindsight's
    browser-history output is already its own workbook and is deliberately
    left where it is rather than copied here - open it directly from
    WebBrowsers\.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResultsPath,

    [string]$ReviewFolder
)

$ErrorActionPreference = 'Stop'

if (-not $ReviewFolder) {
    $ReviewFolder = Join-Path $ResultsPath 'Review'
}
New-Item -ItemType Directory -Path $ReviewFolder -Force | Out-Null

# One entry per output file: a destination filename, and a relative glob
# under ResultsPath. If a pattern matches more than one file, each gets a
# numbered suffix.
$items = @(
    @{ Name = 'Triage-EVTX.csv';    Pattern = 'EventLogs\EvtxTriage.csv' }
    @{ Name = 'Triage-Files.csv';   Pattern = 'FileSystem\InterestingFiles.csv' }
    @{ Name = 'Hayabusa.csv';       Pattern = 'EventLogs\hayabusa_events_offline.csv' }
    @{ Name = 'Chainsaw-Sigma.csv'; Pattern = 'EventLogs\sigma.csv' }
    @{ Name = 'Amcache.csv';        Pattern = 'ProgramExecution\*Amcache_UnassociatedFileEntries.csv' }
    @{ Name = 'Prefetch.csv';       Pattern = 'ProgramExecution\*PECmd_Output.csv' }
    @{ Name = 'Shimcache.csv';      Pattern = 'ProgramExecution\*AppCompatCache.csv' }
    @{ Name = 'LNK.csv';            Pattern = 'FileFolderAccess\*LECmd_Output.csv' }
    @{ Name = 'RecycleBin.csv';     Pattern = 'FileDeletion\*RBCmd_Output.csv' }
)

$includedCount = 0
foreach ($item in $items) {
    $matchedFiles = Get-ChildItem -Path (Join-Path $ResultsPath $item.Pattern) -ErrorAction SilentlyContinue
    if (-not $matchedFiles) { continue }

    $i = 0
    foreach ($file in $matchedFiles) {
        $destName = if ($matchedFiles.Count -gt 1) {
            $i++
            "{0}_{1}{2}" -f [IO.Path]::GetFileNameWithoutExtension($item.Name), $i, [IO.Path]::GetExtension($item.Name)
        } else {
            $item.Name
        }
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $ReviewFolder $destName) -Force
        $includedCount++
    }
}

if ($includedCount -eq 0) {
    Write-Host "No matching output found under $ResultsPath - run Run-IRParse.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host "Copied $includedCount file(s) into $ReviewFolder"
