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


# =============================================================================
#  GENERATED FILE - do not edit.
#  Built from the VbrMigrationPrecheck module by Build-SingleFile.ps1.
#  Version : 0.4.3
#  Built   : 2026-08-05 15:43:15
#  Sources : 15 files
#
#  Edit the module under VbrMigrationPrecheck/ and rebuild - changes made here
#  are lost on the next build.
# =============================================================================

# Reports default to this script's own folder (the module sets this to the repo
# root instead). Keeps the output path independent of the folder layout.
$script:PrecheckRoot = $PSScriptRoot

# Stamped in at build time so reports state which build produced them.
$script:PrecheckVersion = '0.4.3'

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Private/Get-VbrProductVersion.ps1
# -----------------------------------------------------------------------------
# Get-VbrProductVersion
# Resolves the installed VBR product version/build. There is no single stable
# cmdlet across builds, so we try strategies in order of reliability and return
# the first that works. Callers get a normalised object; the raw build string
# is what the version check parses.
#
# Returned object: @{ Build = [version]|$null; DisplayName = [string] }

function Get-VbrProductVersion {
    [CmdletBinding()]
    param()

    $build       = $null
    $displayName = 'Unknown'

    # Strategy 1: Get-VBRBackupServerInfo (a real v13 cmdlet - verified against
    # the A-Z reference). Probe for a build/version property defensively.
    if (Get-Command -Name 'Get-VBRBackupServerInfo' -ErrorAction SilentlyContinue) {
        try {
            $info = Get-VBRBackupServerInfo -ErrorAction Stop
            if ($info) {
                foreach ($p in 'Build', 'Version', 'PatchVersion', 'ProductVersion') {
                    if ($info.PSObject.Properties[$p] -and $info.$p) {
                        $val = [string]$info.$p
                        $parsed = $null
                        if ($val -match '(\d+(\.\d+){1,3})' -and [version]::TryParse($Matches[1], [ref]$parsed)) {
                            $build = $parsed
                            $displayName = "Veeam Backup & Replication $val"
                            break
                        }
                    }
                }
            }
        } catch { }
    }

    # Strategy 2: the core assembly's file version (authoritative when the
    # console is installed locally). CorePath lives in the registry.
    if (-not $build) {
    try {
        $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication' -ErrorAction Stop
        if ($reg.CorePath) {
            $dll = Join-Path $reg.CorePath 'Veeam.Backup.Core.dll'
            if (Test-Path $dll) {
                $fv = (Get-Item $dll).VersionInfo.ProductVersion
                if ($fv) {
                    $displayName = $fv
                    $parsed = $null
                    # ProductVersion can carry trailing text; take the leading dotted quad.
                    if ($fv -match '^(\d+(\.\d+){1,3})') {
                        [void][version]::TryParse($Matches[1], [ref]$parsed)
                    }
                    $build = $parsed
                }
            }
        }
        # Some builds also expose a friendly string here.
        if ($displayName -eq 'Unknown' -and $reg.'DisplayVersion') {
            $displayName = $reg.'DisplayVersion'
        }
    } catch { }
    }

    # Strategy 3: Windows uninstall entry (works when run remotely with the
    # console still present on the box).
    if (-not $build) {
        try {
            $uninstall = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'Veeam Backup & Replication Server*' } |
                Select-Object -First 1
            if ($uninstall -and $uninstall.DisplayVersion) {
                $displayName = "Veeam Backup & Replication $($uninstall.DisplayVersion)"
                $parsed = $null
                if ([version]::TryParse($uninstall.DisplayVersion, [ref]$parsed)) { $build = $parsed }
            }
        } catch { }
    }

    [PSCustomObject]@{
        Build       = $build
        DisplayName = $displayName
    }
}

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Private/New-PrecheckResult.ps1
# -----------------------------------------------------------------------------
# New-PrecheckResult
# Factory for the single result object every check returns. Keeping one shape
# here means the orchestrator, console renderer, and JSON/HTML exporters can all
# rely on the same fields.
#
# Status vocabulary (also drives the overall verdict and the exit code):
#   Pass     - no issue found for this limitation.
#   Blocker  - migration is NOT supported / WILL fail until resolved. Hard stop.
#   Action   - must be remediated BEFORE migration or it will fail.
#   Warning  - migration proceeds, but configuration is lost/changed/disabled.
#   Manual   - a manual step is required (pre- or post-migration) that cannot be
#              automated; operator must confirm it was done.
#   NextStep - an advisory PRE-migration preparation action (from KB4800's
#              "Pre-Migration Considerations"). Not a blocker; surfaced in the
#              report's "Pre-Migration Next Steps" section, and typically only
#              when the related limitation applies to this environment.
#   Info     - could not be auto-evaluated (cmdlet/property absent); verify by hand.
#   Skipped  - check not applicable to this deployment.

# When KB4800 was last read and mapped to these checks. Stamped into every report so
# a report stays honestly bounded: the KB is a living document and its guidance can
# change with a new release, long after a given report was produced.
# UPDATE THIS whenever KB4800 is re-read and the checks are reconciled against it.
$script:PrecheckKbCaptured = '2026-07-24'

$script:PrecheckStatusRank = @{
    Blocker  = 6
    Action   = 5
    Warning  = 4
    Manual   = 3
    NextStep = 2
    Info     = 1
    Pass     = 0
    Skipped  = 0
}

function New-PrecheckResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Blocker', 'Action', 'Warning', 'Manual', 'NextStep', 'Info', 'Skipped')]
        [string] $Status,
        [string]   $Detail = '',
        [string]   $Recommendation = '',
        # Concrete objects/names that triggered the finding (job names, repo
        # names, credential names, dates...). Rendered as a bullet list.
        [object[]] $Evidence = @(),
        # KB4800 anchor / doc reference for the operator to read more.
        [string]   $Reference = 'https://www.veeam.com/kb4800'
    )

    [PSCustomObject]@{
        Id             = $Id
        Category       = $Category
        Title          = $Title
        Status         = $Status
        Rank           = $script:PrecheckStatusRank[$Status]
        Detail         = $Detail
        Recommendation = $Recommendation
        Evidence       = @($Evidence)
        Reference      = $Reference
    }
}

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Private/Test-PrecheckCmdlet.ps1
# -----------------------------------------------------------------------------
# Guard used at the top of every check: the Veeam.Backup.PowerShell surface varies
# by installed feature, so a check must never assume a cmdlet exists. True only
# when all named cmdlets resolve.

function Test-PrecheckCmdlet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromRemainingArguments)]
        [string[]] $Name
    )
    foreach ($n in $Name) {
        # Cmdlet availability cannot change during a run, so resolve each name once.
        if (-not $script:PrecheckCmdletCache.ContainsKey($n)) {
            $script:PrecheckCmdletCache[$n] = [bool](Get-Command -Name $n -ErrorAction SilentlyContinue)
        }
        if (-not $script:PrecheckCmdletCache[$n]) { return $false }
    }
    return $true
}

# Per-run cache for data several checks share (licence, job list, Entra ID
# tenants, storage plug-in hosts). Cleared at the start of every run, so it cannot
# go stale or leak between servers. ContainsKey, not a null test, so an empty
# result is cached rather than re-fetched.

$script:PrecheckCache       = @{}
$script:PrecheckCmdletCache = @{}

function Clear-PrecheckCache {
    [CmdletBinding()] param()
    $script:PrecheckCache       = @{}
    $script:PrecheckCmdletCache = @{}
}

function Get-PrecheckCached {
    # A getter that throws is not cached, so a transient failure stays transient.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]      $Key,
        [Parameter(Mandatory)] [scriptblock] $Getter
    )
    if (-not $script:PrecheckCache.ContainsKey($Key)) {
        $script:PrecheckCache[$Key] = & $Getter
    }
    # Plain return, not `return ,$value`: callers use @(...), and the comma form
    # makes that yield one element containing the collection.
    return $script:PrecheckCache[$Key]
}

# Stops one failing check from aborting the run. A check that throws is a defect,
# so the result is labelled with the function to fix rather than a KB item ID.
function Invoke-PrecheckSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [scriptblock] $Body
    )
    try {
        & $Body
    }
    catch {
        Write-PrecheckLog "Check $Title errored: $($_.Exception.Message)" -Level WARN
        New-PrecheckResult -Id "FAILED" -Category 'Check error' -Title $Title -Status Info `
            -Detail "$Title did not complete, so its KB4800 item was NOT evaluated: $($_.Exception.Message)" `
            -Recommendation 'This is a tool defect - report it. Meanwhile evaluate this limitation manually against KB4800.'
    }
}

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Private/Write-PrecheckLog.ps1
# -----------------------------------------------------------------------------
# Write-PrecheckLog
# Minimal, dependency-free console/file logger shared by the orchestrator and
# checks. Level colouring keeps the interactive run readable; the same lines are
# appended to $script:PrecheckLogFile when the orchestrator has set one.

function Write-PrecheckLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG', 'STEP')]
        [string] $Level = 'INFO'
    )

    $ts   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"

    if ($Level -eq 'DEBUG' -and -not $script:PrecheckVerbose) {
        # Debug lines still go to the file, just not the console.
    } else {
        $color = switch ($Level) {
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red' }
            'STEP'  { 'Cyan' }
            'DEBUG' { 'DarkGray' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }

    if ($script:PrecheckLogFile) {
        try { Add-Content -Path $script:PrecheckLogFile -Value $line -ErrorAction Stop } catch { }
    }
}

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Checks/Test-Agents.ps1
# -----------------------------------------------------------------------------
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
            -Detail 'The discovered-computer inventory on this server was read successfully and is empty, so no managed agent needs upgrading.'
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
    $jobCount = 0
    $readJobs = $false
    try {
        $all = @(Get-VBRComputerBackupJob -ErrorAction SilentlyContinue)
        $jobCount = $all.Count
        # Whole words only. A bare substring match on 'Mac' also matches the word
        # "machine", which these type strings are very likely to contain, and that
        # reported ordinary Windows agent jobs as Mac jobs on every server - the same
        # mistake that made AGT-004 flag the built-in "Manually Added" group. The
        # exact OSPlatform vocabulary is still unconfirmed (see LAB-PLAN), so this
        # stays a word match rather than an enum comparison for now.
        $macJobs = @($all |
            Where-Object { "$($_.OSPlatform) $($_.Type) $($_.TypeToString)" -match '\b(mac|osx|macos)\b' } |
            ForEach-Object { $_.Name })
        $readJobs = $true
    } catch { }

    if ($macJobs.Count -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "$($macJobs.Count) of $jobCount agent job(s) on this server look like Veeam Agent for Mac jobs." `
            -Recommendation 'Confirm none connect using a domain account. Any that do must be reconfigured to a local user account before migration.' `
            -Evidence $macJobs
    }

    if (-not $readJobs) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'Agent jobs could not be enumerated on this server, so Mac agent authentication was not checked.' `
            -Recommendation 'Any Veeam Agent for Mac job connecting with a DOMAIN account must be reconfigured to use a LOCAL user account (Mac agent = no Kerberos; VSA = no NTLM).'
    }

    # The denominator matters here: this check identifies Mac jobs by platform
    # strings, so "no Mac jobs" is only meaningful alongside how many jobs it read.
    $detail = if ($jobCount -eq 0) {
        'The agent job list on this server was read successfully and is empty, so no Veeam Agent for Mac job exists.'
    } else {
        "$jobCount agent job(s) were examined and none of them is a Veeam Agent for Mac job, so no Mac agent authentication needs changing."
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass -Detail $detail
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
    $readGroups = $false
    if (Test-PrecheckCmdlet 'Get-VBRProtectionGroup') {
        try {
            $groups = @(Get-VBRProtectionGroup -ErrorAction SilentlyContinue)
            $readGroups = $true
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

    # An unread collection is empty, and this check's clean result used to be reached
    # by falling through that empty collection - so a missing or throwing cmdlet
    # produced "no Protection Groups found" rather than saying it could not look.
    # Every other check fails safe to Manual/Info here; this one failed OPEN, and the
    # finding it suppresses is a post-migration instruction the operator never sees.
    if (-not $readGroups) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'Protection Groups could not be enumerated on this server, so none could be examined.' `
            -Recommendation 'After migration, rescan every Protection Group. Any Protection Group for Computers with Pre-installed Backup Agents must also be reconfigured with a new configuration file.'
    }

    if ($groups.Count -eq 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail 'The Protection Group list on this server was read successfully and is empty, so no post-migration rescan is needed.'
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

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Checks/Test-Database.ps1
# -----------------------------------------------------------------------------
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

    # The supplied date has to be plausible before anything is concluded from it.
    # PowerShell binds '-UpgradeDate 0' to DateTime.MinValue without complaint, which
    # computed 105690 weeks since "the upgrade on 0001-01-01" and returned a confident
    # Pass - a mistyped parameter clearing the very check meant to catch this blocker.
    # A future date cannot describe an upgrade that has already happened, and Veeam
    # Backup & Replication did not exist before 2008, so neither can be a real cutoff.
    $earliestPlausible = [datetime] '2008-01-01'
    if ($cutoff -lt $earliestPlausible -or $cutoff -gt (Get-Date)) {
        $why = if ($cutoff -gt (Get-Date)) { 'is in the future' } else { 'predates Veeam Backup & Replication' }
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "The upgrade date supplied ($cutoffStr) $why, so it cannot be this environment's upgrade date and session-history retention was not judged against it. Session history is kept for $weeks week(s)." `
            -Recommendation "Re-run supplying the date this environment was upgraded, as -UpgradeDate yyyy-MM-dd (for example -UpgradeDate 2024-03-15). Then compare that against the $weeks week(s) of history being kept." `
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
        -Detail "Session history is kept for $weeks week(s), which reaches back to or past the upgrade on $cutoffStr ($weeksSince week(s) ago) - so job sessions predating the upgrade may still be in the database. KB4800 lists those sessions as a cause of migration failure." `
        -Recommendation "Reduce session-history retention to fewer than $weeksSince week(s) (e.g. Set-VBRHistoryOptions -RetentionLimitWeeks $target), allow the old sessions to be pruned, then re-run this check before migrating." `
        -Evidence $ev
}

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Checks/Test-Deployment.ps1
# -----------------------------------------------------------------------------
# Deployment-shape checks: configurations that block or partially block a whole
# deployment from migrating.
# KB4800: "Cloud Connectivity", "Google Cloud Integration", "Entra ID Tenant Backups".

function Test-CloudConnect {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'DEP-001'; $cat = 'Deployment'; $title = 'Cloud Connect deployment'

    # Cloud Connect status is recorded in the licence: VBRInstalledLicense
    # .CloudConnect = Enabled | Disabled | Enterprise | Invalid.
    #
    # Read that rather than enumerating tenants/gateways: on a non-Cloud-Connect
    # server those cmdlets throw ("service provider license is required"), which
    # would surface as a noise item on every such server. Tenants and gateways are
    # enumerated only when the licence says Cloud Connect is present.
    $ccMode = $null
    if (Test-PrecheckCmdlet 'Get-VBRInstalledLicense') {
        try {
            $lic = Get-PrecheckCached -Key 'InstalledLicense' -Getter { Get-VBRInstalledLicense -ErrorAction Stop }
            if ($lic -and $lic.PSObject.Properties['CloudConnect']) { $ccMode = [string]$lic.CloudConnect }
        } catch { }
    }

    if ($ccMode -ieq 'Disabled') {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail 'Not a Cloud Connect deployment - the installed license reports CloudConnect = Disabled.' `
            -Evidence @("License CloudConnect mode: $ccMode")
    }

    if ($ccMode -ieq 'Enabled' -or $ccMode -ieq 'Enterprise') {
        # Licence says Cloud Connect, so these cmdlets will work. Use them for detail.
        $tenants  = @()
        $gateways = @()
        try { if (Test-PrecheckCmdlet 'Get-VBRCloudTenant')  { $tenants  = @(Get-VBRCloudTenant  -ErrorAction SilentlyContinue) } } catch { }
        try { if (Test-PrecheckCmdlet 'Get-VBRCloudGateway') { $gateways = @(Get-VBRCloudGateway -ErrorAction SilentlyContinue) } } catch { }

        $ev = @("License CloudConnect mode: $ccMode") +
              @($tenants  | ForEach-Object { "Tenant: $($_.Name)" }) +
              @($gateways | ForEach-Object { "Gateway: $($_.Name)" })

        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Blocker `
            -Detail "This is a Veeam Cloud Connect deployment - the installed license reports CloudConnect = $ccMode ($($tenants.Count) tenant(s), $($gateways.Count) gateway(s) found). Cloud Connect deployments cannot be migrated to the Veeam Software Appliance." `
            -Recommendation 'Cloud Connect deployments are not migratable. Do not proceed via this process.' `
            -Evidence $ev
    }

    # 'Invalid', or the licence/property could not be read: do not guess in either
    # direction on a Blocker-grade check.
    $detail = if ($ccMode) {
        "The installed license reports CloudConnect = $ccMode, which does not clearly indicate whether this is a Cloud Connect deployment."
    } else {
        'The installed license could not be read, so Cloud Connect licensing state is unknown.'
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
        -Detail $detail `
        -Recommendation 'Confirm manually that this is not a Cloud Connect provider deployment - those cannot be migrated to the Veeam Software Appliance.' `
        -Evidence @("License CloudConnect mode: $(if ($ccMode) { $ccMode } else { '<unreadable>' })")
}

function Test-GoogleCloudPlugin {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'DEP-002'; $cat = 'Deployment'; $title = 'Google Cloud plug-in'

    # The Google Cloud plug-in is Windows-only and its configuration will not migrate.
    #
    # Detect CONFIGURATION, not installation: the plug-in ships with VBR and is present
    # on every server, so its mere presence says nothing. (An earlier version read the
    # uninstall registry and would have raised a finding on every server in the fleet.)
    # Same rule as SEC-002 - scope by usage, not by shape.
    #
    # Only Google-specific cmdlets are used, so a hit is unambiguous. Counted per probe
    # so the clear result can state what it actually examined, and so a server where
    # every probe fails cannot report a Pass.
    $hits = @()
    $probed = 0
    $failed = 0
    foreach ($probe in @(
        @{ Cmdlet = 'Get-VBRGoogleCloudAccount';        Label = 'Google Cloud account' }
        @{ Cmdlet = 'Get-VBRGoogleCloudComputeAccount'; Label = 'Google Compute account' }
    )) {
        if (-not (Test-PrecheckCmdlet $probe.Cmdlet)) { continue }
        $probed++
        try {
            foreach ($o in @(& $probe.Cmdlet -ErrorAction Stop)) {
                $nm = try { "$($o.Name)" } catch { '' }
                $hits += "$($probe.Label): $(if ($nm) { $nm } else { '<configured>' })"
            }
        }
        catch { $failed++ }
    }

    # Job names are a second signal and cost nothing - Get-VBRJob is already cached.
    if (Test-PrecheckCmdlet 'Get-VBRJob') {
        try {
            $hits += @(Get-PrecheckCached -Key 'Jobs' -Getter { Get-VBRJob -ErrorAction SilentlyContinue }) |
                Where-Object { "$($_.JobType) $($_.TypeToString) $($_.Name)" -match 'Google|GCP|GCE' } |
                ForEach-Object { "Job: $($_.Name) [$($_.JobType)]" }
        } catch { }
    }

    if ($hits.Count -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Warning `
            -Detail "Google Cloud is configured on this server. The Veeam Plug-in for Google Cloud is Windows-only, so its configuration will NOT migrate." `
            -Recommendation 'Google Cloud plug-in configuration must be re-established separately after migration. Confirm the scope of what is protected through it before migrating.' `
            -Evidence ($hits | Sort-Object -Unique)
    }
    if ($probed -gt 0 -and $failed -lt $probed) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail "No Google Cloud configuration found. $probed Google Cloud configuration source(s) were checked and no job references Google Cloud. Note the plug-in itself ships with VBR, so it is installed regardless - only configuration matters here. Google Cloud external repositories are not examined."
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
        -Detail 'Whether Google Cloud is configured on this server could not be determined.' `
        -Recommendation 'Confirm by hand whether the Veeam Plug-in for Google Cloud is configured; it is Windows-only and its configuration will not migrate. Note the plug-in is installed with VBR by default, so check for configured Google Cloud accounts rather than for the plug-in being present.'
}

function Test-EntraIdBackups {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'DEP-003'; $cat = 'Deployment'; $title = 'Entra ID tenant backups'

    # Verified against the A-Z reference: the cmdlet is Get-VBREntraIDTenant
    # (Azure AD was renamed to Entra ID; there is no Get-VBRAzureADTenant).
    if (-not (Test-PrecheckCmdlet 'Get-VBREntraIDTenant')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail 'Entra ID tenant backups could not be read on this server.' `
            -Recommendation 'If Entra ID tenant backups exist, their primary data is not migrated (remains on the source PostgreSQL). Verify manually.'
    }

    $tenants = @(Get-PrecheckCached -Key 'EntraIDTenants' -Getter { Get-VBREntraIDTenant -ErrorAction SilentlyContinue })
    if ($tenants.Count -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "$($tenants.Count) Microsoft Entra ID tenant backup(s) found. Primary Entra ID backup DATA is not migrated and remains on the original PostgreSQL instance." `
            -Recommendation 'Follow one of the three documented Entra ID data procedures in KB4800 before/after migration. Manual intervention is required.' `
            -Evidence ($tenants | ForEach-Object { "Entra ID tenant: $($_.Name)" })
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
        -Detail 'The Entra ID tenant inventory on this server was read successfully and is empty, so no Entra ID backup data is affected by the migration.'
}

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Checks/Test-Environment.ps1
# -----------------------------------------------------------------------------
# Environment checks: product version/patch and license model.
# KB4800: "Version Requirements" and "License Requirements".

function Test-VbrVersion {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'ENV-001'; $cat = 'Environment'; $title = 'Source VBR version'
    $build = $Ctx.ProductBuild

    if (-not $build) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail "Could not resolve the installed VBR build (detected string: '$($Ctx.ProductString)')." `
            -Recommendation 'Confirm manually that the server runs the latest available Veeam Backup & Replication 13.0.x patch. Migration is NOT validated on 13.1 or later.'
    }

    $detail = "Detected build $build ('$($Ctx.ProductString)')."

    if ($build.Major -lt 13) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Action `
            -Detail "$detail This is older than 13.0." `
            -Recommendation 'Upgrade the Windows VBR server to the latest 13.0.x patch before attempting migration.'
    }
    if ($build.Major -eq 13 -and $build.Minor -eq 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail "$detail This is within the supported 13.0.x train." `
            -Recommendation 'Ensure this is the LATEST available 13.0.x patch, and that the target Veeam Software Appliance is 13.0.2 or newer.'
    }
    # Never name or make claims about an unreleased build: this output goes to
    # customers and in-development behaviour can still change. Point at the released
    # train and let KB4800 speak for anything newer.
    if ($build.Major -eq 13 -and $build.Minor -eq 1) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Blocker `
            -Detail "$detail Migration from a Windows VBR 13.1 source is NOT possible." `
            -Recommendation 'Do not migrate from 13.1. Migration is supported from the 13.0.x train - use a source running the latest available 13.0.x patch.'
    }
    # Newer than 13.1: no assertion - that is a question for KB4800 at the time.
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
        -Detail "$detail This build is newer than the 13.0.x train that this check validates, and newer than 13.1 (from which migration is not possible)." `
        -Recommendation 'Confirm against KB4800 whether migration to the Veeam Software Appliance is supported from this build before proceeding. Migration is supported from the 13.0.x train.'
}

function Test-VbrLicense {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'ENV-002'; $cat = 'Environment'; $title = 'License type'

    if (-not (Test-PrecheckCmdlet 'Get-VBRInstalledLicense')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail 'The installed license could not be read on this server.' `
            -Recommendation 'Confirm the license is instance-based VUL. Socket-based licenses must be migrated to VUL before migration.'
    }

    # Shared with DEP-001, which reads the same licence for its CloudConnect mode.
    $lic = Get-PrecheckCached -Key 'InstalledLicense' -Getter { Get-VBRInstalledLicense }
    if (-not $lic) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail 'No installed license object returned.' `
            -Recommendation 'Confirm the license is instance-based VUL before migration.'
    }

    # VBRInstalledLicense: SocketLicenseSummary (an ARRAY), InstanceLicenseSummary,
    # CapacityLicenseSummary, Type, Edition.
    $socketSummary   = if ($lic.PSObject.Properties['SocketLicenseSummary'])   { @($lic.SocketLicenseSummary) } else { @() }
    $instanceSummary = if ($lic.PSObject.Properties['InstanceLicenseSummary']) { $lic.InstanceLicenseSummary } else { $null }

    # Count the SOCKETS, not the array entries: an instance-based licence still
    # returns a SocketLicenseSummary entry, containing zero sockets. If no entry
    # exposes a countable figure the verdict is unknown, not "socket-based".
    # VBRSocketLicenseSummary exposes LicensedSocketsNumber / RemainingSocketsNumber /
    # UsedSocketsNumber / Workload - confirmed by reflection on a real licence object, so
    # the name is not a guess. Earlier revisions probed a list of alternatives; none of
    # them exists, and one of them ('Count') would be actively dangerous if a future
    # build ever exposed it, because a collection count read as a socket count reproduces
    # the false Action this check already had once.
    $sockets      = 0
    $socketCountable = $false
    foreach ($ss in $socketSummary) {
        if ($null -eq $ss) { continue }
        if ($ss.PSObject.Properties['LicensedSocketsNumber'] -and $null -ne $ss.LicensedSocketsNumber) {
            $n = 0
            if ([int]::TryParse("$($ss.LicensedSocketsNumber)", [ref]$n)) {
                $sockets += $n
                $socketCountable = $true
            }
        }
    }

    # Instances: the summary object carries the counts; probe its own members
    # rather than assuming one name.
    # VBRInstanceLicenseSummary exposes LicensedInstancesNumber (a double) - also
    # reflection-confirmed, same reasoning as the socket count above.
    $instances = $null
    if ($instanceSummary) {
        if ($instanceSummary.PSObject.Properties['LicensedInstancesNumber'] -and
            $null -ne $instanceSummary.LicensedInstancesNumber) {
            $instances = $instanceSummary.LicensedInstancesNumber
        }
        # Present but uncountable still means an instance licence exists.
        if ($null -eq $instances) { $instances = 'present' }
    }

    $type    = if ($lic.PSObject.Properties['Type'])    { [string]$lic.Type }    else { '' }
    $edition = if ($lic.PSObject.Properties['Edition']) { [string]$lic.Edition } else { '' }
    $ev = @(
        "Type=$type"
        "Edition=$edition"
        "InstanceLicenseSummary=$instances"
        "SocketLicenseSummary entries=$($socketSummary.Count)"
        "Licensed sockets counted=$(if ($socketCountable) { $sockets } else { 'not countable' })"
    )

    # A socket licence is only asserted on a POSITIVE socket count.
    if ($socketCountable -and $sockets -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Action `
            -Detail "A socket-based license is installed ($sockets licensed socket(s)). The Veeam Software Appliance supports ONLY instance-based VUL." `
            -Recommendation 'Migrate the socket-based license to a Veeam Universal License (VUL) before proceeding.' `
            -Evidence $ev
    }
    if ($instances) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail "Instance-based license detected (instances=$instances, type=$type, edition=$edition). No licensed sockets found." `
            -Evidence $ev
    }
    # Socket summary present but no countable socket figure and no instance summary:
    # genuinely unknown, so say so rather than guessing in either direction.
    if ($socketSummary.Count -gt 0 -and -not $socketCountable) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail "A SocketLicenseSummary is present but exposes no countable socket figure, and no instance summary was found - the license model could not be classified." `
            -Recommendation 'Manually confirm the license is instance-based VUL (not socket-based). The appliance supports ONLY instance-based VUL.' `
            -Evidence $ev
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
        -Detail "Could not classify the license as socket vs instance from available properties." `
        -Recommendation 'Manually confirm the license is instance-based VUL (not socket-based).' `
        -Evidence $ev
}

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Checks/Test-Jobs.ps1
# -----------------------------------------------------------------------------
# Job-configuration checks.
# KB4800: "Continuous Data Protection (CDP)", "SureBackup/Application Groups"
# (SQL Server Checker Script), "File Migration" (scripts/CSV must be copied).

function Test-CdpJobs {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'JOB-001'; $cat = 'Jobs'; $title = 'CDP policies'

    # Verified against the A-Z reference: the cmdlet is Get-VBRCDPPolicy.
    if (-not (Test-PrecheckCmdlet 'Get-VBRCDPPolicy')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail 'CDP policies could not be read on this server.' `
            -Recommendation 'If any CDP policies exist, their configuration is NOT migrated and must be reconfigured manually after migration.'
    }
    $cdp = @(Get-VBRCDPPolicy -ErrorAction SilentlyContinue)
    if ($cdp.Count -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Warning `
            -Detail "$($cdp.Count) CDP policy/policies found. CDP job configuration is NOT migrated." `
            -Recommendation 'Document these CDP policies now; they must be reconfigured manually on the Veeam Software Appliance after migration.' `
            -Evidence ($cdp | ForEach-Object { "CDP policy: $($_.Name)" })
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
        -Detail 'The CDP policy list on this server was read successfully and is empty, so there is no CDP configuration to re-create after migration.'
}

function Test-SureBackupSqlChecker {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'JOB-002'; $cat = 'Jobs'; $title = 'SureBackup SQL Server Checker Script'

    if (-not (Test-PrecheckCmdlet 'Get-VBRApplicationGroup') -and -not (Test-PrecheckCmdlet 'Get-VBRSureBackupJob')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'SureBackup configuration could not be read on this server.' `
            -Recommendation 'SureBackup/Application Group VM roles using the SQL Server Checker Script will FAIL on the VSA (that script is Windows-only). Verify manually.'
    }

    # Get-VBRApplicationGroup -> VM (VBRSureBackupVM[]), each with Role
    # (VBRSureBackupRole[], an ARRAY) and TestScript (VBRSureBackupTestScript[]).
    # Assigning the SQLServer role is what attaches the SQL Checker Script, so the
    # role is the signal; the test-script array is corroboration only.
    $hits = @()
    $agCount = 0
    $vmCount = 0
    $readGroups = $false
    if (Test-PrecheckCmdlet 'Get-VBRApplicationGroup') {
        try {
            foreach ($ag in Get-VBRApplicationGroup -ErrorAction SilentlyContinue) {
                $agCount++
                foreach ($vm in @($ag.VM)) {
                    if (-not $vm) { continue }
                    $vmCount++
                    $vmName = if ($vm.PSObject.Properties['Name']) { [string]$vm.Name } else { '<unnamed>' }

                    # Primary signal: the SQLServer role.
                    $roles = @()
                    if ($vm.PSObject.Properties['Role']) {
                        $roles = @($vm.Role | ForEach-Object { "$_" } | Where-Object { $_ })
                    }
                    $sqlRole = @($roles | Where-Object { $_ -match 'Sql' })

                    # Corroboration: a predefined test script whose type/name mentions SQL.
                    $scriptHit = $false
                    if ($vm.PSObject.Properties['TestScript']) {
                        foreach ($ts in @($vm.TestScript)) {
                            if (-not $ts) { continue }
                            $tsDesc = @()
                            try { $tsDesc += $ts.GetType().Name } catch { }
                            foreach ($np in 'Name', 'Type', 'PredefinedScript', 'Path') {
                                if ($ts.PSObject.Properties[$np] -and $ts.$np) { $tsDesc += "$($ts.$np)" }
                            }
                            if (($tsDesc -join ' ') -match 'Sql') { $scriptHit = $true }
                        }
                    }

                    if ($sqlRole.Count -gt 0 -or $scriptHit) {
                        $detail = if ($sqlRole.Count -gt 0) { "role(s): $($sqlRole -join ', ')" } else { 'predefined SQL test script' }
                        $hits += "Application Group '$($ag.Name)' -> VM '$vmName' ($detail)"
                    }
                }
            }
            $readGroups = $true
        } catch { }
    }

    if ($hits.Count -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Blocker `
            -Detail "SureBackup Application Group(s) appear to use the SQL Server Checker Script, which is available ONLY on Windows deployments and will FAIL on the VSA." `
            -Recommendation 'Remove/replace the SQL Server Checker Script in these Application Groups before migration (or accept those SureBackup tests will fail).' `
            -Evidence $hits
    }

    # This is the only check that can emit a Blocker, so it must never report a clean
    # result it did not earn. The guard above passes when EITHER SureBackup cmdlet
    # exists, so the application groups can still be unreadable at this point - and an
    # unread collection is empty, which would otherwise look exactly like a clean one.
    if (-not $readGroups) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'SureBackup application groups could not be enumerated on this server, so their VM roles were not checked.' `
            -Recommendation 'Check by hand whether any Application Group VM has the SQL Server role: the SQL Server Checker Script it attaches is Windows-only and will FAIL on the Veeam Software Appliance.'
    }

    $detail = if ($agCount -eq 0) {
        'The SureBackup application group list on this server was read successfully and is empty, so no VM can be using the SQL Server Checker Script.'
    } else {
        "$agCount SureBackup application group(s) containing $vmCount VM(s) were examined, and none uses the SQL Server role or a predefined SQL test script."
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass -Detail $detail
}

function Test-JobScriptsAndFiles {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'JOB-003'; $cat = 'Jobs'; $title = 'Job and guest-processing scripts'

    if (-not (Test-PrecheckCmdlet 'Get-VBRJob')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'Job details could not be read on this server, so script and CSV usage was not checked.' `
            -Recommendation 'CSV files, pre/post-job scripts, and pre-freeze/post-thaw scripts are NOT copied by migration. Copy them manually and update the paths afterward.'
    }

    # Three separate surfaces hold scripts, and they must all be read - see
    # docs/checks-reference.md for why an earlier version that read only the first
    # returned a clean result on a job with four scripts configured.
    $scripts = @()
    try {
        foreach ($job in @(Get-PrecheckCached -Key 'Jobs' -Getter { Get-VBRJob -ErrorAction SilentlyContinue })) {

            # --- 1. pre/post-JOB commands (job Advanced settings) --------------
            $jsc = $null
            try { $jsc = $job.GetOptions().JobScriptCommand } catch { }
            if ($jsc) {
                foreach ($slot in @(@{ N = 'Pre-job';  E = 'PreScriptEnabled';  C = 'PreScriptCommandLine' },
                                    @{ N = 'Post-job'; E = 'PostScriptEnabled'; C = 'PostScriptCommandLine' })) {
                    if (-not $jsc.PSObject.Properties[$slot.E] -or -not $jsc.($slot.E)) { continue }
                    $path = Get-PrecheckScriptPath ([string]$jsc.($slot.C))
                    $scripts += if ($path) { "$($job.Name): $($slot.N) command -> $path" }
                                else       { "$($job.Name): $($slot.N) command is enabled (command line not shown - could not be separated from its arguments)" }
                }
            }

            # --- 2. guest scripts, job-level default --------------------------
            $gpo = $null
            try { $gpo = $job.Info.VssOptions } catch { }
            if (-not $gpo) { try { $gpo = Get-VBRJobVSSOptions -Job $job -ErrorAction Stop } catch { } }
            $scripts += @(Get-PrecheckGuestScripts -GuestScriptsOptions $gpo.GuestScriptsOptions -Label "$($job.Name): job default")

            # --- 3. guest scripts, PER-OBJECT override ------------------------
            # "Application handling for individual servers" writes here, not to the
            # job default above. Read the object's own .VssOptions property: it
            # carries identical data to Get-VBRJobObjectVssOptions at a fraction of
            # the cost (measured 4 ms vs 56 ms for two objects), which matters when
            # the run is repeated across a large fleet. Cmdlet kept as a fallback.
            $objs = @()
            try { $objs = @(Get-VBRJobObject -Job $job -ErrorAction Stop) } catch { }
            if ($objs.Count -eq 0) { try { $objs = @($job.GetObjectsInJob()) } catch { } }
            foreach ($o in $objs) {
                $ovss = $null
                try { if ($o.PSObject.Properties['VssOptions']) { $ovss = $o.VssOptions } } catch { }
                if (-not $ovss) { try { $ovss = Get-VBRJobObjectVssOptions -ObjectInJob $o -ErrorAction Stop } catch { } }
                if (-not $ovss) { continue }
                $scripts += @(Get-PrecheckGuestScripts -GuestScriptsOptions $ovss.GuestScriptsOptions -Label "$($job.Name) -> $($o.Name)")
            }
        }
    } catch { }

    if ($scripts.Count -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "$($scripts.Count) script reference(s) found. These files are NOT copied by migration." `
            -Recommendation 'Copy each script to the Veeam Software Appliance manually and update the job settings (paths) after migration. Also confirm whether any job reads a CSV file - those are not detectable here and are not copied either.' `
            -Evidence $scripts
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
        -Detail 'No scripts are configured on any job - pre/post-job commands, job-level guest scripts, and per-machine guest script overrides were all checked. CSV files read by a job cannot be detected; confirm those by hand.'
}

# Pulls the configured script paths out of a CGuestScriptsOptions, for either the
# job-level default or a per-object override. Reads only the *ScriptFilePath
# members: enumerating every property also emits the IsAtLeastOneScriptSet flag as
# though it were a file path.
function Get-PrecheckGuestScripts {
    [CmdletBinding()] param($GuestScriptsOptions, [Parameter(Mandatory)][string] $Label)

    $out = @()
    $gs = $GuestScriptsOptions
    if (-not $gs) { return $out }
    # The object states outright whether anything is set, and it is accurate at
    # each level - job default reports False while a per-machine override reports
    # True on the same job.
    if ($gs.PSObject.Properties['IsAtLeastOneScriptSet'] -and -not $gs.IsAtLeastOneScriptSet) { return $out }

    # Every entry returned is a file the operator has to copy - nothing else. The
    # ScriptingMode setting was reported here originally and inflated the count,
    # sending the reader looking for a script that did not exist.
    foreach ($setName in 'WinScriptFiles', 'LinScriptFiles', 'JobLinScriptFiles', 'JobMacScriptFiles') {
        if (-not $gs.PSObject.Properties[$setName]) { continue }
        $set = $gs.$setName
        if (-not $set) { continue }
        foreach ($member in 'PreScriptFilePath', 'PostScriptFilePath') {
            if (-not $set.PSObject.Properties[$member]) { continue }
            $v = "$($set.$member)"
            if ($v -ne '') { $out += "${Label}: $setName.$member -> $v" }
        }
    }
    return $out
}

# A pre/post-job entry is a COMMAND LINE, not a path, so it can carry arguments -
# including a password. Return the executable only, and nothing at all when it
# cannot be separated confidently: the caller then reports that a command is set
# without echoing it.
function Get-PrecheckScriptPath {
    [CmdletBinding()] param([string] $CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $s = $CommandLine.Trim()

    if ($s.StartsWith('"')) {
        $end = $s.IndexOf('"', 1)
        if ($end -gt 1) { $s = $s.Substring(1, $end - 1) } else { return $null }
    }
    else {
        # Unquoted: only the first token can be the executable. An unquoted path
        # containing spaces is indistinguishable from a path plus arguments.
        $s = ($s -split '\s+', 2)[0]
        if ($s -notmatch '\.(cmd|bat|exe|ps1|vbs|js|sh|py)$') { return $null }
    }

    # An interpreter tells the operator nothing about which file to copy, and the
    # script itself is in the arguments we are deliberately discarding.
    if ([System.IO.Path]::GetFileNameWithoutExtension($s) -match '^(powershell|pwsh|cmd|cscript|wscript|python|perl|sh|bash)$') { return $null }
    return $s
}

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Checks/Test-PreMigration.ps1
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Checks/Test-Security.ps1
# -----------------------------------------------------------------------------
# Security / identity checks.
# KB4800: "Four-Eyes Authorization", "Credential Format Requirements"
# (UPN + no trusted-domain auth), and the repository access "SID not found" blocker.

function Test-FourEyes {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'SEC-001'; $cat = 'Security'; $title = 'Four-eyes authorization'

    # Permanently manual, not pending: no *foureyes*/*authoriz*/*approv* cmdlet
    # exists, and Get-VBRSecurityOptions covers only FIPS, Linux trusted hosts and
    # audit logs. Console path is Users & Roles > Authorization.
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
        -Detail 'Four-eyes authorization state is not exposed to PowerShell.' `
        -Recommendation 'Check it in the console under Users & Roles > Authorization tab. If it is enabled, plan to re-enable it on the Veeam Software Appliance after migration. This step cannot be automated and will need doing on every server.'
}

function Test-CredentialUpnFormat {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'SEC-002'; $cat = 'Security'
    $title = 'Credential format for Kerberos connections'

    # Reports candidates, prescribes nothing: one credential store feeds surfaces
    # with different documented requirements - vSphere hosts take MACHINE\USER or
    # DOMAIN\USER, while Kerberos paths (Windows server add, guest processing, agent
    # management) need user@fqdn or fqdn\user. Format alone cannot decide which a
    # given credential serves. See the SEC-002 note in docs/checks-reference.md.
    #
    # Excluded: non-Standard types (SSH, SSH key, Kasten token, Managed service
    # account); 'root' (Linux/ESXi/appliance, and VBR auto-creates several per
    # server); user@fqdn; and fqdn\user, which the Add Windows Server wizard accepts
    # alongside UPN. Note SEC-005 is stricter - console login takes UPN only.

    if (-not (Test-PrecheckCmdlet 'Get-VBRCredentials')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'Stored credentials could not be read on this server.' `
            -Recommendation 'Review manually: connections that authenticate with Kerberos - Windows servers added to the backup infrastructure, guest OS processing of Windows VMs, Windows agent management - need an Active Directory account in user@fqdn or fqdn\user form. Credentials used only for vSphere host connections take MACHINE\USER or DOMAIN\USER format and do not need changing.'
    }

    $candidates = @()
    $examined = 0
    $setAside = 0
    $acceptable = 0
    $readCreds = $false
    try {
        foreach ($c in Get-VBRCredentials -ErrorAction SilentlyContinue) {
            $u = [string]$c.Name
            if (-not $u) { continue }
            $examined++

            # Standard type only. Excludes SSH, SSH private key, Kasten auth token,
            # Managed Service Account, and anything new that appears later.
            $type = if ($c.PSObject.Properties['Type']) { [string]$c.Type } else { '' }
            if ($type -and $type -ne 'Standard') { $setAside++; continue }

            # Linux / appliance / ESXi root, incl. VBR's own auto-created records.
            if ($u -ieq 'root') { $setAside++; continue }

            # Already UPN-shaped (or an SSO/IdP suffix form) - not a candidate.
            if ($u -match '@') { $acceptable++; continue }

            # FQDN\user is an accepted Kerberos form alongside user@fqdn - the Add
            # Windows Server wizard asks for "USER@FQDN or FQDN\USER". A prefix
            # containing a dot is therefore already acceptable; a prefix without one
            # is a NetBIOS domain or a machine name, and neither can authenticate
            # with Kerberos.
            $prefix = if ($u -match '\\') { $u.Split('\')[0] } else { '' }
            if ($prefix -and $prefix.Contains('.')) { $acceptable++; continue }

            $shape = if ($prefix) { 'NetBIOS or machine prefix' } else { 'bare user name' }
            $desc  = if ($c.PSObject.Properties['Description']) { [string]$c.Description } else { '' }
            $candidates += "$u  [$shape]$(if ($desc) { "  - $desc" })"
        }
        $readCreds = $true
    } catch { }

    if ($candidates.Count -eq 0) {
        if (-not $readCreds) {
            return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
                -Detail 'The stored credentials on this server could not be enumerated, so their format was not checked.' `
                -Recommendation 'Review manually: connections that authenticate with Kerberos - Windows servers added to the backup infrastructure, guest OS processing of Windows VMs, Windows agent management - need an Active Directory account in user@fqdn or fqdn\user form.'
        }

        # Says which credentials were judged and which were deliberately not. Most
        # servers carry several records VBR created itself, so a bare "all clear"
        # hides whether anything was actually in scope.
        $detail = if ($examined -eq 0) {
            'The stored credential list on this server was read successfully and is empty.'
        }
        else {
            "$examined stored credential(s) were examined and none uses a NetBIOS domain prefix, a machine prefix, or a bare user name, so nothing needs review for Kerberos-authenticated connections." +
            "$(if ($acceptable) { " $acceptable are already in user@fqdn or fqdn\user form." })" +
            "$(if ($setAside)   { " $setAside were set aside as not applying to Kerberos paths (SSH, key, token or managed-service credentials, and 'root' accounts)." })"
        }
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass -Detail $detail
    }

    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
        -Detail "$($candidates.Count) credential(s) use a NetBIOS domain prefix, a machine prefix, or a bare user name. Connections that authenticate with Kerberos - Windows servers added to the backup infrastructure, guest OS processing of Windows VMs, and Windows agent management - need an Active Directory account in user@fqdn or fqdn\user form. A machine-local account cannot authenticate with Kerberos at all." `
        -Recommendation 'Review each credential below against where it is used. Where the connection authenticates with Kerberos, re-enter the account as user@fqdn or fqdn\user (a machine-local account must be replaced with a domain account). Credentials used only for vSphere host connections are documented as taking MACHINE\USER or DOMAIN\USER format and do not need changing.' `
        -Evidence ($candidates | Sort-Object -Unique)
}

function Test-RoleAssignmentUpnFormat {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'SEC-005'; $cat = 'Security'
    $title = 'Console role assignment format'

    # Console login accepts UPN ONLY - the appliance sign-in rejects any prefixed
    # form. This is deliberately STRICTER than SEC-002, where fqdn\user is also
    # accepted because the Add Windows Server wizard takes "USER@FQDN or FQDN\USER".
    # Do not harmonise the two.
    #
    # Action rather than Blocker: the appliance install creates veeamadmin, so access
    # is not lost, but these assignments stop working until re-created in UPN form,
    # which can be done before migrating.
    if (-not (Test-PrecheckCmdlet 'Get-VBRUserRoleAssignment')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'Console role assignments could not be read on this server.' `
            -Recommendation 'Console login on the Veeam Software Appliance requires UPN format (user@fqdn). Review Users & Roles and re-create any BUILTIN, local-machine or DOMAIN\user assignment in UPN form.'
    }

    # The target form differs by principal type, and naming the wrong one sends the
    # operator to do something that fails:
    #   domain USER  -> user@fqdn
    #   domain GROUP -> group@domain, e.g. Administrators@tech.local
    # (Veeam UG, Configuring Users and Roles: "To add a default domain security group,
    # use the group@domain format".) A group has no userPrincipalName in AD - this is
    # Veeam's input syntax for naming a group, not a real UPN - but the shape the
    # appliance wants is the same '@' form either way, so both are flagged the same;
    # only the remediation wording differs.
    # The target form differs by principal type, and naming the wrong one sends the
    # operator to do something that fails:
    #   domain USER  -> user@fqdn
    #   domain GROUP -> group@domain, e.g. Administrators@tech.local
    # (Veeam UG, Configuring Users and Roles: "To add a default domain security group,
    # use the group@domain format".) A group has no userPrincipalName in AD - this is
    # Veeam's input syntax for naming a group, not a real UPN - but the shape the
    # appliance wants is the same '@' form either way, so both are flagged the same;
    # only the remediation wording differs.
    #
    # OPEN QUESTION: whether a down-level DOMAIN\principal is in fact acceptable as a
    # stored ASSIGNMENT. The evidence for requiring '@' is the appliance SIGN-IN form
    # rejecting a non-UPN username, which constrains what a person types at login - not
    # necessarily the stored string, since VBR may match the two by SID. Until that is
    # confirmed this check reports the prefixed forms; do not narrow it on reasoning
    # alone.
    $bad = @()
    $ok  = 0
    try {
        foreach ($ra in Get-VBRUserRoleAssignment -ErrorAction SilentlyContinue) {
            $nm = [string]$ra.Name
            if (-not $nm) { continue }
            $role = if ($ra.PSObject.Properties['Role']) { [string]$ra.Role } else { '' }
            $type = if ($ra.PSObject.Properties['Type']) { [string]$ra.Type } else { '' }
            $isGroup = $type -ieq 'Group'
            $want = if ($isGroup) { 'group@domain' } else { 'user@fqdn' }

            if ($nm -match '@') { $ok++; continue }

            $prefix = if ($nm -match '\\') { $nm.Split('\')[0] } else { '' }
            $why =
                if (($prefix -match '^(BUILTIN|NT AUTHORITY)$') -or ($prefix -and ($prefix -ieq $env:COMPUTERNAME))) {
                    "local or builtin principal - has no counterpart on a Linux appliance; add the equivalent DOMAIN principal as $want"
                } elseif ($prefix) {
                    "prefixed form - the appliance needs $want"
                } else {
                    "unqualified name - the appliance needs $want"
                }
            $bad += "$nm  [$(if ($type) { $type } else { 'type not reported' }), role: $role]  -> $why"
        }
    } catch { }

    if ($bad.Count -eq 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail "All $ok console role assignment(s) already use the domain form the appliance requires (user@fqdn for a user, group@domain for a group)."
    }

    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Action `
        -Detail "$($bad.Count) console role assignment(s) are not in the form the Veeam Software Appliance requires, so they will not work after migration. Access is not lost outright - the appliance install creates a veeamadmin account - but the administrators listed below will be unable to log in until their assignments are re-created." `
        -Recommendation 'Before migrating, re-create each assignment below in the appliance form: a domain USER as user@fqdn, a domain SECURITY GROUP as group@domain (for example Administrators@tech.local). Local and builtin principals have no counterpart on the appliance, so assign a domain principal instead. The sign-in page rejects a non-UPN username with: "Specify a username in the UPN format (username@domain.com)."' `
        -Evidence ($bad | Sort-Object -Unique)
}

function Test-TrustedDomainAuth {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'SEC-003'; $cat = 'Security'; $title = 'Trusted-domain authentication'

    # Not derivable from cmdlets - guided manual check.
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
        -Detail 'The Veeam Software Appliance does not support trusted-domain authentication.' `
        -Recommendation 'Confirm no credentials/servers authenticate across a domain trust (accounts from a trusted, non-primary domain). Such access must be reworked before migration.'
}

function Test-RepositoryLocalAccounts {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'SEC-004'; $cat = 'Security'; $title = 'Repository access accounts'

    # Get-VBREPPermission -Repository <repo> -> .Users lists the granted accounts
    # (covers Veeam Agent / Plug-in standalone targets).
    if (-not (Test-PrecheckCmdlet 'Get-VBRBackupRepository')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'Repository details could not be read on this server.' `
            -Recommendation 'Remove all local (non-domain) account entries from repository access permissions to avoid "SID not found" errors during migration.'
    }
    if (-not (Test-PrecheckCmdlet 'Get-VBREPPermission')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'Repository access permissions could not be read on this server.' `
            -Recommendation 'Manually remove all local (non-domain) account entries from every repository access permission list before migration ("SID not found" risk).'
    }

    # This server's own identity, resolved once. Needed to tell a MACHINE\user
    # prefix from this server's own NetBIOS DOMAIN\user prefix - both are a bare
    # label with no dot, and only the first one breaks on the appliance.
    $me = $env:COMPUTERNAME
    $domainLabels = [System.Collections.Generic.List[string]]::new()
    try {
        $cs = Get-PrecheckCached -Key 'ComputerSystem' -Getter { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
        if ($cs.PartOfDomain -and $cs.Domain) { $domainLabels.Add($cs.Domain); $domainLabels.Add(($cs.Domain -split '\.')[0]) }
    } catch { }
    foreach ($v in $env:USERDOMAIN, $env:USERDNSDOMAIN) {
        if ($v) { $domainLabels.Add($v); $domainLabels.Add(($v -split '\.')[0]) }
    }
    $domains = @($domainLabels | Where-Object { $_ } | Sort-Object -Unique)

    # Counted so a Pass can say what it evaluated. A Pass with no numbers reads the
    # same whether it inspected every account and found them all clean or inspected
    # nothing at all - which is how an earlier version of this check reporting a
    # non-existent property went unnoticed.
    $repoCount = 0; $acctCount = 0
    $local = @(); $review = @(); $sawUsers = $false; $sawPerm = $false
    try {
        foreach ($repo in Get-VBRBackupRepository -ErrorAction SilentlyContinue) {
            $repoCount++
            $perm = Get-VBREPPermission -Repository $repo -ErrorAction SilentlyContinue
            if (-not $perm) { continue }
            $sawPerm = $true
            # VBREPPermission carries Users (string[]), not Accounts. An earlier
            # version read .Accounts, which does not exist on the object - so the
            # list was always empty and the check could only ever return Pass.
            if (-not $perm.PSObject.Properties['Users']) { continue }
            $sawUsers = $true

            # A repository hosted on another managed server can be granted a local
            # account of THAT machine, so its short name counts as local too.
            $hostShort = ''
            try { $hostShort = ("$($repo.Host.Name)" -split '\.')[0] } catch { }

            foreach ($u in @($perm.Users)) {
                $name = "$u".Trim()
                if ($name -eq '') { continue }
                $acctCount++
                if ($name -notmatch '\\') {
                    if ($name -match '@') { continue }   # UPN - a domain account
                    $review += "$($repo.Name): $name  [bare name - cannot tell local from domain]"
                    continue
                }
                $prefix = $name.Split('\')[0]
                if ($prefix -eq '.' -or $prefix -ieq 'BUILTIN' -or $prefix -ieq 'NT AUTHORITY' -or
                    $prefix -ieq $me -or ($hostShort -and $prefix -ieq $hostShort)) {
                    $local += "$($repo.Name): $name  [machine-local account]"
                }
                elseif ($prefix -match '\.' -or $domains -contains $prefix) { continue }  # domain account
                else { $review += "$($repo.Name): $name  [cannot tell machine-local from domain]" }
            }
        }
    } catch { }

    if ($local.Count -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Action `
            -Detail "$($local.Count) machine-local account(s) are granted access to a repository. Their SIDs do not exist on the Veeam Software Appliance, so migration reports 'SID not found'." `
            -Recommendation 'Remove these machine-local accounts from the repository access permissions before migrating, replacing them with domain accounts where the access is still needed.' `
            -Evidence (@($local) + @($review) | Sort-Object -Unique)
    }
    if ($review.Count -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "$($review.Count) repository access account(s) could not be classified as local or domain from the name alone." `
            -Recommendation 'Confirm each account below is a domain account. A machine-local account must be removed before migrating - its SID does not exist on the appliance and migration reports "SID not found".' `
            -Evidence ($review | Sort-Object -Unique)
    }
    if ($sawPerm -and -not $sawUsers) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail 'Repository access permissions were returned but carried no account list in the expected form, so they were not evaluated.' `
            -Recommendation 'Check each repository''s access permissions by hand and remove any machine-local accounts before migrating ("SID not found" risk).'
    }
    $detail = if ($acctCount -gt 0) {
        "No machine-local accounts are granted access to any repository. $acctCount account entry/entries across $repoCount repository/repositories were evaluated, and all are domain accounts."
    } else {
        "No machine-local accounts are granted access to any repository. $repoCount repository/repositories were checked and none grants access to a named account."
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass -Detail $detail
}

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Checks/Test-Storage.ps1
# -----------------------------------------------------------------------------
# Storage-integration checks.
# KB4800: "Storage System Limitations" (NetApp ONTAP roles, HPE Nimble/Alletra
# FIPS, plug-in version requirements post-migration).
#
# NOTE: storage-system cmdlets have NO 'VBR' prefix (verified against the A-Z
# reference in docs/reference/vbr-v13-cmdlets.md):
#   NetApp ONTAP ............. Get-NetAppHost
#   HPE Nimble / Alletra 5/6k  Get-NimbleHost
#   Universal Storage Plugin . Get-StoragePluginHost  (IBM FlashSystem, Hitachi,
#                              HPE XP, Fujitsu, etc.)
#   HPE 3PAR/Primera ......... Get-HP3Storage
#   Dell VNX ................. Get-VNXHost
#   Cisco HyperFlex .......... Get-HyperFlexHost
#   Lenovo ThinkSystem ....... Get-ThinkSystemHost

function Test-NetAppOntapRole {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'STG-001'; $cat = 'Storage'; $title = 'NetApp ONTAP role'

    if (-not (Test-PrecheckCmdlet 'Get-NetAppHost')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail 'NetApp ONTAP integration could not be checked on this server.' `
            -Recommendation 'If NetApp ONTAP is integrated, confirm it is used ONLY in the NAS filer role - other roles cannot migrate to the VSA.'
    }

    $hosts = @(Get-NetAppHost -ErrorAction SilentlyContinue)
    if ($hosts.Count -eq 0) {
        # Says the inventory was read and was empty. A bare "none found" reads the
        # same whether it looked and found nothing or never looked at all.
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail 'The storage inventory on this server was read successfully and contains no NetApp ONTAP systems, so no ONTAP role needs review.'
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Warning `
        -Detail "$($hosts.Count) NetApp ONTAP system(s) integrated. Only the NAS filer role is supported on the Veeam Software Appliance; other roles cannot migrate." `
        -Recommendation 'Confirm each NetApp ONTAP system is used only in the NAS filer role. Any other storage-snapshot role will not migrate.' `
        -Evidence ($hosts | ForEach-Object { "NetApp: $($_.Name)" })
}

function Test-StoragePluginVersions {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'STG-002'; $cat = 'Storage'; $title = 'Universal Storage Plugin versions'

    # IBM FlashSystem, Hitachi and HPE XP all integrate via the Universal Storage
    # Plugin -> Get-StoragePluginHost. The cmdlet doesn't split by vendor, so we
    # report presence and the post-migration minimum plug-in versions from KB4800.
    if (-not (Test-PrecheckCmdlet 'Get-StoragePluginHost')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail 'Universal Storage Plugin integration could not be checked on this server.' `
            -Recommendation 'If IBM FlashSystem / Hitachi / HPE XP are integrated, ensure post-migration plug-in versions: IBM FlashSystem >= 2.3.80; Hitachi >= 2.2.271; HPE XP >= 2.2.271.'
    }

    $hosts = @(Get-PrecheckCached -Key 'StoragePluginHosts' -Getter { Get-StoragePluginHost -ErrorAction SilentlyContinue })
    if ($hosts.Count -eq 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail 'The Universal Storage Plugin inventory on this server was read successfully and contains no systems, so no IBM FlashSystem, Hitachi or HPE XP plug-in version applies.'
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
        -Detail "$($hosts.Count) Universal Storage Plugin system(s) detected. These have minimum plug-in versions on the VSA." `
        -Recommendation 'After migration ensure: IBM FlashSystem plug-in >= 2.3.80; Hitachi plug-in >= 2.2.271; HPE XP plug-in >= 2.2.271.' `
        -Evidence ($hosts | ForEach-Object { "Storage plugin host: $($_.Name)" })
}

function Test-NimbleFips {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'STG-003'; $cat = 'Storage'; $title = 'HPE Nimble / Alletra FIPS support'

    if (-not (Test-PrecheckCmdlet 'Get-NimbleHost')) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail 'HPE Nimble / Alletra integration could not be checked on this server.' `
            -Recommendation 'If HPE Nimble/Alletra 5000/6000 is integrated, verify the Nimble OS version is supported when the VSA runs in FIPS-compliant mode.'
    }

    $hosts = @(Get-NimbleHost -ErrorAction SilentlyContinue)
    if ($hosts.Count -eq 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail 'The storage inventory on this server was read successfully and contains no HPE Nimble or Alletra 5000/6000 systems, so FIPS-mode OS support does not need review.'
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Warning `
        -Detail "$($hosts.Count) HPE Nimble/Alletra system(s) detected. Some Nimble OS versions may be unsupported when the Veeam Software Appliance runs in FIPS-compliant mode." `
        -Recommendation 'Verify Nimble OS version support against FIPS mode before migrating (or before enabling FIPS on the VSA).' `
        -Evidence ($hosts | ForEach-Object { "Storage: $($_.Name)" })
}

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Public/Connect-VbrPrecheck.ps1
# -----------------------------------------------------------------------------
# Connect-VbrPrecheck
# Loads the Veeam.Backup.PowerShell module and opens a session to the Windows
# VBR server being evaluated for migration. Returns a lightweight context object
# that Invoke-VbrMigrationPrecheck passes to every check.
#
# Design notes:
#  * Runs best ON the VBR server itself (default -Server localhost) - the richest
#    and most reliable place to read configuration. Remote works too if the
#    console/module is installed locally and the account can authenticate.
#  * v13's module requires PowerShell 7.0+. PowerShell 5.1 / ISE will fail to
#    import Veeam.Backup.PowerShell - we fail fast with a clear message.
#  * Connect-VBRServer against a Windows VBR uses the classic path (no port
#    switch needed). This tool targets the WINDOWS source server, NOT the VSA
#    appliance - do not point it at a v13 appliance (that would need :443 Identity
#    service and is not the object of the precheck).

function Connect-VbrPrecheck {
    [CmdletBinding()]
    param(
        [string] $Server = 'localhost',
        [PSCredential] $Credential
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "PowerShell 7.0+ is required (Veeam.Backup.PowerShell will not load under $($PSVersionTable.PSVersion)). Run this from 'pwsh', not Windows PowerShell / ISE."
    }

    Write-PrecheckLog "Importing Veeam.Backup.PowerShell module..." -Level STEP
    try {
        Import-Module Veeam.Backup.PowerShell -DisableNameChecking -ErrorAction Stop -Verbose:$false
    }
    catch {
        throw "Could not import Veeam.Backup.PowerShell. Run this on a machine with the VBR v13 console/module installed. Original error: $($_.Exception.Message)"
    }

    # Reuse an existing session if there is one. The Veeam PowerShell Toolkit opens
    # a session on launch, so connecting again would be redundant - and worse, the
    # caller would then disconnect at the end and drop the session the operator was
    # working in. OpenedSession records who owns it.
    $existing = $null
    if (Test-PrecheckCmdlet 'Get-VBRServerSession') {
        try { $existing = Get-VBRServerSession -ErrorAction SilentlyContinue } catch { }
    }

    $openedSession = $false
    if ($existing) {
        $connectedTo = if ($existing.PSObject.Properties['Server'] -and $existing.Server) { "$($existing.Server)" } else { $Server }
        Write-PrecheckLog "Reusing the existing VBR session ($connectedTo) - not connecting or disconnecting." -Level INFO
    }
    else {
        Write-PrecheckLog "Connecting to VBR server '$Server'..." -Level STEP
        $connectArgs = @{ Server = $Server; ErrorAction = 'Stop' }
        if ($Credential) { $connectArgs.Credential = $Credential }
        try {
            Connect-VBRServer @connectArgs | Out-Null
            $openedSession = $true
        }
        catch {
            # Connect-VBRServer is fatal when a session already exists ("You are
            # already connected to <server>. Close previous session first"). Treat
            # that as success and reuse it - the detection above cannot be relied on
            # alone, since Get-VBRServerSession may be missing or return nothing.
            if ($_.Exception.Message -match 'already connected') {
                Write-PrecheckLog "Already connected - reusing the existing session." -Level INFO
            }
            else { throw }
        }
    }

    # Capture whatever product version we can resolve up front so the version
    # check and the report header can reuse it.
    $version = Get-VbrProductVersion

    $ctx = [PSCustomObject]@{
        Server        = $Server
        ConnectedAt   = Get-Date
        ProductBuild  = $version.Build
        ProductString = $version.DisplayName
        PSVersion     = $PSVersionTable.PSVersion.ToString()
        OpenedSession = $openedSession
    }

    Write-PrecheckLog "Connected. Detected VBR build: $($version.DisplayName)" -Level INFO
    return $ctx
}

# Disconnect-VbrPrecheck - convenience wrapper so callers/tests do not have to
# remember the Veeam verb.
function Disconnect-VbrPrecheck {
    [CmdletBinding()]
    param()
    if (Test-PrecheckCmdlet 'Disconnect-VBRServer') {
        try { Disconnect-VBRServer -ErrorAction SilentlyContinue } catch { }
    }
}

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Public/Export-PrecheckReport.ps1
# -----------------------------------------------------------------------------
# Export-PrecheckReport
# Writes the precheck results to disk as JSON (machine-readable, feeds the
# migration runbook / ticketing) or a self-contained HTML page (share with the
# customer / account team). No external assets - safe to email.

function Export-PrecheckReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Results,
        [Parameter(Mandatory)] $Verdict,
        $Context,
        [ValidateSet('Json', 'Html')]
        [string] $Format = 'Json',
        [Parameter(Mandatory)] [string] $Path
    )

    $generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')

    if ($Format -eq 'Json') {
        $payload = [PSCustomObject]@{
            tool          = 'VbrMigrationPrecheck'
            # Version matters most here: JSON is what aggregates across a fleet, and
            # a phased migration means reports arrive from several tool builds.
            toolVersion   = if ($script:PrecheckVersion) { $script:PrecheckVersion } else { 'unknown' }
            kb            = 'https://www.veeam.com/kb4800'
            # KB4800 is a living document; record when it was mapped to these checks.
            kbCaptured    = if ($script:PrecheckKbCaptured) { $script:PrecheckKbCaptured } else { 'unknown' }
            generatedAt   = $generated
            server        = if ($Context) { $Context.Server } else { $null }
            productBuild  = if ($Context) { $Context.ProductString } else { $null }
            verdict       = $Verdict.Label
            exitCode      = $Verdict.ExitCode
            counts        = $Verdict.Counts
            results       = $Results
        }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
        return $Path
    }

    # --- HTML -----------------------------------------------------------------
    $enc = { param($s) if ($null -eq $s) { '' } else { [System.Net.WebUtility]::HtmlEncode([string]$s) } }

    $badge = @{
        Blocker = '#c0392b'; Action = '#8e44ad'; Warning = '#d68910'
        Manual  = '#2980b9'; NextStep = '#1f6feb'; Info = '#7f8c8d'; Pass = '#27ae60'; Skipped = '#95a5a6'
    }
    $verdictColor = switch ($Verdict.Label) {
        'MIGRATION BLOCKED' { '#c0392b' }
        'ACTION REQUIRED'   { '#8e44ad' }
        'REVIEW WARNINGS'   { '#d68910' }
        default             { '#27ae60' }
    }

    $limitationResults = $Results | Where-Object { $_.Status -ne 'NextStep' }
    $nextSteps         = @($Results | Where-Object { $_.Status -eq 'NextStep' } | Sort-Object Id)

    $rows = foreach ($r in ($limitationResults | Sort-Object -Property @{E = 'Rank'; Descending = $true}, Id)) {
        $ev = ''
        if ($r.Evidence -and $r.Evidence.Count -gt 0) {
            $items = ($r.Evidence | ForEach-Object { "<li>$(& $enc $_)</li>" }) -join ''
            $ev = "<ul class='ev'>$items</ul>"
        }
        $color = $badge[$r.Status]
@"
<tr>
  <td><span class="pill" style="background:$color">$(& $enc $r.Status)</span></td>
  <td class="mono">$(& $enc $r.Id)</td>
  <td>
    <div class="title">$(& $enc $r.Title)</div>
    <div class="detail">$(& $enc $r.Detail)</div>
    $(if ($r.Recommendation) { "<div class='rec'>&#8594; $(& $enc $r.Recommendation)</div>" })
    $ev
  </td>
  <td class="cat">$(& $enc $r.Category)</td>
</tr>
"@
    }

    # Pre-migration next steps block (only rendered when any apply).
    $nextStepsHtml = ''
    if ($nextSteps.Count -gt 0) {
        $nsItems = foreach ($r in $nextSteps) {
            $ev = ''
            if ($r.Evidence -and $r.Evidence.Count -gt 0) {
                $items = ($r.Evidence | ForEach-Object { "<li>$(& $enc $_)</li>" }) -join ''
                $ev = "<ul class='ev'>$items</ul>"
            }
@"
<li class="nsitem">
  <div class="title"><span class="mono">$(& $enc $r.Id)</span> &nbsp; $(& $enc $r.Title)</div>
  <div class="detail">$(& $enc $r.Detail)</div>
  $(if ($r.Recommendation) { "<div class='rec'>&#8594; $(& $enc $r.Recommendation)</div>" })
  $ev
</li>
"@
        }
        $nextStepsHtml = @"
  <div class="nextsteps">
    <h2>Pre-Migration Next Steps ($($nextSteps.Count))</h2>
    <p class="nsintro">KB4800 preparation actions that apply to this environment &mdash; complete these before starting the migration.</p>
    <ul class="nslist">
      $($nsItems -join "`n")
    </ul>
  </div>
"@
    }

    $c = $Verdict.Counts
    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>VBR to VSA Migration Precheck</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif; margin: 0; background:#f4f6f8; color:#1c2833; }
  @media (prefers-color-scheme: dark){ body{ background:#12171d; color:#e6eaee } .card,.legend,table{ background:#1b222b !important } td,th{ border-color:#2b333d !important } .detail{ color:#9aa7b4 !important } }
  header { background:#0b3d5c; color:#fff; padding:22px 28px; }
  header h1 { margin:0 0 4px; font-size:20px; }
  header .meta { font-size:13px; opacity:.85 }
  .wrap { max-width:1100px; margin:0 auto; padding:20px 28px 60px; }
  .verdict { display:inline-block; padding:10px 18px; border-radius:8px; color:#fff; font-weight:700; font-size:18px; background:$verdictColor; margin:18px 0 8px; }
  .counts { font-size:13px; color:#566573; margin-bottom:18px; }
  .nextsteps { margin-top:26px; border:1px solid #1f6feb; border-radius:10px; padding:6px 20px 14px; background:#eef4ff; }
  @media (prefers-color-scheme: dark){ .nextsteps{ background:#12203a !important; border-color:#1f6feb } }
  .nextsteps h2 { font-size:16px; color:#1f6feb; margin:14px 0 2px; }
  .nsintro { font-size:13px; color:#566573; margin:0 0 8px; }
  .nslist { list-style:none; margin:0; padding:0; }
  .nsitem { padding:10px 0; border-top:1px solid #d5e2fb; }
  .nsitem:first-child { border-top:none; }
  .card { background:#fff; border-radius:10px; box-shadow:0 1px 3px rgba(0,0,0,.12); overflow:hidden; }
  table { width:100%; border-collapse:collapse; background:#fff; }
  th,td { text-align:left; padding:11px 14px; border-bottom:1px solid #e5e9ed; vertical-align:top; font-size:14px; }
  th { background:#eef2f5; font-size:12px; text-transform:uppercase; letter-spacing:.04em; color:#566573; }
  .pill { color:#fff; padding:3px 9px; border-radius:20px; font-size:11px; font-weight:700; letter-spacing:.03em; white-space:nowrap; }
  .mono { font-family:ui-monospace, Menlo, Consolas, monospace; font-size:12px; color:#566573; white-space:nowrap; }
  .title { font-weight:600; }
  .detail { color:#566573; margin-top:3px; }
  .rec { margin-top:5px; color:#0b6; font-weight:600; }
  .ev { margin:6px 0 0; padding-left:18px; color:#7f8c8d; font-size:13px; }
  .cat { color:#7f8c8d; font-size:13px; white-space:nowrap; }
  footer { max-width:1100px; margin:0 auto; padding:0 28px 40px; color:#7f8c8d; font-size:12px; }
</style></head>
<body>
<header>
  <h1>Windows VBR &#8594; Veeam Software Appliance &mdash; Migration Precheck</h1>
  <div class="meta">Server: $(& $enc ($(if ($Context) { $Context.Server } else { 'n/a' }))) &nbsp;|&nbsp;
    Build: $(& $enc ($(if ($Context) { $Context.ProductString } else { 'n/a' }))) &nbsp;|&nbsp;
    Generated: $(& $enc $generated) &nbsp;|&nbsp;
    Precheck version: $(& $enc $(if ($script:PrecheckVersion) { $script:PrecheckVersion } else { 'unknown' })) &nbsp;|&nbsp;
    Reference: KB4800 (captured $(& $enc $(if ($script:PrecheckKbCaptured) { $script:PrecheckKbCaptured } else { 'unknown' })))</div>
</header>
<div class="wrap">
  <div class="verdict">$(& $enc $Verdict.Label)</div>
  <div class="counts">$($Verdict.Total) checks &nbsp;&bull;&nbsp; Blocker $($c.Blocker) &nbsp;&bull;&nbsp; Action $($c.Action) &nbsp;&bull;&nbsp; Warning $($c.Warning) &nbsp;&bull;&nbsp; Manual $($c.Manual) &nbsp;&bull;&nbsp; NextStep $($c.NextStep) &nbsp;&bull;&nbsp; Info $($c.Info) &nbsp;&bull;&nbsp; Pass $($c.Pass) &nbsp;&bull;&nbsp; Skipped $($c.Skipped)</div>
  <div class="card">
    <table>
      <thead><tr><th>Status</th><th>ID</th><th>Check</th><th>Category</th></tr></thead>
      <tbody>
        $($rows -join "`n")
      </tbody>
    </table>
  </div>
$nextStepsHtml
</div>
<footer>
  Generated by VbrMigrationPrecheck. This report evaluates the known limitations in Veeam KB4800 and is provided as guidance;
  it does not guarantee migration success. Verify Info/Manual items by hand.
</footer>
</body></html>
"@

    $html | Set-Content -Path $Path -Encoding UTF8
    return $Path
}

# -----------------------------------------------------------------------------
# VbrMigrationPrecheck/Public/Invoke-VbrMigrationPrecheck.ps1
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Entry logic (from Run-Precheck.ps1)
# -----------------------------------------------------------------------------

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

