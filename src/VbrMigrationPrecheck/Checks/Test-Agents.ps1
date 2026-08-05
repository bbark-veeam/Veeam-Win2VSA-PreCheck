# Veeam Agent checks.
# KB4800: "Agent Compatibility", "Agent-Related Blockers", "Veeam Agent for Mac Specific".

function Test-AgentVersions {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'AGT-001'; $cat = 'Agents'; $title = 'Managed agent versions'

    if (-not (Test-PrecheckCmdlet 'Get-VBRDiscoveredComputer')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'Managed agent details could not be read on this server, so agent versions were not checked.' `
            -Recommendation 'The VSA requires all Veeam Agents to be v13+. Upgrade every remote agent to v13 before migration; agents on OSes not compatible with v13 will be unable to connect.'
    }

    $computers = @(Get-VBRDiscoveredComputer -ErrorAction SilentlyContinue)
    if ($computers.Count -eq 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail 'No discovered/managed agent computers found.'
    }

    # Probe for a version-bearing property; names differ across builds.
    $old = @()
    $unknown = 0
    foreach ($c in $computers) {
        $ver = $null
        foreach ($p in 'AgentVersion', 'Version', 'InstalledAgentVersion') {
            if ($c.PSObject.Properties[$p] -and $c.$p) { $ver = [string]$c.$p; break }
        }
        if (-not $ver) { $unknown++; continue }
        $parsed = $null
        if (-not [version]::TryParse((($ver -split '\s')[0]), [ref]$parsed)) {
            # A version string that will not parse counts as unread, not as fine.
            # Skipping it silently let it contribute to a Pass.
            $unknown++
            continue
        }
        if ($parsed.Major -lt 13) {
            $name = if ($c.PSObject.Properties['Name']) { $c.Name } else { '<unknown>' }
            $old += "$name (agent $ver)"
        }
    }

    if ($old.Count -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Action `
            -Detail "$($old.Count) managed agent(s) are below v13. The VSA requires all agents to be v13+ to connect." `
            -Recommendation 'Upgrade these agents to v13 before migration. Any host on an OS not supported by the v13 agent will be unable to connect afterward.' `
            -Evidence $old
    }
    if ($unknown -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "Enumerated $($computers.Count) agent computer(s) but could not read a version property for $unknown of them." `
            -Recommendation 'Manually confirm every remote Veeam Agent is v13+ before migration.'
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
        -Detail "All $($computers.Count) managed agent(s) report v13 or higher."
}

function Test-AgentDisabledPolicies {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'AGT-002'; $cat = 'Agents'; $title = 'Disabled agent backup policies'

    if (-not (Test-PrecheckCmdlet 'Get-VBRComputerBackupJob')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'Agent backup policy details could not be read on this server.' `
            -Recommendation 'Any DISABLED Veeam Agent Backup Policy must have its configuration applied successfully (policies in Protection Groups synced) before migration, or migration will fail.'
    }

    # The property is JobEnabled. There is no IsEnabled on VBRComputerBackupJob -
    # an earlier version filtered on that name, matched nothing, and so returned
    # Pass on every server even with a disabled policy present.
    #
    # ScheduleEnabled is a DIFFERENT property and must not be used: a policy can be
    # JobEnabled=True with ScheduleEnabled=False, which is an enabled policy that
    # simply has no schedule.
    $policies = @()
    $disabled = @()
    $readable = $false
    try {
        $policies = @(Get-VBRComputerBackupJob -ErrorAction SilentlyContinue)
        foreach ($p in $policies) {
            if (-not $p.PSObject.Properties['JobEnabled']) { continue }
            $readable = $true
            if ($p.JobEnabled) { continue }
            $mode = if ($p.PSObject.Properties['Mode']) { "$($p.Mode)" } else { 'unknown mode' }
            $target = if ($p.PSObject.Properties['BackupObject']) { "$($p.BackupObject)" } else { '' }
            $disabled += "$($p.Name)  [$mode$(if ($target) { ", target: $target" })]"
        }
    } catch { }

    if ($policies.Count -gt 0 -and -not $readable) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail "$($policies.Count) Agent Backup Policy/policies were returned but their enabled state could not be read, so none was evaluated." `
            -Recommendation 'Check each Agent Backup Policy by hand: any disabled policy must have its configuration applied successfully before migration, or migration will fail.'
    }
    if ($disabled.Count -gt 0) {
        # Whether the configuration was ever applied is NOT exposed on this object -
        # there is no apply/sync/state property - so the check reports the disabled
        # policies and leaves that confirmation to the operator rather than implying
        # it was verified.
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Action `
            -Detail "$($disabled.Count) of $($policies.Count) Agent Backup Policy/policies are disabled. A disabled policy must have had its configuration applied successfully, or migration will fail. Whether that already happened is not something this check can read." `
            -Recommendation 'For each policy below, apply/sync its configuration successfully before migrating - or delete the policy if it is no longer wanted.' `
            -Evidence $disabled
    }
    $detail = if ($policies.Count -gt 0) {
        "No disabled Agent Backup Policies. All $($policies.Count) policy/policies were evaluated and are enabled."
    } else {
        'No Agent Backup Policies exist on this server.'
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass -Detail $detail
}

function Test-MacAgentDomainAuth {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'AGT-003'; $cat = 'Agents'; $title = 'Veeam Agent for Mac authentication'

    # Mac agents cannot use Kerberos and the VSA does not support NTLM, so Mac
    # agent jobs using domain accounts must be reconfigured to a local account.
    # Best-effort: identify Mac agent jobs; deep credential inspection is
    # unreliable across builds, so degrade to Manual with the specific hosts.
    if (-not (Test-PrecheckCmdlet 'Get-VBRComputerBackupJob')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'Agent job details could not be read on this server, so Mac agent authentication was not checked.' `
            -Recommendation 'Any Veeam Agent for Mac job connecting with a DOMAIN account must be reconfigured to use a LOCAL user account (Mac agent = no Kerberos; VSA = no NTLM).'
    }

    $macJobs = @()
    try {
        $macJobs = @(Get-VBRComputerBackupJob -ErrorAction SilentlyContinue |
            Where-Object { "$($_.OSPlatform) $($_.Type) $($_.TypeToString)" -match 'Mac|OSX|macOS' } |
            ForEach-Object { $_.Name })
    } catch { }

    if ($macJobs.Count -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "$($macJobs.Count) possible Veeam Agent for Mac job(s) found." `
            -Recommendation 'Confirm none connect using a domain account. Any that do must be reconfigured to a local user account before migration.' `
            -Evidence $macJobs
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
        -Detail 'No Veeam Agent for Mac jobs detected.'
}

function Test-ProtectionGroupPostMigration {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'AGT-004'; $cat = 'Agents'; $title = 'Protection group post-migration steps'

    # What the console calls "Computers with pre-installed Veeam backup agents" is
    # NOT on VBRProtectionGroup.Type - that enum holds only Custom and ManuallyAdded.
    # It is the CONTAINER: Container.Type (VBRProtectionGroupContainerType) =
    # IndividualComputers | ActiveDirectory | CSV | ManuallyDeployed | CloudMachines
    # | MongoDBComputers, and the one we want is ManuallyDeployed. The phrase
    # "pre-installed" appears nowhere in the object model.
    #
    # Exact enum comparison, never a substring: ManuallyDeployed (container) and
    # ManuallyAdded (group type) both contain "Manual", and a loose match flagged the
    # built-in "Manually Added" group on every server.
    $groups = @()
    $preInstalled = @()
    $evidence = @()
    if (Test-PrecheckCmdlet 'Get-VBRProtectionGroup') {
        try {
            $groups = @(Get-VBRProtectionGroup -ErrorAction SilentlyContinue)
            foreach ($g in $groups) {
                $ct = ''
                try { if ($g.Container) { $ct = "$($g.Container.Type)" } } catch { }
                if ($ct -ieq 'ManuallyDeployed') { $preInstalled += $g.Name }
                # State each group's kind so the classification is checkable from the
                # report rather than taken on trust.
                $evidence += "Protection Group: $($g.Name)  [$(if ($ct) { $ct } else { 'kind could not be read' })]"
            }
        } catch { }
    }

    if ($groups.Count -eq 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail 'No Protection Groups found (no post-migration rescan needed).'
    }

    $detail = "$($groups.Count) Protection Group(s) present. After migration ALL Protection Groups must be rescanned."
    $rec = 'Post-migration: rescan every Protection Group.'
    $ev = $evidence
    if ($preInstalled.Count -gt 0) {
        $detail += " $($preInstalled.Count) group(s) appear to use Computers with Pre-installed Backup Agents, which must be reconfigured with a NEW configuration file."
        $rec += ' Protection Groups for Computers with Pre-installed Backup Agents must be reconfigured with a new configuration file.'
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
        -Detail $detail -Recommendation $rec -Evidence $ev
}
