[CmdletBinding()]
param(
    [string]$ToolsRoot = 'C:\Tools',
    [ValidateSet('Setup', 'Update')]
    [string]$Mode = 'Setup',

    # Which tiers from workstation-tools.json to install. Optional tools are
    # opt-in; -Include names one regardless of tier or Enabled flag.
    [ValidateSet('Standard', 'Optional', 'All')]
    [string]$Tier = 'Standard',

    # Wildcards match tool Names. -Include overrides tier and Enabled;
    # -Exclude always wins.
    [string[]]$Include,
    [string[]]$Exclude,

    # Resolve every download and report what WOULD be installed, touching
    # nothing. Cheap way to check a workstation-tools.json edit is valid.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Headers = @{ 'User-Agent' = 'Setup-Workstation.ps1' }

New-Item -ItemType Directory -Path $ToolsRoot -Force -ErrorAction SilentlyContinue | Out-Null

$KapePath = Join-Path $ToolsRoot 'kape'
$results = @()
$script:installedManifest = @()

function Add-Result {
    param([string]$Component, [string]$Status, [string]$Detail)
    $script:results += [pscustomobject]@{ Component = $Component; Status = $Status; Detail = $Detail }
}

function Get-LatestReleaseAsset {
    param([string]$Repo, [string]$Pattern)
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $Headers
    $asset = $release.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    return [pscustomobject]@{ Tag = $release.tag_name; Asset = $asset }
}

# --- KAPE itself ---
# KAPE requires accepting Kroll's license/registration at https://www.kroll.com/kape - it
# is not available as a plain public download, so this is a manual prerequisite, exactly
# like Forensic_Collector.exe. This script only checks for it and deploys the
# ir-endpoint-investigations module on top once it's present.
Write-Host "=== KAPE core ==="
if (-not (Test-Path (Join-Path $KapePath 'kape.exe'))) {
    Add-Result 'KAPE' 'MANUAL' "kape.exe not found at $KapePath. Download from https://www.kroll.com/kape (requires accepting Kroll's terms) and extract to $KapePath before running this script again."
    Write-Host "kape.exe not found - see manual step in summary." -ForegroundColor Yellow
} else {
    Write-Host "kape.exe found at $KapePath"

    # Deploy this project's own module + scripts onto the KAPE install. Delegates to
    # Deploy-Module.ps1 (a small standalone script) rather than duplicating the copy
    # logic here - run that script directly for a fast redeploy without the rest of
    # this script's slower tool-fetching steps.
    $binDest = Join-Path $KapePath 'Modules\bin'
    $localDest = Join-Path $KapePath 'Modules\!Local'
    try {
        & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File (Join-Path $PSScriptRoot 'Deploy-Module.ps1') -KapePath $KapePath
        if ($LASTEXITCODE -eq 0) {
            Add-Result 'ir-endpoint-investigations module' 'OK' "Deployed Manage-Tools.ps1 / Run-IRParse.ps1 to $binDest and IR_00_ToolVerify.mkape / IR_Compound_Full.mkape to $localDest"
        } else {
            Add-Result 'ir-endpoint-investigations module' 'FAILED' "Deploy-Module.ps1 exited $LASTEXITCODE"
        }
    } catch {
        Add-Result 'ir-endpoint-investigations module' 'FAILED' $_.Exception.Message
    }

    try {
        $manageToolsMode = if ($Mode -eq 'Update') { 'Update' } else { 'Setup' }
        & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File (Join-Path $binDest 'Manage-Tools.ps1') -KapePath $KapePath -Mode $manageToolsMode
        if ($LASTEXITCODE -eq 0) {
            Add-Result 'KAPE toolchain (EZ Tools/Hayabusa/Chainsaw/Hindsight/RegRipper)' 'OK' "Manage-Tools.ps1 -Mode $manageToolsMode succeeded"
        } else {
            Add-Result 'KAPE toolchain (EZ Tools/Hayabusa/Chainsaw/Hindsight/RegRipper)' 'FAILED' "Manage-Tools.ps1 -Mode $manageToolsMode exited $LASTEXITCODE - see its own output above"
        }
    } catch {
        Add-Result 'KAPE toolchain (EZ Tools/Hayabusa/Chainsaw/Hindsight/RegRipper)' 'FAILED' $_.Exception.Message
    }
}
# --- Analyst workstation tools (config-driven) ---
# The list lives in workstation-tools.json, not in this script, so adding or
# retiering a tool is a data edit rather than a code change. See that file's
# comment block for the schema.
#
# Downloads run in PARALLEL but installs run SERIALLY, and that split is
# deliberate: fetching is IO-bound and benefits from concurrency, but Windows
# Installer holds a machine-wide mutex, so two MSIs at once would simply
# collide. PowerShell 5.1 has no ForEach-Object -Parallel, hence Start-Job.
Write-Host ""
Write-Host "=== Analyst workstation tools ==="

$toolsConfigPath = Join-Path $PSScriptRoot 'workstation-tools.json'
$tools = @()
if (Test-Path -LiteralPath $toolsConfigPath) {
    try {
        $tools = @((Get-Content -Raw -LiteralPath $toolsConfigPath | ConvertFrom-Json).tools)
    } catch {
        Add-Result 'workstation-tools.json' 'FAILED' "Could not parse: $($_.Exception.Message)"
    }
} else {
    Add-Result 'workstation-tools.json' 'FAILED' "Not found at $toolsConfigPath"
}

# -Include wins over everything: ask for a tool by name and you get it, even
# if it is Optional or Enabled=false.
$selected = foreach ($t in $tools) {
    $named = $Include -and ($Include | Where-Object { $t.Name -like $_ })
    if ($Exclude -and ($Exclude | Where-Object { $t.Name -like $_ })) { continue }
    if ($named) { $t; continue }
    if (-not $t.Enabled) { continue }
    if ($Tier -eq 'All' -or $t.Tier -eq $Tier) { $t }
}
$selected = @($selected)
Write-Host ("Selected {0} of {1} tool(s): {2}" -f $selected.Count, $tools.Count, (($selected | ForEach-Object { $_.Name }) -join ', '))

# Say WHY the rest were left out. Without this, "-Tier All selected 6 of 8"
# reads like a bug rather than two tools being Enabled=false on purpose.
$skipped = @($tools | Where-Object { $_.Name -notin @($selected | ForEach-Object { $_.Name }) })
if ($skipped.Count -gt 0) {
    foreach ($grp in $skipped | Group-Object { if (-not $_.Enabled) { 'disabled in config' } elseif ($Exclude -and ($Exclude | Where-Object { $_.Name -like $_ })) { 'excluded' } else { "tier '$($_.Tier)'" } }) {
        Write-Host ("  not selected ({0}): {1}" -f $grp.Name, (($grp.Group | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor DarkGray
    }
    Write-Host "  (enable in workstation-tools.json, or force one with -Include <name>)" -ForegroundColor DarkGray
}

function Resolve-ToolDownload {
    # Turn a config entry into a concrete Url / Version / FileName.
    param($Tool)
    switch ($Tool.Source.Type) {
        'GitHubRelease' {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$($Tool.Source.Repo)/releases/latest" -Headers $Headers
            $asset = $rel.assets | Where-Object { $_.name -match $Tool.Source.AssetPattern } | Select-Object -First 1
            if (-not $asset) { throw "No asset in $($rel.tag_name) matched the configured AssetPattern" }
            return [pscustomobject]@{ Url = $asset.browser_download_url; Version = $rel.tag_name; FileName = $asset.name }
        }
        'Url' {
            return [pscustomobject]@{ Url = $Tool.Source.Url; Version = 'n/a'; FileName = ([uri]$Tool.Source.Url).Segments[-1] }
        }
        'PSModule' {
            # Nothing to download - Install-Module does its own fetching.
            return [pscustomobject]@{ Url = "psgallery:$($Tool.Source.Module)"; Version = 'latest'; FileName = $null }
        }
        default { throw "Unknown Source.Type" }
    }
}

# Resolve first (serial, cheap), then download (parallel).
$plan = @()
foreach ($t in $selected) {
    try {
        $d = Resolve-ToolDownload -Tool $t
        $plan += [pscustomobject]@{
            Tool = $t; Url = $d.Url; Version = $d.Version
            FileName = $d.FileName; Path = (Join-Path $env:TEMP $d.FileName)
        }
    } catch {
        Add-Result $t.Name 'FAILED' "Could not resolve download: $($_.Exception.Message)"
    }
}

if ($plan.Count -gt 0 -and -not $DryRun) {
    Write-Host "Downloading $($plan.Count) tool(s) in parallel..."
    $jobs = foreach ($item in ($plan | Where-Object { $_.Tool.Source.Type -ne 'PSModule' })) {
        Start-Job -ScriptBlock {
            param($Url, $Path)
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
        } -ArgumentList $item.Url, $item.Path
    }
    $null = $jobs | Wait-Job -Timeout 1800
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
}

foreach ($item in $plan) {
    $t = $item.Tool
    if ($DryRun) {
        Add-Result $t.Name 'WOULD INSTALL' "$($item.Version) from $($item.Url)"
        continue
    }
    try {
        if ($t.Install.Type -ne 'PSModule' -and -not (Test-Path -LiteralPath $item.Path)) { throw "download did not produce $($item.FileName)" }
        switch ($t.Install.Type) {
            'Msi' {
                $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$($item.Path)`" /quiet /norestart" -Wait -PassThru
                if ($proc.ExitCode -notin @(0, 3010, 1638)) { throw "msiexec exited $($proc.ExitCode)" }
            }
            'Zip' {
                $dest = Join-Path $ToolsRoot $t.Install.Dest
                $staging = Join-Path $env:TEMP ("tool-" + [guid]::NewGuid().ToString('N'))
                Expand-Archive -LiteralPath $item.Path -DestinationPath $staging -Force
                $root = $staging
                if ($t.Install.Flatten) {
                    $only = @(Get-ChildItem -LiteralPath $staging -Force)
                    if ($only.Count -eq 1 -and $only[0].PSIsContainer) { $root = $only[0].FullName }
                }
                New-Item -ItemType Directory -Path $dest -Force -ErrorAction SilentlyContinue | Out-Null
                Get-ChildItem -LiteralPath $root -Force | Copy-Item -Destination $dest -Recurse -Force
                Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            }
            'Exe' {
                $dest = Join-Path $ToolsRoot $t.Install.Dest
                New-Item -ItemType Directory -Path $dest -Force -ErrorAction SilentlyContinue | Out-Null
                $name = if ($t.Install.FileName) { $t.Install.FileName } else { $item.FileName }
                Copy-Item -LiteralPath $item.Path -Destination (Join-Path $dest $name) -Force
            }
            'PSModule' {
                # AllUsers so the module is available to the SYSTEM-context
                # scheduled tasks and to any analyst who logs in, not just
                # whoever happened to run setup.
                if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                    Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
                }
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
                Install-Module -Name $t.Source.Module -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
            }
            default { throw "Unknown Install.Type" }
        }
        Remove-Item -LiteralPath $item.Path -Force -ErrorAction SilentlyContinue

        # Verify rather than trusting an exit code.
        $ok = $true
        $detail = "$($item.Version)"
        if ($t.Verify.Path) {
            $verifyPath = Join-Path $ToolsRoot $t.Verify.Path
            $ok = Test-Path -LiteralPath $verifyPath
            $detail = "$($item.Version) -> $verifyPath"
        } elseif ($t.Verify.Module) {
            $m = Get-Module -ListAvailable $t.Verify.Module | Sort-Object Version -Descending | Select-Object -First 1
            $ok = [bool]$m
            if ($m) { $detail = "v$($m.Version) (PowerShell module)" }
        } elseif ($t.Verify.Registry) {
            $ok = [bool](Get-ItemProperty -Path @(
                    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
                ) -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $t.Verify.Registry })
        }
        if ($ok) {
            Add-Result $t.Name 'OK' $detail
            $script:installedManifest += [pscustomobject]@{
                Name = $t.Name; Version = $item.Version; Source = $item.Url
                Why = $t.Why; InstalledUtc = (Get-Date).ToUniversalTime().ToString('o')
            }
        } else {
            Add-Result $t.Name 'FAILED' 'installed but verification failed'
        }
    } catch {
        Add-Result $t.Name 'FAILED' $_.Exception.Message
    }
}

# --- EZ Tools GUI suite ---
# Stays bespoke: Get-ZimmermanTools.ps1 is its own updater with its own
# manifest and idempotency, which a generic fetcher would only wrap badly.
Write-Host ""
Write-Host "=== EZ Tools GUI suite (Timeline Explorer, Registry Explorer, ...) ==="
if ($DryRun) {
    Add-Result 'EZ Tools GUI suite' 'WOULD INSTALL' 'via Get-ZimmermanTools.ps1'
} else {
    try {
        $guiDest = Join-Path $ToolsRoot 'EZTools-GUI'
        New-Item -ItemType Directory -Path $guiDest -Force -ErrorAction SilentlyContinue | Out-Null
        $getZT = Join-Path $guiDest 'Get-ZimmermanTools.ps1'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/EricZimmerman/Get-ZimmermanTools/master/Get-ZimmermanTools.ps1' -Headers $Headers -OutFile $getZT
        & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File $getZT -Dest $guiDest -NetVersion 9
        Add-Result 'EZ Tools GUI suite' 'OK' "Fetched to $guiDest"
        $script:installedManifest += [pscustomobject]@{
            Name = 'EZ Tools GUI suite'; Version = 'rolling'
            Source = 'https://ericzimmerman.github.io'
            Why = 'Timeline Explorer / Registry Explorer - the primary review GUIs for KAPE output.'
            InstalledUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
    } catch {
        Add-Result 'EZ Tools GUI suite' 'FAILED' $_.Exception.Message
    }
}

# --- Arsenal Image Mounter ---
Write-Host ""
Write-Host "=== Arsenal Image Mounter ==="
Add-Result 'Arsenal Image Mounter' 'MANUAL' 'No scriptable public download (a MEGA link on https://arsenalrecon.com/downloads that changes per release). Install manually, then launch it once to register its mount driver.'


# --- Summary ---
Write-Host ""
Write-Host "=== Setup-Workstation summary ($Mode) ==="
foreach ($r in $results) {
    $color = switch ($r.Status) { 'OK' { 'Green' }; 'MANUAL' { 'Yellow' }; default { 'Red' } }
    Write-Host ("{0,-55} {1,-7} {2}" -f $r.Component, $r.Status, $r.Detail) -ForegroundColor $color
}

# --- Tool manifest ---
# Records what is actually on this host, with resolved versions. Six months
# into a matter, 'which MFTECmd parsed this evidence?' has an answer that is
# not someone's memory. Written next to the case breadcrumb the cloud
# bootstrap already leaves, so one place on C:\ tells the whole story.
if (-not $DryRun -and $script:installedManifest.Count -gt 0) {
    $manifestPath = 'C:\ir-toolkit-manifest.json'
    try {
        [pscustomobject]@{
            GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
            Host         = $env:COMPUTERNAME
            ToolsRoot    = $ToolsRoot
            Mode         = $Mode
            Tier         = $Tier
            Tools        = $script:installedManifest
        } | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $manifestPath -Encoding utf8
        Write-Host ""
        Write-Host "Tool manifest written to $manifestPath ($($script:installedManifest.Count) tools)." -ForegroundColor Green
    } catch {
        Write-Host "Could not write the tool manifest: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($results | Where-Object { $_.Status -eq 'FAILED' }) { exit 1 } else { exit 0 }
