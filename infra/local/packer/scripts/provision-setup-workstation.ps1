#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Packer provisioner step: runs this repo's own Setup-Workstation.ps1
    inside the golden-image guest, exactly as a human would on a
    hand-built workstation. Not reimplemented here on purpose - see
    infra\local\README.md's "Reuse" section and root README.md's
    Setup-Workstation.ps1 documentation for what this installs.

.DESCRIPTION
    Runs with -Tier All so the golden image comes up with every workstation
    tool this project knows how to fetch (Standard AND Optional, e.g.
    Notepad++/LibreOffice/Loki), since a reusable golden image is exactly
    the case for "build it once with everything, decide what to actually
    use per case" rather than a disposable cloud host where every extra
    download costs boot time on every case.
#>
$ErrorActionPreference = 'Continue'   # A single tool failing to fetch must not fail the whole Packer build - same policy Setup-Workstation.ps1 itself documents (EZ Tools is the only hard dependency).

$repoRoot = 'C:\ir-endpoint-investigations'
$setupScript = Join-Path $repoRoot 'scripts\Setup-Workstation.ps1'

if (-not (Test-Path -LiteralPath $setupScript)) {
    Write-Host "Setup-Workstation.ps1 not found at $setupScript - the repo 'file' provisioner step may not have completed." -ForegroundColor Red
    exit 1
}

Write-Host "=== Running Setup-Workstation.ps1 -Tier All inside the golden image ===" -ForegroundColor Cyan
& powershell.exe -ExecutionPolicy Bypass -NonInteractive -File $setupScript -ToolsRoot 'C:\Tools' -Mode Setup -Tier All
Write-Host "Setup-Workstation.ps1 exited $LASTEXITCODE (non-zero does not fail this build - see Prerequisites in root README.md for the one hard dependency, EZ Tools)." -ForegroundColor DarkGray

# KAPE itself is still a manual prerequisite (Kroll's licence gate - see
# root README.md). If the optional kape_zip_path Packer variable staged
# one to C:\Tools\kape before this script ran, Setup-Workstation.ps1 just
# found it there and deployed this project's module on top; if not, it
# already printed the manual-download instructions to its own output
# above.

Write-Host "=== Golden image provisioning complete ===" -ForegroundColor Green
Write-Host "Next: let Packer finish (it shuts the VM down), then run New-GoldenSnapshot.ps1 to take the 'golden-clean' snapshot this module's case lifecycle reverts to." -ForegroundColor Green
