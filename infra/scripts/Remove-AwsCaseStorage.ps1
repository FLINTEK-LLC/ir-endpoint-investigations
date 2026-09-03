<#
.SYNOPSIS
    Permanently deletes a case's S3 evidence bucket, including every object
    version and delete marker.

.DESCRIPTION
    THIS DESTROYS EVIDENCE. It exists because `aws s3 rb --force` does not
    work on these buckets and the correct alternative is genuinely awkward.

    The case-storage module enables versioning (so an accidental overwrite
    never loses the original), which means deleting an object only writes a
    delete marker on top of it. `aws s3 rm --recursive` removes current
    versions, leaves every noncurrent version and marker behind, and the
    bucket delete then fails with BucketNotEmpty - having looked like it
    worked.

    The documented CLI answer is to pass a JSON document of key/version pairs
    to `aws s3api delete-objects` on the command line. On Windows that is the
    quoting trap this project has been bitten by repeatedly: braces and quotes
    in an argument do not survive intact, and the failure is a confusing
    parameter error rather than an obvious one. So this enumerates versions
    and deletes them one API call at a time instead - slower, but it cannot
    be silently mangled.

    Object Lock: if the case was created with enable_immutability = true,
    versions under retention CANNOT be deleted before their retention expires,
    and under COMPLIANCE mode not even by the account root. That is the
    feature working as intended. This script reports such failures rather than
    pretending to succeed.

.PARAMETER BucketName
    The bucket to destroy, e.g. ir-case-awstest-01.

.PARAMETER Force
    Skip the typed confirmation. For scripted teardown only.

.EXAMPLE
    .\Remove-AwsCaseStorage.ps1 -BucketName ir-case-awstest-01
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BucketName,

    [string]$AwsProfile = 'ir-cloud',
    [string]$Region = 'us-east-1',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command aws -CommandType Application -ErrorAction SilentlyContinue)) {
    throw "aws CLI not found - run infra\scripts\Test-Prerequisites.ps1 (elevated) first."
}

function Invoke-Aws {
    param([Parameter(ValueFromRemainingArguments)][string[]]$CliArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & aws @CliArgs --profile $AwsProfile --region $Region --output json 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { throw "aws $($CliArgs -join ' ') failed: $(($raw | Out-String).Trim())" }
    $text = ($raw | Out-String).Trim()
    if (-not $text) { return $null }
    return ($text | ConvertFrom-Json)
}

# --- Show what is about to be destroyed, before asking ---
Write-Host "Inspecting s3://$BucketName ..." -ForegroundColor Cyan
$versions = Invoke-Aws s3api list-object-versions --bucket $BucketName
$objVersions = @($versions.Versions)
$markers = @($versions.DeleteMarkers)
$totalBytes = ($objVersions | Measure-Object -Property Size -Sum).Sum
if (-not $totalBytes) { $totalBytes = 0 }

Write-Host "  object versions : $($objVersions.Count)"
Write-Host "  delete markers  : $($markers.Count)"
Write-Host "  total size      : $([math]::Round($totalBytes/1GB, 2)) GB"

# Warn if the bucket is locked - the delete will partly fail and that is correct.
$lock = $null
try { $lock = Invoke-Aws s3api get-object-lock-configuration --bucket $BucketName } catch { }
if ($lock -and $lock.ObjectLockConfiguration.ObjectLockEnabled -eq 'Enabled') {
    $mode = $lock.ObjectLockConfiguration.Rule.DefaultRetention.Mode
    Write-Host ""
    Write-Host "  Object Lock is ENABLED on this bucket (mode: $mode)." -ForegroundColor Yellow
    Write-Host "  Versions still under retention cannot be deleted - by design." -ForegroundColor Yellow
    if ($mode -eq 'COMPLIANCE') {
        Write-Host "  COMPLIANCE mode: not even the account root can remove them early." -ForegroundColor Yellow
    }
}

if ($objVersions.Count -eq 0 -and $markers.Count -eq 0) {
    Write-Host "Bucket is already empty." -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "This permanently destroys the evidence in this bucket. There is no undo." -ForegroundColor Red
    if (-not $Force) {
        $typed = Read-Host "Type the bucket name to confirm"
        if ($typed -ne $BucketName) {
            Write-Host "Name did not match - nothing was deleted." -ForegroundColor Yellow
            return
        }
    }

    $failed = 0
    $done = 0
    foreach ($item in @($objVersions + $markers)) {
        try {
            Invoke-Aws s3api delete-object --bucket $BucketName --key $item.Key --version-id $item.VersionId | Out-Null
            $done++
            if ($done % 25 -eq 0) { Write-Host "  deleted $done of $($objVersions.Count + $markers.Count)..." -ForegroundColor DarkGray }
        } catch {
            $failed++
            if ($failed -le 3) { Write-Host "  could not delete $($item.Key) ($($item.VersionId)): $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }
    Write-Host "  deleted $done version(s)/marker(s); $failed failed."
    if ($failed -gt 0) {
        Write-Host "Failures are expected if Object Lock retention is still in force - the" -ForegroundColor Yellow
        Write-Host "bucket cannot be removed until it expires. That is the feature working." -ForegroundColor Yellow
        return
    }
}

Invoke-Aws s3api delete-bucket --bucket $BucketName | Out-Null
Write-Host "Deleted bucket s3://$BucketName" -ForegroundColor Green
Write-Host ""
Write-Host "Confirm the account is clear with:" -ForegroundColor DarkGray
Write-Host "  .\Test-AwsTeardown.ps1 -AllRegions" -ForegroundColor DarkGray
