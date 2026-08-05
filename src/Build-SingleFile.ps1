#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the module into ONE standalone script for handover.

.DESCRIPTION
    The precheck is developed as a module (Private/ Checks/ Public/) because that
    keeps 25 checks navigable. But it is RUN by the customer, unattended, on a large
    number of servers - and a multi-file module means copying a folder tree, keeping
    an entry script beside it, a .psd1/.psm1 to explain, and Mark-of-the-Web on every
    file. That has already caused mistakes.

    This produces `dist/VbrMigrationPrecheck-<version>.ps1`: a single file with no
    module import, no folder structure and no manifest. Copy one file to the server
    and run it. The version is in the filename because the customer keeps copies for
    months across a phased migration.

    Concatenation order does not matter for correctness - everything except one
    hashtable and the entry call is a function definition, and nothing is invoked
    until the end of the file. The order below is kept for readability only.

    The parameter block and the entry logic are taken from Run-Precheck.ps1 rather
    than duplicated here, split on its BUILD:MODULE-LOAD-BEGIN/END markers so the
    module-loading section is left out. If those markers are missing the build fails
    loudly instead of emitting something subtly wrong.

.EXAMPLE
    ./Build-SingleFile.ps1
    ./Build-SingleFile.ps1 -OutputPath ./dist/precheck.ps1
#>
[CmdletBinding()]
param(
    # Version in the filename on purpose: the customer keeps copies for months
    # across a phased migration, so which build produced a report has to be obvious
    # from the file itself.
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'
$root       = $PSScriptRoot
$moduleDir  = Join-Path $root 'VbrMigrationPrecheck'
$entryPath  = Join-Path $root 'Run-Precheck.ps1'
$versionRaw = if (Test-Path (Join-Path $root 'VERSION')) { (Get-Content (Join-Path $root 'VERSION') -Raw).Trim() } else { '0.0.0' }

if (-not $OutputPath) {
    $OutputPath = Join-Path $root 'dist' "VbrMigrationPrecheck-$versionRaw.ps1"
}

# --- split the entry script on its explicit build markers -------------------
# Reuse Run-Precheck.ps1's help, parameter block and entry logic, but EXCLUDE the
# module-loading section between the markers - the standalone build has no module,
# and the guard in there would fire on the very file it is meant to point people to.
# (That is exactly what happened when this split was inferred from the Import-Module
# line instead: a guard added above it silently leaked into the standalone.)
$entryLines = Get-Content $entryPath
$beginIdx = ($entryLines | Select-String -Pattern '^\s*#\s*BUILD:MODULE-LOAD-BEGIN' | Select-Object -First 1).LineNumber
$endIdx   = ($entryLines | Select-String -Pattern '^\s*#\s*BUILD:MODULE-LOAD-END'   | Select-Object -First 1).LineNumber
if (-not $beginIdx -or -not $endIdx) {
    throw "Could not find the BUILD:MODULE-LOAD-BEGIN/END markers in $entryPath. Build-SingleFile.ps1 uses them to decide what to reuse and what to leave out; restore them or update this build."
}
# LineNumbers are 1-based.
$entryHeader = $entryLines[0..($beginIdx - 2)]
$entryTail   = $entryLines[$endIdx..($entryLines.Count - 1)]

# --- collect the module parts ------------------------------------------------
$parts = foreach ($folder in 'Private', 'Checks', 'Public') {
    $dir = Join-Path $moduleDir $folder
    if (-not (Test-Path $dir)) { continue }
    Get-ChildItem -Path $dir -Filter '*.ps1' -File | Sort-Object Name
}
if (-not $parts) { throw "No module parts found under $moduleDir." }

$sb = [System.Text.StringBuilder]::new()
function Emit { param([string] $Text = '') $null = $sb.AppendLine($Text) }

# --- header: the entry script's #Requires, help and param block --------------
foreach ($line in $entryHeader) { Emit $line }

Emit ''
Emit '# ============================================================================='
Emit "#  GENERATED FILE - do not edit."
Emit "#  Built from the VbrMigrationPrecheck module by Build-SingleFile.ps1."
Emit "#  Version : $versionRaw"
Emit "#  Built   : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
Emit "#  Sources : $($parts.Count) files"
Emit '#'
Emit '#  Edit the module under VbrMigrationPrecheck/ and rebuild - changes made here'
Emit '#  are lost on the next build.'
Emit '# ============================================================================='
Emit ''
Emit '# Reports default to this script''s own folder (the module sets this to the repo'
Emit '# root instead). Keeps the output path independent of the folder layout.'
Emit '$script:PrecheckRoot = $PSScriptRoot'
Emit ''
Emit '# Stamped in at build time so reports state which build produced them.'
Emit "`$script:PrecheckVersion = '$versionRaw'"
Emit ''

# --- the module parts --------------------------------------------------------
foreach ($p in $parts) {
    $rel = $p.FullName.Substring($root.Length).TrimStart([char]'\', [char]'/')
    Emit '# -----------------------------------------------------------------------------'
    Emit "# $rel"
    Emit '# -----------------------------------------------------------------------------'
    foreach ($line in (Get-Content $p.FullName)) {
        # Per-file #Requires would be duplicated; the header already carries it.
        if ($line -match '^\s*#Requires\b') { continue }
        Emit $line
    }
    Emit ''
}

# --- entry logic (everything after Import-Module in Run-Precheck.ps1) --------
Emit '# -----------------------------------------------------------------------------'
Emit '# Entry logic (from Run-Precheck.ps1)'
Emit '# -----------------------------------------------------------------------------'
foreach ($line in $entryTail) { Emit $line }

# --- write + verify ----------------------------------------------------------
$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
Set-Content -Path $OutputPath -Value $sb.ToString() -Encoding UTF8

$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($OutputPath, [ref]$null, [ref]$errors) | Out-Null
if ($errors) {
    Write-Host "PARSE ERRORS in the generated file:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
    throw "Build produced a file that does not parse."
}

# Count what landed, so a silently truncated build is obvious.
$text      = Get-Content $OutputPath -Raw
$funcCount = ([regex]::Matches($text, '(?m)^function\s+\S+')).Count
$checkIds  = ([regex]::Matches($text, "\`$id\s*=\s*'[A-Z]{2,3}-\d{3}'")).Count
$lineCount = (Get-Content $OutputPath).Count

# Catch the class of bug where the standalone silently loses something the entry
# logic needs: any variable the emitted script READS at top level must also be
# ASSIGNED in it. This is how a $root that lived inside the excluded module-load
# block got shipped as $null.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($OutputPath, [ref]$null, [ref]$null)
$assigned = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
    ForEach-Object { $_.Left } |
    Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] } |
    ForEach-Object { $_.VariablePath.UserPath })
# Only top-level entry-logic variables matter here, so check the handful the tail uses.
$missing = @()
foreach ($v in 'root', 'cfg', 'params') {
    # Substring, not -match: in a regex a leading '$' is an end-of-string anchor,
    # so the pattern silently never matched and this guard did nothing at all.
    if ($text.Contains('$' + $v) -and $assigned -notcontains $v) { $missing += $v }
}
if ($missing) {
    throw "The generated file reads `$$($missing -join ', $') but never assigns it - something the entry logic needs was left inside the excluded module-load block."
}

Write-Host ''
Write-Host "Built: $OutputPath" -ForegroundColor Green
Write-Host ("  version   : {0}" -f $versionRaw)
Write-Host ("  lines     : {0}" -f $lineCount)
Write-Host ("  size      : {0:N0} KB" -f ((Get-Item $OutputPath).Length / 1KB))
Write-Host ("  functions : {0}" -f $funcCount)
Write-Host ("  check IDs : {0}" -f $checkIds)
Write-Host ("  parses    : yes")
Write-Host ''
Write-Host "Hand over this one file. No module import, no folder structure." -ForegroundColor Cyan
