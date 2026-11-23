# Runs once as the unattended local administrator. The builder keeps A:
# attached until provisioning ends. Do not put build credentials here.
$ErrorActionPreference = 'Stop'
Start-Transcript -Path "$env:WINDIR\Temp\packer-winrm.log" -Append
try {
    # LogonCount=1 can produce an extra automatic logon on Windows. Disable
    # automatic logon explicitly and remove the cached AutoLogon password.
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $winlogon -Name AutoLogonCount -Value 0
    Set-ItemProperty $winlogon -Name AutoAdminLogon -Value '0'
    Remove-ItemProperty $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue

    # A fresh NAT adapter may be Public. -Force alone does not bypass that
    # client-Windows restriction. The explicit rule covers every profile,
    # with access limited to the local subnet, including the VMware host.
    Enable-PSRemoting -SkipNetworkProfileCheck -Force
    New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 1 -Force | Out-Null
    if (-not (Get-NetFirewallRule -Name PackerWinRM -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name PackerWinRM -DisplayName 'Packer WinRM HTTP (local subnet)' `
            -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 `
            -Profile Any -RemoteAddress LocalSubnet | Out-Null
    }
    Set-Service WinRM -StartupType Automatic
    Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true
    # Enable Basic last, after the account policy and firewall are ready.
    Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
    Restart-Service WinRM
} finally {
    Stop-Transcript
}
