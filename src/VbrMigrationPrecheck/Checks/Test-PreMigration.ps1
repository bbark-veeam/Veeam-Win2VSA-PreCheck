# Pre-Migration Considerations (KB4800 "Pre-Migration Considerations" section).
# These are preparatory ACTIONS to take before starting the migration rather
# than pass/fail blockers, so they emit the advisory 'NextStep' status and are
# collected into the report's "Pre-Migration Next Steps" section. Each one that
# is tied to a specific feature stays silent (Skipped) when that feature is not
# present - i.e. the next step only appears when the related consideration
# actually applies to this environment.
#
# Considerations already enforced by other checks (not repeated here):
#   CDP config (JOB-001), disabled agent policies (AGT-002), agents v13 (AGT-001),
#   local repo accounts (SEC-004).

function Test-PreEntraIdSecondaryTarget {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    # Consideration #1: for Entra ID tenant backups, configure a secondary
    # destination repository BEFORE migration so backup continuity is preserved
    # (primary Entra ID data stays on the source PostgreSQL). Complements DEP-003.
    $id = 'PRE-001'; $cat = 'Preparation'; $title = 'Entra ID secondary target'

    if (-not (Test-PrecheckCmdlet 'Get-VBREntraIDTenant')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Skipped `
            -Detail 'Entra ID tenant backups could not be read on this server.'
    }
    $tenants = @(Get-PrecheckCached -Key 'EntraIDTenants' -Getter { Get-VBREntraIDTenant -ErrorAction SilentlyContinue })
    if ($tenants.Count -eq 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Skipped `
            -Detail 'No Entra ID tenant backups present; secondary-target step not applicable.'
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status NextStep `
        -Detail "$($tenants.Count) Entra ID tenant backup(s) present. Primary Entra ID data is NOT migrated (stays on the source PostgreSQL)." `
        -Recommendation 'Before migrating, configure a secondary destination repository for each Entra ID tenant backup (New-/Set-VBREntraIDBackupSecondaryTarget) to preserve backup continuity.' `
        -Evidence ($tenants | ForEach-Object { "Entra ID tenant: $($_.Name)" })
}

function Test-PreMachineAccessibility {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    # Consideration #2: verify every machine managed by the Windows deployment is
    # reachable from the VSA (network, firewalls, DNS). This cannot be tested from
    # the Windows source (the VSA does not exist yet), so it is always a NextStep;
    # we enumerate the managed infrastructure to make it concrete.
    $id = 'PRE-002'; $cat = 'Preparation'; $title = 'Machine reachability from the appliance'

    $servers = @()
    if (Test-PrecheckCmdlet 'Get-VBRServer') {
        try { $servers = @(Get-VBRServer -ErrorAction SilentlyContinue) } catch { }
    }
    $ev = @()
    if ($servers.Count -gt 0) {
        $ev = $servers | ForEach-Object {
            $t = if ($_.PSObject.Properties['Type']) { " [$($_.Type)]" } else { '' }
            "Managed server: $($_.Name)$t"
        }
    }
    $detail = if ($servers.Count -gt 0) {
        "$($servers.Count) managed server(s)/host(s) are registered. Each must be reachable from the VSA after migration."
    } else {
        'Confirm every machine managed by this deployment will be reachable from the VSA.'
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status NextStep `
        -Detail $detail `
        -Recommendation 'Before migrating, verify network connectivity, firewall rules, and DNS resolution from the Veeam Software Appliance to every managed machine (hosts, proxies, repositories, agents).' `
        -Evidence $ev
}

function Test-PreFileToTapeHostname {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    # Consideration #3: if the backup server is a source for file-to-tape jobs,
    # the original server's SHORT hostname must be used when selecting the Source
    # server during migration, and it must be resolvable.
    $id = 'PRE-003'; $cat = 'Preparation'; $title = 'File-to-tape source hostname'

    if (-not (Test-PrecheckCmdlet 'Get-VBRTapeJob')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Skipped `
            -Detail 'File-to-tape jobs could not be read on this server.'
    }

    $fileToTape = @()
    try {
        $fileToTape = @(Get-VBRTapeJob -ErrorAction SilentlyContinue |
            Where-Object { "$($_.Type) $($_.TypeToString)" -match 'File' } |
            ForEach-Object { $_.Name })
    } catch { }

    if ($fileToTape.Count -eq 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Skipped `
            -Detail 'No file-to-tape jobs detected; source-hostname step not applicable.'
    }

    $short = $env:COMPUTERNAME
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status NextStep `
        -Detail "$($fileToTape.Count) file-to-tape job(s) detected. If this backup server is their source, the original server's SHORT hostname must be used when selecting the Source server during migration." `
        -Recommendation "During migration, select the source using the short hostname (this server: '$short') and make sure that short hostname is resolvable from the VSA." `
        -Evidence $fileToTape
}

function Test-PreStorageTimezone {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    # Consideration #8: for Hitachi and HPE XP systems, the timezone set on the
    # VSA must match the timezone of the Windows machine. Those integrate via the
    # Universal Storage Plugin (Get-StoragePluginHost).
    $id = 'PRE-004'; $cat = 'Preparation'; $title = 'Appliance timezone (Hitachi / HPE XP)'

    if (-not (Test-PrecheckCmdlet 'Get-StoragePluginHost')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Skipped `
            -Detail 'Hitachi / HPE XP integration could not be checked on this server.'
    }
    $hosts = @(Get-PrecheckCached -Key 'StoragePluginHosts' -Getter { Get-StoragePluginHost -ErrorAction SilentlyContinue })
    if ($hosts.Count -eq 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Skipped `
            -Detail 'No Universal Storage Plugin (Hitachi/HPE XP) systems detected; timezone-alignment step not applicable.'
    }

    $tz = try { (Get-TimeZone).Id } catch { 'unknown' }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status NextStep `
        -Detail "$($hosts.Count) Universal Storage Plugin system(s) present (may include Hitachi / HPE XP). This Windows machine's timezone is '$tz'." `
        -Recommendation "Before/at migration, set the Veeam Software Appliance timezone to match this Windows machine's timezone ('$tz') so Hitachi / HPE XP snapshot scheduling stays aligned." `
        -Evidence ($hosts | ForEach-Object { "Storage plugin host: $($_.Name)" })
}
