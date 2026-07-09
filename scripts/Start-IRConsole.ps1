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

function Read-Default {
    param([string]$Prompt, [string]$Default)
    $val = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val
}

function Read-Required {
    param([string]$Prompt)
    while ($true) {
        $val = Read-Host "$Prompt (blank to cancel)"
        if ([string]::IsNullOrWhiteSpace($val)) { return $null }
        return $val
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $suffix = if ($Default) { 'Y/n' } else { 'y/N' }
    $val = Read-Host "$Prompt [$suffix]"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val.Trim().ToUpper().StartsWith('Y')
}

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

function Wait-ForEnter {
    Write-Host ""
    Read-Host "Press Enter to return to the menu" | Out-Null
}

function Show-Menu {
    Clear-Host
    $kapeStatus = if (Test-Path (Join-Path $script:KapePath 'kape.exe')) { 'found' } else { 'kape.exe NOT found here' }
    Write-Host "=================================================="
    Write-Host " IR Endpoint Investigations - Console"
    Write-Host "=================================================="
    Write-Host "KAPE path: $script:KapePath ($kapeStatus)"
    Write-Host ""
    Write-Host " [1] Full workstation setup (first time)"
    Write-Host " [2] Verify KAPE toolchain (fast, no network)"
    Write-Host " [3] Update KAPE toolchain (rule sets, EZ Tools re-sync)"
    Write-Host " [4] Update broader analyst toolset (EZ Tools GUI, Sysinternals, Autopsy)"
    Write-Host " [5] Deploy/redeploy this module onto the KAPE install"
    Write-Host " [6] Parse a single host collection"
    Write-Host " [7] Parse a case (multiple hosts)"
    Write-Host " [8] Rebuild review workbook/bundle from existing results"
    Write-Host " [9] Change KAPE path"
    Write-Host " [Q] Quit"
    Write-Host ""
}

while ($true) {
    Show-Menu
    $choice = (Read-Host "Choose an option").Trim().ToUpper()

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
            $collectionRoot = Read-Required -Prompt "Collection root (extracted Velociraptor collection folder)"
            if ($collectionRoot) {
                $outputPath = Read-Default -Prompt "Output path" -Default "$collectionRoot\results"
                $skip = Read-YesNo -Prompt "Skip triage post-processing (workbook/bundle/browser history)?" -Default $false
                $scriptArgs = @('-CollectionRoot', $collectionRoot, '-OutputPath', $outputPath, '-KapePath', $script:KapePath)
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
            $caseRoot = Read-Required -Prompt "Case root (folder with one subfolder per host)"
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
