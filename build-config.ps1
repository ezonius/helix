<#
.SYNOPSIS
    Merges Helix config fragments (keys/*.toml) into a single config.toml.

.DESCRIPTION
    Helix reads exactly one config file and has no include mechanism, and TOML
    forbids defining [keys.normal] twice. This script therefore merges the
    fragments itself: every keys/*.toml is read in name order, and the resulting
    tables are written out as one config.toml. A later fragment wins when two
    fragments set the same key in the same table (reported as "override").

    Supported fragment syntax (deliberately small, to stay dependency-free):
      [table]                 dotted and quoted segments, e.g. [keys.normal."+"]
      key = value             one per line; values are copied verbatim
      # comment               full-line comments only

    Not supported: [[array.of.tables]], multi-line arrays/strings, dotted keys,
    trailing comments after a value.

.PARAMETER ConfigDir
    Helix config directory. Defaults to %APPDATA%\helix on Windows,
    $XDG_CONFIG_HOME/helix or ~/.config/helix elsewhere.

.PARAMETER FragmentDir
    Fragment directory. Defaults to <ConfigDir>/keys.

.PARAMETER Platform
    Pretend to run on this platform (windows, linux, macos); defaults to the real one.
    A fragment may declare `# platform: <list>` in a comment; it is then only merged
    when the list matches. Tokens: windows, linux, macos (mac/osx/darwin),
    unix (linux + macos), all/any/*. No directive means every platform.

.PARAMETER Check
    Parse and validate only; report overrides, write nothing. Exit code 1 on error.

.PARAMETER Print
    Write the merged configuration to stdout instead of to config.toml.

.PARAMETER Quiet
    Only print errors.

.EXAMPLE
    .\build-config.ps1
    .\build-config.ps1 -Check
    .\build-config.ps1 -ConfigDir C:\tmp\helix -Print
#>
[CmdletBinding()]
param(
    [string]$ConfigDir,
    [string]$FragmentDir,
    [ValidateSet('windows', 'linux', 'macos')]
    [string]$Platform,
    [switch]$Check,
    [switch]$Print,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    [Console]::Error.WriteLine("error: $Message")
    exit 1
}

function Note([string]$Message) {
    if (-not $Quiet) { Write-Host $Message }
}

function Resolve-HelixConfigDir {
    if ($env:HELIX_CONFIG_DIR) { return $env:HELIX_CONFIG_DIR }
    if ($env:OS -eq 'Windows_NT' -and $env:APPDATA) { return (Join-Path $env:APPDATA 'helix') }
    if ($env:XDG_CONFIG_HOME) { return (Join-Path $env:XDG_CONFIG_HOME 'helix') }
    return (Join-Path $HOME '.config/helix')
}

# Splits a leading dotted key (bare or "quoted" segments) off a string.
# Returns @{ Segments = @(...); Rest = '...' }
function Read-KeyPrefix([string]$Text) {
    $segments = New-Object System.Collections.Generic.List[string]
    $i = 0
    $n = $Text.Length
    while ($true) {
        while ($i -lt $n -and $Text[$i] -eq ' ') { $i++ }
        if ($i -ge $n) { throw 'unexpected end of input while reading a key' }
        if ($Text[$i] -eq '"') {
            $i++
            $sb = New-Object System.Text.StringBuilder
            $closed = $false
            while ($i -lt $n) {
                $c = $Text[$i]
                if ($c -eq '\') {
                    if ($i + 1 -ge $n) { throw 'unterminated escape in quoted key' }
                    [void]$sb.Append($Text[$i + 1]); $i += 2; continue
                }
                if ($c -eq '"') { $i++; $closed = $true; break }
                [void]$sb.Append($c); $i++
            }
            if (-not $closed) { throw 'unterminated quoted key' }
            [void]$segments.Add($sb.ToString())
        }
        else {
            $start = $i
            while ($i -lt $n -and $Text[$i] -match '[A-Za-z0-9_-]') { $i++ }
            if ($i -eq $start) { throw "invalid key character '$($Text[$i])'" }
            [void]$segments.Add($Text.Substring($start, $i - $start))
        }
        while ($i -lt $n -and $Text[$i] -eq ' ') { $i++ }
        if ($i -lt $n -and $Text[$i] -eq '.') { $i++; continue }
        break
    }
    return @{ Segments = $segments.ToArray(); Rest = $Text.Substring($i) }
}

function Test-ValueIsSingleLine([string]$Value) {
    $depth = 0
    $inString = $false
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $c = $Value[$i]
        if ($inString) {
            if ($c -eq '\') { $i++; continue }
            if ($c -eq '"') { $inString = $false }
            continue
        }
        if ($c -eq '"') { $inString = $true; continue }
        if ($c -eq '[') { $depth++; continue }
        if ($c -eq ']') { $depth--; if ($depth -lt 0) { return $false }; continue }
    }
    return ($depth -eq 0 -and -not $inString)
}

function Get-CurrentPlatform {
    if ($env:OS -eq 'Windows_NT') { return 'windows' }
    $isMac = Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue
    if ($isMac) { return 'macos' }
    return 'linux'
}

# Reads `# platform: windows, unix` from a fragment's comments.
# Returns $null when the fragment has no directive (applies everywhere).
function Get-FragmentPlatforms([string[]]$Lines, [string]$Name) {
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '^\s*#\s*platform\s*[:=]\s*(.+)$', 'IgnoreCase')
        if ($m.Success) {
            return @($m.Groups[1].Value -split '[, \t]+' | Where-Object { $_ })
        }
    }
    return $null
}

function Test-PlatformMatch([string[]]$Tokens, [string]$Current, [string]$Name) {
    foreach ($token in $Tokens) {
        switch ($token.ToLowerInvariant()) {
            'windows' { if ($Current -eq 'windows') { return $true } }
            'linux' { if ($Current -eq 'linux') { return $true } }
            'macos' { if ($Current -eq 'macos') { return $true } }
            'mac' { if ($Current -eq 'macos') { return $true } }
            'osx' { if ($Current -eq 'macos') { return $true } }
            'darwin' { if ($Current -eq 'macos') { return $true } }
            'unix' { if ($Current -in @('linux', 'macos')) { return $true } }
            'all' { return $true }
            'any' { return $true }
            '*' { return $true }
            default { Fail "${Name} : unknown platform '$token' (use windows, linux, macos, unix or all)" }
        }
    }
    return $false
}

function Format-Key([string]$Key) {
    if ($Key -match '^[A-Za-z0-9_-]+$') { return $Key }
    $escaped = $Key.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

if (-not $ConfigDir) { $ConfigDir = Resolve-HelixConfigDir }
if (-not $FragmentDir) { $FragmentDir = Join-Path $ConfigDir 'keys' }
$outFile = Join-Path $ConfigDir 'config.toml'

if (-not (Test-Path -LiteralPath $FragmentDir)) { Fail "fragment directory not found: $FragmentDir" }
$fragments = @(Get-ChildItem -LiteralPath $FragmentDir -Filter '*.toml' -File | Sort-Object Name)
if ($fragments.Count -eq 0) { Fail "no *.toml fragments in $FragmentDir" }

function Ensure-Table([string]$TableKey, [string[]]$Segments) {
    if ($tableInfo.Contains($TableKey)) { return }
    $tableInfo[$TableKey] = @{
        Segments = $Segments
        Depth    = $Segments.Count
        Index    = $tableInfo.Count
    }
    $tables[$TableKey] = [ordered]@{}
}

# tableKey -> ordered dict of keyText -> @{ Value; Source }
$tables = [ordered]@{}
# tableKey -> @{ Segments; Depth; Index }
$tableInfo = [ordered]@{}
$overrides = New-Object System.Collections.Generic.List[string]

if (-not $Platform) { $Platform = Get-CurrentPlatform }
$skipped = New-Object System.Collections.Generic.List[string]

foreach ($fragment in $fragments) {
    $lines = [System.IO.File]::ReadAllLines($fragment.FullName)
    $platforms = Get-FragmentPlatforms $lines $fragment.Name
    if ($platforms -and -not (Test-PlatformMatch $platforms $Platform $fragment.Name)) {
        $skipped.Add("$($fragment.Name) (platform: $($platforms -join ' '))")
        continue
    }

    $currentTable = ''   # '' = top-level (before any [table] header)
    $lineNo = 0
    foreach ($rawLine in $lines) {
        $lineNo++
        $line = $rawLine.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('#')) { continue }
        $where = "$($fragment.Name):$lineNo"

        if ($line.StartsWith('[')) {
            if ($line.StartsWith('[[')) { Fail "$where : [[array.of.tables]] is not supported" }
            if (-not $line.EndsWith(']')) { Fail "$where : table header is missing its closing ']'" }
            $inner = $line.Substring(1, $line.Length - 2).Trim()
            try { $parsed = Read-KeyPrefix $inner } catch { Fail "$where : $_" }
            if ($parsed.Rest.Trim()) { Fail "$where : unexpected text after table header: '$($parsed.Rest)'" }
            $segments = @($parsed.Segments)
            $currentTable = $segments -join [char]1
            Ensure-Table $currentTable $segments
            continue
        }

        # top-level key (theme = ...) or key inside the current table
        Ensure-Table $currentTable @()

        try { $parsed = Read-KeyPrefix $line } catch { Fail "$where : $_" }
        if (@($parsed.Segments).Count -ne 1) { Fail "$where : dotted keys are not supported" }
        $rest = $parsed.Rest.TrimStart()
        if (-not $rest.StartsWith('=')) { Fail "$where : expected '=' after the key" }
        $value = $rest.Substring(1).Trim()
        if (-not $value) { Fail "$where : missing value" }
        if ($value.Contains('"""')) { Fail "$where : multi-line strings are not supported" }
        if (-not (Test-ValueIsSingleLine $value)) {
            Fail "$where : unbalanced quotes or brackets (multi-line values are not supported)"
        }

        $keyText = $parsed.Segments[0]
        $table = $tables[$currentTable]
        if ($table.Contains($keyText)) {
            $previous = $table[$keyText].Source
            $overrides.Add("[$([string]::Join('.', $tableInfo[$currentTable].Segments))] $keyText : $previous -> $($fragment.Name)")
        }
        $table[$keyText] = @{ Value = $value; Source = $fragment.Name }
    }
}

foreach ($override in $overrides) { Note "override  $override" }
foreach ($skip in $skipped) { Note "skipped   $skip" }

# --- emit -------------------------------------------------------------------
$out = New-Object System.Collections.Generic.List[string]
$out.Add('# Helix configuration - GENERATED FILE, do not edit.')
$out.Add('# Edit the fragments in keys/*.toml, then run:')
$out.Add('#     ./build-config.sh      (Linux/macOS)')
$out.Add('#     .\build-config.ps1     (Windows)')
$out.Add('# and reload with :config-reload inside Helix.')
$out.Add("# generated for platform: $Platform")
$out.Add('')

$orderedTables = $tableInfo.Keys | Sort-Object { $tableInfo[$_].Depth }, { $tableInfo[$_].Index }
foreach ($tableKey in $orderedTables) {
    $entries = $tables[$tableKey]
    if ($entries.Count -eq 0) { continue }
    $headerSegments = @($tableInfo[$tableKey].Segments)
    if ($headerSegments.Count -gt 0) {
        $out.Add('[' + (($headerSegments | ForEach-Object { Format-Key $_ }) -join '.') + ']')
    }
    foreach ($entryKey in $entries.Keys) {
        $out.Add("$((Format-Key $entryKey)) = $($entries[$entryKey].Value)")
    }
    $out.Add('')
}
# drop the trailing blank line: the file ends with a single newline after the
# last key, so the output is byte-identical to build-config.sh
if ($out.Count -gt 0 -and $out[$out.Count - 1] -eq '') { $out.RemoveAt($out.Count - 1) }

$text = ($out -join "`n") + "`n"

if ($Print) {
    # PowerShell appends a newline to pipeline output; drop one so `-Print`
    # matches ./build-config.sh --print byte for byte.
    Write-Output ($text -replace "`n$", '')
    exit 0
}
if ($Check) {
    Note "ok: $($fragments.Count) fragments, $($tables.Count) tables, $(($tables.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum) keys - nothing written"
    exit 0
}

if ((Test-Path -LiteralPath $outFile) -and ([System.IO.File]::ReadAllText($outFile) -eq $text)) {
    Note "unchanged: $outFile"
    exit 0
}
if (-not (Test-Path -LiteralPath $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($outFile, $text, (New-Object System.Text.UTF8Encoding($false)))
Note "wrote $outFile ($($fragments.Count) fragments, $(($tables.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum) keys)"
