<#
.SYNOPSIS
    Offline self-test for this repository. Runs in seconds, touches no cloud
    account, and needs no credentials.

.DESCRIPTION
    This exists because of a specific, repeated failure mode in this project:
    code that is obviously correct by inspection, and wrong the moment it
    crosses a process boundary. A parameter forwarded to a script that never
    declared it. A menu entry dispatching to a function that was renamed. An
    array that counts as one element when it holds a single null. Every one of
    those shipped, and every one of them cost a live cloud deploy to find.

    So the checks here are deliberately structural rather than stylistic:

      1. Syntax    - every .ps1 in the repo parses.
      2. Prompts   - the shared prompt library's selection maths and key
                     handling, exhaustively, including the negative-modulo
                     wrap and the section-header skip.
      3. Wiring    - every console menu entry resolves to a real function,
                     every script a console invokes exists, and every flag it
                     passes is a declared parameter of that script.
      4. Contracts - the array/null traps that produced phantom resources and
                     empty --key arguments.

    What it does NOT do is verify anything that requires a cloud API. Those
    paths are marked "needs a live test" in the testing docs and stay that way.

.PARAMETER Quiet
    Only print failures and the summary.

.EXAMPLE
    .\Invoke-SelfTest.ps1
#>
[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$InfraRoot = Join-Path $RepoRoot 'infra'

$script:Pass = 0
$script:Fail = 0
$script:Failures = @()

function Test-Item {
    param([string]$Label, [bool]$Condition, [string]$Detail)
    if ($Condition) {
        $script:Pass++
        if (-not $Quiet) { Write-Host "  OK   $Label" -ForegroundColor DarkGray }
    } else {
        $script:Fail++
        $script:Failures += $Label
        Write-Host "  FAIL $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
    }
}

function Write-Section {
    param([string]$Name)
    if (-not $Quiet) { Write-Host ""; Write-Host "=== $Name ===" -ForegroundColor Cyan }
}

# ---------------------------------------------------------------------------
Write-Section "1. PowerShell syntax"
$allScripts = Get-ChildItem -LiteralPath $RepoRoot -Recurse -Filter '*.ps1' |
    Where-Object { $_.FullName -notmatch '\\\.git\\' }
foreach ($f in $allScripts) {
    $t = $null; $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e) | Out-Null
    $rel = $f.FullName.Substring($RepoRoot.Length + 1)
    Test-Item -Label $rel -Condition ($null -eq $e -or $e.Count -eq 0) `
        -Detail $(if ($e) { ($e | ForEach-Object { $_.Message }) -join '; ' })
}

# ---------------------------------------------------------------------------
Write-Section "2. Prompt library"
. (Join-Path $PSScriptRoot 'IRPrompt.ps1')

# Negative modulo: -1 % 5 is -1 in PowerShell, so a naive wrap goes
# out of bounds the first time you press Up on the first item.
Test-Item 'Up from first wraps to last' ((Step-SelectionIndex -Current 0 -Delta -1 -Count 5) -eq 4)
Test-Item 'Down from last wraps to first' ((Step-SelectionIndex -Current 4 -Delta 1 -Count 5) -eq 0)
Test-Item 'Delta larger than count wraps correctly' ((Step-SelectionIndex -Current 0 -Delta -7 -Count 5) -eq 3)
Test-Item 'Zero items does not divide by zero' ((Step-SelectionIndex -Current 0 -Delta 1 -Count 0) -eq 0)

Test-Item 'Viewport: short list needs no scroll' ((Get-ViewportTop -Selected 0 -Top 0 -Visible 5 -Count 3) -eq 0)
Test-Item 'Viewport: scrolls down to reveal' ((Get-ViewportTop -Selected 7 -Top 0 -Visible 5 -Count 20) -eq 3)
Test-Item 'Viewport: clamps at the end' ((Get-ViewportTop -Selected 19 -Top 0 -Visible 5 -Count 20) -eq 15)

# Section headers must never hold the selection.
$sel = [bool[]]@($false, $true, $true, $false, $true)
Test-Item 'Header skipped moving down' ((Step-ToSelectable -Current 2 -Direction 1 -Selectable $sel) -eq 4)
Test-Item 'Header skipped wrapping backwards' ((Step-ToSelectable -Current 1 -Direction -1 -Selectable $sel) -eq 4)
Test-Item 'All-header list returns current, does not hang' `
    ((Step-ToSelectable -Current 0 -Direction 1 -Selectable ([bool[]]@($false, $false))) -eq 0)
Test-Item 'Enter on a header does not select' `
    ((Invoke-ChoiceKey -KeyName 'Enter' -KeyChar '' -Selected 0 -Top 0 -Visible 5 -Count 5 -Selectable $sel).Action -eq 'move')
Test-Item 'Enter on an item selects' `
    ((Invoke-ChoiceKey -KeyName 'Enter' -KeyChar '' -Selected 1 -Top 0 -Visible 5 -Count 5 -Selectable $sel).Action -eq 'select')
Test-Item 'Escape cancels' `
    ((Invoke-ChoiceKey -KeyName 'Escape' -KeyChar '' -Selected 1 -Top 0 -Visible 5 -Count 5 -Selectable $sel).Action -eq 'cancel')
Test-Item 'Home lands on first selectable' `
    ((Invoke-ChoiceKey -KeyName 'Home' -KeyChar '' -Selected 4 -Top 0 -Visible 5 -Count 5 -Selectable $sel).Selected -eq 1)
Test-Item 'End lands on last selectable' `
    ((Invoke-ChoiceKey -KeyName 'End' -KeyChar '' -Selected 1 -Top 0 -Visible 5 -Count 5 -Selectable $sel).Selected -eq 4)
Test-Item 'Digit shortcut jumps to an item' `
    ((Invoke-ChoiceKey -KeyName 'D5' -KeyChar '5' -Selected 1 -Top 0 -Visible 5 -Count 5 -Selectable $sel).Selected -eq 4)
Test-Item 'Digit pointing at a header is ignored' `
    ((Invoke-ChoiceKey -KeyName 'D1' -KeyChar '1' -Selected 4 -Top 0 -Visible 5 -Count 5 -Selectable $sel).Selected -eq 4)
Test-Item 'Unhandled key is a no-op' `
    ((Invoke-ChoiceKey -KeyName 'Spacebar' -KeyChar ' ' -Selected 2 -Top 0 -Visible 5 -Count 5 -Selectable $sel).Selected -eq 2)

# A redirected stdin must take the numbered path, or every scripted caller
# and this very test would hang waiting on a key that never comes.
Test-Item 'Redirected input falls back to the numbered prompt' ((Test-InteractiveKeyboard) -eq $false)

# ---------------------------------------------------------------------------
Write-Section "3. Console wiring"

function Get-ScriptParams {
    param([string]$Path)
    $t = $null; $e = $null
    $a = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$t, [ref]$e)
    if ($e -and $e.Count -gt 0) { return $null }
    if (-not $a.ParamBlock) { return @() }
    return $a.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
}

function Test-Console {
    param([string]$ConsolePath, [string]$ScriptDir, [string]$InvokerName)
    $name = Split-Path $ConsolePath -Leaf
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ConsolePath, [ref]$t, [ref]$e)
    if ($e -and $e.Count -gt 0) { Test-Item "$name parses" $false; return }

    $defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            ForEach-Object { $_.Name })
    # Dot-sourced helpers count as defined too.
    $defined += @('Read-Default', 'Read-Required', 'Read-YesNo', 'Read-Choice', 'Wait-ForEnter')

    # Every function named in the dispatch switch must exist.
    $src = Get-Content -Raw $ConsolePath
    $dispatch = [regex]::Matches($src, "(?m)^\s*'[^']+'\s*\{\s*(Invoke-[A-Za-z-]+|Show-[A-Za-z-]+)") |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    foreach ($fn in $dispatch) {
        Test-Item "$name dispatches to $fn" ($defined -contains $fn)
    }

    # Every menu VALUE must have a matching branch in the switch, and vice
    # versa. A menu entry with no branch silently does nothing; a branch with
    # no entry is unreachable. Both have happened here.
    $menuValues = [regex]::Matches($src, "Value\s*=\s*'([^']+)'\s*;\s*Label") |
        ForEach-Object { $_.Groups[1].Value }
    if ($menuValues) {
        $branches = [regex]::Matches($src, "(?m)^\s*'([^']+)'\s*\{") | ForEach-Object { $_.Groups[1].Value }
        foreach ($v in $menuValues) {
            if ($v -eq 'Q') { continue }   # Q is handled by the -in @('Q','QUIT','EXIT') branch
            Test-Item "$name menu key [$v] has a dispatch branch" ($branches -contains $v)
        }
    }

    # Every invoked script must exist, and every flag must be a real parameter.
    $calls = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $InvokerName
        }, $true)
    foreach ($call in $calls) {
        $elems = $call.CommandElements
        if ($elems.Count -lt 2) { continue }
        $target = $elems[1].Extent.Text.Trim("'", '"')
        $path = Join-Path $ScriptDir $target
        Test-Item "$name -> $target exists" (Test-Path $path)
        if (-not (Test-Path $path)) { continue }
        $declared = Get-ScriptParams -Path $path
        if ($null -eq $declared) { continue }
        # Only this call's own arguments - a regex spanning newlines once
        # attributed one call's flags to a different call's script.
        $argText = ($elems | Select-Object -Skip 2 | ForEach-Object { $_.Extent.Text }) -join ' '
        $flags = [regex]::Matches($argText, "'-([A-Za-z][A-Za-z0-9]*)'") |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        foreach ($flag in $flags) {
            Test-Item "$name -> $target -$flag is a declared parameter" ($declared -contains $flag)
        }
    }
}

Test-Console -ConsolePath (Join-Path $InfraRoot 'Start-CloudConsole.ps1') `
    -ScriptDir (Join-Path $InfraRoot 'scripts') -InvokerName 'Invoke-ScriptFile'

# The IR console runs deployed copies under <KapePath>\Modules\bin, which may
# not exist on this machine, so only its checkout-relative calls are checked.
Test-Console -ConsolePath (Join-Path $PSScriptRoot 'Start-IRConsole.ps1') `
    -ScriptDir $PSScriptRoot -InvokerName 'Invoke-CheckoutScript'

# Flags assembled into a variable at runtime are invisible to the AST check
# above, so they are asserted explicitly here.
$runtimeFlags = @(
    @{ Script = 'New-ToolsStorage.ps1'; Flags = @('CloudProvider', 'Region', 'AwsProfile', 'ResourceGroup', 'Location', 'KapeZipPath', 'Name', 'Delete') }
    @{ Script = 'Test-AwsTeardown.ps1'; Flags = @('AwsProfile', 'Region', 'AllRegions') }
    @{ Script = 'Test-AzureTeardown.ps1'; Flags = @('AllSubscriptions') }
)
foreach ($rf in $runtimeFlags) {
    $declared = Get-ScriptParams -Path (Join-Path $InfraRoot "scripts\$($rf.Script)")
    foreach ($flag in $rf.Flags) {
        Test-Item "runtime-built -$flag binds on $($rf.Script)" ($declared -contains $flag)
    }
}

# ---------------------------------------------------------------------------
Write-Section "4. Array and null contracts"

# @($null) is a ONE-element array containing null. This is why an empty S3
# bucket was treated as non-empty and delete-object was called with --key ''.
$emptyApiResult = [pscustomobject]@{ }
Test-Item 'Unfiltered @($null) counts as 1 (the trap itself)' `
    ((@($emptyApiResult.Versions)).Count -eq 1)
Test-Item 'Filtered with Where-Object counts as 0 (the fix)' `
    ((@($emptyApiResult.Versions | Where-Object { $_ })).Count -eq 0)

# Every enumeration of a cloud API result in the teardown scripts must filter.
# Every file that enumerates a cloud API result. Start-CloudConsole.ps1 is
# included because seven sites in it had exactly this defect, two of them
# in the VM-size lookup where an absent property would have dropped every
# size and left the picker empty.
$enumFiles = @(
    'scripts\Test-AwsTeardown.ps1', 'scripts\New-AwsTestNetwork.ps1',
    'scripts\Remove-AwsCaseStorage.ps1', 'scripts\Test-AzureTeardown.ps1',
    'scripts\New-ToolsStorage.ps1', 'scripts\New-AzureTestNetwork.ps1',
    'Start-CloudConsole.ps1'
)
foreach ($f in $enumFiles) {
    $body = Get-Content -Raw (Join-Path $InfraRoot $f)
    $unfiltered = [regex]::Matches($body, '@\(\$[A-Za-z]+\.[A-Za-z]+\)')
    Test-Item "$f filters every API enumeration" ($unfiltered.Count -eq 0) `
        -Detail $(($unfiltered | ForEach-Object { $_.Value }) -join ', ')
}

# The prereq store must not be readable as a case record.
$casesGuard = Get-Content -Raw (Join-Path $InfraRoot 'Start-CloudConsole.ps1')
Test-Item 'Case records are guarded on case_id' ($casesGuard -match 'Where-Object \{ \$_ -and \$_\.case_id \}')
Test-Item 'Prereq store lives outside .cases' ($casesGuard -match "PrereqPath = Join-Path \`$InfraRoot '\.prereqs\.json'")

# ---------------------------------------------------------------------------
Write-Section "5. Security regressions"

# Each of these encodes a finding from the security audit. They are string
# assertions against the Terraform source rather than plan output, because a
# plan needs cloud credentials and this suite deliberately runs offline.

$awsHost = Get-Content -Raw (Join-Path $InfraRoot 'modules\aws\investigation-host\main.tf')
$awsUserData = Get-Content -Raw (Join-Path $InfraRoot 'modules\aws\investigation-host\user_data.ps1.tftpl')

# user_data is readable by any process on the instance via IMDS. The password
# must not be in it.
Test-Item 'AWS user_data does not carry the admin password' `
    (-not ($awsUserData -match '\$\{admin_password\}'))
Test-Item 'AWS admin password is stored in SSM Parameter Store' `
    ($awsHost -match 'resource "aws_ssm_parameter" "admin_password"' -and $awsHost -match 'SecureString')
Test-Item 'AWS SSM parameter read is scoped to this case only' `
    ($awsHost -match 'aws_ssm_parameter\.admin_password\.arn')
Test-Item 'AWS instance requires IMDSv2' `
    ($awsHost -match 'http_tokens\s*=\s*"required"')

# A named account, not the built-in Administrator.
Test-Item 'AWS creates a named interactive account, not Administrator' `
    ($awsUserData -notmatch 'net user Administrator' -and $awsUserData -match 'New-LocalUser')
Test-Item 'AWS password is set without appearing on a command line' `
    ($awsUserData -match 'ConvertTo-SecureString')

# The bootstrap runs as SYSTEM on a host that mounts evidence, so the ref it
# is fetched from must not be a mutable branch.
foreach ($cloud in @('aws', 'azure')) {
    $m = Get-Content -Raw (Join-Path $InfraRoot "modules\$cloud\investigation-host\main.tf")
    $v = Get-Content -Raw (Join-Path $InfraRoot "modules\$cloud\investigation-host\variables.tf")
    Test-Item "$cloud bootstrap ref is a variable, not hardcoded main" `
        ($m -notmatch 'refs/heads/main\.zip' -and $m -match '\$\{var\.repo_ref\}')
    Test-Item "$cloud repo_ref defaults to a pinned 40-char commit SHA" `
        ($v -match 'variable "repo_ref"' -and $v -match 'default\s*=\s*"[0-9a-f]{40}"')
}

# case_id reaches code that executes as SYSTEM, so Terraform must validate it
# even when the console is bypassed.
foreach ($env in @('aws-case', 'azure-case')) {
    $vars = Get-Content -Raw (Join-Path $InfraRoot "environments\$env\variables.tf")
    Test-Item "$env validates case_id" `
        ($vars -match '(?s)variable "case_id".*?validation')
}

# Evidence integrity tooling exists and is reachable from the console.
Test-Item 'Evidence manifest script exists' `
    (Test-Path (Join-Path $PSScriptRoot 'Get-EvidenceManifest.ps1'))
$manifest = Get-Content -Raw (Join-Path $PSScriptRoot 'Get-EvidenceManifest.ps1')
Test-Item 'Manifest uses SHA-256, not MD5/SHA-1' `
    ($manifest -match "Algorithm SHA256" -and $manifest -notmatch "Algorithm MD5")
Test-Item 'Manifest hashing includes hidden files' ($manifest -match '-Recurse -File -Force')
$irConsole = Get-Content -Raw (Join-Path $PSScriptRoot 'Start-IRConsole.ps1')
Test-Item 'IR console exposes the evidence manifest' `
    ($irConsole -match "Get-EvidenceManifest\.ps1")

# Opt-in audit logging is wired on both clouds.
$awsStorage = Get-Content -Raw (Join-Path $InfraRoot 'modules\aws\case-storage\main.tf')
$azStorage = Get-Content -Raw (Join-Path $InfraRoot 'modules\azure\case-storage\main.tf')
Test-Item 'AWS case storage supports access logging' `
    ($awsStorage -match 'aws_s3_bucket_logging')
Test-Item 'Azure case storage supports blob diagnostics' `
    ($azStorage -match 'azurerm_monitor_diagnostic_setting' -and $azStorage -match 'StorageRead')

# The comment that claimed a control which did not exist.
Test-Item 'Azure storage comment no longer claims nonexistent network rules' `
    ($azStorage -notmatch 'network\s*\n?\s*#?\s*rules below')

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("-" * 60)
if ($script:Fail -eq 0) {
    Write-Host "ALL $($script:Pass) CHECKS PASSED" -ForegroundColor Green
} else {
    Write-Host "$($script:Fail) FAILED, $($script:Pass) passed" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
Write-Host ""
Write-Host "Not covered here: anything needing a live cloud account. See" -ForegroundColor DarkGray
Write-Host "infra/TESTING.md and infra/TESTING-AWS.md for those." -ForegroundColor DarkGray
exit $script:Fail
