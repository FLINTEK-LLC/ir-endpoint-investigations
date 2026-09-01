<#
.SYNOPSIS
    First-boot configuration for a per-case investigation host: mounts the
    case's cloud storage as D:, installs the DFIR toolkit, and applies
    baseline hardening. Called by fetch-and-bootstrap.ps1, not run directly.

.DESCRIPTION
    Mount credentials are deliberately never stored anywhere on this VM -
    rclone is configured to use the host's own ambient cloud identity (the
    EC2 instance role via env_auth on AWS, the VM's system-assigned managed
    identity via use_msi on Azure), which Terraform already scoped to
    read-only access on exactly this case's bucket/container. There is no
    access key, secret, or SAS token in the rclone config file this script
    writes.

.PARAMETER StorageIdentifier
    S3 bucket name (AWS) or "<storage-account>/<container>" (Azure).

.PARAMETER RepoRoot
    Local path to the already-extracted ir-endpoint-investigations checkout
    (fetch-and-bootstrap.ps1 downloads and extracts it before calling this).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CaseId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('AWS', 'Azure')]
    [string]$CloudProvider,

    [Parameter(Mandatory = $true)]
    [string]$StorageIdentifier,

    [Parameter(Mandatory = $true)]
    [string]$Region,

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    # Preferred drive letter for the case evidence mount. D: is the
    # documented default the rest of this project refers to, but see the
    # mount section below - if it's already taken (e.g. an Azure VM size
    # whose local temp disk lands on D:) this falls back to the first free
    # letter rather than silently failing.
    # D-Z only: A/B are historically floppy, C is the OS volume.
    [ValidatePattern('^[D-Zd-z]$')]
    [string]$MountDriveLetter = 'D',

    # Optional "<account>/<container>" holding licensed tooling this host
    # cannot download itself - see the KAPE staging step below.
    [string]$ToolsStorageIdentifier = '',

    # Fallback when ToolsStorageIdentifier is empty: any URL reachable
    # without interactive sign-in. May embed its own authorisation, so it is
    # never echoed to the log.
    [string]$ToolsZipUrl = '',

    # Windows time zone ID. UTC is deliberate for a forensic host - see the
    # clock section below. 'Eastern Standard Time', 'GMT Standard Time' etc.
    # are valid alternatives (tzutil /l lists them all).
    [string]$TimeZoneId = 'UTC'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Headers = @{ 'User-Agent' = 'bootstrap-investigation-host.ps1' }

Write-Host "=== bootstrap-investigation-host.ps1: case $CaseId on $CloudProvider ==="

function Install-KapeFromZip {
    # Flattens a KAPE zip to C:\Tools\kape no matter how deeply it nests.
    #
    # The previous version only looked ONE directory down, so a zip laid out
    # as kape/kape/kape.exe (which is what a real KAPE download produced)
    # left the tree nested and Setup-Workstation.ps1 never found kape.exe.
    # Search recursively for the binary and flatten from whatever directory
    # actually contains it.
    param([string]$ZipPath, [string]$Destination = 'C:\Tools\kape')

    $staging = Join-Path $env:TEMP ('kape-extract-' + [guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $staging -Force
    $exe = Get-ChildItem -LiteralPath $staging -Filter 'kape.exe' -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $exe) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }
    New-Item -ItemType Directory -Path $Destination -Force -ErrorAction SilentlyContinue | Out-Null
    Get-ChildItem -LiteralPath $exe.DirectoryName -Force | Move-Item -Destination $Destination -Force
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    return (Test-Path -LiteralPath (Join-Path $Destination 'kape.exe'))
}

# --- 0. Clock ---
# Azure Windows VMs boot on UTC. That is the RIGHT default for a forensic
# host - every timeline, log and report should be in UTC so artifacts from
# different hosts and timezones line up without mental arithmetic - so it is
# set explicitly here rather than left to chance. Override per case with
# -TimeZoneId if you would rather the box match your local wall clock; the
# tooling still records UTC internally either way.
try {
    Set-TimeZone -Id $TimeZoneId -ErrorAction Stop
    Write-Host "Time zone set to '$TimeZoneId' (now: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))"
} catch {
    Write-Host "Could not set time zone '$TimeZoneId': $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- 1. WinFsp + rclone - the drive-letter mount mechanism ---
Write-Host ""
Write-Host "=== Installing WinFsp + rclone ==="
$winFspRelease = Invoke-RestMethod -Uri 'https://api.github.com/repos/winfsp/winfsp/releases/latest' -Headers $Headers
$winFspAsset = $winFspRelease.assets | Where-Object { $_.name -match '\.msi$' } | Select-Object -First 1
if (-not $winFspAsset) { throw "No WinFsp MSI asset found in latest release ($($winFspRelease.tag_name))" }
$winFspMsi = Join-Path $env:TEMP 'winfsp.msi'
Invoke-WebRequest -Uri $winFspAsset.browser_download_url -Headers $Headers -OutFile $winFspMsi
$p = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$winFspMsi`" /quiet /norestart" -Wait -PassThru
Remove-Item -LiteralPath $winFspMsi -Force -ErrorAction SilentlyContinue
if ($p.ExitCode -ne 0) { throw "WinFsp msiexec exited $($p.ExitCode)" }

$rcloneDir = 'C:\Tools\rclone'
New-Item -ItemType Directory -Path $rcloneDir -Force | Out-Null
$rcloneZip = Join-Path $env:TEMP 'rclone.zip'
Invoke-WebRequest -Uri 'https://downloads.rclone.org/rclone-current-windows-amd64.zip' -Headers $Headers -OutFile $rcloneZip
$rcloneTmp = Join-Path $env:TEMP ("rclone_" + [guid]::NewGuid().ToString('N'))
Expand-Archive -LiteralPath $rcloneZip -DestinationPath $rcloneTmp -Force
$rcloneExtracted = Get-ChildItem -LiteralPath $rcloneTmp -Directory | Select-Object -First 1
Copy-Item -LiteralPath (Join-Path $rcloneExtracted.FullName 'rclone.exe') -Destination $rcloneDir -Force
Remove-Item -LiteralPath $rcloneZip, $rcloneTmp -Recurse -Force -ErrorAction SilentlyContinue
$rcloneExe = Join-Path $rcloneDir 'rclone.exe'
if (-not (Test-Path -LiteralPath $rcloneExe)) { throw "rclone.exe missing after extraction" }

# Add to the machine PATH so it's usable from any future session too, not
# just this bootstrap run.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -notlike "*$rcloneDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$rcloneDir", 'Machine')
}
$env:Path += ";$rcloneDir"

# --- 2. rclone remote - ambient identity only, no stored credentials ---
Write-Host ""
Write-Host "=== Configuring rclone remote (ambient cloud identity, no stored keys) ==="
$rcloneConfigDir = Join-Path $env:ProgramData 'rclone'
New-Item -ItemType Directory -Path $rcloneConfigDir -Force -ErrorAction SilentlyContinue | Out-Null
$rcloneConfigPath = Join-Path $rcloneConfigDir 'rclone.conf'

if ($CloudProvider -eq 'AWS') {
    # env_auth pulls credentials from the EC2 instance's IAM role via the
    # instance metadata service - confirmed against rclone's own docs.
    $remoteTarget = "case:$StorageIdentifier"
    @"
[case]
type = s3
provider = AWS
env_auth = true
region = $Region
"@ | Out-File -LiteralPath $rcloneConfigPath -Encoding ascii
} else {
    # use_msi (not env_auth, which conflicts with it per rclone's own docs)
    # pulls credentials from the VM's system-assigned managed identity.
    $accountAndContainer = $StorageIdentifier -split '/', 2
    $account = $accountAndContainer[0]
    $container = $accountAndContainer[1]
    $remoteTarget = "case:$container"
    @"
[case]
type = azureblob
account = $account
use_msi = true
"@ | Out-File -LiteralPath $rcloneConfigPath -Encoding ascii
}

# --- 3. Mount the case storage, and register a scheduled task so a reboot remounts it ---
Write-Host ""
Write-Host "=== Mounting case storage ==="

# D: is the documented evidence drive, but it is NOT safe to assume it is
# free, and Test-Path is NOT a sufficient check.
#
# Two separate things claim D: on an Azure Windows VM:
#   * a local temporary disk, on VM sizes that have one;
#   * the virtual DVD/CD-ROM drive Azure attaches to every Windows image,
#     which takes D: precisely on the no-temp-disk sizes this project
#     prefers (it lands on E: when a temp disk already holds D:).
#
# An optical drive with no media is INVISIBLE to Test-Path (returns False)
# but is a real, claimed drive letter - confirmed directly. The old check
# used Test-Path alone, so it saw D: as free, told rclone to mount there,
# and the mount lost to the DVD drive. Enumerate Win32_LogicalDisk instead,
# which lists empty optical and removable drives too.
$claimed = @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
    ForEach-Object { $_.DeviceID.TrimEnd(':').ToUpper() })
Write-Host "Drive letters already claimed: $($claimed -join ', ')"

if ($claimed -contains $MountDriveLetter.ToUpper()) {
    # Prefer relocating an optical drive over surrendering D:, so the
    # documented evidence letter stays what every other doc says it is.
    $optical = Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveType -eq 5 -and $_.DriveLetter -eq "${MountDriveLetter}:" }
    $relocated = $false
    if ($optical) {
        $spare = @('Z', 'Y', 'X', 'W') | Where-Object { $claimed -notcontains $_ } | Select-Object -First 1
        if ($spare) {
            try {
                Set-CimInstance -InputObject $optical -Property @{ DriveLetter = "${spare}:" } -ErrorAction Stop
                Write-Host "Moved the virtual DVD drive off ${MountDriveLetter}: to ${spare}: so evidence can use the documented letter."
                $relocated = $true
                $claimed = @($claimed | Where-Object { $_ -ne $MountDriveLetter.ToUpper() }) + $spare
            } catch {
                Write-Host "Could not move the DVD drive off ${MountDriveLetter}: ($($_.Exception.Message)) - will pick another letter instead." -ForegroundColor Yellow
            }
        }
    }
    if (-not $relocated) {
        $fallback = @('E', 'F', 'G', 'H', 'I', 'J', 'K') | Where-Object { $claimed -notcontains $_ } | Select-Object -First 1
        if (-not $fallback) { throw "${MountDriveLetter}: is taken and no fallback letter (E-K) is free." }
        Write-Host "WARNING: ${MountDriveLetter}: is claimed by something this script will not move. Mounting case evidence at ${fallback}: instead." -ForegroundColor Yellow
        $MountDriveLetter = $fallback
    }
}

$mountPoint = "${MountDriveLetter}:"
Write-Host "Mounting $remoteTarget at $mountPoint ..."
$mountArgs = "mount $remoteTarget $mountPoint --config `"$rcloneConfigPath`" --vfs-cache-mode writes --network-mode --volname `"Case $CaseId`""

$taskName = 'IR-Case-Mount'
$action = New-ScheduledTaskAction -Execute $rcloneExe -Argument $mountArgs
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

# Poll rather than sleeping a flat 15s - the mount usually appears in a
# couple of seconds, and a slow first run shouldn't be reported as failure.
$mounted = $false
foreach ($attempt in 1..15) {
    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath "$mountPoint\") { $mounted = $true; break }
}
if ($mounted) {
    Write-Host "$mountPoint mounted (case: $CaseId)"
} else {
    Write-Host "$mountPoint did not appear within 30s - check Task Scheduler history for the '$taskName' task, and C:\ir-bootstrap-fetch.log" -ForegroundColor Yellow
}

# Leave a breadcrumb the analyst can find after RDP'ing in, since the
# letter is no longer guaranteed to be D:.
"Case $CaseId evidence is mounted at $mountPoint (rclone remote: $remoteTarget)" |
    Out-File -LiteralPath 'C:\ir-case-mount.txt' -Encoding ascii -Force

# --- 4. DFIR toolkit - reuses this repo's own setup script exactly as-is ---
Write-Host ""
# --- 4pre. Licensed tooling (KAPE) from the shared tools container ---
# KAPE is gated behind Kroll licence acceptance, so it can never be fetched
# unattended from the internet. If the operator staged their own licensed
# copy in a private tools container, pull it here - BEFORE
# Setup-Workstation.ps1 runs, because that script only deploys the parsing
# toolchain (Deploy-Module.ps1 + Manage-Tools.ps1) when it finds kape.exe.
#
# Authentication is the VM's own managed identity, exactly as for the
# evidence mount: no key, no SAS, nothing written to disk. Terraform grants
# it "Storage Blob Data Reader" on the tools account only when
# tools_storage_account_id is set.
#
# Deliberately a SEPARATE account from case evidence - staging tools in an
# evidence container muddies chain of custody, inherits any WORM retention,
# and gets lifecycle-archived to cold tier.
if ($ToolsStorageIdentifier -and $CloudProvider -eq 'Azure') {
    Write-Host ""
    Write-Host "=== Staging licensed tooling from $ToolsStorageIdentifier ==="
    try {
        $toolsParts = $ToolsStorageIdentifier -split '/', 2
        $toolsAccount = $toolsParts[0]
        $toolsContainer = $toolsParts[1]

        # Second rclone remote, same ambient-identity pattern as [case].
        Add-Content -LiteralPath $rcloneConfigPath -Value @"

[tools]
type = azureblob
account = $toolsAccount
use_msi = true
"@

        $kapeStaging = Join-Path $env:TEMP 'kape-staging'
        New-Item -ItemType Directory -Path $kapeStaging -Force -ErrorAction SilentlyContinue | Out-Null
        & $rcloneExe copy "tools:$toolsContainer/kape.zip" $kapeStaging --config $rcloneConfigPath
        $kapeZip = Join-Path $kapeStaging 'kape.zip'
        if (Test-Path -LiteralPath $kapeZip) {
            if (Install-KapeFromZip -ZipPath $kapeZip) {
                Write-Host "KAPE staged to C:\Tools\kape - the full parsing toolchain will install."
            } else {
                Write-Host "WARNING: kape.zip downloaded but no kape.exe was found anywhere inside it. Check the zip's layout." -ForegroundColor Yellow
            }
        } else {
            Write-Host "WARNING: kape.zip not found in $ToolsStorageIdentifier. Upload it there, or install KAPE manually." -ForegroundColor Yellow
        }
        Remove-Item -LiteralPath $kapeStaging -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "WARNING: could not stage KAPE: $($_.Exception.Message). The host will come up without the parsing toolchain." -ForegroundColor Yellow
    }
} elseif ($ToolsZipUrl) {
    # Fallback path: a plain URL (OneDrive/SharePoint share link, artifact
    # repo, SAS). Deliberately never logged - a share link or SAS IS the
    # credential, and this log is world-readable on the host.
    Write-Host ""
    Write-Host "=== Staging licensed tooling from a URL ==="
    try {
        $kapeStaging = Join-Path $env:TEMP 'kape-staging'
        New-Item -ItemType Directory -Path $kapeStaging -Force -ErrorAction SilentlyContinue | Out-Null
        $kapeZip = Join-Path $kapeStaging 'kape.zip'
        Invoke-WebRequest -Uri $ToolsZipUrl -Headers $Headers -OutFile $kapeZip
        if (Install-KapeFromZip -ZipPath $kapeZip) {
            Write-Host "KAPE staged to C:\Tools\kape - the full parsing toolchain will install."
        } else {
            Write-Host "WARNING: download succeeded but no kape.exe was found inside it. If this is a OneDrive share link, confirm it returns the FILE and not an HTML preview page (append '&download=1')." -ForegroundColor Yellow
        }
        Remove-Item -LiteralPath $kapeStaging -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        # Message only - the URL itself stays out of the log.
        Write-Host "WARNING: could not download tooling from the configured URL: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# --- 4a. .NET Desktop Runtime - EZ Tools will not launch without it ---
# Setup-Workstation.ps1 fetches EZ Tools with `Get-ZimmermanTools.ps1
# -NetVersion 9`, and that script's net9 branch downloads ONLY /net9/ builds
# (confirmed from its own source). Those are framework-dependent binaries
# that need the .NET 9 DESKTOP runtime - which a stock Windows Server
# image does not have. Without this step the tools download successfully and
# then fail to start, which looks like a broken toolkit rather than a
# missing runtime.
#
# aka.ms/dotnet/9.0/windowsdesktop-runtime-win-x64.exe is Microsoft's stable
# alias (verified to redirect to a current build); the installer is a WiX
# bundle, so /install /quiet /norestart is the supported silent form.
Write-Host ""
Write-Host "=== Installing .NET 9 Desktop Runtime (required by EZ Tools) ==="
try {
    $dotnetExe = Join-Path $env:TEMP 'windowsdesktop-runtime-9-x64.exe'
    Invoke-WebRequest -Uri 'https://aka.ms/dotnet/9.0/windowsdesktop-runtime-win-x64.exe' -Headers $Headers -OutFile $dotnetExe
    $p = Start-Process -FilePath $dotnetExe -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
    Remove-Item -LiteralPath $dotnetExe -Force -ErrorAction SilentlyContinue
    # 0 = installed, 3010 = installed but wants a reboot, 1638 = a newer/equal
    # version is already present. All three mean "the runtime is there".
    if ($p.ExitCode -in @(0, 3010, 1638)) {
        Write-Host ".NET 9 Desktop Runtime present (installer exit $($p.ExitCode))"
    } else {
        Write-Host "WARNING: .NET 9 Desktop Runtime installer exited $($p.ExitCode). EZ Tools may fail to launch until it is installed manually." -ForegroundColor Yellow
    }
} catch {
    Write-Host "WARNING: could not install the .NET 9 Desktop Runtime: $($_.Exception.Message). EZ Tools may fail to launch." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Installing DFIR toolkit (Setup-Workstation.ps1) ==="
& powershell.exe -ExecutionPolicy Bypass -NonInteractive -File (Join-Path $RepoRoot 'scripts\Setup-Workstation.ps1') -ToolsRoot 'C:\Tools' -Mode Setup
if ($LASTEXITCODE -ne 0) {
    Write-Host "Setup-Workstation.ps1 exited $LASTEXITCODE - see its own output above for which component(s) failed" -ForegroundColor Yellow
}

# --- 5. Baseline hardening - modest, safe defaults, not a full CIS pass ---
Write-Host ""
Write-Host "=== Host hardening ==="
try {
    Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null
    Set-SmbServerConfiguration -RequireSecuritySignature $true -Force -ErrorAction SilentlyContinue
    Disable-LocalUser -Name 'Guest' -ErrorAction SilentlyContinue
    Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
    Write-Host "Applied: disabled SMBv1, required SMB signing, disabled the Guest account, confirmed Defender real-time protection is on"
} catch {
    Write-Host "One or more hardening steps failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- 6. Report what actually landed ---
# Setup-Workstation.ps1 reports a missing KAPE as status MANUAL, and its exit
# code only reflects FAILED - so a host with NO KAPE at all exits 0 and looks
# like a clean success. KAPE cannot be fetched automatically (Kroll gates it
# behind license acceptance), so on a stock cloud image it is genuinely
# absent, and with it the whole parsing toolchain: Deploy-Module.ps1 and
# Manage-Tools.ps1 are BOTH skipped, meaning no EZ Tools CLI parsers, no
# Hayabusa, Chainsaw, Hindsight or RegRipper either. State that plainly here
# rather than letting the analyst discover it mid-case.
Write-Host ""
Write-Host "=== Toolkit state ==="
$kapePresent = Test-Path -LiteralPath 'C:\Tools\kape\kape.exe'
$toolkitNotes = @()
if ($kapePresent) {
    Write-Host "KAPE: present - full parsing toolchain was installed."
    $toolkitNotes += "KAPE: present, parsing toolchain installed."
} else {
    Write-Host "KAPE: NOT PRESENT. Everything that depends on it was skipped -" -ForegroundColor Yellow
    Write-Host "  no KAPE, no EZ Tools CLI parsers, no Hayabusa/Chainsaw/Hindsight/RegRipper." -ForegroundColor Yellow
    Write-Host "  KAPE requires accepting Kroll's terms at https://www.kroll.com/kape, so it" -ForegroundColor Yellow
    Write-Host "  cannot be downloaded unattended. To make this host able to PARSE a" -ForegroundColor Yellow
    Write-Host "  collection, copy your licensed KAPE into C:\Tools\kape on this VM and run:" -ForegroundColor Yellow
    Write-Host "    powershell -File C:\ir-repo\<repo>\scripts\Setup-Workstation.ps1 -ToolsRoot C:\Tools -Mode Setup" -ForegroundColor Yellow
    $toolkitNotes += "KAPE: NOT PRESENT - parsing toolchain skipped. Copy KAPE to C:\Tools\kape and re-run Setup-Workstation.ps1 -Mode Setup."
}
foreach ($t in @(
        @{ Name = 'Sysinternals'; Path = 'C:\Tools\SysinternalsSuite' },
        @{ Name = 'EZ Tools GUI'; Path = 'C:\Tools\EZTools-GUI' })) {
    $present = Test-Path -LiteralPath $t.Path
    Write-Host ("{0}: {1}" -f $t.Name, $(if ($present) { 'present' } else { 'MISSING' }))
    $toolkitNotes += ("{0}: {1}" -f $t.Name, $(if ($present) { 'present' } else { 'MISSING' }))
}

# Fold the toolkit state into the same breadcrumb that records the mount, so
# one file on C:\ answers "where is my evidence and what can I run on it".
$toolkitNotes | Out-File -LiteralPath 'C:\ir-case-mount.txt' -Encoding ascii -Append

Write-Host ""
Write-Host "=== bootstrap-investigation-host.ps1 complete ==="
