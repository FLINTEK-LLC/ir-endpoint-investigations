[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CollectionRoot,

    [string]$OutputPath,

    [string]$KapePath
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

exit $kapeExit
