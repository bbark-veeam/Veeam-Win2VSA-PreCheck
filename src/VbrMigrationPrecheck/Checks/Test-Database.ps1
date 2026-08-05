# Database checks. KB4800: job-history sessions predating the upgrade to v12 cause
# migration to fail - the limiting factor is session data written by v11 and earlier.
# The remedy is to reduce session-history retention so those sessions age out.
#
# Reads the retention SETTING (Get-VBRHistoryOptions: KeepAllSessions,
# RetentionLimitWeeks) rather than enumerating sessions - Get-VBRBackupSession has
# no date filter or ordering, so checking the rows means loading all of them.

function Test-SessionHistoryAge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Ctx,
        # THE DATE IS WHEN THIS ENVIRONMENT WAS UPGRADED TO v12. That is the boundary
        # that matters, because what breaks migration is session data written by v11 and
        # earlier. Supplying a later date (e.g. the v13 upgrade) errs safe but over-flags:
        # it also counts legitimate v12-era sessions, so it can prescribe a retention
        # reduction that is not actually needed.
        [Alias('V12UpgradeDate', 'V13UpgradeDate')]
        [Nullable[datetime]] $UpgradeDate
    )

    $id = 'DB-001'; $cat = 'Job history'
    $title = 'Session-history retention'

    if (-not (Test-PrecheckCmdlet 'Get-VBRHistoryOptions')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail 'Session-history retention could not be read on this server.' `
            -Recommendation 'Job-history sessions predating the upgrade to v12 cause migration to fail - the problem is session data from v11 and earlier. Check Options > History and reduce session-history retention so those sessions age out before migrating.'
    }

    $opts = $null
    try { $opts = Get-VBRHistoryOptions -ErrorAction Stop } catch { }
    if (-not $opts) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail 'Session-history options could not be retrieved.' `
            -Recommendation 'Check Options > History manually and reduce session-history retention so pre-upgrade sessions age out.'
    }

    $keepAll = if ($opts.PSObject.Properties['KeepAllSessions']) { [bool]$opts.KeepAllSessions } else { $null }
    $weeks   = if ($opts.PSObject.Properties['RetentionLimitWeeks']) { $opts.RetentionLimitWeeks } else { $null }
    $ev      = @("KeepAllSessions=$keepAll", "RetentionLimitWeeks=$weeks")

    # Keeping everything means nothing ever ages out.
    if ($keepAll) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Action `
            -Detail 'Session history is set to keep ALL sessions, so job sessions predating the upgrade to v12 are still in the database. KB4800 lists those sessions - written by v11 and earlier - as a cause of migration failure.' `
            -Recommendation 'Set a session-history retention limit (Options > History, or Set-VBRHistoryOptions -RetentionLimitWeeks <n>) short enough that pre-upgrade sessions age out, allow them to be pruned, then re-run this check before migrating.' `
            -Evidence $ev
    }

    if ($null -eq $weeks) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail 'Session history is not set to keep all sessions, but no retention period could be read.' `
            -Recommendation 'Confirm the session-history retention period in Options > History and ensure it is shorter than the time since this environment was upgraded to v12.' `
            -Evidence $ev
    }

    # No cutoff supplied: report the retention window so the operator can compare it
    # to their own upgrade date. Still actionable, and still no table scan.
    if (-not $UpgradeDate) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "Session history is kept for $weeks week(s). Sessions predating the upgrade to v12 cause migration to fail - the problem is session data from v11 and earlier - and this check cannot tell whether $weeks week(s) reaches back past that upgrade without knowing its date." `
            -Recommendation "Compare $weeks week(s) against the date this environment was upgraded to v12. If the window reaches back before that, reduce it so the older sessions age out. Re-run with -UpgradeDate <date of the v12 upgrade> to have this decided automatically." `
            -Evidence $ev
    }

    # Use $UpgradeDate directly, not .Value: the binder unwraps [Nullable[datetime]]
    # to DateTime, so .Value returns $null.
    $cutoff        = [datetime] $UpgradeDate
    $weeksSince    = [math]::Floor(((Get-Date) - $cutoff).TotalDays / 7)
    $cutoffStr     = $cutoff.ToString('yyyy-MM-dd')
    $ev           += @("Upgrade cutoff=$cutoffStr", "Weeks since cutoff=$weeksSince")

    # The supplied date has to be plausible before anything is concluded from it.
    # PowerShell binds '-UpgradeDate 0' to DateTime.MinValue without complaint, which
    # computed 105690 weeks since "the upgrade on 0001-01-01" and returned a confident
    # Pass - a mistyped parameter clearing the very check meant to catch this blocker.
    # A future date cannot describe an upgrade that has already happened. The floor is
    # v12's own existence: the date being asked for is when this environment moved TO v12,
    # so anything earlier is not that date - most likely the v11 upgrade date, or a
    # mistyped year. That catches a realistic mistake, not just DateTime.MinValue.
    $earliestPlausible = [datetime] '2023-01-01'
    if ($cutoff -lt $earliestPlausible -or $cutoff -gt (Get-Date)) {
        $why = if ($cutoff -gt (Get-Date)) {
            'is in the future'
        } else {
            'predates Veeam Backup & Replication v12, so it cannot be the date this environment was upgraded to v12'
        }
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "The upgrade date supplied ($cutoffStr) $why. Session-history retention was therefore not judged against it. Session history is kept for $weeks week(s)." `
            -Recommendation "Re-run supplying the date this environment was upgraded to v12, as -UpgradeDate yyyy-MM-dd (for example -UpgradeDate 2024-03-15). What breaks migration is session data written by v11 and earlier, so that is the boundary to compare the $weeks week(s) of retention against." `
            -Evidence $ev
    }

    if ($weeks -lt $weeksSince) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail "Session history is kept for $weeks week(s), which is shorter than the $weeksSince week(s) since the upgrade on $cutoffStr - so any sessions predating the upgrade have already aged out of the database." `
            -Evidence $ev
    }

    # Cutoff less than a week old: retention is set in whole weeks, so there is no
    # value that would age out sessions predating it. Advising a reduction here would
    # produce an impossible instruction ("fewer than 0 weeks").
    if ($weeksSince -lt 1) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "The upgrade cutoff supplied ($cutoffStr) is less than a week ago, and session history is kept in whole weeks ($weeks), so retention cannot be used to age out sessions from before it." `
            -Recommendation 'Check the cutoff date is the one you meant - KB4800 concerns long-standing history, normally the date the environment first moved to v12. If it is correct, sessions predating it will remain until retention rolls past that point.' `
            -Evidence $ev
    }

    $target = [math]::Max(1, $weeksSince - 1)
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Action `
        -Detail "Session history is kept for $weeks week(s), which reaches back to or past the v12 upgrade on $cutoffStr ($weeksSince week(s) ago) - so job sessions predating that upgrade may still be in the database. KB4800 lists those sessions - written by v11 and earlier - as a cause of migration failure." `
        -Recommendation "Reduce session-history retention to fewer than $weeksSince week(s) (e.g. Set-VBRHistoryOptions -RetentionLimitWeeks $target), allow the old sessions to be pruned, then re-run this check before migrating." `
        -Evidence $ev
}
