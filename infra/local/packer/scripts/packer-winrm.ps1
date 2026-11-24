# Staged from Packer's A: floppy to Windows\Temp during specialize, so the
# first-logon command does not depend on installation media. Keep the XML
# launchers short: Deployment RunSynchronous Path is limited to 259 chars.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Specialize', 'FirstLogon')]
    [string]$Phase
)

$ErrorActionPreference = 'Stop'
$logPath = Join-Path $env:WINDIR 'Temp\packer-winrm.log'

function Invoke-BootstrapStep {
    param([string]$Name, [scriptblock]$Action)

    "$(Get-Date -Format o) $Phase $Name start" | Out-File -Append $logPath
    try {
        & $Action *>> $logPath
        "$(Get-Date -Format o) $Phase $Name complete" | Out-File -Append $logPath
    }
    catch {
        $_ | Out-File -Append $logPath
        # Preserve the nonfatal specialize bootstrap behavior. At first
        # logon, stop before enabling Basic if credential cleanup fails.
        if ($Phase -eq 'FirstLogon') { throw }
    }
}

if ($Phase -eq 'Specialize') {
    Invoke-BootstrapStep 'Local administrator remote authentication' {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        New-ItemProperty -Path $key -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 1 -Force
    }
    Invoke-BootstrapStep 'Private network profile' {
        Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
    }
    Invoke-BootstrapStep 'Enable PS Remoting' {
        Enable-PSRemoting -SkipNetworkProfileCheck -Force
    }
    Invoke-BootstrapStep 'WinRM firewall rule' {
        if (-not (Get-NetFirewallRule -Name PackerWinRM -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name PackerWinRM -DisplayName 'Packer WinRM HTTP (local subnet)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 -Profile Any -RemoteAddress LocalSubnet
        }
    }
    Invoke-BootstrapStep 'WinRM transport policy' {
        $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name AllowUnencryptedTraffic -PropertyType DWord -Value 1 -Force
    }
    Invoke-BootstrapStep 'WinRM service and quotas' {
        Set-Service WinRM -StartupType Automatic
        Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true
        Set-Item WSMan:\localhost\Service\Auth\Basic -Value $false
        Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB -Value 2048
        Set-Item WSMan:\localhost\MaxTimeoutms -Value 1800000
        Restart-Service WinRM
    }
    exit 0
}

Invoke-BootstrapStep 'Clear AutoLogon credentials and enable Basic' {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $key -Name AutoLogonCount -Value 0
    Set-ItemProperty $key -Name AutoAdminLogon -Value '0'
    Remove-ItemProperty $key -Name DefaultPassword -ErrorAction SilentlyContinue
    Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
    'WinRM configured OK'
}
