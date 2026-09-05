<#
.SYNOPSIS
    Menu-driven front end for this project's scripts - nothing here is new
    logic, it's prompts that collect the same parameters you'd otherwise pass
    on the command line, then calls the real script.

.DESCRIPTION
    Every action here shells out to the corresponding script under
    <KapePath>\Modules\bin (the deployed copies - same call pattern
    Setup-Workstation.ps1 already uses for Manage-Tools.ps1), as a separate
    powershell.exe process, same as everywhere else in this project - a
    called script's own `exit` only ends that script, not this console.

    This script itself is not deployed onto the KAPE install (see the
    exclusion list in Deploy-Module.ps1) - run it from your checkout of this
    repo, the same way you'd run Setup-Workstation.ps1.

.PARAMETER KapePath
    Defaults to C:\Tools\KAPE; changeable from the menu (option 9) without
    restarting.
#>
[CmdletBinding()]
param(
    [string]$KapePath = 'C:\Tools\KAPE'
)

$ErrorActionPreference = 'Stop'

# Prompt helpers (including arrow-key selection) are shared with
# infra\Start-CloudConsole.ps1 - see IRPrompt.ps1's header.
. (Join-Path $PSScriptRoot 'IRPrompt.ps1')

function Invoke-DeployedScript {
    # Runs a script from <KapePath>\Modules\bin - the deployed/live copy, not
    # this console's own sibling file - so KapePath auto-detection inside the
    # called script (which assumes it's running from Modules\bin) works.
    param([string]$Name, [string[]]$ScriptArgs = @())
    $binDest = Join-Path $script:KapePath 'Modules\bin'
    $target = Join-Path $binDest $Name
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host "$Name not found under $binDest - deploy the module first (option 5)." -ForegroundColor Red
        return
    }
    Write-Host ""
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File $target @ScriptArgs
    Write-Host ""
    Write-Host "(exit code $LASTEXITCODE)" -ForegroundColor DarkGray
}

function Invoke-CheckoutScript {
    # Runs a script from this console's own folder - for the two scripts
    # (Deploy-Module.ps1, Setup-Workstation.ps1) meant to run from the
    # checkout rather than the deployed install, same as this console itself.
    param([string]$Name, [string[]]$ScriptArgs = @())
    $target = Join-Path $PSScriptRoot $Name
    Write-Host ""
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File $target @ScriptArgs
    Write-Host ""
    Write-Host "(exit code $LASTEXITCODE)" -ForegroundColor DarkGray
}

$script:MenuItems = @(
    [pscustomobject]@{ Separator = 'Setup and maintenance' }
    [pscustomobject]@{ Value = '1'; Label = 'Full workstation setup (first time)' }
    [pscustomobject]@{ Value = '2'; Label = 'Verify KAPE toolchain (fast, no network)' }
    [pscustomobject]@{ Value = '3'; Label = 'Update KAPE toolchain (rule sets, EZ Tools re-sync)' }
    [pscustomobject]@{ Value = '4'; Label = 'Update broader analyst toolset (EZ Tools GUI, Sysinternals, Autopsy)' }
    [pscustomobject]@{ Value = '5'; Label = 'Deploy/redeploy this module onto the KAPE install' }
    [pscustomobject]@{ Separator = 'Parsing' }
    [pscustomobject]@{ Value = '6'; Label = 'Parse a single host collection' }
    [pscustomobject]@{ Value = '7'; Label = 'Parse a case (multiple hosts)' }
    [pscustomobject]@{ Value = '8'; Label = 'Rebuild review workbook/bundle from existing results' }
    [pscustomobject]@{ Separator = 'Evidence integrity' }
    [pscustomobject]@{ Value = 'H'; Label = 'Hash a collection / verify it against its manifest' }
    [pscustomobject]@{ Separator = '' }
    [pscustomobject]@{ Value = '9'; Label = 'Change KAPE path' }
    [pscustomobject]@{ Value = 'Q'; Label = 'Quit' }
)

function Show-MenuHeader {
    Clear-Host
    $kapeStatus = if (Test-Path (Join-Path $script:KapePath 'kape.exe')) { 'found' } else { 'kape.exe NOT found here' }
    Write-Host "=================================================="
    Write-Host " IR Endpoint Investigations - Console"
    Write-Host "=================================================="
    Write-Host "KAPE path: $script:KapePath ($kapeStatus)"
}

while ($true) {
    Show-MenuHeader
    $choice = Read-Choice -Prompt 'Choose an option:' -Items $script:MenuItems `
        -DisplayProperty Label -ValueProperty Value
    if (-not $choice) { continue }

    switch ($choice) {
        '1' {
            $toolsRoot = Read-Default -Prompt "Tools root" -Default (Split-Path -Parent $script:KapePath)
            Invoke-CheckoutScript 'Setup-Workstation.ps1' @('-ToolsRoot', $toolsRoot, '-Mode', 'Setup')
            Wait-ForEnter
        }
        '2' {
            Invoke-DeployedScript 'Manage-Tools.ps1' @('-KapePath', $script:KapePath, '-Mode', 'Verify')
            Wait-ForEnter
        }
        '3' {
            Invoke-DeployedScript 'Manage-Tools.ps1' @('-KapePath', $script:KapePath, '-Mode', 'Update')
            Wait-ForEnter
        }
        '4' {
            $toolsRoot = Read-Default -Prompt "Tools root" -Default (Split-Path -Parent $script:KapePath)
            Invoke-CheckoutScript 'Setup-Workstation.ps1' @('-ToolsRoot', $toolsRoot, '-Mode', 'Update')
            Wait-ForEnter
        }
        '5' {
            Invoke-CheckoutScript 'Deploy-Module.ps1' @('-KapePath', $script:KapePath)
            Wait-ForEnter
        }
        '6' {
            $collectionRoot = Read-Required -Prompt "Collection root (extracted collection folder, or a collection .zip)"
            if ($collectionRoot) {
                # A zip's real output path depends on where it gets extracted (next to
                # itself by default) - only suggest the naive <root>\results default for
                # an already-extracted folder; leave it blank for a zip and let
                # Run-IRParse.ps1's own default (relative to its resolved extraction
                # path) apply.
                $isZip = $collectionRoot -match '\.zip$'
                $suggestedOutput = if ($isZip) { '' } else { "$collectionRoot\results" }
                $outputPath = Read-Default -Prompt "Output path (blank = default)" -Default $suggestedOutput
                $skip = Read-YesNo -Prompt "Skip triage post-processing (workbook/bundle/browser history)?" -Default $false
                $scriptArgs = @('-CollectionRoot', $collectionRoot, '-KapePath', $script:KapePath)
                if ($outputPath) { $scriptArgs += @('-OutputPath', $outputPath) }
                if ($skip) { $scriptArgs += '-SkipTriagePostProcessing' }
                if (-not $skip) {
                    $openWhenDone = Read-YesNo -Prompt "Open the review workbook when finished?" -Default $true
                    if ($openWhenDone) { $scriptArgs += '-OpenWhenDone' }
                }
                Invoke-DeployedScript 'Run-IRParse.ps1' $scriptArgs
            } else {
                Write-Host "Cancelled." -ForegroundColor Yellow
            }
            Wait-ForEnter
        }
        '7' {
            $caseRoot = Read-Required -Prompt "Case root (folder with one subfolder or .zip per host)"
            if ($caseRoot) {
                $skip = Read-YesNo -Prompt "Skip triage post-processing / cross-host rollup?" -Default $false
                $scriptArgs = @('-CaseRoot', $caseRoot, '-KapePath', $script:KapePath)
                if ($skip) { $scriptArgs += '-SkipTriagePostProcessing' }
                Invoke-DeployedScript 'Start-CaseParse.ps1' $scriptArgs
            } else {
                Write-Host "Cancelled." -ForegroundColor Yellow
            }
            Wait-ForEnter
        }
        '8' {
            $resultsPath = Read-Required -Prompt "Results folder (the results\ produced by a parse)"
            if ($resultsPath) {
                Invoke-DeployedScript 'New-ReviewWorkbook.ps1' @('-ResultsPath', $resultsPath)
                Invoke-DeployedScript 'New-ReviewBundle.ps1' @('-ResultsPath', $resultsPath)
            } else {
                Write-Host "Cancelled." -ForegroundColor Yellow
            }
            Wait-ForEnter
        }
        'H' {
            # Hash on arrival, verify whenever it matters. See
            # Get-EvidenceManifest.ps1's header for why this exists.
            $collection = Read-Required -Prompt "Collection folder or .zip"
            if ($collection) {
                $action = Read-Choice -Prompt "What would you like to do?" -Items @(
                    [pscustomobject]@{ Label = 'Write a manifest (do this when the collection arrives)'; Value = 'write' }
                    [pscustomobject]@{ Label = 'Verify against an existing manifest'; Value = 'verify' }
                ) -DisplayProperty Label -ValueProperty Value -Default 'write'
                $scriptArgs = @('-Path', $collection)
                if ($action -eq 'verify') { $scriptArgs += '-Verify' }
                Invoke-DeployedScript 'Get-EvidenceManifest.ps1' $scriptArgs
            } else {
                Write-Host "Cancelled." -ForegroundColor Yellow
            }
            Wait-ForEnter
        }
        '9' {
            $script:KapePath = Read-Default -Prompt "New KAPE path" -Default $script:KapePath
        }
        { $_ -in @('Q', 'QUIT', 'EXIT') } {
            return
        }
        default {
            Write-Host "Not a valid option." -ForegroundColor Yellow
            Start-Sleep -Milliseconds 800
        }
    }
}
