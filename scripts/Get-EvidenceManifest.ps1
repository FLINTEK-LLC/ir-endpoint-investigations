<#
.SYNOPSIS
    Writes a SHA-256 manifest of a collection, or verifies one written earlier.

.DESCRIPTION
    This project could tell you what was IN a collection but not that the
    collection was still what it had been. Versioning and Object Lock on the
    evidence bucket make tampering hard; they do not let you state what the
    bytes were when you received them. That is what a manifest is for.

    Hash on arrival, before anything else touches the collection. Verify again
    whenever it matters: after the upload, after the download onto an
    investigation host, before you write up findings, or when someone asks
    six months later whether the copy in the archive is the copy you worked.

    SHA-256 rather than MD5 or SHA-1. Both of those still appear in forensic
    tooling for historical reasons, and both have practical collision attacks;
    the point of this file is to be worth something in an argument.

.PARAMETER Path
    Folder to hash (a collection root), or a single file such as a .zip.

.PARAMETER ManifestPath
    Where to write, or where to read when verifying. Defaults to
    evidence-manifest.csv beside the target.

.PARAMETER Verify
    Re-hash and compare against an existing manifest instead of writing one.
    Reports changed, missing and added files, and exits non-zero if any of
    those are found so a scripted caller can act on it.

.EXAMPLE
    .\Get-EvidenceManifest.ps1 -Path D:\cases\INC1234\HOST01
    .\Get-EvidenceManifest.ps1 -Path D:\cases\INC1234\HOST01 -Verify
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [string]$ManifestPath,

    [switch]$Verify
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) { throw "Path not found: $Path" }
$target = Get-Item -LiteralPath $Path
$isDir = $target.PSIsContainer

if (-not $ManifestPath) {
    $ManifestPath = if ($isDir) {
        Join-Path $target.FullName 'evidence-manifest.csv'
    } else {
        Join-Path $target.DirectoryName "$($target.BaseName)-manifest.csv"
    }
}

function Get-Entries {
    param([System.IO.FileSystemInfo]$Root, [bool]$Directory, [string]$SkipFullName)

    $files = if ($Directory) {
        # -Force so hidden/system files are included: leaving them out would
        # make the manifest quietly incomplete, which is worse than not having
        # one. Sorted so two runs over the same tree produce identical files.
        Get-ChildItem -LiteralPath $Root.FullName -Recurse -File -Force | Sort-Object FullName
    } else {
        @($Root)
    }

    $base = if ($Directory) { $Root.FullName.TrimEnd('\') + '\' } else { $Root.DirectoryName.TrimEnd('\') + '\' }
    $total = @($files).Count
    $n = 0

    foreach ($f in $files) {
        $n++
        # The manifest must never include itself - it does not exist yet on the
        # first run and would differ on every later one.
        if ($SkipFullName -and $f.FullName -eq $SkipFullName) { continue }
        if ($total -gt 50 -and ($n % 250 -eq 0)) {
            Write-Progress -Activity 'Hashing' -Status "$n of $total" -PercentComplete (($n / $total) * 100)
        }
        try {
            $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        } catch {
            # A file locked by another process is a fact about the collection,
            # not a reason to abandon the manifest. Record it and move on.
            $hash = "ERROR: $($_.Exception.Message -replace ',', ';')"
        }
        [pscustomobject]@{
            RelativePath     = $f.FullName.Substring($base.Length)
            SizeBytes        = $f.Length
            SHA256           = $hash
            LastWriteTimeUtc = $f.LastWriteTimeUtc.ToString('o')
        }
    }
    Write-Progress -Activity 'Hashing' -Completed
}

# ---------------------------------------------------------------------------
if ($Verify) {
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "No manifest to verify at $ManifestPath" }
    Write-Host "Verifying $($target.FullName)" -ForegroundColor Cyan
    Write-Host "  against $ManifestPath"

    $expected = @{}
    foreach ($row in (Import-Csv -LiteralPath $ManifestPath)) { $expected[$row.RelativePath] = $row }

    $actual = @{}
    foreach ($row in (Get-Entries -Root $target -Directory $isDir -SkipFullName $ManifestPath)) { $actual[$row.RelativePath] = $row }

    $changed = @(); $missing = @(); $added = @()
    foreach ($k in $expected.Keys) {
        if (-not $actual.ContainsKey($k)) { $missing += $k; continue }
        if ($actual[$k].SHA256 -ne $expected[$k].SHA256) { $changed += $k }
    }
    foreach ($k in $actual.Keys) { if (-not $expected.ContainsKey($k)) { $added += $k } }

    Write-Host ""
    Write-Host ("  files in manifest : {0}" -f $expected.Count)
    Write-Host ("  files on disk     : {0}" -f $actual.Count)
    Write-Host ""
    if ($changed.Count -eq 0 -and $missing.Count -eq 0 -and $added.Count -eq 0) {
        Write-Host "  VERIFIED - every file matches its recorded hash." -ForegroundColor Green
        exit 0
    }
    if ($changed.Count) {
        Write-Host "  CHANGED ($($changed.Count)):" -ForegroundColor Red
        $changed | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        if ($changed.Count -gt 20) { Write-Host "    ... and $($changed.Count - 20) more" -ForegroundColor Red }
    }
    if ($missing.Count) {
        Write-Host "  MISSING ($($missing.Count)):" -ForegroundColor Red
        $missing | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        if ($missing.Count -gt 20) { Write-Host "    ... and $($missing.Count - 20) more" -ForegroundColor Red }
    }
    if ($added.Count) {
        Write-Host "  ADDED ($($added.Count)) - not in the manifest:" -ForegroundColor Yellow
        $added | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        if ($added.Count -gt 20) { Write-Host "    ... and $($added.Count - 20) more" -ForegroundColor Yellow }
    }
    Write-Host ""
    Write-Host "  Parsing writes its output alongside a collection, so 'ADDED' is" -ForegroundColor DarkGray
    Write-Host "  expected if you hashed before parsing. CHANGED or MISSING is not." -ForegroundColor DarkGray
    exit 1
}

# ---------------------------------------------------------------------------
Write-Host "Hashing $($target.FullName)" -ForegroundColor Cyan
$started = Get-Date
$entries = @(Get-Entries -Root $target -Directory $isDir -SkipFullName $ManifestPath)

$entries | Export-Csv -LiteralPath $ManifestPath -NoTypeInformation -Encoding UTF8

$bytes = ($entries | Measure-Object -Property SizeBytes -Sum).Sum
$errors = @($entries | Where-Object { $_.SHA256 -like 'ERROR:*' })

Write-Host ""
Write-Host ("  files   : {0}" -f $entries.Count)
Write-Host ("  bytes   : {0:N0} ({1:N2} GB)" -f $bytes, ($bytes / 1GB))
Write-Host ("  elapsed : {0:mm\:ss}" -f ((Get-Date) - $started))
if ($errors.Count) {
    Write-Host ("  unreadable: {0} (recorded in the manifest as ERROR rows)" -f $errors.Count) -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Manifest: $ManifestPath" -ForegroundColor Green
Write-Host ""
Write-Host "  Verify later with:" -ForegroundColor DarkGray
Write-Host "    .\Get-EvidenceManifest.ps1 -Path `"$($target.FullName)`" -Verify" -ForegroundColor DarkGray
