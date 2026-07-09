[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CollectionRoot,

    [string]$OutputPath,

    [string]$KapePath,

    # Skip the automatic Get-InterestingFiles.ps1 / Get-EvtxTriage.ps1 post-processing
    # pass - use this if you only want KAPE's raw output, or want to run those scripts
    # yourself with non-default parameters.
    [switch]$SkipTriagePostProcessing,

    # Opens the finished ReviewWorkbook.xlsx automatically. Off by default so
    # Start-CaseParse.ps1 doesn't pop a window per host across a multi-host run -
    # Start-IRConsole.ps1's single-host menu option turns it on by default instead.
    [switch]$OpenWhenDone
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

if (-not $KapePath) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $candidate = Split-Path -Parent (Split-Path -Parent $scriptDir)
    if (Test-Path (Join-Path $candidate 'kape.exe')) {
        $KapePath = $candidate
    } else {
        $KapePath = 'C:\KAPE'
    }
}

$CollectionRoot = (Resolve-Path -LiteralPath $CollectionRoot).Path
$uploadsPath = Join-Path $CollectionRoot 'uploads'

if (-not (Test-Path -LiteralPath $uploadsPath -PathType Container)) {
    Write-Host "CollectionRoot '$CollectionRoot' does not contain an uploads\ folder - is this a Velociraptor collection?" -ForegroundColor Red
    exit 1
}

if (-not $OutputPath) {
    # Parsed output always lives alongside the collection's own Velociraptor results,
    # not in some separate location the analyst has to remember.
    $OutputPath = Join-Path $CollectionRoot 'results'
}

# Prefer the hostname Velociraptor itself recorded (client_info.json, written at the
# collection root by every Windows.KapeFiles.Targets collection) over the folder name -
# an analyst can name the extracted-collection folder anything, but this field is always
# accurate. Falls back to the folder name if that file is missing/unparsable (e.g. a
# collection format other than this project's target one). Used to keep multiple hosts'
# ReviewWorkbook.xlsx/Review\ output distinguishable when open side by side.
$hostLabel = $null
$clientInfoPath = Join-Path $CollectionRoot 'client_info.json'
if (Test-Path -LiteralPath $clientInfoPath) {
    try {
        $hostLabel = (Get-Content -LiteralPath $clientInfoPath -Raw | ConvertFrom-Json).Hostname
    } catch { }
}
if ([string]::IsNullOrWhiteSpace($hostLabel)) {
    $hostLabel = Split-Path -Leaf $CollectionRoot
}
$hostLabel = ($hostLabel -replace '[\\/:*?"<>|]', '_')
$dateLabel = Get-Date -Format 'yyyyMMdd'
$reviewWorkbookPath = Join-Path $OutputPath "${hostLabel}_${dateLabel}_ReviewWorkbook.xlsx"

# --- Verify tools ---
$verifyScript = Join-Path $KapePath 'Modules\bin\Manage-Tools.ps1'
& powershell.exe -ExecutionPolicy Bypass -NonInteractive -File $verifyScript -KapePath $KapePath -Mode Verify
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Tool verification failed - one or more required tools are missing. Run Manage-Tools.ps1 -Mode Setup first. Aborting without running KAPE." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$kapeExe = Join-Path $KapePath 'kape.exe'
Write-Host ""
Write-Host "Running KAPE module IR_Compound_Full ..."
Write-Host "  msource: $uploadsPath"
Write-Host "  mdest:   $OutputPath"
# Deliberately no --mflush: OutputPath defaults to <CollectionRoot>\results, which
# already holds Velociraptor's own artifact manifest CSVs - --mflush would delete
# everything already there before KAPE writes its own output. msource is pointed at
# uploads\ (not a specific device-root subfolder) because every referenced sub-module
# uses either FileMask/%sourceFile% or a tool's own recursive -d scan, both of which
# find artifacts at any depth without needing to know Velociraptor's percent-encoded
# device-root folder name.
& $kapeExe --msource $uploadsPath --mdest $OutputPath --module IR_Compound_Full
$kapeExit = $LASTEXITCODE

# --- Summarize output folders ---
# Each referenced module writes into its own native Category subfolder rather than a
# custom numbered scheme, since IR_Compound_Full intentionally uses stock modules as-is.
Write-Host ""
Write-Host "=== Output summary ($OutputPath) ==="
$expectedFolders = @(
    'IR', 'FileSystem', 'Registry', 'FileFolderAccess', 'ProgramExecution',
    'SRUMDatabase', 'SUMDatabase', 'FileDeletion', 'EventLogs', 'WebBrowsers'
)
foreach ($folder in $expectedFolders) {
    $full = Join-Path $OutputPath $folder
    if (-not (Test-Path -LiteralPath $full)) {
        Write-Host ("{0,-20} MISSING" -f $folder) -ForegroundColor Red
        continue
    }
    $files = Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue
    $nonEmpty = $files | Where-Object { $_.Length -gt 0 }
    if ($nonEmpty.Count -gt 0) {
        Write-Host ("{0,-20} OK ({1} file(s))" -f $folder, $nonEmpty.Count) -ForegroundColor Green
    } else {
        Write-Host ("{0,-20} EMPTY" -f $folder) -ForegroundColor Yellow
    }
}


# --- Fast triage post-processing ---
# These narrow the firehose above down to a first-look view (recent high-signal
# files, a curated EVTX window) - not a replacement for the full output, just
# somewhere to start. Failures here are reported but don't change the overall
# exit code - the main KAPE run already succeeded or failed by this point.
if (-not $SkipTriagePostProcessing) {
    Write-Host ""
    Write-Host "=== Triage post-processing ==="
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    # Spawned as separate powershell.exe processes, not called directly - an `exit`
    # inside either script would otherwise terminate this whole Run-IRParse.ps1
    # session, not just that script.
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File (Join-Path $scriptDir 'Get-InterestingFiles.ps1') -ResultsPath $OutputPath
    if ($LASTEXITCODE -ne 0) { Write-Host "Get-InterestingFiles.ps1 exited $LASTEXITCODE" -ForegroundColor Yellow }
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File (Join-Path $scriptDir 'Get-EvtxTriage.ps1') -ResultsPath $OutputPath
    if ($LASTEXITCODE -ne 0) { Write-Host "Get-EvtxTriage.ps1 exited $LASTEXITCODE" -ForegroundColor Yellow }
    # Reads the raw uploads\ tree directly (not KAPE's parsed output), so it needs
    # CollectionRoot/KapePath rather than -ResultsPath - see the script's own header
    # for why this runs as a standalone step instead of a KAPE module processor.
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File (Join-Path $scriptDir 'Get-BroaderBrowserHistory.ps1') -CollectionRoot $CollectionRoot -OutputPath (Join-Path $OutputPath 'WebBrowsers') -KapePath $KapePath
    if ($LASTEXITCODE -ne 0) { Write-Host "Get-BroaderBrowserHistory.ps1 exited $LASTEXITCODE" -ForegroundColor Yellow }
    # Both of the below run after the two above so they can pick up
    # EvtxTriage.csv/InterestingFiles.csv. New-ReviewWorkbook.ps1 (a single merged .xlsx,
    # requires Excel installed) is the real fix for tab-switching between output folders;
    # New-ReviewBundle.ps1 (a folder of the same CSVs, no dependencies) is a portable
    # fallback for a workstation without Excel and always runs regardless.
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File (Join-Path $scriptDir 'New-ReviewBundle.ps1') -ResultsPath $OutputPath -FilePrefix "${hostLabel}_${dateLabel}_"
    if ($LASTEXITCODE -ne 0) { Write-Host "New-ReviewBundle.ps1 exited $LASTEXITCODE" -ForegroundColor Yellow }
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File (Join-Path $scriptDir 'New-ReviewWorkbook.ps1') -ResultsPath $OutputPath -OutputFile $reviewWorkbookPath
    $reviewWorkbookExit = $LASTEXITCODE
    if ($reviewWorkbookExit -ne 0) { Write-Host "New-ReviewWorkbook.ps1 exited $reviewWorkbookExit (Excel may not be installed - the CSV bundle above still covers this)" -ForegroundColor Yellow }
}

# --- Triage summary ---
# A quick "how hot does this host look" signal before opening the full workbook -
# row counts, not conclusions. Runs regardless of -SkipTriagePostProcessing, since
# Chainsaw/Hayabusa's own raw output comes straight from KAPE, not the triage scripts.
function Get-CsvRowCount {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return ([System.IO.File]::ReadLines($Path) | Measure-Object).Count - 1
}
$triageCounts = [ordered]@{
    'Chainsaw Sigma hits'    = Get-CsvRowCount (Join-Path $OutputPath 'EventLogs\sigma.csv')
    'Hayabusa hits'          = Get-CsvRowCount (Join-Path $OutputPath 'EventLogs\hayabusa_events_offline.csv')
    'EVTX triage rows'       = Get-CsvRowCount (Join-Path $OutputPath 'EventLogs\EvtxTriage.csv')
    'Interesting files'      = Get-CsvRowCount (Join-Path $OutputPath 'FileSystem\InterestingFiles.csv')
    'Browser history rows'   = Get-CsvRowCount (Join-Path $OutputPath 'WebBrowsers\BrowsingHistory.csv')
    'Browser download rows'  = Get-CsvRowCount (Join-Path $OutputPath 'WebBrowsers\BrowserDownloadsView.csv')
}
Write-Host ""
Write-Host "=== Triage summary ($hostLabel) ==="
foreach ($key in $triageCounts.Keys) {
    $val = if ($null -eq $triageCounts[$key]) { 'n/a' } else { $triageCounts[$key] }
    Write-Host ("{0,-24} {1}" -f $key, $val)
}

# --- Run log ---
# Appended, not overwritten, so re-running against the same collection keeps a
# history - parameters, timing, and the triage summary above, for case-note/
# chain-of-custody documentation. Deliberately a small structured summary, not a
# full console transcript.
$endTime = Get-Date
$logLines = @(
    "=== Run-IRParse.ps1 - $($startTime.ToString('u')) ==="
    "Host: $hostLabel"
    "CollectionRoot: $CollectionRoot"
    "OutputPath: $OutputPath"
    "KapePath: $KapePath"
    "SkipTriagePostProcessing: $($SkipTriagePostProcessing.IsPresent)"
    "Tool verification: PASSED"
    "Started:  $($startTime.ToString('u'))"
    "Finished: $($endTime.ToString('u')) (duration: $([Math]::Round(($endTime - $startTime).TotalMinutes, 1)) min)"
    "KAPE exit code: $kapeExit"
    "Triage summary:"
) + ($triageCounts.Keys | ForEach-Object {
    "  ${_}: $(if ($null -eq $triageCounts[$_]) { 'n/a' } else { $triageCounts[$_] })"
}) + @('')
Add-Content -LiteralPath (Join-Path $OutputPath 'RunLog.txt') -Value $logLines

if ($OpenWhenDone -and $reviewWorkbookExit -eq 0 -and (Test-Path -LiteralPath $reviewWorkbookPath)) {
    Invoke-Item -LiteralPath $reviewWorkbookPath
}

exit $kapeExit
