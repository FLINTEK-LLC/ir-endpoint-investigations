<#
.SYNOPSIS
    Remaster a Windows x64 ISO with an EFI no-prompt El Torito boot entry.
.DESCRIPTION
    Run on Windows with the Windows ADK Deployment Tools (oscdimg.exe).
    Uses efi\microsoft\boot\efisys_noprompt.bin from the SAME source ISO;
    no boot binaries are downloaded or borrowed from another Windows version.
    The result is EFI-only, matching golden-image.pkr.hcl and its GPT layout.
    All source files are retained, but the boot catalog points to the no-prompt
    image. Merely replacing a visible efisys.bin file is insufficient.
    Mounts the source read-only and dismounts only if this script mounted it.
    Refuses to overwrite any existing output. Requires room for another ISO.
.EXAMPLE
    .\New-NoPromptWindowsIso.ps1 -SourceIso C:\Downloads\Win11_Pro.iso -OutputIso C:\Downloads\Win11_Pro-noprompt.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceIso,
    [Parameter(Mandatory = $true)][string]$OutputIso,
    [string]$OscdimgPath = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this helper on Windows (Mount-DiskImage and Windows ADK required).' }
$source = (Resolve-Path -LiteralPath $SourceIso).ProviderPath
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputIso)
if (Test-Path -LiteralPath $output) { throw "Output already exists; choose a new path: $output" }
if (-not (Test-Path -LiteralPath (Split-Path -Parent $output) -PathType Container)) {
    throw 'The output directory must already exist.'
}
if (-not (Test-Path -LiteralPath $OscdimgPath -PathType Leaf)) {
    throw 'Install Windows ADK Deployment Tools, or supply -OscdimgPath to oscdimg.exe.'
}
$mountedHere = $false
$orderFile = $null
try {
    $disk = Get-DiskImage -ImagePath $source
    if (-not $disk.Attached) {
        $disk = Mount-DiskImage -ImagePath $source -Access ReadOnly -PassThru
        $mountedHere = $true
    }
    $volumes = @($disk | Get-Volume | Where-Object { $_.DriveLetter })
    if ($volumes.Count -ne 1) { throw 'Expected exactly one mounted ISO volume with a drive letter.' }
    $media = "$($volumes[0].DriveLetter):\"
    $bootImage = Join-Path $media 'efi\microsoft\boot\efisys_noprompt.bin'
    foreach ($relative in @('efi\microsoft\boot\efisys_noprompt.bin', 'efi\boot\bootx64.efi', 'sources\boot.wim', 'setup.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $media $relative) -PathType Leaf)) {
            throw "Source must be a Windows x64 installer ISO containing $relative. Use original Microsoft media with the matching no-prompt image."
        }
    }
    # Microsoft requires boot-file ordering for images larger than 4.5 GB.
    # Paths are relative to the media root; ASCII is ANSI-compatible here.
    $orderFile = [IO.Path]::GetTempFileName()
    $bootFiles = @('efi\microsoft\boot\efisys_noprompt.bin', 'efi\boot\bootx64.efi',
        'bootmgr', 'bootmgr.efi', 'boot\bcd', 'efi\microsoft\boot\bcd',
        'boot\boot.sdi', 'sources\boot.wim')
    $bootFiles | Where-Object { Test-Path -LiteralPath (Join-Path $media $_) -PathType Leaf } |
        Set-Content -LiteralPath $orderFile -Encoding Ascii
    $arguments = @('-m', '-o', '-h', '-u2', '-udfver102', '-lWIN11_NOPROMPT',
        "-bootdata:1#pEF,e,b$bootImage", "-yo$orderFile", $media, $output)
    & $OscdimgPath @arguments
    if ($LASTEXITCODE -ne 0) { throw "oscdimg failed with exit code $LASTEXITCODE. Remove any partial output before retrying: $output" }
    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) { throw 'oscdimg did not produce the output ISO.' }
    $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "iso_url=$output"
    Write-Host "iso_checksum=sha256:$hash"
} finally {
    if ($orderFile) { Remove-Item -LiteralPath $orderFile -Force }
    if ($mountedHere) { Dismount-DiskImage -ImagePath $source | Out-Null }
}
