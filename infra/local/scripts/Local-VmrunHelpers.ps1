<#
.SYNOPSIS
    Shared vmrun wrapper functions for the local VMware Workstation IR
    module - dot-sourced by New-LocalCase.ps1, Connect-LocalHost.ps1,
    Stop-LocalCase.ps1 and Start-LocalConsole.ps1, the same way
    scripts\IRPrompt.ps1 is shared by both menu front ends.

.DESCRIPTION
    This project's cloud module (infra\) talks to AWS/Azure through their
    own CLIs (aws, az) plus Terraform. There is no Terraform provider for
    VMware Workstation worth depending on here - vmrun.exe (shipped with
    Workstation itself) is the whole automation surface, and it is a thin,
    stateless CLI: every call takes the .vmx path explicitly, there is no
    persistent session or SDK object to wrap. So this file is a set of
    small, directly-testable PowerShell functions around vmrun, not a
    client library - testable in the sense that Invoke-SelfTest.ps1 can
    parse this file and exercise the pure string/path logic (e.g.
    Get-VmrunExePath's search order) without ever calling vmrun itself or
    needing VMware Workstation installed.

    CASE MODEL: snapshot-revert, not clone-per-case.

    The cloud module destroys and recreates a whole VM per case. That
    model does not fit well here: a VMware Workstation host is a single
    physical machine's one golden VM, and creating a full clone per case
    would multiply disk usage by the golden image's size (tens of GB) for
    every case, with no cloud storage tier to archive the unused ones to
    afterwards. Reverting ONE VM to its `golden-clean` snapshot before
    every case gives the same guarantee the cloud module's "destroy then
    re-apply" does - a case never sees artifacts left behind by a
    previous one - without the disk cost. The tradeoff: only one case can
    be open on a given physical machine's golden VM at a time, since
    there is only one VM. Two investigators working two cases
    simultaneously need two separate Workstation hosts (or two golden
    VMs under different names/paths), not two case folders.
#>

function Get-VmrunExePath {
    <#
        Resolves vmrun.exe to a full path. vmrun ships INSIDE the VMware
        Workstation install, not as a separately-installed/PATH-registered
        tool, so `Get-Command vmrun` typically fails even on a machine with
        Workstation fully installed - unlike terraform/aws/az in the cloud
        module, which the user explicitly installs onto PATH.
    #>
    param([string]$VmrunPath)
    if ($VmrunPath -and (Test-Path -LiteralPath $VmrunPath)) { return $VmrunPath }
    $cmd = Get-Command vmrun -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in @(
            'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe',
            'C:\Program Files\VMware\VMware Workstation\vmrun.exe'
        )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Invoke-Vmrun {
    <#
        Runs one vmrun subcommand and returns its stdout as a single
        string, trimmed. Throws on a non-zero exit code so callers can use
        a plain try/catch instead of checking $LASTEXITCODE everywhere -
        every caller in this module wants "did it work", and vmrun's own
        error text already goes to stdout/stderr, which the exception
        message carries forward.

        -T ws is passed on every call: vmrun supports several host types
        (ws, fusion, player, esx...) and without it, it guesses - usually
        correctly for a plain Workstation install, but guessing is exactly
        the kind of thing that fails quietly on one machine and not
        another.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$VmrunExe,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 120
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $VmrunExe
    $psi.ArgumentList.Add('-T')
    $psi.ArgumentList.Add('ws')
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch { }
        throw "vmrun $($Arguments -join ' ') did not finish within $TimeoutSeconds seconds"
    }
    if ($proc.ExitCode -ne 0) {
        $msg = (@($stdout, $stderr) | Where-Object { $_ }) -join ' '
        throw "vmrun $($Arguments -join ' ') failed (exit $($proc.ExitCode)): $($msg.Trim())"
    }
    return $stdout.Trim()
}

function Test-VmxPath {
    param([string]$VmxPath)
    if (-not $VmxPath) { return $false }
    return (Test-Path -LiteralPath $VmxPath) -and ($VmxPath -match '\.vmx$')
}

function Get-VmPowerState {
    <#
        vmrun's own `list` subcommand prints every RUNNING vm's .vmx path,
        one per line, with no "stopped" output at all - there is no vmrun
        query for a specific VM's state beyond "is it in this list".
        Comparing paths case-insensitively because Windows paths are
        case-insensitive but vmrun's list output and a hand-typed/JSON-
        stored path are not guaranteed to match byte-for-byte.
    #>
    param([Parameter(Mandatory = $true)][string]$VmrunExe, [Parameter(Mandatory = $true)][string]$VmxPath)
    try {
        $running = Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('list')
        $lines = @($running -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^Total running VMs' })
        $isRunning = @($lines | Where-Object { $_.Trim().TrimEnd('\') -ieq $VmxPath.TrimEnd('\') }).Count -gt 0
        return $(if ($isRunning) { 'running' } else { 'stopped' })
    } catch {
        return 'unknown'
    }
}

function Get-SnapshotList {
    param([Parameter(Mandatory = $true)][string]$VmrunExe, [Parameter(Mandatory = $true)][string]$VmxPath)
    try {
        $raw = Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('listSnapshots', $VmxPath)
        # First line is "Total snapshots: N" - not a snapshot name.
        return @($raw -split "`r?`n" | Select-Object -Skip 1 | Where-Object { $_ })
    } catch {
        return @()
    }
}

function Wait-ForGuestIp {
    <#
        Polls vmrun getGuestIPAddress until it returns an address or the
        timeout elapses. This needs VMware Tools (or open-vm-tools)
        running INSIDE the guest - which the golden image has, since the
        autounattend.xml-driven Windows setup installs it as part of the
        Packer build - and it can legitimately take a couple of minutes
        after `vmrun start` for Tools to come up and report an address,
        especially right after a snapshot revert.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$VmrunExe,
        [Parameter(Mandatory = $true)][string]$VmxPath,
        [int]$TimeoutSeconds = 180,
        [int]$PollSeconds = 5
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $ip = Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('getGuestIPAddress', $VmxPath, '-wait') -TimeoutSeconds $PollSeconds
            if ($ip -and $ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
        } catch {
            # Not up yet - keep polling rather than surfacing every
            # intermediate failure.
        }
        Start-Sleep -Seconds $PollSeconds
    }
    return $null
}

function Add-CaseSharedFolder {
    <#
        Mounts a host folder (the case's evidence - VHD/memdump/KAPE zips)
        read-only into the guest, the local equivalent of the cloud
        module's D: evidence mount. vmrun's addSharedFolder/
        enableSharedFolders subcommands edit the running VM's shared-folder
        state directly (no manual Workstation GUI step, no hand-editing the
        .vmx) - which is exactly the automation surface #5 in this
        project's design asked for.

        Deliberately NOT passing the "writable" flag: an investigation
        host's job is to read evidence, never to modify it, and the
        cloud module's investigation-host role is read-only on the case
        bucket/container for the identical reason (see infra\SECURITY.md).
        vmrun's own flag model only has "writable" to opt IN to write
        access - omitting it is the read-only default.

        Inside the guest, a VMware shared folder surfaces under
        \\vmware-host\Shared Folders\<ShareName> (and, once Windows
        notices it, usually also gets its own drive letter automatically -
        same "may not land on the letter you expect" caveat the cloud
        module's README documents for Azure's local temp disk). This
        module does not force a specific guest drive letter, because
        vmrun has no subcommand to request one - see infra\local\README.md
        for how to pin one by hand if a case needs it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$VmrunExe,
        [Parameter(Mandatory = $true)][string]$VmxPath,
        [Parameter(Mandatory = $true)][string]$ShareName,
        [Parameter(Mandatory = $true)][string]$HostPath
    )
    if (-not (Test-Path -LiteralPath $HostPath)) {
        throw "Evidence host path does not exist: $HostPath"
    }
    Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('enableSharedFolders', $VmxPath) | Out-Null
    Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('addSharedFolder', $VmxPath, $ShareName, $HostPath) | Out-Null
}

function Remove-CaseSharedFolder {
    param(
        [Parameter(Mandatory = $true)][string]$VmrunExe,
        [Parameter(Mandatory = $true)][string]$VmxPath,
        [Parameter(Mandatory = $true)][string]$ShareName
    )
    try {
        Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('removeSharedFolder', $VmxPath, $ShareName) | Out-Null
    } catch {
        # Not fatal - a case being torn down with no shared folder currently
        # configured (e.g. the previous session already removed it) should
        # not block Stop-LocalCase.ps1 from reverting the snapshot.
    }
}
