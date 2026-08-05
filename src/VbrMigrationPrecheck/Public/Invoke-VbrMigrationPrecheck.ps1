# Invoke-VbrMigrationPrecheck
# Orchestrator. Connects to the Windows VBR server (unless already connected via
# Connect-VbrPrecheck and passed a context), runs every KB4800 check, renders a
# console summary, optionally writes a JSON/HTML report, and returns the result
# objects. The overall verdict + a process exit code make it CI/automation-friendly.
#
# Verdict / exit-code mapping:
#   MIGRATION BLOCKED   (exit 2)  - at least one Blocker.
#   ACTION REQUIRED     (exit 1)  - no Blocker, but at least one Action.
#   REVIEW WARNINGS     (exit 0)  - only Warning/Manual/Info items.
#   READY               (exit 0)  - all Pass/Skipped.

function Invoke-VbrMigrationPrecheck {
    [CmdletBinding()]
    param(
        [string] $Server = 'localhost',
        [PSCredential] $Credential,

        # Upgrade cutoff date for DB-001: sessions from before this date are
        # flagged. Use the v12 upgrade date for the strict KB4800 boundary, or the
        # v13 upgrade date for a broader/conservative check. Optional.
        [Alias('V12UpgradeDate', 'V13UpgradeDate')]
        [Nullable[datetime]] $UpgradeDate,

        # Where JSON/HTML/log artefacts are written. Defaults to ../../output
        # relative to the module (repo output/ dir), created if missing.
        [string] $OutputPath,

        [ValidateSet('None', 'Json', 'Html', 'All')]
        [string] $ReportFormat = 'All',

        # Reuse an existing context from Connect-VbrPrecheck instead of connecting.
        $Context,

        # Emit the raw result objects to the pipeline (in addition to console).
        [switch] $PassThru,

        [switch] $VerboseLog
    )

    $script:PrecheckVerbose = [bool]$VerboseLog

    Clear-PrecheckCache

    # --- Output location + log file ------------------------------------------
    # Output location must not depend on the folder layout: this code ships both as
    # a module (Public/ two levels below the repo root) and as a single
    # concatenated script (no folders at all). Whoever loads it sets
    # $script:PrecheckRoot; fall back to the working directory.
    if (-not $OutputPath) {
        $base = if ($script:PrecheckRoot) { $script:PrecheckRoot } else { (Get-Location).Path }
        $OutputPath = Join-Path $base 'output'
    }
    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $script:PrecheckLogFile = Join-Path $OutputPath "precheck-$stamp.log"

    Write-PrecheckLog "=== VBR -> VSA Migration Precheck (KB4800) ===" -Level STEP
    Write-PrecheckLog "Output directory: $OutputPath" -Level INFO

    # --- Connect (or reuse) ---------------------------------------------------
    $ctx = $Context
    $weConnected = $false
    if (-not $ctx) {
        $ctx = Connect-VbrPrecheck -Server $Server -Credential $Credential
        $weConnected = $true
    }

    # --- Run checks -----------------------------------------------------------
    # Explicit registry keeps ordering and coverage auditable. Each entry is the
    # check function name; DB-001 takes the extra -V12UpgradeDate argument.
    $checks = @(
        'Test-VbrVersion'
        'Test-VbrLicense'
        'Test-CloudConnect'
        'Test-GoogleCloudPlugin'
        'Test-EntraIdBackups'
        'Test-AgentVersions'
        'Test-AgentDisabledPolicies'
        'Test-MacAgentDomainAuth'
        'Test-ProtectionGroupPostMigration'
        'Test-NetAppOntapRole'
        'Test-StoragePluginVersions'
        'Test-NimbleFips'
        'Test-CdpJobs'
        'Test-SureBackupSqlChecker'
        'Test-JobScriptsAndFiles'
        'Test-FourEyes'
        'Test-CredentialUpnFormat'
        'Test-RoleAssignmentUpnFormat'
        'Test-TrustedDomainAuth'
        'Test-RepositoryLocalAccounts'
        'Test-SessionHistoryAge'
        # KB4800 "Pre-Migration Considerations" not covered by the checks above.
        'Test-PreEntraIdSecondaryTarget'
        'Test-PreMachineAccessibility'
        'Test-PreFileToTapeHostname'
        'Test-PreStorageTimezone'
    )

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($name in $checks) {
        Write-PrecheckLog "Running $name..." -Level DEBUG
        $out = Invoke-PrecheckSafe -Title $name -Body {
            if ($name -eq 'Test-SessionHistoryAge') {
                & $name -Ctx $ctx -UpgradeDate $UpgradeDate
            } else {
                & $name -Ctx $ctx
            }
        }
        foreach ($r in @($out)) { if ($r) { $results.Add($r) } }
    }

    # Only close a session this run opened. If we reused one - the Veeam PowerShell
    # Toolkit opens a session on launch - disconnecting would drop the operator's own.
    if ($weConnected -and $ctx.OpenedSession) { Disconnect-VbrPrecheck }

    # Hand downstream consumers a plain array, not the List. PowerShell 7.6.4
    # throws "Argument types do not match" on @(<List[object]>) — the array
    # subexpression operator itself fails, so any @($Results) in the verdict /
    # summary / report code would break. .ToArray() sidesteps it and costs
    # nothing.
    $results = $results.ToArray()

    # --- Verdict --------------------------------------------------------------
    $verdict = Get-PrecheckVerdict -Results $results

    # --- Console summary ------------------------------------------------------
    Write-PrecheckSummary -Results $results -Verdict $verdict -Context $ctx

    # --- Reports --------------------------------------------------------------
    if ($ReportFormat -ne 'None') {
        $formats = if ($ReportFormat -eq 'All') { @('Json', 'Html') } else { @($ReportFormat) }
        foreach ($f in $formats) {
            $path = Join-Path $OutputPath "precheck-$stamp.$($f.ToLower())"
            Export-PrecheckReport -Results $results -Verdict $verdict -Context $ctx -Format $f -Path $path
            Write-PrecheckLog "$f report: $path" -Level INFO
        }
    }

    # Make the exit code available without forcing it on interactive callers.
    $global:LASTPRECHECKEXITCODE = $verdict.ExitCode

    if ($PassThru) {
        return [PSCustomObject]@{
            Verdict = $verdict
            Results = $results
            Context = $ctx
        }
    }
}

# Get-PrecheckVerdict - reduce the result set to an overall status + exit code.
function Get-PrecheckVerdict {
    [CmdletBinding()] param([Parameter(Mandatory)] $Results)

    $counts = @{}
    foreach ($s in 'Blocker', 'Action', 'Warning', 'Manual', 'NextStep', 'Info', 'Pass', 'Skipped') {
        $counts[$s] = @($Results | Where-Object { $_.Status -eq $s }).Count
    }

    # NextStep is advisory (pre-migration prep) and never downgrades the verdict.
    if ($counts.Blocker -gt 0) {
        $label = 'MIGRATION BLOCKED'; $code = 2
    } elseif ($counts.Action -gt 0) {
        $label = 'ACTION REQUIRED'; $code = 1
    } elseif (($counts.Warning + $counts.Manual + $counts.Info) -gt 0) {
        $label = 'REVIEW WARNINGS'; $code = 0
    } else {
        $label = 'READY'; $code = 0
    }

    [PSCustomObject]@{
        Label    = $label
        ExitCode = $code
        Counts   = $counts
        Total    = @($Results).Count
    }
}

# Write-PrecheckSummary - human-readable console output.
function Write-PrecheckSummary {
    [CmdletBinding()] param(
        [Parameter(Mandatory)] $Results,
        [Parameter(Mandatory)] $Verdict,
        $Context
    )

    $statusColor = @{
        Blocker = 'Red'; Action = 'Magenta'; Warning = 'Yellow'
        Manual = 'Cyan'; NextStep = 'Blue'; Info = 'DarkYellow'; Pass = 'Green'; Skipped = 'DarkGray'
    }

    # Pre-migration next steps are shown in their own section below, not inline.
    $limitationResults = $Results | Where-Object { $_.Status -ne 'NextStep' }
    $nextSteps         = @($Results | Where-Object { $_.Status -eq 'NextStep' })

    Write-Host ''
    Write-Host ('=' * 72)
    Write-Host " Migration Precheck Results  (KB4800)"
    if ($Context) { Write-Host "  Server: $($Context.Server)   Build: $($Context.ProductString)" }
    Write-Host "  Precheck version: $(if ($script:PrecheckVersion) { $script:PrecheckVersion } else { 'unknown' })   Reference: KB4800 (captured $(if ($script:PrecheckKbCaptured) { $script:PrecheckKbCaptured } else { 'unknown' }))"
    Write-Host ('=' * 72)

    # Show most severe first.
    foreach ($r in ($limitationResults | Sort-Object -Property @{E = 'Rank'; Descending = $true}, Id)) {
        $c = $statusColor[$r.Status]
        Write-Host ("  [{0,-7}] " -f $r.Status.ToUpper()) -ForegroundColor $c -NoNewline
        Write-Host ("{0}  {1}" -f $r.Id, $r.Title)
        if ($r.Detail)         { Write-Host "            $($r.Detail)" -ForegroundColor DarkGray }
        if ($r.Recommendation) { Write-Host "            -> $($r.Recommendation)" -ForegroundColor DarkGray }
        foreach ($e in $r.Evidence) { Write-Host "               - $e" -ForegroundColor DarkGray }
    }

    Write-Host ('-' * 72)
    $c = $Verdict.Counts
    # Every status is listed, so the parts reconcile with the stated total.
    Write-Host ("  Totals: {0} checks | Blocker {1} | Action {2} | Warning {3} | Manual {4} | NextStep {5} | Info {6} | Pass {7} | Skipped {8}" -f `
        $Verdict.Total, $c.Blocker, $c.Action, $c.Warning, $c.Manual, $c.NextStep, $c.Info, $c.Pass, $c.Skipped)

    $vColor = switch ($Verdict.Label) {
        'MIGRATION BLOCKED' { 'Red' }
        'ACTION REQUIRED'   { 'Magenta' }
        'REVIEW WARNINGS'   { 'Yellow' }
        default             { 'Green' }
    }
    Write-Host ''
    Write-Host ("  VERDICT: {0}" -f $Verdict.Label) -ForegroundColor $vColor

    # Pre-migration next steps: the KB4800 preparation actions that apply to this
    # environment. Shown even when the limitation checks are clean - these are
    # what to do before starting the migration.
    if ($nextSteps.Count -gt 0) {
        Write-Host ''
        Write-Host ("  PRE-MIGRATION NEXT STEPS ({0}):" -f $nextSteps.Count) -ForegroundColor Blue
        foreach ($r in ($nextSteps | Sort-Object Id)) {
            Write-Host ("    - [{0}] {1}" -f $r.Id, $r.Title) -ForegroundColor Blue
            if ($r.Recommendation) { Write-Host "        -> $($r.Recommendation)" -ForegroundColor DarkGray }
            foreach ($e in $r.Evidence) { Write-Host "           - $e" -ForegroundColor DarkGray }
        }
    }
    Write-Host ('=' * 72)
    Write-Host ''
}
