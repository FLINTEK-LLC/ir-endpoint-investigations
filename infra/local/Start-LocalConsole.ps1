<#
.SYNOPSIS
    Menu-driven front end for the local VMware Workstation IR
    infrastructure in this folder - same thin-wrapper philosophy as
    ..\scripts\Start-IRConsole.ps1 and Start-CloudConsole.ps1: prompts
    collect the same inputs you'd otherwise hand-type as vmrun/Packer
    arguments, then this console runs the real scripts. Nothing here is
    logic you can't also run by hand - see infra\local\README.md.

.DESCRIPTION
    Case lifecycle, all through this menu:
      [1] Start a case      - New-LocalCase.ps1: reverts the golden VM to
                               golden-clean, mounts the case's evidence
                               folder read-only, powers it on.
      [2] Connect            - Connect-LocalHost.ps1: console window or a
                                real RDP session, your choice.
      [3] Stop a case        - Stop-LocalCase.ps1: powers the VM off and
                                reverts it - the "destroy" analog, since
                                there is no cloud resource to delete.
      [4] List cases         - reads infra\local\.cases\*.json.
      [G] Take golden-clean snapshot - packer\scripts\New-GoldenSnapshot.ps1,
                                for right after a Packer build finishes.

    Same bookkeeping-not-secrets rule as infra\.cases\: case records in
    infra\local\.cases\<CaseId>.json are gitignored and never contain
    credential material - see infra\local\README.md.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:LocalRoot = $PSScriptRoot
$script:ScriptsDir = Join-Path $LocalRoot 'scripts'
$script:PackerScriptsDir = Join-Path $LocalRoot 'packer\scripts'
$script:CasesDir = Join-Path $LocalRoot '.cases'

# Shared with both OTHER consoles in this project - see that file's header
# for why arrow-key selection falls back to a numbered list under a pipe,
# the ISE, or VS Code's PowerShell host.
. (Join-Path (Split-Path -Parent (Split-Path -Parent $LocalRoot)) 'scripts\IRPrompt.ps1')

function Invoke-ScriptFile {
    # Same separate-process pattern as both other consoles: a called
    # script's own exit/throw only ends that process, never this one.
    param([string]$Dir, [string]$Name, [string[]]$ScriptArgs = @())
    $target = Join-Path $Dir $Name
    Write-Host ""
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File $target @ScriptArgs
    Write-Host ""
    Write-Host "(exit code $LASTEXITCODE)" -ForegroundColor DarkGray
}

function Get-AllLocalCases {
    # Same -NoEnumerate rule as Start-CloudConsole.ps1's Get-AllCaseRecords -
    # without it, a folder holding exactly one case.json gets flattened from
    # an array back to a bare object by PowerShell's output pipeline, which
    # breaks a caller's .Count check on "no cases found".
    $items = @()
    if (Test-Path -LiteralPath $script:CasesDir) {
        $items = @(Get-ChildItem -LiteralPath $script:CasesDir -Filter '*.json' | ForEach-Object {
                Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json
            } | Where-Object { $_ -and $_.case_id })
    }
    Write-Output -NoEnumerate $items
}

function Select-ExistingLocalCase {
    param([string]$Prompt = "Case ID")
    $cases = Get-AllLocalCases
    if ($cases.Count -eq 0) {
        Write-Host "No cases found in infra\local\.cases\ - start one first (option 1)." -ForegroundColor Yellow
        return $null
    }
    $items = $cases | Sort-Object case_id | ForEach-Object {
        [pscustomobject]@{ Label = ('{0,-20} {1}' -f $_.case_id, $_.status); Value = $_.case_id }
    }
    $caseId = Read-Choice -Prompt "$($Prompt):" -Items $items -DisplayProperty Label -ValueProperty Value `
        -AllowCustom -CustomPrompt 'Case ID (one not listed here)'
    if (-not $caseId) { return $null }
    return $caseId
}

function Invoke-StartCase {
    $caseId = Read-Required -Prompt "Case ID (lowercase letters/numbers/hyphens)"
    if (-not $caseId) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
    $evidencePath = Read-Required -Prompt "Host folder with this case's evidence (mounted read-only into the guest)"
    if (-not $evidencePath) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
    $vmxDefault = Join-Path $LocalRoot 'packer\output-ir-golden\ir-golden.vmx'
    $vmxPath = Read-Default -Prompt "Golden VM .vmx path" -Default $vmxDefault
    $gui = Read-YesNo -Prompt "Start with the VM's console window visible?" -Default $true
    $scriptArgs = @('-CaseId', $caseId, '-EvidencePath', $evidencePath, '-VmxPath', $vmxPath, '-Gui', $(if ($gui) { 'true' } else { 'false' }))
    Invoke-ScriptFile -Dir $script:ScriptsDir -Name 'New-LocalCase.ps1' -ScriptArgs $scriptArgs
}

function Invoke-ConnectCase {
    $caseId = Select-ExistingLocalCase -Prompt "Case ID to connect to"
    if (-not $caseId) { return }
    $method = Read-Choice -Prompt "How would you like to connect?" -Default 'Console' -Items @(
        [pscustomobject]@{ Label = "Console - the VM's own Workstation window (no network dependency)"; Value = 'Console' }
        [pscustomobject]@{ Label = 'RDP - a resizable mstsc.exe session to the guest IP'; Value = 'Rdp' }
    ) -DisplayProperty Label -ValueProperty Value
    Invoke-ScriptFile -Dir $script:ScriptsDir -Name 'Connect-LocalHost.ps1' -ScriptArgs @('-CaseId', $caseId, '-Method', $method)
}

function Invoke-StopCase {
    $caseId = Select-ExistingLocalCase -Prompt "Case ID to stop"
    if (-not $caseId) { return }
    Write-Host "This powers the VM off and reverts it to its golden-clean snapshot. Evidence storage is untouched." -ForegroundColor Cyan
    if (-not (Read-YesNo -Prompt "Continue?" -Default $false)) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
    $deleteRecord = Read-YesNo -Prompt "Also delete the local case record (infra\local\.cases\$caseId.json)?" -Default $false
    $scriptArgs = @('-CaseId', $caseId)
    if ($deleteRecord) { $scriptArgs += '-DeleteRecord' }
    Invoke-ScriptFile -Dir $script:ScriptsDir -Name 'Stop-LocalCase.ps1' -ScriptArgs $scriptArgs
}

function Show-LocalCaseList {
    $cases = Get-AllLocalCases
    if ($cases.Count -eq 0) {
        Write-Host "No cases found in infra\local\.cases\." -ForegroundColor Yellow
        return
    }
    $cases | Sort-Object case_id | ForEach-Object {
        [pscustomobject]@{
            CaseId   = $_.case_id
            Status   = $_.status
            Evidence = $_.evidence_path
            Created  = $_.created_utc
        }
    } | Format-Table -AutoSize
}

function Invoke-TakeGoldenSnapshot {
    $vmxDefault = Join-Path $LocalRoot 'packer\output-ir-golden\ir-golden.vmx'
    $vmxPath = Read-Default -Prompt "Freshly Packer-built VM .vmx path" -Default $vmxDefault
    Invoke-ScriptFile -Dir $script:PackerScriptsDir -Name 'New-GoldenSnapshot.ps1' -ScriptArgs @('-VmxPath', $vmxPath)
}

$script:MenuItems = @(
    [pscustomobject]@{ Separator = 'Golden image (one-time, see infra\local\README.md)' }
    [pscustomobject]@{ Value = 'G'; Label = 'Take the golden-clean snapshot after a Packer build' }
    [pscustomobject]@{ Separator = 'Case workflow' }
    [pscustomobject]@{ Value = '1'; Label = 'Start a case (revert golden VM, mount evidence, power on)' }
    [pscustomobject]@{ Value = '2'; Label = 'Connect to the investigation host' }
    [pscustomobject]@{ Value = '3'; Label = 'Stop a case (power off + revert to golden-clean)' }
    [pscustomobject]@{ Value = '4'; Label = 'List cases' }
    [pscustomobject]@{ Separator = '' }
    [pscustomobject]@{ Value = 'Q'; Label = 'Quit' }
)

function Show-MenuHeader {
    Clear-Host
    Write-Host "=================================================="
    Write-Host " IR Endpoint Investigations - Local VMware Console"
    Write-Host "=================================================="
}

while ($true) {
    Show-MenuHeader
    $choice = Read-Choice -Prompt 'Choose an option:' -Items $script:MenuItems `
        -DisplayProperty Label -ValueProperty Value
    if (-not $choice) { continue }

    switch ($choice) {
        'G' { Invoke-TakeGoldenSnapshot; Wait-ForEnter }
        '1' { Invoke-StartCase; Wait-ForEnter }
        '2' { Invoke-ConnectCase; Wait-ForEnter }
        '3' { Invoke-StopCase; Wait-ForEnter }
        '4' { Show-LocalCaseList; Wait-ForEnter }
        { $_ -in @('Q', 'QUIT', 'EXIT') } { return }
        default {
            Write-Host "Not a valid option." -ForegroundColor Yellow
            Start-Sleep -Milliseconds 800
        }
    }
}
