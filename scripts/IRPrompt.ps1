<#
.SYNOPSIS
    Shared console prompt helpers for this project's two menu front ends -
    scripts\Start-IRConsole.ps1 and infra\Start-CloudConsole.ps1.

.DESCRIPTION
    Dot-source this; it defines functions and does nothing on its own.

    Both consoles had their own copies of Read-Default/Read-Required/
    Read-YesNo/Wait-ForEnter, which had already drifted apart slightly. They
    live here now so a change to how prompting works happens once - which is
    what made arrow-key selection practical to add at all.

    ARROW-KEY SELECTION, AND WHY IT FALLS BACK

    Read-Choice draws a live list you move through with the arrow keys. That
    needs three things that are not always true: a real console host, a
    keyboard that is not redirected, and a cursor that can be repositioned.
    None of those hold when the console is driven by a pipe (which is how
    this project's own smoke tests exercise the menus), under the ISE, or in
    the VS Code PowerShell host, whose ReadKey does not behave like a
    terminal's.

    So Read-Choice detects the capability and falls back to the numbered
    prompt that was here before. The fallback is not a degraded afterthought:
    it is the same code path the consoles used for months, it accepts the
    same input, and it returns the same values. Anything scripted against
    these menus keeps working.

    A picker also never renders more rows than fit on screen. A VM size list
    can run to twenty-plus entries, and drawing past the bottom of the window
    scrolls the buffer out from under the cursor arithmetic, which corrupts
    the display on every subsequent redraw. Longer lists scroll inside a
    fixed viewport instead.
#>

# ---------------------------------------------------------------------------
# Capability detection
# ---------------------------------------------------------------------------

function Test-InteractiveKeyboard {
    <#
        True only where raw key reading genuinely works. Deliberately
        conservative: a false negative costs a nicer picker, a false positive
        throws an exception in the middle of an operator's workflow.
    #>
    try {
        if ([Console]::IsInputRedirected) { return $false }
        # ConsoleHost is the real terminal. 'Windows PowerShell ISE Host' and
        # 'Visual Studio Code Host' both fail on ReadKey($true) or cursor
        # positioning, so they take the numbered path.
        if ($Host.Name -ne 'ConsoleHost') { return $false }
        # Touching these throws in some redirected/embedded hosts even when
        # the checks above pass, so prove they work before relying on them.
        $null = [Console]::CursorTop
        $null = $Host.UI.RawUI.WindowSize.Height
        return $true
    } catch {
        return $false
    }
}

function Get-ConsoleWidth {
    try {
        $w = [Console]::WindowWidth
        if ($w -gt 20) { return $w }
    } catch { }
    return 80
}

function Get-ConsoleHeight {
    try {
        $h = [Console]::WindowHeight
        if ($h -gt 8) { return $h }
    } catch { }
    return 25
}

# ---------------------------------------------------------------------------
# Pure selection maths - kept separate so it can be tested without a console
# ---------------------------------------------------------------------------

function Step-SelectionIndex {
    <#
        Moves a selection by $Delta within $Count items, wrapping at both
        ends. Wrapping is why this is a function rather than inline
        arithmetic: PowerShell's % operator returns a NEGATIVE result for a
        negative left operand (-1 % 5 is -1, not 4), so the obvious
        one-liner puts the selection out of bounds the first time you press
        Up on the first item.
    #>
    param(
        [int]$Current,
        [int]$Delta,
        [int]$Count
    )
    if ($Count -le 0) { return 0 }
    $next = ($Current + $Delta) % $Count
    if ($next -lt 0) { $next += $Count }
    return $next
}

function Get-ViewportTop {
    <#
        Given a selected index and a window of $Visible rows, returns the
        first row to draw so the selection stays on screen.
    #>
    param(
        [int]$Selected,
        [int]$Top,
        [int]$Visible,
        [int]$Count
    )
    if ($Count -le $Visible) { return 0 }
    $newTop = $Top
    if ($Selected -lt $Top) { $newTop = $Selected }
    elseif ($Selected -ge ($Top + $Visible)) { $newTop = $Selected - $Visible + 1 }
    if ($newTop -lt 0) { $newTop = 0 }
    $maxTop = $Count - $Visible
    if ($newTop -gt $maxTop) { $newTop = $maxTop }
    return $newTop
}

function Step-ToSelectable {
    <#
        Moves the selection by one step in $Direction, skipping any entry that
        is not selectable, and wrapping. This is what lets a menu carry
        section headers ("Case workflow", "Teardown and cost") as real rows
        without the operator ever landing on one.

        If nothing is selectable it returns $Current rather than looping
        forever - a menu of nothing but headers is a caller bug, not a reason
        to hang the console.
    #>
    param(
        [int]$Current,
        [int]$Direction,
        [bool[]]$Selectable
    )
    $count = $Selectable.Count
    if ($count -le 0) { return $Current }
    if (-not ($Selectable -contains $true)) { return $Current }
    $idx = $Current
    for ($n = 0; $n -lt $count; $n++) {
        $idx = Step-SelectionIndex -Current $idx -Delta $Direction -Count $count
        if ($Selectable[$idx]) { return $idx }
    }
    return $Current
}

function Invoke-ChoiceKey {
    <#
        The picker's entire key handling, as a pure function: given a key and
        the current selection state, return the next state and what the caller
        should do about it.

        Extracted from the render loop so it can actually be tested. The loop
        around it needs a real console - raw key reads and cursor positioning
        are unavailable under a pipe - so leaving this logic inline would have
        made every arrow-key behaviour permanently unverifiable. Here it is
        exhaustively testable, and what stays untestable is only the drawing.

        Returns Selected, Top, and Action: 'move', 'select' or 'cancel'.
    #>
    param(
        [string]$KeyName,
        [string]$KeyChar,
        [int]$Selected,
        [int]$Top,
        [int]$Visible,
        [int]$Count,
        # Which rows can hold the selection. Defaults to all of them; a menu
        # with section headers passes $false for those rows.
        [bool[]]$Selectable
    )
    if (-not $Selectable -or $Selectable.Count -ne $Count) {
        $Selectable = @($true) * $Count
    }
    $action = 'move'
    switch ($KeyName) {
        'UpArrow' { $Selected = Step-ToSelectable -Current $Selected -Direction -1 -Selectable $Selectable }
        'DownArrow' { $Selected = Step-ToSelectable -Current $Selected -Direction 1 -Selectable $Selectable }
        'PageUp' {
            for ($i = 0; $i -lt $Visible; $i++) { $Selected = Step-ToSelectable -Current $Selected -Direction -1 -Selectable $Selectable }
        }
        'PageDown' {
            for ($i = 0; $i -lt $Visible; $i++) { $Selected = Step-ToSelectable -Current $Selected -Direction 1 -Selectable $Selectable }
        }
        'Home' {
            $Selected = 0
            if (-not $Selectable[0]) { $Selected = Step-ToSelectable -Current 0 -Direction 1 -Selectable $Selectable }
        }
        'End' {
            $Selected = $Count - 1
            if (-not $Selectable[$Selected]) { $Selected = Step-ToSelectable -Current $Selected -Direction -1 -Selectable $Selectable }
        }
        'Escape' { $action = 'cancel' }
        'Enter' { if ($Selectable[$Selected]) { $action = 'select' } }
        default {
            # Number keys still jump straight to an entry, so anyone who
            # learned the numbered menu keeps their muscle memory. Only 1-9
            # are reachable this way; longer lists use the arrows.
            if ($KeyChar -match '^[1-9]$') {
                $n = [int]$KeyChar
                if ($n -le $Count -and $Selectable[$n - 1]) { $Selected = $n - 1 }
            }
        }
    }
    $Top = Get-ViewportTop -Selected $Selected -Top $Top -Visible $Visible -Count $Count
    return [pscustomobject]@{ Selected = $Selected; Top = $Top; Action = $action }
}

# ---------------------------------------------------------------------------
# Text prompts
# ---------------------------------------------------------------------------

function Read-Default {
    <#
        Free-text prompt with the default rendered in colour, so "what
        happens if I just press Enter" is answerable at a glance rather than
        by parsing a bracketed string.
    #>
    param([string]$Prompt, [string]$Default)
    Write-Host "$Prompt " -NoNewline
    if ($Default) {
        Write-Host "[" -NoNewline -ForegroundColor DarkGray
        Write-Host $Default -NoNewline -ForegroundColor Green
        Write-Host "]" -NoNewline -ForegroundColor DarkGray
    } else {
        Write-Host "[blank]" -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ": " -NoNewline
    $val = Read-Host
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val.Trim()
}

function Read-Required {
    param([string]$Prompt)
    Write-Host "$Prompt " -NoNewline
    Write-Host "(blank to cancel)" -NoNewline -ForegroundColor DarkGray
    Write-Host ": " -NoNewline
    $val = Read-Host
    if ([string]::IsNullOrWhiteSpace($val)) { return $null }
    return $val.Trim()
}

function Read-YesNo {
    <#
        The default is capitalised AND coloured. Typing y/n still works, and
        Enter takes the default - unchanged from before, so muscle memory and
        piped input both survive.
    #>
    param([string]$Prompt, [bool]$Default = $false)
    Write-Host "$Prompt " -NoNewline
    Write-Host "[" -NoNewline -ForegroundColor DarkGray
    if ($Default) {
        Write-Host "Y" -NoNewline -ForegroundColor Green
        Write-Host "/n" -NoNewline -ForegroundColor DarkGray
    } else {
        Write-Host "y/" -NoNewline -ForegroundColor DarkGray
        Write-Host "N" -NoNewline -ForegroundColor Green
    }
    Write-Host "]" -NoNewline -ForegroundColor DarkGray
    Write-Host ": " -NoNewline
    $val = Read-Host
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val.Trim().ToUpper().StartsWith('Y')
}

function Wait-ForEnter {
    Write-Host ""
    Write-Host "Press Enter to return to the menu" -NoNewline -ForegroundColor DarkGray
    Read-Host | Out-Null
}

# ---------------------------------------------------------------------------
# Read-Choice
# ---------------------------------------------------------------------------

function ConvertTo-ChoiceEntry {
    # Normalises -Items (plain strings or objects) into Display/Value pairs
    # once, so neither the picker nor the fallback has to care which it got.
    param(
        [object[]]$Items,
        [string]$DisplayProperty,
        [string]$ValueProperty,
        [switch]$AllowCustom
    )
    $entries = @()
    foreach ($item in $Items) {
        # An item carrying a Separator property is a section header: rendered,
        # never selectable, never numbered.
        $isSep = $false
        if ($item -isnot [string] -and $item.PSObject.Properties['Separator']) { $isSep = $true }
        if ($isSep) {
            $entries += [pscustomobject]@{
                Display = [string]$item.Separator; Value = ''; Custom = $false; Selectable = $false
            }
            continue
        }
        $entries += [pscustomobject]@{
            Display    = $(if ($DisplayProperty) { [string]$item.$DisplayProperty } else { [string]$item })
            Value      = $(if ($ValueProperty) { [string]$item.$ValueProperty } else { [string]$item })
            Custom     = $false
            Selectable = $true
        }
    }
    if ($AllowCustom) {
        $entries += [pscustomobject]@{ Display = 'Something else - type it myself'; Value = ''; Custom = $true; Selectable = $true }
    }
    return $entries
}

function Read-ChoiceNumbered {
    # The original numbered prompt, unchanged in behaviour. Used wherever raw
    # key input is unavailable, and by every piped/scripted caller.
    param(
        [string]$Prompt,
        [object[]]$Entries,
        [int]$DefaultIndex,
        [string]$Default,
        [string]$CustomPrompt
    )
    Write-Host ""
    Write-Host $Prompt -ForegroundColor Cyan
    # Separators are printed but not numbered, so the visible numbers stay
    # contiguous. $numberMap translates a typed number back to the real index.
    $numberMap = @{}
    $shown = 0
    $defaultNumber = -1

    # When every selectable entry has a short, distinct value - which is what a
    # MENU looks like ('1'..'9', 'B', 'C', 'Q') - show that value as the key
    # instead of a running number. Otherwise the cloud console's [B]/[C]/[D]
    # would print here as [10]/[12]/[13] and contradict every reference to them
    # in the docs. Data lists (regions, VM sizes) have long values and stay
    # numbered.
    $picks = @($Entries | Where-Object { $_.Selectable })
    $shortVals = @($picks | Where-Object { $_.Value -and $_.Value.Length -le 2 })
    $useValueKeys = ($picks.Count -gt 0 -and $shortVals.Count -eq $picks.Count -and
        (@($picks | ForEach-Object { $_.Value.ToUpper() } | Sort-Object -Unique).Count -eq $picks.Count))

    for ($i = 0; $i -lt $Entries.Count; $i++) {
        if (-not $Entries[$i].Selectable) {
            Write-Host ""
            if ($Entries[$i].Display) { Write-Host ("  {0}" -f $Entries[$i].Display) -ForegroundColor DarkGray }
            continue
        }
        $shown++
        $numberMap[$shown] = $i
        if ($i -eq $DefaultIndex) { $defaultNumber = $shown }
        $key = if ($useValueKeys) { $Entries[$i].Value } else { "$shown" }
        Write-Host ("   [{0}] {1}" -f $key, $Entries[$i].Display) -NoNewline
        if ($i -eq $DefaultIndex) { Write-Host ' (default)' -ForegroundColor Green } else { Write-Host "" }
    }
    while ($true) {
        $hintKey = if ($useValueKeys -and $DefaultIndex -ge 0) { $Entries[$DefaultIndex].Value } else { "$defaultNumber" }
        $hint = if ($defaultNumber -ge 1) { " [$hintKey]" } else { '' }
        $raw = (Read-Host "Choose$hint").Trim()
        if (-not $raw -and $defaultNumber -ge 1) {
            $raw = if ($useValueKeys) { $Entries[$DefaultIndex].Value } else { "$defaultNumber" }
        }
        $n = 0
        if ([int]::TryParse($raw, [ref]$n)) {
            if ($numberMap.ContainsKey($n)) {
                $chosen = $Entries[$numberMap[$n]]
                if ($chosen.Custom) { return Read-Default -Prompt $CustomPrompt -Default $Default }
                return $chosen.Value
            }
        }
        # A typed VALUE also selects, so the menus' letter keys ('Q' to quit,
        # 'B', 'D', 'L') keep working on hosts that fall back to this prompt.
        # Without this, converting the menus to Read-Choice would have made Q
        # unreachable under a pipe or in the ISE - i.e. no way to quit.
        $byValue = $Entries | Where-Object { $_.Selectable -and $_.Value -and $_.Value -eq $raw } | Select-Object -First 1
        if ($byValue) {
            if ($byValue.Custom) { return Read-Default -Prompt $CustomPrompt -Default $Default }
            return $byValue.Value
        }
        Write-Host "Enter a number from the list." -ForegroundColor Yellow
    }
}

function Read-Choice {
    <#
    .SYNOPSIS
        Pick one item from a list, with the arrow keys where possible and a
        numbered prompt everywhere else.

    .PARAMETER Items
        Plain strings, or objects addressed by -DisplayProperty/-ValueProperty.

    .PARAMETER Default
        Matched against each item's VALUE. That entry starts selected and is
        marked, so Enter alone takes it.

    .PARAMETER AllowCustom
        Appends a "type it myself" entry, for lists that cannot be exhaustive.
    #>
    param(
        [string]$Prompt,
        [object[]]$Items,
        [string]$DisplayProperty,
        [string]$ValueProperty,
        [string]$Default,
        [switch]$AllowCustom,
        [string]$CustomPrompt = 'Enter a value',
        # Overridden only by the test harness, which has no real console to
        # read keys from. Production always uses the real reader.
        [scriptblock]$KeyReader = { [Console]::ReadKey($true) }
    )

    if (-not $Items -or $Items.Count -eq 0) {
        if ($AllowCustom) { return Read-Default -Prompt $CustomPrompt -Default $Default }
        return $null
    }

    $entries = ConvertTo-ChoiceEntry -Items $Items -DisplayProperty $DisplayProperty `
        -ValueProperty $ValueProperty -AllowCustom:$AllowCustom

    # -1 means "no default", which the numbered path renders as no hint.
    $defaultIndex = -1
    if ($Default) {
        for ($i = 0; $i -lt $entries.Count; $i++) {
            if ($entries[$i].Value -eq $Default) { $defaultIndex = $i; break }
        }
    }

    if (-not (Test-InteractiveKeyboard)) {
        return Read-ChoiceNumbered -Prompt $Prompt -Entries $entries -DefaultIndex $defaultIndex `
            -Default $Default -CustomPrompt $CustomPrompt
    }

    $selectable = [bool[]]@($entries | ForEach-Object { [bool]$_.Selectable })
    $selected = if ($defaultIndex -ge 0) { $defaultIndex } else { 0 }
    # Never start parked on a section header.
    if (-not $selectable[$selected]) {
        $selected = Step-ToSelectable -Current $selected -Direction 1 -Selectable $selectable
    }
    $width = (Get-ConsoleWidth) - 1
    # Leave room for the prompt line, the hint line, and whatever the caller
    # printed above; never claim the whole window.
    $visible = [Math]::Min($entries.Count, [Math]::Max(3, (Get-ConsoleHeight) - 8))
    $top = Get-ViewportTop -Selected $selected -Top 0 -Visible $visible -Count $entries.Count
    $linesRendered = $visible + 2   # prompt line + rows + hint line
    $startTop = $null

    function Write-PaddedLine {
        param([string]$Text, [hashtable]$ColorArgs = @{})
        # Truncate then pad to the console width. Truncating stops a long line
        # wrapping, which would desynchronise the cursor arithmetic; padding
        # erases whatever the previous frame left on that row.
        if ($Text.Length -gt $width) { $Text = $Text.Substring(0, $width) }
        Write-Host $Text.PadRight($width) @ColorArgs
    }

    try {
        while ($true) {
            if ($null -ne $startTop) {
                [Console]::SetCursorPosition(0, $startTop)
            }

            Write-PaddedLine -Text $Prompt -ColorArgs @{ ForegroundColor = 'Cyan' }

            for ($row = 0; $row -lt $visible; $row++) {
                $idx = $top + $row
                if ($idx -ge $entries.Count) { Write-PaddedLine -Text ''; continue }
                if (-not $entries[$idx].Selectable) {
                    Write-PaddedLine -Text ("  " + $entries[$idx].Display) -ColorArgs @{ ForegroundColor = 'DarkGray' }
                    continue
                }
                $isSel = ($idx -eq $selected)
                $isDef = ($idx -eq $defaultIndex)
                $prefix = if ($isSel) { '>' } else { ' ' }
                $suffix = if ($isDef) { ' (default)' } else { '' }
                $text = "{0} {1}{2}" -f $prefix, $entries[$idx].Display, $suffix
                if ($isSel) {
                    Write-PaddedLine -Text $text -ColorArgs @{ ForegroundColor = 'Black'; BackgroundColor = 'Cyan' }
                } elseif ($isDef) {
                    Write-PaddedLine -Text $text -ColorArgs @{ ForegroundColor = 'Green' }
                } else {
                    Write-PaddedLine -Text $text
                }
            }

            $more = if ($entries.Count -gt $visible) { "  ({0} of {1})" -f ($selected + 1), $entries.Count } else { '' }
            Write-PaddedLine -Text ("  up/down to move, Enter to select, Esc to cancel$more") -ColorArgs @{ ForegroundColor = 'DarkGray' }

            if ($null -eq $startTop) {
                # Established after the first frame, not before: rendering can
                # scroll the buffer, which moves everything already drawn up.
                $startTop = [Console]::CursorTop - $linesRendered
                if ($startTop -lt 0) { $startTop = 0 }
            }

            $key = & $KeyReader
            $state = Invoke-ChoiceKey -KeyName ([string]$key.Key) -KeyChar ([string]$key.KeyChar) `
                -Selected $selected -Top $top -Visible $visible -Count $entries.Count -Selectable $selectable
            $selected = $state.Selected
            $top = $state.Top

            if ($state.Action -eq 'cancel') {
                [Console]::SetCursorPosition(0, $startTop + $linesRendered)
                return $null
            }
            if ($state.Action -eq 'select') {
                [Console]::SetCursorPosition(0, $startTop + $linesRendered)
                $chosen = $entries[$selected]
                Write-Host ("  -> {0}" -f $chosen.Display) -ForegroundColor Green
                if ($chosen.Custom) { return Read-Default -Prompt $CustomPrompt -Default $Default }
                return $chosen.Value
            }
        }
    } catch {
        # Any console/cursor failure mid-picker drops to the prompt that
        # cannot fail, rather than taking the operator's session with it.
        Write-Host ""
        Write-Host "(falling back to numbered selection: $($_.Exception.Message))" -ForegroundColor DarkGray
        return Read-ChoiceNumbered -Prompt $Prompt -Entries $entries -DefaultIndex $defaultIndex `
            -Default $Default -CustomPrompt $CustomPrompt
    }
}

function Read-MenuChoice {
    <#
        The top-level menu reader. Accepts a typed key (so '2', 'q', 'B' all
        work exactly as before) and returns it uppercased.
    #>
    param([string]$Prompt = 'Choose an option')
    Write-Host "$Prompt" -NoNewline
    Write-Host ": " -NoNewline
    $val = Read-Host
    if ($null -eq $val) { return '' }
    return $val.Trim().ToUpper()
}
