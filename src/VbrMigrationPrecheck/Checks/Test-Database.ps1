# Database checks. KB4800: job-history sessions predating the environment upgrade
# cause migration to fail; the remedy is to reduce session-history retention.
#
# Reads the retention SETTING (Get-VBRHistoryOptions: KeepAllSessions,
# RetentionLimitWeeks) rather than enumerating sessions - Get-VBRBackupSession has
# no date filter or ordering, so checking the rows means loading all of them.

function Test-SessionHistoryAge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Ctx,
        # v12 upgrade date is the strict KB boundary; the v13 date is a broader,
        # safe-erring cutoff. Same remedy either way.
        [Alias('V12UpgradeDate', 'V13UpgradeDate')]
        [Nullable[datetime]] $UpgradeDate
    )

    $id = 'DB-001'; $cat = 'Job history'
    $title = 'Session-history retention'

    if (-not (Test-PrecheckCmdlet 'Get-VBRHistoryOptions')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail 'Session-history retention could not be read on this server.' `
            -Recommendation 'Job-history sessions predating the environment upgrade cause migration to fail. Check Options > History and reduce session-history retention so those sessions age out before migrating.'
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
            -Detail 'Session history is set to keep ALL sessions, so job sessions predating the environment upgrade are still in the database. KB4800 lists those sessions as a cause of migration failure.' `
            -Recommendation 'Set a session-history retention limit (Options > History, or Set-VBRHistoryOptions -RetentionLimitWeeks <n>) short enough that pre-upgrade sessions age out, allow them to be pruned, then re-run this check before migrating.' `
            -Evidence $ev
    }

    if ($null -eq $weeks) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail 'Session history is not set to keep all sessions, but no retention period could be read.' `
            -Recommendation 'Confirm the session-history retention period in Options > History and ensure it is shorter than the time since the environment was upgraded.' `
            -Evidence $ev
    }

    # No cutoff supplied: report the retention window so the operator can compare it
    # to their own upgrade date. Still actionable, and still no table scan.
    if (-not $UpgradeDate) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "Session history is kept for $weeks week(s). Sessions predating the environment upgrade cause migration to fail, and this check cannot tell whether $weeks week(s) reaches back past that upgrade without knowing its date." `
            -Recommendation "Compare $weeks week(s) against the date this environment was upgraded. If the window reaches back before the upgrade, reduce it so those sessions age out. Re-run with -UpgradeDate <date> to have this decided automatically." `
            -Evidence $ev
    }

    # Use $UpgradeDate directly, not .Value: the binder unwraps [Nullable[datetime]]
    # to DateTime, so .Value returns $null.
    $cutoff        = [datetime] $UpgradeDate
    $weeksSince    = [math]::Floor(((Get-Date) - $cutoff).TotalDays / 7)
    $cutoffStr     = $cutoff.ToString('yyyy-MM-dd')
    $ev           += @("Upgrade cutoff=$cutoffStr", "Weeks since cutoff=$weeksSince")

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
        -Detail "Session history is kept for $weeks week(s), which reaches back to or past the upgrade on $cutoffStr ($weeksSince week(s) ago) - so job sessions predating the upgrade may still be in the database. KB4800 lists those sessions as a cause of migration failure." `
        -Recommendation "Reduce session-history retention to fewer than $weeksSince week(s) (e.g. Set-VBRHistoryOptions -RetentionLimitWeeks $target), allow the old sessions to be pruned, then re-run this check before migrating." `
        -Evidence $ev
}
