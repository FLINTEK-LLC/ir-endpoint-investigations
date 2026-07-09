<#
.SYNOPSIS
    Fast "what got dropped recently" view: filters MFTECmd's $MFT output down
    to rows matching high-signal file extensions within a recent time window,
    excluding common dev/package noise, sorted chronologically.

.DESCRIPTION
    Reads every *_$MFT_Output.csv under <ResultsPath>\FileSystem\ (produced by
    Run-IRParse.ps1 / IR_Compound_Full), filters to a curated extension list
    AND a recency window on file creation, and writes a sorted CSV analysts
    can review before waiting on a full MFT timeline pass.

    Extension filtering alone is not enough to be useful - a real system
    easily has hundreds of thousands of .dll files from installed software
    alone, and .js in particular is dominated by node_modules on any endpoint
    with dev tooling (confirmed on the project's own reference collection:
    ~81,000 of ~96,000 matching-extension rows were .js, almost entirely
    node_modules noise). The recency window and path exclusions are what
    actually make this a triage view rather than a dump of the filesystem;
    set -DaysBack 0 or -ExcludePathPattern '' to disable either if that's
    genuinely what you want. Run standalone against existing results, or let
    Run-IRParse.ps1 call it automatically after a parse.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResultsPath,

    [string[]]$Extensions = @(
        '.exe', '.dll', '.ps1', '.vbs', '.vbe', '.js', '.jse', '.cmd', '.bat',
        '.scr', '.msi', '.jar', '.hta', '.zip', '.7z', '.rar', '.xml', '.json',
        '.vhd', '.avhd', '.iso'
    ),

    # How far back (by file creation on this volume, Created0x10) counts as
    # "recent". 0 disables the recency filter entirely. 30 is a reasonable
    # starting point for an active-intrusion timeframe; widen it for a case
    # with a longer suspected dwell time.
    [int]$DaysBack = 30,

    # Regex (case-insensitive) matched against ParentPath - rows matching are
    # excluded. Default targets common dev-tooling/package-manager noise that
    # is virtually never relevant to an intrusion and drowns out real signal
    # on any endpoint with development tools installed. Pass '' to disable.
    [string]$ExcludePathPattern = '\\node_modules\\|\\\.git\\|\\WinSxS\\|\\Package Cache\\|\\vcpkg\\|\\\.nuget\\|\\site-packages\\',

    [string]$OutputFile
)

$ErrorActionPreference = 'Stop'

$fileSystemDir = Join-Path $ResultsPath 'FileSystem'
$mftFiles = Get-ChildItem -LiteralPath $fileSystemDir -Filter '*MFT_Output.csv' -ErrorAction SilentlyContinue
if (-not $mftFiles) {
    Write-Host "No MFTECmd `$MFT output found under $fileSystemDir - run Run-IRParse.ps1 first." -ForegroundColor Red
    exit 1
}

if (-not $OutputFile) {
    $OutputFile = Join-Path $fileSystemDir 'InterestingFiles.csv'
}

$cutoff = if ($DaysBack -gt 0) { (Get-Date).AddDays(-$DaysBack) } else { $null }

$rows = foreach ($mftFile in $mftFiles) {
    Import-Csv -LiteralPath $mftFile.FullName | Where-Object { $_.Extension -in $Extensions } | Where-Object {
        if (-not $cutoff) { return $true }
        try { [datetime]$_.Created0x10 -gt $cutoff } catch { $false }
    } | Where-Object {
        if ([string]::IsNullOrEmpty($ExcludePathPattern)) { return $true }
        -not ($_.ParentPath -match $ExcludePathPattern)
    }
}

# Created0x10 is a fixed-width, zero-padded ISO-like timestamp string
# ("yyyy-MM-dd HH:mm:ss.fffffff") - sorts correctly as a string, no date
# parsing needed for the sort itself.
$sorted = $rows | Sort-Object Created0x10
$sorted | Export-Csv -LiteralPath $OutputFile -NoTypeInformation

$windowText = if ($DaysBack -gt 0) { "last $DaysBack days" } else { "no recency filter" }
Write-Host "Wrote $($sorted.Count) interesting-file row(s) ($windowText) to $OutputFile"
