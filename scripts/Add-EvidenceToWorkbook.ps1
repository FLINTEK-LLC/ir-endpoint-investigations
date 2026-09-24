<#
.SYNOPSIS
    Appends rows to a case workbook's Evidence Log from a manifest written by
    Get-EvidenceManifest.ps1.

.DESCRIPTION
    The Evidence Log's Hash (SHA256), Collected (UTC) and Collection Method
    columns are exactly what the manifest already holds. Transcribing a SHA-256
    by hand is slow and is the one column where a typo destroys the point of
    recording it at all, so this copies them across instead.

    TWO MODES, AND WHY THE DEFAULT IS SUMMARY

    A manifest has one line per file. A triage collection runs to tens or
    hundreds of thousands of files, and an Evidence Log with a hundred thousand
    rows in it is not an evidence log. That log records evidence ITEMS - the
    collection you received, the disk image, the memory capture.

    So Summary (the default) writes ONE row for the whole collection, and the
    hash it records is the hash OF THE MANIFEST. That is the useful anchor: the
    manifest covers every file, so pinning the manifest pins the set. Verify it
    later with Get-EvidenceManifest.ps1 -Verify and the single hash in the log
    tells you whether the manifest you are verifying against is the one you
    started from.

    PerFile writes one row per file, for the small targeted collections where
    that is genuinely what you want - a handful of exported mailboxes, four
    .eml samples, one memory dump.

.PARAMETER ManifestPath
    evidence-manifest.csv from Get-EvidenceManifest.ps1.

.PARAMETER WorkbookPath
    The case workbook. Edited in place, so work on your case copy rather than
    the template in templates\.

.PARAMETER CollectionMethod
    Must match a value in the workbook's Lists sheet, or the cell lands with a
    red validation flag. Validated up front against that sheet, and the valid
    values are printed on a mismatch.

.PARAMETER Mode
    Summary (default) or PerFile. See above.

.EXAMPLE
    .\Add-EvidenceToWorkbook.ps1 -ManifestPath D:\Cases\INC1234\HOST01\evidence-manifest.csv `
        -WorkbookPath D:\Cases\INC1234\INC1234-tracking.xlsx `
        -SourceHost HOST01 -CollectionMethod 'Velociraptor Offline Collector' -CollectedBy 'D. Flinton'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$WorkbookPath,

    [string]$SourceHost = '',
    [string]$CollectionMethod = 'Velociraptor Offline Collector',
    [string]$CollectedBy = $env:USERNAME,
    [string]$StorageLocation = '',

    [ValidateSet('Collected', 'Hashed', 'Stored', 'Analyzed', 'Archived', 'Chain of Custody Issue')]
    [string]$Status = 'Hashed',

    [ValidateSet('Summary', 'PerFile')]
    [string]$Mode = 'Summary',

    [string]$WorksheetName = 'Evidence Log'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable ImportExcel)) {
    throw "The ImportExcel module is required. scripts\Setup-Workstation.ps1 installs it, or: Install-Module ImportExcel -Scope CurrentUser"
}
Import-Module ImportExcel -ErrorAction Stop

foreach ($p in @($ManifestPath, $WorkbookPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Not found: $p" }
}
$ManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$WorkbookPath = (Resolve-Path -LiteralPath $WorkbookPath).Path

$rows = @(Import-Csv -LiteralPath $ManifestPath)
if ($rows.Count -eq 0) { throw "Manifest is empty: $ManifestPath" }
foreach ($col in @('RelativePath', 'SizeBytes', 'SHA256')) {
    if ($rows[0].PSObject.Properties.Name -notcontains $col) {
        throw "'$ManifestPath' does not look like a Get-EvidenceManifest.ps1 manifest - no '$col' column."
    }
}

$pkg = Open-ExcelPackage -Path $WorkbookPath
try {
    $ws = $pkg.Workbook.Worksheets[$WorksheetName]
    if (-not $ws) { throw "No '$WorksheetName' worksheet in $WorkbookPath" }

    # --- validate CollectionMethod against the workbook's own dropdown source ---
    # A value that is not on the list still writes, but shows as a validation
    # error in Excel. Better to refuse here and name the valid options.
    $lists = $pkg.Workbook.Worksheets['Lists']
    if ($lists) {
        $methodCol = 0
        for ($c = 1; $c -le $lists.Dimension.End.Column; $c++) {
            if ($lists.Cells.Item(1, $c).Text -eq 'CollectionMethod') { $methodCol = $c; break }
        }
        if ($methodCol -gt 0) {
            $valid = @()
            for ($r = 2; $r -le $lists.Dimension.End.Row; $r++) {
                $v = $lists.Cells.Item($r, $methodCol).Text
                if ($v) { $valid += $v }
            }
            if ($valid.Count -gt 0 -and $valid -notcontains $CollectionMethod) {
                Write-Host "'$CollectionMethod' is not one of this workbook's Collection Method values:" -ForegroundColor Red
                $valid | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
                throw "CollectionMethod must match the Lists sheet, or the cell lands flagged as invalid."
            }
        }
    }

    # --- find where to append -------------------------------------------------
    # Column A is '=ROW()-3', so it is never blank and cannot mark the end.
    # Column B (Evidence Item) is what actually indicates a used row.
    $headerRow = 3
    $firstBody = $headerRow + 1
    $appendAt = $firstBody
    $scanTo = [Math]::Max($ws.Dimension.End.Row, $firstBody)
    for ($r = $firstBody; $r -le $scanTo + 1; $r++) {
        if ([string]::IsNullOrWhiteSpace($ws.Cells.Item($r, 2).Text)) { $appendAt = $r; break }
        $appendAt = $r + 1
    }

    # --- existing hashes, so a re-run does not duplicate ----------------------
    $existing = @{}
    for ($r = $firstBody; $r -lt $appendAt; $r++) {
        $h = $ws.Cells.Item($r, 7).Text
        if ($h) { $existing[$h.Trim().ToUpper()] = $true }
    }

    # --- build the rows -------------------------------------------------------
    $collectedUtc = (Get-Item -LiteralPath $ManifestPath).LastWriteTimeUtc
    $manifestName = Split-Path $ManifestPath -Leaf
    $toWrite = @()

    if ($Mode -eq 'Summary') {
        $manifestHash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash
        $bytes = ($rows | Measure-Object -Property SizeBytes -Sum).Sum
        $unreadable = @($rows | Where-Object { $_.SHA256 -like 'ERROR:*' }).Count
        $note = "Manifest of $($rows.Count) files, $([math]::Round($bytes/1GB,2)) GB. Hash above is of $manifestName, which lists every file's own SHA-256."
        if ($unreadable -gt 0) { $note += " $unreadable file(s) were unreadable and are recorded as ERROR rows in the manifest." }
        $toWrite += [pscustomobject]@{
            Item = (Split-Path (Split-Path $ManifestPath -Parent) -Leaf)
            Hash = $manifestHash
            Note = $note
        }
    } else {
        foreach ($row in $rows) {
            if ($row.SHA256 -like 'ERROR:*') { continue }
            $toWrite += [pscustomobject]@{
                Item = $row.RelativePath
                Hash = $row.SHA256
                Note = "$([math]::Round([double]$row.SizeBytes/1MB,2)) MB. From $manifestName."
            }
        }
    }

    $skipped = @($toWrite | Where-Object { $existing.ContainsKey($_.Hash.ToUpper()) }).Count
    $toWrite = @($toWrite | Where-Object { -not $existing.ContainsKey($_.Hash.ToUpper()) })

    if ($toWrite.Count -eq 0) {
        Write-Host "Nothing to add - all $skipped item(s) are already in the Evidence Log by hash." -ForegroundColor Yellow
        Close-ExcelPackage $pkg -NoSave
        return
    }

    if (-not $PSCmdlet.ShouldProcess($WorkbookPath, "append $($toWrite.Count) row(s) to '$WorksheetName' starting at row $appendAt")) {
        Close-ExcelPackage $pkg -NoSave
        return
    }

    $r = $appendAt
    foreach ($item in $toWrite) {
        # Column A carries '=ROW()-3' inside the table. Rows appended past the
        # pre-built body need it written explicitly.
        if ([string]::IsNullOrWhiteSpace($ws.Cells.Item($r, 1).Formula)) {
            $ws.Cells.Item($r, 1).Formula = "ROW()-$headerRow"
        }
        $ws.Cells.Item($r, 2).Value = $item.Item
        $ws.Cells.Item($r, 3).Value = $SourceHost
        $ws.Cells.Item($r, 4).Value = $CollectionMethod
        # A real DateTime, not a string, so the column's yyyy-mm-dd hh:mm:ss
        # format applies and the column sorts chronologically.
        $ws.Cells.Item($r, 5).Value = $collectedUtc
        $ws.Cells.Item($r, 5).Style.Numberformat.Format = 'yyyy-mm-dd hh:mm:ss'
        $ws.Cells.Item($r, 6).Value = $CollectedBy
        $ws.Cells.Item($r, 7).Value = $item.Hash
        $ws.Cells.Item($r, 8).Value = $StorageLocation
        $ws.Cells.Item($r, 9).Value = $Status
        $ws.Cells.Item($r, 10).Value = $item.Note
        $r++
    }

    # Grow the table so the new rows sit inside it and keep their validation
    # and banding. ExcelTable.Address is read-only in the EPPlus that ships
    # with ImportExcel, so this edits the table's backing XML instead - both
    # the table ref and its autoFilter ref, which Excel expects to agree.
    $tbl = $ws.Tables | Where-Object { $_.Name -eq 'tblEvidence' } | Select-Object -First 1
    if ($tbl) {
        $end = $r - 1
        if ($end -gt $tbl.Address.End.Row) {
            $startRow = $tbl.Address.Start.Row
            $startCol = $tbl.Address.Start.Address -replace '\d', ''
            $endCol = $tbl.Address.End.Address -replace '\d', ''
            $newRef = '{0}{1}:{2}{3}' -f $startCol, $startRow, $endCol, $end
            $xml = $tbl.TableXml
            $xml.DocumentElement.SetAttribute('ref', $newRef)
            $af = $xml.DocumentElement.SelectSingleNode('*[local-name()="autoFilter"]')
            if ($af) { $af.SetAttribute('ref', $newRef) }
            $tbl.TableXml = $xml
            Write-Host "Table tblEvidence grown to $newRef" -ForegroundColor DarkGray
        }
    }

    Close-ExcelPackage $pkg   # saves by default; -NoSave is the opt-out

    Write-Host ""
    Write-Host "Added $($toWrite.Count) row(s) to '$WorksheetName' at rows $appendAt-$($r-1)." -ForegroundColor Green
    if ($skipped -gt 0) { Write-Host "Skipped $skipped already present by hash." -ForegroundColor DarkGray }
    Write-Host "  workbook : $WorkbookPath"
    Write-Host "  mode     : $Mode"
    if ($Mode -eq 'Summary') {
        Write-Host ""
        Write-Host "  The hash recorded is of the manifest, which lists every file's own" -ForegroundColor DarkGray
        Write-Host "  SHA-256. Verify the collection later with:" -ForegroundColor DarkGray
        Write-Host "    .\Get-EvidenceManifest.ps1 -Path <collection> -Verify" -ForegroundColor DarkGray
    }
} catch {
    if ($pkg) { try { Close-ExcelPackage $pkg -NoSave } catch { } }
    throw
}
