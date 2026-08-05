#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the Windows VBR -> Veeam Software Appliance migration precheck (KB4800).

.DESCRIPTION
    Convenience entry point: imports the VbrMigrationPrecheck module, merges
    config/config.json (if present) with any CLI parameters, connects to the VBR
    server, runs all KB4800 checks, prints a console summary, and writes JSON +
    HTML reports to the output directory. Exits with a code reflecting the verdict
    (0 ready/warnings, 1 action required, 2 migration blocked) for automation.

.PARAMETER Server
    The WINDOWS VBR v13.0.x server to evaluate. Default 'localhost'. Run on the
    server itself when possible. Do NOT target a v13 VSA appliance.

.PARAMETER UpgradeDate
    Upgrade cutoff for DB-001: sessions from before this date are flagged. Use the
    v12 upgrade date for the strict KB4800 boundary, or the v13 upgrade date for a
    broader/conservative check. (Aliases: -V12UpgradeDate, -V13UpgradeDate.)

.EXAMPLE
    ./Run-Precheck.ps1
    Runs against the local VBR server using config.json (or defaults).

.EXAMPLE
    ./Run-Precheck.ps1 -Server vbr01.corp.local -UpgradeDate 2024-06-01
#>
[CmdletBinding()]
param(
    [string] $Server,
    [PSCredential] $Credential,
    [Alias('V12UpgradeDate', 'V13UpgradeDate')]
    [Nullable[datetime]] $UpgradeDate,
    [string] $OutputPath,
    [ValidateSet('None', 'Json', 'Html', 'All')] [string] $ReportFormat,
    [switch] $VerboseLog
)

$ErrorActionPreference = 'Stop'

# Used by the config-file lookup below, so it must stay OUTSIDE the markers - the
# standalone build needs it too.
$root = Split-Path -Parent $PSCommandPath

# BUILD:MODULE-LOAD-BEGIN
# Everything between these markers is specific to the development layout and is
# EXCLUDED from the standalone build, which has no module to load. Build-SingleFile.ps1
# splits on these markers, so do not remove them.
#
# Anything the code AFTER the markers depends on must be defined BEFORE them, or it
# will be missing from the standalone build.

# Say plainly that the module folder is missing rather than emitting a
# module-not-found error - copying this file on its own is the obvious mistake.
$manifest = Join-Path $root 'VbrMigrationPrecheck' 'VbrMigrationPrecheck.psd1'
if (-not (Test-Path $manifest)) {
    throw @"
Run-Precheck.ps1 requires the VbrMigrationPrecheck folder alongside it, and it was not found in:
  $root

If you copied a single file to this machine, use the standalone build instead - it needs nothing
beside it. Build it with ./Build-SingleFile.ps1, which writes dist\VbrMigrationPrecheck-<version>.ps1.
"@
}

# Load the module fresh so edits are picked up between runs.
Import-Module $manifest -Force
# BUILD:MODULE-LOAD-END

# Merge config file (CLI wins).
$cfg = @{}
$cfgPath = Join-Path $root 'config' 'config.json'
if (Test-Path $cfgPath) {
    $json = Get-Content $cfgPath -Raw | ConvertFrom-Json
    foreach ($p in $json.PSObject.Properties) {
        if ($p.Name -notlike '//*' -and $null -ne $p.Value -and $p.Value -ne '') {
            $cfg[$p.Name] = $p.Value
        }
    }
}

$params = @{}
if ($Server)                    { $params.Server = $Server }         elseif ($cfg.Server)         { $params.Server = $cfg.Server }
if ($Credential)                { $params.Credential = $Credential }
if ($UpgradeDate)               { $params.UpgradeDate = $UpgradeDate }
elseif ($cfg.UpgradeDate)       { $params.UpgradeDate = [datetime]$cfg.UpgradeDate }
elseif ($cfg.V12UpgradeDate)    { $params.UpgradeDate = [datetime]$cfg.V12UpgradeDate }
if ($OutputPath)                { $params.OutputPath = $OutputPath }  elseif ($cfg.OutputPath)     { $params.OutputPath = $cfg.OutputPath }
if ($ReportFormat)              { $params.ReportFormat = $ReportFormat } elseif ($cfg.ReportFormat) { $params.ReportFormat = $cfg.ReportFormat }
if ($VerboseLog)                { $params.VerboseLog = $true }

Invoke-VbrMigrationPrecheck @params

exit ([int]$global:LASTPRECHECKEXITCODE)
