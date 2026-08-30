<#
.SYNOPSIS
    Builds a custom Velociraptor offline collector via the CLI - the same
    server artifact (Server.Utils.CreateCollector) the GUI's "Offline
    Collector Builder" calls, not the simpler `config repack` trick.

.DESCRIPTION
    Deliberately uses Server.Utils.CreateCollector rather than `config
    repack`: the latter does not reliably carry bundled third-party tools
    (e.g. Autoruns' autorunsc.exe) into the new binary, per Velociraptor's
    own docs, which would silently break any artifact that needs one.

    Two non-obvious things this script handles that cost real debugging time
    to work out - both confirmed directly against a real build, not guessed:

    1. Windows.KapeFiles.Targets is NOT built into current Velociraptor
       releases - confirmed directly ("Loaded 421 built in artifacts" is
       identical with or without it). It was split out into a separate
       "Triage Artifacts" project (see Velocidex/velociraptor discussion
       #4481, "I miss you, KAPE"). The current artifact is
       Windows.Triage.Targets, fetched from
       https://triage.velocidex.com/ and loaded via -DefinitionsFolder. Its
       real parameter is HighLevelTargets (confirmed from the artifact's own
       declared schema: type multichoice, default "[]") - a JSON array
       *encoded as a string*, not a bare key like `_SANS_Triage: Y`.

    2. Server.Utils.CreateCollector needs the base Windows client binary
       registered as a named tool ("VelociraptorWindows") via inventory_add()
       first, or it fails with "Tool VelociraptorWindows not declared in
       inventory". This script does that registration automatically,
       pointing at the same $VeloExe binary running the whole script.

    Everything passed to the Velociraptor binary as a CLI argument goes
    through ConvertTo-NativeArg first. PowerShell does not correctly
    re-escape embedded double quotes when handing an argument containing
    them to a *native* executable - it can silently strip them or corrupt
    them depending on how many backslashes happen to precede a quote. The
    real rule (confirmed by deliberately triggering and diagnosing the
    corruption): a run of N backslashes immediately before a literal quote
    becomes N/2 literal backslashes if N is even (with the quote itself
    consumed as a delimiter, never appearing in the output), or (N-1)/2
    backslashes plus one literal quote if N is odd.
    ConvertTo-NativeArg implements the correct escaping for this rule so
    nothing here needs hand-escaped JSON strings.

.PARAMETER VeloExe
    Path to a plain Velociraptor binary - NOT an already-repacked collector.
    Every Velociraptor binary (plain or repacked) refuses to run at all
    without elevation, confirmed directly - even `--help` fails non-elevated.
    Download the windows-amd64 release from
    https://github.com/Velocidex/velociraptor/releases.

.PARAMETER DefinitionsFolder
    Folder for custom/extra artifact YAML - this script places
    Windows.Triage.Targets.yaml here automatically if not already present.
    Also point this at (or copy into it) any of your own custom artifacts,
    e.g. Custom.Windows.Hash.RecentExecutables.yaml from this same folder.

.PARAMETER Artifacts
    Full artifact list for the collector. Defaults to this project's
    recommended set - see velociraptor/README.md.

.PARAMETER HighLevelTargets
    Windows.Triage.Targets meta-target(s) to select - e.g. _SANS_Triage,
    _KapeTriage, _BasicCollection, _Live. Multiple values are allowed.

.PARAMETER GlobsCsv
    Path to a Glob-column CSV for Generic.Collectors.File. Defaults to this
    folder's own malware-drop-locations.csv.

.EXAMPLE
    # Run in an ELEVATED PowerShell window:
    .\Build-Collector.ps1 -VeloExe C:\Tools\velociraptor.exe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VeloExe,

    [string]$DefinitionsFolder = $PSScriptRoot,

    [string[]]$Artifacts = @(
        'Windows.Triage.Targets',
        'Windows.Network.NetstatEnriched',
        'Windows.System.Pslist',
        'Windows.Sysinternals.Autoruns',
        'Windows.System.DNSCache',
        'Windows.System.Services',
        'Custom.Windows.Hash.RecentExecutables',
        'Generic.Collectors.File'
    ),

    [string[]]$HighLevelTargets = @('_SANS_Triage'),

    [string]$GlobsCsv = (Join-Path $PSScriptRoot 'malware-drop-locations.csv'),

    [string]$OutputZip = ".\NewCollector.zip",
    [string]$ServerConfig = ".\throwaway-server.config.yaml"
)

$ErrorActionPreference = 'Stop'

function ConvertTo-NativeArg {
    # See the .DESCRIPTION block above for exactly what rule this implements
    # and why it's needed - PowerShell's own native-argument passing does
    # not do this correctly for you.
    param([string]$Value)
    $result = New-Object System.Text.StringBuilder
    $i = 0
    $n = $Value.Length
    while ($i -lt $n) {
        $j = $i
        $backslashCount = 0
        while ($j -lt $n -and $Value[$j] -eq '\') { $backslashCount++; $j++ }
        if ($j -eq $n) {
            [void]$result.Append([string]::new('\', $backslashCount))
            $i = $j
        } elseif ($Value[$j] -eq '"') {
            [void]$result.Append([string]::new('\', $backslashCount * 2 + 1))
            [void]$result.Append('"')
            $i = $j + 1
        } else {
            [void]$result.Append([string]::new('\', $backslashCount))
            [void]$result.Append($Value[$j])
            $i = $j + 1
        }
    }
    return $result.ToString()
}

# 1. Fetch Windows.Triage.Targets.yaml if not already present - see point 1
#    in the header comment for why this can't just be a built-in artifact
#    name. Fetched fresh rather than committed to this repo, so it stays
#    current with whatever the Triage Artifacts project currently ships.
$triageTargetsYaml = Join-Path $DefinitionsFolder 'Windows.Triage.Targets.yaml'
if (-not (Test-Path -LiteralPath $triageTargetsYaml)) {
    $tmpZip = Join-Path $env:TEMP 'Windows.Triage.Targets.zip'
    Invoke-WebRequest -Uri 'https://triage.velocidex.com/docs/windows.triage.targets/Windows.Triage.Targets.zip' -OutFile $tmpZip
    Expand-Archive -LiteralPath $tmpZip -DestinationPath $DefinitionsFolder -Force
    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
}

# 2. Generate a throwaway self-signed server config. No live server ever
#    runs - this file just carries the X.509 certs CreateCollector wants.
if (-not (Test-Path -LiteralPath $ServerConfig)) {
    & $VeloExe config generate | Out-File -Encoding utf8 $ServerConfig
}

# 3. Register the base client binary as a named tool - see point 2 in the
#    header comment.
$veloFullPath = (Resolve-Path -LiteralPath $VeloExe).Path
$inventoryQuery = 'SELECT inventory_add(tool="VelociraptorWindows", filename="velociraptor.exe", file="' + ($veloFullPath -replace '\\', '\\') + '", serve_locally=TRUE) FROM scope()'
& $VeloExe --config $ServerConfig -v query (ConvertTo-NativeArg -Value $inventoryQuery)

# 4. Build the actual artifacts/parameters payload as real PowerShell
#    objects, then serialize with ConvertTo-Json - only the FINAL JSON
#    string ever needs argv-escaping this way, instead of hand-building
#    nested JSON-as-a-string by hand (which is exactly how this script's
#    early drafts went wrong).
    # [string] cast is load-bearing, not decoration: Get-Content -Raw returns a
    # string object decorated with filesystem note properties (PSPath, PSDrive,
    # PSProvider, etc.). ConvertTo-Json at any -Depth beyond 2 serializes those
    # note properties instead of the plain text - and since PSDrive/PSProvider
    # themselves nest further, the output size explodes exponentially with
    # -Depth (confirmed directly: 815 bytes at -Depth 2, 2.2MB at -Depth 6,
    # effectively hung well before -Depth 10). The cast discards the
    # decoration and gives ConvertTo-Json a plain .NET string, which fixes
    # both the correctness bug and the blowup at any depth.
$globsContent = [string](Get-Content -Raw -LiteralPath $GlobsCsv)

# ConvertTo-Json silently unwraps a single-element array to a bare scalar
# when piped to it - Velociraptor's multichoice parameter needs a real JSON
# array ("[...]") even for one selection, so this always uses -InputObject
# (never a pipe) to avoid that.
$highLevelTargetsValue = ConvertTo-Json -InputObject $HighLevelTargets -Compress

$parametersObj = [ordered]@{
    'Windows.Triage.Targets'  = @{ HighLevelTargets = $highLevelTargetsValue }
    'Generic.Collectors.File' = @{ collectionSpec = $globsContent; Root = 'C:'; Accessor = 'auto' }
}

$artifactsJson  = ConvertTo-Json -InputObject $Artifacts -Compress
$parametersJson = ConvertTo-Json -InputObject $parametersObj -Compress -Depth 10

$artifactsArg   = ConvertTo-NativeArg -Value "artifacts=$artifactsJson"
$parametersArg  = ConvertTo-NativeArg -Value "parameters=$parametersJson"

& $VeloExe --config $ServerConfig -v artifacts collect Server.Utils.CreateCollector `
    --args "OS=Windows" `
    --args $artifactsArg `
    --args $parametersArg `
    --args "target=ZIP" `
    --args "opt_admin=Y" `
    --args "opt_prompt=N" `
    --definitions $DefinitionsFolder `
    --output $OutputZip

Write-Host ""
Write-Host "Built $OutputZip - unzip it; the collector exe (and any bundled tools) is under uploads\scope\."
Write-Host "Verify Windows.Sysinternals.Autoruns actually produces data (not a 'tool not found' error) before trusting this collector - that's the one dependency this build path exists to get right."
