[CmdletBinding()]
param(
    [string]$KapePath,
    [ValidateSet('Verify', 'Setup', 'Update')]
    [string]$Mode = 'Verify'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $KapePath) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    # scripts live at <kape>\Modules\bin, so kape root is two levels up
    $candidate = Split-Path -Parent (Split-Path -Parent $scriptDir)
    if (Test-Path (Join-Path $candidate 'kape.exe')) {
        $KapePath = $candidate
    } else {
        # Matches the README's documented install location and every other script's
        # own default - previously fell back to 'C:\KAPE' here, a different,
        # undocumented path that silently pointed at nothing on a standard install.
        $KapePath = 'C:\Tools\KAPE'
    }
}

$BinPath = Join-Path $KapePath 'Modules\bin'
$Headers = @{ 'User-Agent' = 'Manage-Tools.ps1' }
# Explicit path, not a bare `tar` call - a machine with Git for Windows installed
# (this project already requires git on PATH) commonly has Git\usr\bin ahead of
# System32 in PATH, and Git's own tar treats "C:\..." as remote host:file syntax
# ("Cannot connect to C: resolve failed") instead of extracting locally. The
# Windows-bundled bsdtar at this fixed path doesn't have that problem.
$TarExe = Join-Path $env:SystemRoot 'System32\tar.exe'

# Ground-truth layout: paths as actually installed under Modules\bin, not the
# aspirational "EZTools\" subfolder some designs assume. EZ Tools and Hayabusa
# already sit at the bin root / bin\hayabusa on this KAPE install.
#
# Tier is Core or Auxiliary, not just a Group label. Core = EZ Tools - the baseline
# KAPE parsers IR_Compound_Full's stock modules directly depend on; without these,
# most of a parse produces nothing. Auxiliary = the detection/enrichment layer
# (Hayabusa, Chainsaw, Hindsight, RegRipper, NirSoft) - each adds real value, but
# IR_Compound_Full still produces a useful parse without any one of them (KAPE just
# skips that module's processor). Verify/Setup only fail (exit 1, which
# Run-IRParse.ps1 treats as "abort without running KAPE") on a missing Core tool;
# a missing Auxiliary tool is reported but doesn't block a run - see Invoke-Verify/
# Invoke-Setup. This was a real problem before: one flaky Auxiliary fetch (e.g.
# nirsoft.net being unreachable) used to fail Setup/Verify entirely and block
# Run-IRParse.ps1 from running KAPE at all, even with every Core tool present.
$RequiredItems = @(
    @{ Name = 'MFTECmd';               RelPath = 'MFTECmd.exe';                                   Type = 'File'; Group = 'EZTools';   Tier = 'Core' }
    @{ Name = 'PECmd';                 RelPath = 'PECmd.exe';                                     Type = 'File'; Group = 'EZTools';   Tier = 'Core' }
    @{ Name = 'RECmd';                 RelPath = 'RECmd\RECmd.exe';                               Type = 'File'; Group = 'EZTools';   Tier = 'Core' }
    @{ Name = 'AppCompatCacheParser';  RelPath = 'AppCompatCacheParser.exe';                       Type = 'File'; Group = 'EZTools';   Tier = 'Core' }
    @{ Name = 'AmcacheParser';         RelPath = 'AmcacheParser.exe';                              Type = 'File'; Group = 'EZTools';   Tier = 'Core' }
    @{ Name = 'LECmd';                 RelPath = 'LECmd.exe';                                     Type = 'File'; Group = 'EZTools';   Tier = 'Core' }
    @{ Name = 'JLECmd';                RelPath = 'JLECmd.exe';                                    Type = 'File'; Group = 'EZTools';   Tier = 'Core' }
    @{ Name = 'SrumECmd';              RelPath = 'SrumECmd.exe';                                  Type = 'File'; Group = 'EZTools';   Tier = 'Core' }
    @{ Name = 'SumECmd';               RelPath = 'SumECmd.exe';                                   Type = 'File'; Group = 'EZTools';   Tier = 'Core' }
    @{ Name = 'SBECmd';                RelPath = 'SBECmd.exe';                                    Type = 'File'; Group = 'EZTools';   Tier = 'Core' }
    @{ Name = 'WxTCmd';                RelPath = 'WxTCmd.exe';                                    Type = 'File'; Group = 'EZTools';   Tier = 'Core' }
    @{ Name = 'RBCmd';                 RelPath = 'RBCmd.exe';                                     Type = 'File'; Group = 'EZTools';   Tier = 'Core' }
    @{ Name = 'EvtxECmd';              RelPath = 'EvtxECmd\EvtxECmd.exe';                          Type = 'File'; Group = 'EZTools';   Tier = 'Core' }
    @{ Name = 'RECmd_Batch_MC.reb';    RelPath = 'RECmd\BatchExamples\RECmd_Batch_MC.reb';         Type = 'File'; Group = 'EZTools';   Tier = 'Core' }
    @{ Name = 'Hayabusa';              RelPath = 'hayabusa\hayabusa.exe';                          Type = 'File'; Group = 'Hayabusa';  Tier = 'Auxiliary' }
    @{ Name = 'Hayabusa rules';        RelPath = 'hayabusa\rules';                                 Type = 'Dir';  Group = 'Hayabusa';  Tier = 'Auxiliary' }
    @{ Name = 'Chainsaw';              RelPath = 'Chainsaw\chainsaw.exe';                          Type = 'File'; Group = 'Chainsaw';  Tier = 'Auxiliary' }
    @{ Name = 'Chainsaw rules';        RelPath = 'Chainsaw\rules';                                  Type = 'Dir';  Group = 'Chainsaw';  Tier = 'Auxiliary' }
    @{ Name = 'Chainsaw sigma rules';  RelPath = 'Chainsaw\sigma\rules';                            Type = 'Dir';  Group = 'Chainsaw';  Tier = 'Auxiliary' }
    @{ Name = 'Chainsaw mapping';      RelPath = 'Chainsaw\mappings\sigma-event-logs-all.yml';      Type = 'File'; Group = 'Chainsaw';  Tier = 'Auxiliary' }
    @{ Name = 'Hindsight';             RelPath = 'hindsight.exe';                                  Type = 'File'; Group = 'Hindsight'; Tier = 'Auxiliary' }
    @{ Name = 'RegRipper';             RelPath = 'RegRipper\rip.exe';                               Type = 'File'; Group = 'RegRipper'; Tier = 'Auxiliary' }
    @{ Name = 'RegRipper plugins';     RelPath = 'RegRipper\plugins';                                Type = 'Dir';  Group = 'RegRipper'; Tier = 'Auxiliary' }
    @{ Name = 'BrowsingHistoryView';   RelPath = 'BrowsingHistoryView.exe';                         Type = 'File'; Group = 'NirSoft';   Tier = 'Auxiliary' }
    @{ Name = 'BrowserDownloadsView';  RelPath = 'BrowserDownloadsView.exe';                        Type = 'File'; Group = 'NirSoft';   Tier = 'Auxiliary' }
)

function Test-RequiredItem {
    param($Item)
    $full = Join-Path $BinPath $Item.RelPath
    if ($Item.Type -eq 'Dir') {
        return (Test-Path -LiteralPath $full -PathType Container) -and ((Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)
    } else {
        return Test-Path -LiteralPath $full -PathType Leaf
    }
}

function Invoke-Verify {
    param([switch]$Quiet)

    $results = foreach ($item in $RequiredItems) {
        $ok = Test-RequiredItem -Item $item
        [pscustomobject]@{
            Name    = $item.Name
            Path    = Join-Path $BinPath $item.RelPath
            Group   = $item.Group
            Tier    = $item.Tier
            Pass    = $ok
        }
    }

    if (-not $Quiet) {
        Write-Host ""
        Write-Host ("{0,-22} {1,-10} {2,-8} {3}" -f 'TOOL', 'TIER', 'STATUS', 'PATH')
        Write-Host ("{0,-22} {1,-10} {2,-8} {3}" -f '----', '----', '------', '----')
        foreach ($r in $results) {
            $status = if ($r.Pass) { 'PASS' } else { 'FAIL' }
            $color = if ($r.Pass) { 'Green' } elseif ($r.Tier -eq 'Core') { 'Red' } else { 'Yellow' }
            Write-Host ("{0,-22} " -f $r.Name) -NoNewline
            Write-Host ("{0,-10} " -f $r.Tier) -NoNewline
            Write-Host ("{0,-8} " -f $status) -NoNewline -ForegroundColor $color
            Write-Host $r.Path
        }
        $passCount = ($results | Where-Object Pass).Count
        $missingAux = $results | Where-Object { -not $_.Pass -and $_.Tier -eq 'Auxiliary' }
        $missingCore = $results | Where-Object { -not $_.Pass -and $_.Tier -eq 'Core' }
        Write-Host ""
        Write-Host "$passCount of $($results.Count) tools verified"
        if ($missingCore) {
            Write-Host "Missing Core tool(s) - Run-IRParse.ps1 will refuse to run KAPE until these are present: $(($missingCore.Name) -join ', ')" -ForegroundColor Red
        }
        if ($missingAux) {
            Write-Host "Missing Auxiliary tool(s) - a parse will still run, just without this coverage: $(($missingAux.Name) -join ', ')" -ForegroundColor Yellow
        }
    }

    return $results
}

function Get-LatestReleaseAsset {
    param(
        [string]$Repo,
        [string]$Pattern
    )
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $Headers
    $asset = $release.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    return [pscustomobject]@{ Tag = $release.tag_name; Asset = $asset }
}

function Expand-ZipFlat {
    param([string]$ZipPath, [string]$Dest)
    $tmp = Join-Path $env:TEMP ("extract_" + [guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $tmp -Force
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
    # Flatten a single top-level wrapper folder if present
    $topItems = Get-ChildItem -LiteralPath $tmp
    if ($topItems.Count -eq 1 -and $topItems[0].PSIsContainer) {
        Get-ChildItem -LiteralPath $topItems[0].FullName | Copy-Item -Destination $Dest -Recurse -Force
    } else {
        Get-ChildItem -LiteralPath $tmp | Copy-Item -Destination $Dest -Recurse -Force
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-RepoFolderZip {
    # Uses a git sparse-checkout rather than a zip download+expand: some repos
    # (e.g. SigmaHQ/sigma) have paths deep/long enough to exceed MAX_PATH
    # during Expand-Archive, which git handles fine with core.longpaths.
    param([string]$Repo, [string]$Branch, [string]$SubFolder, [string]$Dest)
    $tmp = Join-Path $env:TEMP ("g" + [guid]::NewGuid().ToString('N').Substring(0, 12))
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    git -c core.longpaths=true clone --depth 1 --branch $Branch --single-branch --filter=blob:none --sparse "https://github.com/$Repo.git" $tmp 2>$null
    if ($LASTEXITCODE -ne 0) { $ErrorActionPreference = $prevEAP; throw "git clone of $Repo failed (exit $LASTEXITCODE)" }
    if ($SubFolder -ne '.') {
        Push-Location $tmp
        git -c core.longpaths=true sparse-checkout set $SubFolder 2>$null
        $scExit = $LASTEXITCODE
        Pop-Location
        $ErrorActionPreference = $prevEAP
        if ($scExit -ne 0) { throw "git sparse-checkout of $SubFolder in $Repo failed (exit $scExit)" }
        $srcFolder = Join-Path $tmp $SubFolder
    } else {
        $ErrorActionPreference = $prevEAP
        $srcFolder = $tmp
    }
    if (-not (Test-Path $srcFolder)) { throw "Folder '$SubFolder' not found in $Repo@$Branch clone" }
    if (Test-Path $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Dest) -Force -ErrorAction SilentlyContinue | Out-Null
    if ($SubFolder -ne '.') {
        Move-Item -LiteralPath $srcFolder -Destination $Dest -Force
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Remove-Item -LiteralPath (Join-Path $tmp '.git') -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $tmp -Destination $Dest -Force
    }
}

function Install-Chainsaw {
    # The plain per-platform asset (chainsaw_x86_64-pc-windows-msvc.zip) is binary-only.
    # The stock Apps\GitHub\Chainsaw.mkape module expects Chainsaw's own built-in "rules"
    # folder too (separate from Sigma), which only ships in the "+rules" bundle - that
    # bundle also includes a bundled sigma\ and mappings\, so this single fetch covers
    # binary + rules + sigma + mappings in one shot.
    $dest = Join-Path $BinPath 'Chainsaw'
    $rel = Get-LatestReleaseAsset -Repo 'WithSecureLabs/chainsaw' -Pattern '_all_platforms\+rules\.zip$'
    if (-not $rel.Asset) { throw "No '+rules' bundle release asset found for chainsaw ($($rel.Tag))" }
    $zipFile = Join-Path $env:TEMP $rel.Asset.name
    Invoke-WebRequest -Uri $rel.Asset.browser_download_url -Headers $Headers -OutFile $zipFile
    # This bundle's sigma rule tree is deep/long enough to exceed MAX_PATH with
    # Expand-Archive (same class of failure as the standalone SigmaHQ/sigma clone) - tar
    # (bsdtar, bundled with Windows) handles it fine.
    $tmp = Join-Path $env:TEMP ("chainsaw_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    & $TarExe -xf $zipFile -C $tmp
    if ($LASTEXITCODE -ne 0) { throw "tar extraction of chainsaw bundle failed (exit $LASTEXITCODE)" }
    if (Test-Path $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    # A plain folder rename (not Copy-Item -Recurse) - Copy-Item would walk and touch
    # every individual file path same as Expand-Archive, hitting the same MAX_PATH issue.
    Move-Item -LiteralPath (Join-Path $tmp 'chainsaw') -Destination $dest
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue

    $winExePath = Join-Path $dest 'chainsaw_x86_64-pc-windows-msvc.exe'
    if (Test-Path -LiteralPath $winExePath) {
        Copy-Item -LiteralPath $winExePath -Destination (Join-Path $dest 'chainsaw.exe') -Force
    }
    if (-not (Test-Path (Join-Path $dest 'chainsaw.exe'))) { throw "chainsaw.exe missing after extraction ($($rel.Tag))" }
    if (-not (Test-Path (Join-Path $dest 'rules'))) { throw "Chainsaw's own rules\ folder missing after extraction ($($rel.Tag))" }
    if (-not (Test-Path (Join-Path $dest 'mappings\sigma-event-logs-all.yml'))) {
        throw "sigma-event-logs-all.yml mapping missing after extraction - check chainsaw release layout ($($rel.Tag))"
    }

    # The bundle's "sigma" folder is just a git submodule reference (a .git gitlink plus
    # the SigmaHQ/sigma repo's own top-level files) - GitHub's release zip packaging does
    # not check out submodule content, so the actual rules never come from this asset.
    # Overwrite it with a real sparse checkout, same approach as before.
    Get-RepoFolderZip -Repo 'SigmaHQ/sigma' -Branch 'master' -SubFolder 'rules' -Dest (Join-Path $dest 'sigma\rules')
    if (-not (Test-Path (Join-Path $dest 'sigma\rules'))) { throw "sigma\rules folder missing after git checkout" }
}

function Install-Hayabusa {
    # The release zip already bundles a populated rules\ folder (unlike Chainsaw's
    # bundle, where the equivalent folder is just a git submodule stub) - confirmed
    # by extracting a real release and checking rules\ has actual rule content, not
    # just a .git pointer - so a plain release-zip fetch is enough, no separate git
    # checkout needed. win-x64 specifically (not the -live-response or aarch64/x86
    # variants) to match this project's target platform.
    $dest = Join-Path $BinPath 'hayabusa'
    $rel = Get-LatestReleaseAsset -Repo 'Yamato-Security/hayabusa' -Pattern '-win-x64\.zip$'
    if (-not $rel.Asset) { throw "No win-x64 release asset found for hayabusa ($($rel.Tag))" }
    $zipFile = Join-Path $env:TEMP $rel.Asset.name
    Invoke-WebRequest -Uri $rel.Asset.browser_download_url -Headers $Headers -OutFile $zipFile
    Expand-ZipFlat -ZipPath $zipFile -Dest $dest
    Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue

    # The release's exe is named hayabusa-<version>-win-x64.exe, not hayabusa.exe -
    # the stock IR_10_Hayabusa_OfflineEventLogs.mkape module (and Invoke-Update's own
    # version-banner check) both expect the bare name.
    $exe = Get-ChildItem -LiteralPath $dest -Filter 'hayabusa*.exe' | Select-Object -First 1
    if ($exe -and $exe.Name -ne 'hayabusa.exe') {
        Copy-Item -LiteralPath $exe.FullName -Destination (Join-Path $dest 'hayabusa.exe') -Force
    }
    if (-not (Test-Path (Join-Path $dest 'hayabusa.exe'))) { throw "hayabusa.exe missing after extraction ($($rel.Tag))" }
    if (-not (Test-Path (Join-Path $dest 'rules'))) { throw "rules folder missing after extraction ($($rel.Tag))" }
}

function Install-Hindsight {
    # Flat at Modules\bin\hindsight.exe, not a subfolder - the stock
    # Apps\GitHub\ObsidianForensics_Hindsight.mkape module references a bare
    # "hindsight.exe", which KAPE only resolves against Modules\<ModuleName> or
    # Modules\bin directly, not an arbitrary subfolder under bin.
    $dest = $BinPath
    $rel = Get-LatestReleaseAsset -Repo 'obsidianforensics/hindsight' -Pattern '(?i)win.*\.zip$|hindsight.*\.exe$'
    if (-not $rel.Asset) { throw "No standalone Windows release asset found for hindsight ($($rel.Tag))" }
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    if ($rel.Asset.name -match '\.zip$') {
        $zipFile = Join-Path $env:TEMP $rel.Asset.name
        Invoke-WebRequest -Uri $rel.Asset.browser_download_url -Headers $Headers -OutFile $zipFile
        Expand-ZipFlat -ZipPath $zipFile -Dest $dest
        Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue
        $exe = Get-ChildItem -LiteralPath $dest -Recurse -Filter '*.exe' | Select-Object -First 1
        if ($exe -and $exe.Name -ne 'hindsight.exe') {
            Copy-Item -LiteralPath $exe.FullName -Destination (Join-Path $dest 'hindsight.exe') -Force
        }
    } else {
        Invoke-WebRequest -Uri $rel.Asset.browser_download_url -Headers $Headers -OutFile (Join-Path $dest 'hindsight.exe')
    }
    if (-not (Test-Path (Join-Path $dest 'hindsight.exe'))) { throw "hindsight.exe missing after download ($($rel.Tag))" }
}

function Install-RegRipper {
    $dest = Join-Path $BinPath 'RegRipper'
    Get-RepoFolderZip -Repo 'keydet89/RegRipper3.0' -Branch 'master' -SubFolder '.' -Dest $dest
    if (-not (Test-Path (Join-Path $dest 'rip.exe'))) { throw "rip.exe missing after clone/extract" }
    if (-not (Test-Path (Join-Path $dest 'plugins'))) { throw "plugins folder missing after clone/extract" }
}

function Install-NirSoftBrowserTools {
    # Flat at Modules\bin, not a subfolder - these run directly from
    # Get-BroaderBrowserHistory.ps1 (a post-processing script, not a KAPE module
    # processor), which looks for them at $BinPath the same as every other tool here.
    $urls = @{
        'browsinghistoryview-x64.zip' = 'https://www.nirsoft.net/utils/browsinghistoryview-x64.zip'
        'browserdownloadsview-x64.zip' = 'https://www.nirsoft.net/utils/browserdownloadsview-x64.zip'
    }
    foreach ($name in $urls.Keys) {
        $zipFile = Join-Path $env:TEMP $name
        Invoke-WebRequest -Uri $urls[$name] -Headers $Headers -OutFile $zipFile
        Expand-ZipFlat -ZipPath $zipFile -Dest $BinPath
        Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path (Join-Path $BinPath 'BrowsingHistoryView.exe'))) { throw "BrowsingHistoryView.exe missing after download" }
    if (-not (Test-Path (Join-Path $BinPath 'BrowserDownloadsView.exe'))) { throw "BrowserDownloadsView.exe missing after download" }
}

function Install-EZTools {
    # Despite the common name, the maintained repo lives under AndrewRathbun, not
    # EricZimmermann. The published release asset is a plain .ps1 (no zip), and the
    # script must be run with its working directory set to the KAPE root - it resolves
    # .\Modules\bin relative to the caller's cwd, not its own script path.
    $updater = Get-ChildItem -Path $KapePath -Filter '*EZToolsAncillaryUpdater*.ps1' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $updater) {
        $rel = Get-LatestReleaseAsset -Repo 'AndrewRathbun/KAPE-EZToolsAncillaryUpdater' -Pattern '\.ps1$'
        if (-not $rel.Asset) { throw "Could not find KAPE-EZToolsAncillaryUpdater.ps1 release asset" }
        $scriptPath = Join-Path $KapePath 'KAPE-EZToolsAncillaryUpdater.ps1'
        Invoke-WebRequest -Uri $rel.Asset.browser_download_url -Headers $Headers -OutFile $scriptPath
        $updater = Get-Item $scriptPath
    }
    Push-Location $KapePath
    try {
        & $updater.FullName -silent -DoNotUpdate
    } finally {
        Pop-Location
    }
}

function Invoke-Setup {
    $before = Invoke-Verify -Quiet
    $missingGroups = ($before | Where-Object { -not $_.Pass }).Group | Sort-Object -Unique
    # Group -> Tier lookup, so a failed install can be reported (and gate the exit
    # code) by tier rather than by group name.
    $tierByGroup = @{}
    foreach ($item in $RequiredItems) { $tierByGroup[$item.Group] = $item.Tier }

    $installed = @()
    $failed = @()
    $alreadyPresent = ($before | Where-Object Pass).Name

    # Each group's installer is independent and wrapped in its own try/catch - one
    # group failing (e.g. nirsoft.net unreachable) never stops the rest from being
    # attempted. Combined with Invoke-Verify's Core/Auxiliary split below, an
    # Auxiliary-only failure here no longer blocks Run-IRParse.ps1 from running KAPE.
    foreach ($group in $missingGroups) {
        try {
            switch ($group) {
                'EZTools'   { Install-EZTools;   $installed += 'EZTools' }
                'Hayabusa'  { Install-Hayabusa;  $installed += 'Hayabusa' }
                'Chainsaw'  { Install-Chainsaw;  $installed += 'Chainsaw' }
                'Hindsight' { Install-Hindsight; $installed += 'Hindsight' }
                'RegRipper' { Install-RegRipper; $installed += 'RegRipper' }
                'NirSoft'   { Install-NirSoftBrowserTools; $installed += 'NirSoft' }
            }
        } catch {
            $failed += [pscustomobject]@{ Group = $group; Tier = $tierByGroup[$group]; Reason = $_.Exception.Message }
        }
    }

    Write-Host ""
    Write-Host "=== Setup summary ==="
    Write-Host "Already present: $($alreadyPresent -join ', ')"
    Write-Host "Installed:       $(if ($installed) { $installed -join ', ' } else { '(none)' })"
    if ($failed) {
        Write-Host "Failed:"
        foreach ($f in $failed) {
            $color = if ($f.Tier -eq 'Core') { 'Red' } else { 'Yellow' }
            Write-Host "  - [$($f.Tier)] $($f.Group): $($f.Reason)" -ForegroundColor $color
        }
    } else {
        Write-Host "Failed:          (none)"
    }

    $final = Invoke-Verify
    return $final
}

function Invoke-Update {
    # Only Core tools gate this - an Auxiliary tool being absent shouldn't stop
    # refreshing rules/binaries for whatever Auxiliary tools ARE present.
    $verifyResult = Invoke-Verify -Quiet
    if ($verifyResult | Where-Object { -not $_.Pass -and $_.Tier -eq 'Core' }) {
        Write-Host "One or more Core tools are missing. Run -Mode Setup first." -ForegroundColor Red
        Invoke-Verify | Out-Null
        exit 1
    }

    $hayabusaExe = Join-Path $BinPath 'hayabusa\hayabusa.exe'
    Write-Host "=== Update ==="
    if (Test-Path -LiteralPath $hayabusaExe) {
        try {
            # hayabusa.exe has no top-level --version/-V flag; every subcommand prints a
            # "Hayabusa vX.Y.Z" banner to stdout instead, so pull the version from that.
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $bannerBefore = (& $hayabusaExe update-rules --help 2>$null | Select-String 'Hayabusa v').ToString()
            $updateOutput = & $hayabusaExe update-rules 2>&1 | Out-String
            $ErrorActionPreference = $prevEAP
            Write-Host "Hayabusa rules: updated ($($bannerBefore.Trim()))"
            Write-Host ($updateOutput.Trim())
        } catch {
            Write-Host "Hayabusa rules update failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "Hayabusa not installed (Auxiliary) - skipping rule update. Run -Mode Setup to install it." -ForegroundColor Yellow
    }

    try {
        Install-Chainsaw
        Write-Host "Chainsaw: re-fetched binary + built-in rules + bundled sigma + mappings"
    } catch {
        Write-Host "Chainsaw update failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        Install-EZTools
        Write-Host "EZ Tools: re-ran EZToolsAncillaryUpdater"
    } catch {
        Write-Host "EZ Tools update failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "Hindsight, RegRipper, and the NirSoft browser tools have no automated update mechanism - re-run Setup to update them."
}

switch ($Mode) {
    'Verify' {
        # Only a missing Core tool fails the run - a missing Auxiliary tool is
        # reported (see Invoke-Verify) but doesn't block Run-IRParse.ps1 from
        # running KAPE. See the Tier comment on $RequiredItems for why.
        $results = Invoke-Verify
        if ($results | Where-Object { -not $_.Pass -and $_.Tier -eq 'Core' }) { exit 1 } else { exit 0 }
    }
    'Setup' {
        $results = Invoke-Setup
        if ($results | Where-Object { -not $_.Pass -and $_.Tier -eq 'Core' }) { exit 1 } else { exit 0 }
    }
    'Update' {
        Invoke-Update
        exit 0
    }
}
