<#
.SYNOPSIS
    Merges the highest-signal parsed outputs for one host into a single
    review workbook - one worksheet per artifact, each sorted chronologically
    - so first-pass review is one file with tabs, not ten folders of CSVs.

.DESCRIPTION
    Uses Excel COM automation (requires Microsoft Excel installed on this
    workstation), the same approach
    secure-cake/rapid-endpoint-investigations' rtw-script uses to build its
    per-host workbook. Unlike that script, prompts are suppressed
    programmatically (DisplayAlerts = $false) instead of requiring an
    analyst to click through a "keep this format?" dialog, and every COM
    object is explicitly released so this doesn't leave orphaned EXCEL.EXE
    processes behind.

    An earlier version of this script tried a COM-free approach via the
    ImportExcel PowerShell module, to avoid requiring Excel on the analyst
    workstation. It hit a reproducible bug in the bundled EPPlus 4.5.3.2 -
    worksheet writes failed deterministically after the 5th sheet, regardless
    of data size/content or retries. If revisiting that path (e.g. for
    portability to a machine without Excel installed), try a newer
    EPPlus/ImportExcel version first.

.PARAMETER ResultsPath
    The `results\` folder produced by Run-IRParse.ps1 / IR_Compound_Full.

.PARAMETER OutputFile
    Defaults to <ResultsPath>\ReviewWorkbook.xlsx.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResultsPath,

    [string]$OutputFile
)

$ErrorActionPreference = 'Stop'

if (-not $OutputFile) {
    $OutputFile = Join-Path $ResultsPath 'ReviewWorkbook.xlsx'
}
if (Test-Path -LiteralPath $OutputFile) { Remove-Item -LiteralPath $OutputFile -Force }

# One entry per worksheet: a relative glob under ResultsPath, and a list of
# candidate timestamp column names (first one actually present in the CSV's
# header wins) to sort that sheet by before it goes into the workbook.
$sheets = @(
    @{ Name = 'Triage-EVTX';    Pattern = 'EventLogs\EvtxTriage.csv';                     SortCols = @('TimeCreated') }
    @{ Name = 'Triage-Files';   Pattern = 'FileSystem\InterestingFiles.csv';              SortCols = @('Created0x10') }
    @{ Name = 'Hayabusa';       Pattern = 'EventLogs\hayabusa_events_offline.csv';        SortCols = @('Timestamp') }
    @{ Name = 'Chainsaw-Sigma'; Pattern = 'EventLogs\sigma.csv';                          SortCols = @('timestamp') }
    @{ Name = 'Amcache';        Pattern = 'ProgramExecution\*Amcache_UnassociatedFileEntries.csv' ; SortCols = @('FileKeyLastWriteTimestamp') }
    @{ Name = 'Prefetch';       Pattern = 'ProgramExecution\*PECmd_Output.csv';           SortCols = @('LastRun') }
    @{ Name = 'Shimcache';      Pattern = 'ProgramExecution\*AppCompatCache.csv';         SortCols = @('LastModifiedTimeUTC') }
    @{ Name = 'LNK';            Pattern = 'FileFolderAccess\*LECmd_Output.csv';           SortCols = @('TargetModified') }
    @{ Name = 'RecycleBin';     Pattern = 'FileDeletion\*RBCmd_Output.csv';               SortCols = @('DeletedOn') }
    @{ Name = 'BrowserHistory'; Pattern = 'WebBrowsers\BrowsingHistory.csv';              SortCols = @('Visit Time') }
    @{ Name = 'BrowserDownloads'; Pattern = 'WebBrowsers\BrowserDownloadsView.csv';       SortCols = @('Start Time') }
)

# Excel has no simple "sort by column name" call via COM, so each sheet is pre-sorted
# and written to a temp CSV first; Excel just opens each temp CSV and copies its sheet
# into the master workbook.
$tempDir = Join-Path $env:TEMP ("reviewworkbook_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$prepared = @()
try {
    foreach ($sheet in $sheets) {
        $matchedFiles = Get-ChildItem -Path (Join-Path $ResultsPath $sheet.Pattern) -ErrorAction SilentlyContinue
        if (-not $matchedFiles) { continue }
        $data = foreach ($file in $matchedFiles) { Import-Csv -LiteralPath $file.FullName }
        if (-not $data) { continue }
        $sortCol = $sheet.SortCols | Where-Object { $data[0].PSObject.Properties.Name -contains $_ } | Select-Object -First 1
        if ($sortCol) { $data = $data | Sort-Object $sortCol }
        $tempCsv = Join-Path $tempDir "$($sheet.Name).csv"
        $data | Export-Csv -LiteralPath $tempCsv -NoTypeInformation
        $prepared += [pscustomobject]@{ Name = $sheet.Name; Path = $tempCsv }
    }

    if (-not $prepared) {
        Write-Host "No matching output found under $ResultsPath - run Run-IRParse.ps1 first." -ForegroundColor Red
        exit 1
    }

    $excel = $null
    $workbook = $null
    try {
        try {
            $excel = New-Object -ComObject Excel.Application
        } catch {
            Write-Host "Microsoft Excel is not installed/registered on this workstation - New-ReviewWorkbook.ps1 requires it. Use New-ReviewBundle.ps1 instead for a portable, Excel-free alternative." -ForegroundColor Red
            exit 1
        }
        $excel.Visible = $false
        $excel.DisplayAlerts = $false

        $workbook = $excel.Workbooks.Add()
        $defaultSheetCount = $workbook.Sheets.Count

        foreach ($item in $prepared) {
            $sourceBook = $excel.Workbooks.Open($item.Path)
            $sourceSheet = $sourceBook.Sheets.Item(1)
            $sourceSheet.Copy([System.Reflection.Missing]::Value, $workbook.Sheets.Item($workbook.Sheets.Count))
            $newSheet = $workbook.Sheets.Item($workbook.Sheets.Count)
            $newSheet.Name = $item.Name
            $sourceBook.Close($false)
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($sourceSheet) | Out-Null
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($sourceBook) | Out-Null
            Write-Host "Added sheet $($item.Name)"
        }

        # Drop the blank default sheet(s) the new workbook started with, now that real
        # sheets are in place - has to happen after, since a workbook can't have zero sheets.
        for ($i = 1; $i -le $defaultSheetCount; $i++) {
            $workbook.Sheets.Item(1).Delete()
        }

        $workbook.SaveAs($OutputFile, 51)  # 51 = xlOpenXMLWorkbook (.xlsx)
        Write-Host "Wrote $($prepared.Count) worksheet(s) to $OutputFile"
    } finally {
        if ($workbook) {
            $workbook.Close($false)
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($workbook) | Out-Null
        }
        if ($excel) {
            $excel.Quit()
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
        }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
