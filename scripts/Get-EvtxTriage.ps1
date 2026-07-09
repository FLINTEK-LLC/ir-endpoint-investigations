<#
.SYNOPSIS
    Fast, noise-reduced first pass over parsed event logs: a configurable
    date window plus a curated set of high-value Event IDs.

.DESCRIPTION
    Reads every *_EvtxECmd_Output.csv under <ResultsPath>\EventLogs\ (produced
    by Run-IRParse.ps1 / IR_Compound_Full), filters to events within the last
    -DaysBack days matching -EventIds, and writes a sorted CSV. This sits
    alongside - not instead of - the full EvtxECmd/Chainsaw/Hayabusa output;
    it's meant as a quick starting point, not a replacement for the full
    parse. Run standalone against existing results, or let Run-IRParse.ps1
    call it automatically after a parse.

.PARAMETER EventIds
    Defaults to a general-purpose starter set: logon/logoff and account
    changes (4624/4625/4720/4722/4724/4738/4769), audit log clearing
    (1102/1116/1117), scheduled tasks (4698/7045), PowerShell script block
    logging (4104), and Kerberos ticket requests (5001/5007). Adjust for your
    environment - this is a starting point, not a definitive list.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResultsPath,

    [int]$DaysBack = 15,

    [string[]]$EventIds = @(
        '1102', '1116', '1117', '4624', '4625', '4698', '4720', '4722',
        '4724', '4738', '4769', '5001', '5007', '7045', '4104'
    ),

    [string]$OutputFile
)

$ErrorActionPreference = 'Stop'

$eventLogsDir = Join-Path $ResultsPath 'EventLogs'
$evtxFiles = Get-ChildItem -LiteralPath $eventLogsDir -Filter '*EvtxECmd_Output.csv' -ErrorAction SilentlyContinue
if (-not $evtxFiles) {
    Write-Host "No EvtxECmd output found under $eventLogsDir - run Run-IRParse.ps1 first." -ForegroundColor Red
    exit 1
}

if (-not $OutputFile) {
    $OutputFile = Join-Path $eventLogsDir 'EvtxTriage.csv'
}

$cutoff = (Get-Date).AddDays(-$DaysBack)

$rows = foreach ($evtxFile in $evtxFiles) {
    Import-Csv -LiteralPath $evtxFile.FullName | Where-Object { $_.EventId -in $EventIds } | Where-Object {
        try { [datetime]$_.TimeCreated -gt $cutoff } catch { $false }
    }
}

$sorted = $rows | Sort-Object TimeCreated
$sorted | Export-Csv -LiteralPath $OutputFile -NoTypeInformation

Write-Host "Wrote $($sorted.Count) triage event row(s) (last $DaysBack days, EventIDs: $($EventIds -join ',')) to $OutputFile"
