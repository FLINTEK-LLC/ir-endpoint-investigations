<#
.SYNOPSIS
    Runs NirSoft's BrowsingHistoryView and BrowserDownloadsView against the raw
    collection for browser coverage Hindsight doesn't provide (Firefox, Edge
    legacy/IE, and other non-Chromium browsers alongside Chromium ones).

.DESCRIPTION
    Both tools require /HistorySourceFolder (or /SourceFolder) to point
    directly at the folder that contains the user profile subfolders (e.g.
    "C:\Users") - confirmed against NirSoft's own documentation, neither tool
    searches an arbitrary-depth ancestor for it. That's incompatible with how
    IR_Compound_Full.mkape is run: msource is pointed at
    <CollectionRoot>\uploads (not a specific device-root subfolder) precisely
    so nothing in this project needs to know Velociraptor's percent-encoded
    device-root folder name (e.g. uploads\auto\C%3A\Users).

    Rather than reintroduce that device-root detection into the module/compound
    system, this script does a one-time recursive search for the actual
    "Users" folder under uploads\auto, then invokes both NirSoft tools
    directly with that discovered path. It's a standalone post-processing
    step (like Get-InterestingFiles.ps1 / Get-EvtxTriage.ps1), not a KAPE
    module processor - run it manually against existing results, or let
    Run-IRParse.ps1 call it automatically after a parse.

.PARAMETER CollectionRoot
    Root of the extracted Velociraptor collection (the same value passed to
    Run-IRParse.ps1 -CollectionRoot) - needed here because these tools read
    the raw uploads\ tree directly, not KAPE's parsed output.

.PARAMETER OutputPath
    Where to write BrowsingHistory.csv / BrowserDownloadsView.csv. Defaults to
    <CollectionRoot>\results\WebBrowsers, alongside Hindsight's own output.

.PARAMETER KapePath
    Used to locate BrowsingHistoryView.exe / BrowserDownloadsView.exe under
    Modules\bin. Defaults to auto-detection the same way Run-IRParse.ps1 does.
#>
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
$autoRoot = Join-Path $CollectionRoot 'uploads\auto'

if (-not (Test-Path -LiteralPath $autoRoot -PathType Container)) {
    Write-Host "No uploads\auto folder found under $CollectionRoot - is this a Velociraptor collection?" -ForegroundColor Red
    exit 1
}

# One-time recursive search for the actual Users folder, regardless of the
# percent-encoded device-root name (e.g. %5C%5C.%5CC%3A, C%3A) sitting above it.
$usersFolder = Get-ChildItem -LiteralPath $autoRoot -Recurse -Directory -Filter 'Users' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $usersFolder) {
    Write-Host "No Users folder found under $autoRoot - skipping broader browser history (nothing for these tools to read)." -ForegroundColor Yellow
    exit 0
}

$binPath = Join-Path $KapePath 'Modules\bin'
$bhvExe = Join-Path $binPath 'BrowsingHistoryView.exe'
$bdvExe = Join-Path $binPath 'BrowserDownloadsView.exe'
if (-not (Test-Path -LiteralPath $bhvExe) -or -not (Test-Path -LiteralPath $bdvExe)) {
    Write-Host "BrowsingHistoryView.exe / BrowserDownloadsView.exe not found under $binPath - run Manage-Tools.ps1 -Mode Setup first." -ForegroundColor Red
    exit 1
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $CollectionRoot 'results\WebBrowsers'
}
if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host "Using Users folder: $($usersFolder.FullName)"

$historyCsv = Join-Path $OutputPath 'BrowsingHistory.csv'
$downloadsCsv = Join-Path $OutputPath 'BrowserDownloadsView.csv'

# /HistorySource 3 / /DownloadsSource 3 = load from every profile under the
# given folder, matching the stock NirSoft .mkape modules' own flags - just
# pointed at the discovered path instead of an assumed %sourceDirectory%\Users.
#
# Despite passing an export switch, both tools still open a visible window and
# don't reliably self-close when launched directly (confirmed empirically -
# contradicts NirSoft's own documented "export switch implies silent mode"
# behavior). -WindowStyle Hidden makes them run and exit cleanly on their own;
# the WaitForExit timeout + force-kill is a backstop in case a given tool/build
# doesn't, so this script never hangs a Run-IRParse.ps1 run.
function Invoke-NirSoftExport {
    param([string]$Exe, [string[]]$ExeArgs)
    $proc = Start-Process -FilePath $Exe -ArgumentList $ExeArgs -PassThru -WindowStyle Hidden
    $exited = $proc.WaitForExit(120000)
    if (-not $exited) {
        Start-Sleep -Seconds 2
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
}

Invoke-NirSoftExport -Exe $bhvExe -ExeArgs @('/HistorySource', '3', '/HistorySourceFolder', $usersFolder.FullName, '/VisitTimeFilterType', '1', '/ShowTimeInGMT', '1', '/scomma', $historyCsv)
Invoke-NirSoftExport -Exe $bdvExe -ExeArgs @('/DownloadsSource', '3', '/SourceFolder', $usersFolder.FullName, '/ShowTimeInGMT', '1', '/scomma', $downloadsCsv)

foreach ($csv in @($historyCsv, $downloadsCsv)) {
    if (Test-Path -LiteralPath $csv) {
        $count = (Import-Csv -LiteralPath $csv -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Host "Wrote $count row(s) to $csv"
    } else {
        Write-Host "$csv was not created" -ForegroundColor Yellow
    }
}
