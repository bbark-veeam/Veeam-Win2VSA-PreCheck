# VbrMigrationPrecheck.psm1
# Root module loader. Dot-sources every .ps1 under Private/, Checks/, and
# Public/, then exports only the Public function names. Adding a new check is
# just dropping a Test-*.ps1 into Checks/ and registering it in the orchestrator
# ($script:PrecheckRegistry inside Invoke-VbrMigrationPrecheck.ps1).

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# Order matters: Private helpers (New-PrecheckResult, guards) must load before
# the Checks that call them, and Checks before the Public orchestrator.
foreach ($folder in 'Private', 'Checks', 'Public') {
    $dir = Join-Path $here $folder
    if (-not (Test-Path $dir)) { continue }
    Get-ChildItem -Path $dir -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object {
        . $_.FullName
    }
}

# Tool version, stamped into every report. A phased migration runs for months and
# customers keep stale copies, so a report has to say which build produced it.
# The single-file build emits this as a literal instead.
try {
    $script:PrecheckVersion = (Import-PowerShellDataFile (Join-Path $here 'VbrMigrationPrecheck.psd1')).ModuleVersion
} catch { $script:PrecheckVersion = 'unknown' }

# Where reports default to. The single-file build sets this to its own folder;
# here it is the repo root, one level above the module folder.
$script:PrecheckRoot = Split-Path -Parent $here

# Export only the operator-facing verbs; everything in Private/Checks stays
# module-internal.
$public = @(
    'Connect-VbrPrecheck',
    'Invoke-VbrMigrationPrecheck',
    'Export-PrecheckReport'
)
Export-ModuleMember -Function $public
