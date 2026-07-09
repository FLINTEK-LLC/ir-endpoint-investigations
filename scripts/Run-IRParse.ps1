[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CollectionRoot,

    [string]$OutputPath,

    [string]$KapePath,

    # Skip the automatic Get-InterestingFiles.ps1 / Get-EvtxTriage.ps1 post-processing
    # pass - use this if you only want KAPE's raw output, or want to run those scripts
    # yourself with non-default parameters.
    [switch]$SkipTriagePostProcessing
)

$ErrorActionPreference = 'Stop'

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
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File (Join-Path $scriptDir 'New-ReviewBundle.ps1') -ResultsPath $OutputPath
    if ($LASTEXITCODE -ne 0) { Write-Host "New-ReviewBundle.ps1 exited $LASTEXITCODE" -ForegroundColor Yellow }
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File (Join-Path $scriptDir 'New-ReviewWorkbook.ps1') -ResultsPath $OutputPath
    if ($LASTEXITCODE -ne 0) { Write-Host "New-ReviewWorkbook.ps1 exited $LASTEXITCODE (Excel may not be installed - the CSV bundle above still covers this)" -ForegroundColor Yellow }
}

exit $kapeExit
