#Requires -Version 7.0
<#
    One test per defect found in the lab. Each was a plausible-looking member name or
    match that returned nothing, so the check reported a confident clean result. None
    was a crash. These exist so a future edit cannot quietly restore them.

    Stubs are declared once and read from $global:Mock*, so every Veeam cmdlet the
    checks probe exists for the whole run and Test-PrecheckCmdlet's memoised lookup
    stays consistent. The per-run data cache is cleared between tests.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'VbrMigrationPrecheck') -Force
    $script:Mod = Get-Module VbrMigrationPrecheck
    $script:Ctx = [pscustomobject]@{ Server = 'localhost' }

    $global:MockAgents      = @()
    $global:MockPolicies    = @()
    $global:MockGroups      = @()
    $global:MockRepos       = @()
    $global:MockPerms       = @{}
    $global:MockRoles       = @()
    $global:MockJobs        = @()
    $global:MockJobObjects  = @()
    $global:MockAppGroups   = @()
    $global:MockGcpAccounts = @()
    $global:MockGcpCompute  = @()
    $global:MockCdp         = @()
    $global:MockTenants     = @()
    $global:MockNetApp      = @()
    $global:MockPluginHosts = @()
    $global:MockNimble      = @()
    $global:MockCreds       = @()
    $global:MockLicense     = $null
    $global:MockHistory     = $null
    $global:MockSecurityOptions = $null
    $global:MockCloudTenants  = @()
    $global:MockCloudGateways = @()

    # Cmdlets named here throw instead of returning data. That is how an unreadable
    # collection actually presents in the field - a licence-dependent cmdlet (see
    # DEP-001, where the Cloud Connect cmdlets throw without a provider licence) or a
    # permissions failure - and it is distinct from the cmdlet being absent. Several
    # checks used to fall through the resulting empty collection into a clean result.
    $global:MockThrow = @()

    function global:Assert-MockOk {
        param([string] $Name)
        if ($global:MockThrow -contains $Name) { throw "simulated failure reading $Name" }
    }

    function global:Get-VBRDiscoveredComputer      { param($ErrorAction) $global:MockAgents }
    function global:Get-VBRComputerBackupJob       { param($ErrorAction) Assert-MockOk 'Get-VBRComputerBackupJob'; $global:MockPolicies }
    function global:Get-VBRProtectionGroup         { param($ErrorAction) Assert-MockOk 'Get-VBRProtectionGroup'; $global:MockGroups }
    function global:Get-VBRCDPPolicy               { param($ErrorAction) Assert-MockOk 'Get-VBRCDPPolicy'; $global:MockCdp }
    function global:Get-VBREntraIDTenant           { param($ErrorAction) Assert-MockOk 'Get-VBREntraIDTenant'; $global:MockTenants }
    function global:Get-NetAppHost                 { param($ErrorAction) Assert-MockOk 'Get-NetAppHost'; $global:MockNetApp }
    function global:Get-StoragePluginHost          { param($ErrorAction) Assert-MockOk 'Get-StoragePluginHost'; $global:MockPluginHosts }
    function global:Get-NimbleHost                 { param($ErrorAction) Assert-MockOk 'Get-NimbleHost'; $global:MockNimble }
    function global:Get-VBRCredentials             { param($ErrorAction) Assert-MockOk 'Get-VBRCredentials'; $global:MockCreds }
    function global:Get-VBRInstalledLicense       { param($ErrorAction) Assert-MockOk 'Get-VBRInstalledLicense'; $global:MockLicense }
    function global:Get-VBRHistoryOptions        { param($ErrorAction) Assert-MockOk 'Get-VBRHistoryOptions'; $global:MockHistory }
    function global:Get-VBRSecurityOptions       { param($ErrorAction) Assert-MockOk 'Get-VBRSecurityOptions'; $global:MockSecurityOptions }
    # DB-001 reads the retention SETTING, never the sessions. This stub fails loudly if
    # anything reaches for the sessions again: the cmdlet has no date filter and no
    # ordering, so touching it materialises every session on the server - the original
    # fleet-scale cost this check was rewritten to avoid.
    function global:Get-VBRBackupSession {
        param($ErrorAction)
        throw 'Get-VBRBackupSession must never be called: it has no date filter or ordering, so reading it loads every session on the server.'
    }
    function global:Get-VBRCloudTenant            { param($ErrorAction) Assert-MockOk 'Get-VBRCloudTenant'; $global:MockCloudTenants }
    function global:Get-VBRCloudGateway           { param($ErrorAction) Assert-MockOk 'Get-VBRCloudGateway'; $global:MockCloudGateways }
    function global:Get-VBRBackupRepository        { param($ErrorAction) $global:MockRepos }
    function global:Get-VBRUserRoleAssignment      { param($ErrorAction) $global:MockRoles }
    function global:Get-VBRJob                     { param($ErrorAction) $global:MockJobs }
    function global:Get-VBRJobObject               { param($Job, $ErrorAction) $global:MockJobObjects }
    function global:Get-VBRApplicationGroup        { param($ErrorAction) Assert-MockOk 'Get-VBRApplicationGroup'; $global:MockAppGroups }
    function global:Get-VBRGoogleCloudAccount      { param($ErrorAction) $global:MockGcpAccounts }
    function global:Get-VBRGoogleCloudComputeAccount { param($ErrorAction) $global:MockGcpCompute }
    function global:Get-VBREPPermission {
        param($Repository, $ErrorAction)
        $key = "$($Repository.Name)"
        if ($global:MockPerms.ContainsKey($key)) {
            [pscustomobject]@{ PermissionType = 'OnlySelectedUsers'; Users = $global:MockPerms[$key] }
        }
    }
    function global:Get-CimInstance {
        param($ClassName, $ErrorAction)
        [pscustomobject]@{ PartOfDomain = $true; Domain = 'corp.local' }
    }

    function Invoke-Check {
        param([string] $Name)
        & $script:Mod ([scriptblock]::Create("param(`$c) $Name -Ctx `$c")) $script:Ctx
    }

    # Defined here rather than at file scope: Pester 6 does not make root-level
    # functions visible inside Describe blocks.
    function Reset-MockState {
        & $script:Mod { Clear-PrecheckCache }
        $env:COMPUTERNAME = 'BACKUP01'
        $global:MockAgents = @(); $global:MockPolicies = @(); $global:MockGroups = @()
        $global:MockRepos = @(); $global:MockPerms = @{}; $global:MockRoles = @()
        $global:MockJobs = @(); $global:MockJobObjects = @(); $global:MockAppGroups = @()
        $global:MockGcpAccounts = @(); $global:MockGcpCompute = @()
        $global:MockCdp = @(); $global:MockTenants = @(); $global:MockNetApp = @()
        $global:MockPluginHosts = @(); $global:MockNimble = @(); $global:MockCreds = @()
        $global:MockThrow = @()
        $global:MockLicense = $null; $global:MockHistory = $null; $global:MockSecurityOptions = $null
        $global:MockCloudTenants = @(); $global:MockCloudGateways = @()
    }

    # DB-001 is the only check taking a parameter beyond -Ctx, so it needs its own invoker.
    function Invoke-DbCheck {
        param($UpgradeDate)
        if ($null -eq $UpgradeDate) {
            & $script:Mod ([scriptblock]::Create('param($c) Test-SessionHistoryAge -Ctx $c')) $script:Ctx
        } else {
            & $script:Mod ([scriptblock]::Create('param($c,$d) Test-SessionHistoryAge -Ctx $c -UpgradeDate $d')) $script:Ctx $UpgradeDate
        }
    }
}

Describe 'AGT-002 disabled agent policies' {
    BeforeEach { Reset-MockState }

    # The property is JobEnabled. IsEnabled does not exist on VBRComputerBackupJob,
    # so filtering on it matched nothing and the check passed on every server.
    It 'flags a policy whose JobEnabled is false' {
        $global:MockPolicies = @(
            [pscustomobject]@{ Name = 'Live';     JobEnabled = $true;  ScheduleEnabled = $true;  Mode = 'ManagedByAgent';        BackupObject = 'PG' }
            [pscustomobject]@{ Name = 'Disabled'; JobEnabled = $false; ScheduleEnabled = $true;  Mode = 'ManagedByAgent';        BackupObject = 'PG' }
        )
        $r = Invoke-Check 'Test-AgentDisabledPolicies'
        $r.Status | Should -Be 'Action'
        ($r.Evidence -join ';') | Should -Match 'Disabled'
        ($r.Evidence -join ';') | Should -Not -Match 'Live'
    }

    # ScheduleEnabled is a DIFFERENT property. A policy can be enabled with no
    # schedule; any fuzzy match on "Enabled" flags a working policy.
    It 'does not flag an enabled policy that merely has no schedule' {
        $global:MockPolicies = @(
            [pscustomobject]@{ Name = 'NoSchedule'; JobEnabled = $true; ScheduleEnabled = $false; Mode = 'ManagedByBackupServer'; BackupObject = 'PG' }
        )
        (Invoke-Check 'Test-AgentDisabledPolicies').Status | Should -Be 'Pass'
    }

    It 'reports Info rather than Pass when the enabled state cannot be read' {
        $global:MockPolicies = @([pscustomobject]@{ Name = 'Legacy'; Mode = 'ManagedByAgent' })
        (Invoke-Check 'Test-AgentDisabledPolicies').Status | Should -Be 'Info'
    }

    It 'states how many policies it evaluated when reporting a Pass' {
        $global:MockPolicies = @(
            [pscustomobject]@{ Name = 'A'; JobEnabled = $true; ScheduleEnabled = $true; Mode = 'ManagedByAgent'; BackupObject = 'PG' }
            [pscustomobject]@{ Name = 'B'; JobEnabled = $true; ScheduleEnabled = $true; Mode = 'ManagedByAgent'; BackupObject = 'PG' }
        )
        (Invoke-Check 'Test-AgentDisabledPolicies').Detail | Should -Match '2 polic'
    }
}

Describe 'AGT-004 protection group kinds' {
    BeforeEach { Reset-MockState }

    # The kind is Container.Type, not the group's own Type (which only holds
    # Custom / ManuallyAdded), so the pre-installed finding was unreachable.
    It 'counts a ManuallyDeployed container as pre-installed agents' {
        $global:MockGroups = @(
            [pscustomobject]@{ Name = 'PG-Individual';  Type = 'Custom'; Container = [pscustomobject]@{ Type = 'IndividualComputers' } }
            [pscustomobject]@{ Name = 'PG-PreInstall'; Type = 'Custom'; Container = [pscustomobject]@{ Type = 'ManuallyDeployed' } }
        )
        $r = Invoke-Check 'Test-ProtectionGroupPostMigration'
        $r.Detail | Should -Match '1 group\(s\) appear to use Computers with Pre-installed'
        ($r.Evidence -join ';') | Should -Match 'PG-PreInstall.*ManuallyDeployed'
    }

    # ManuallyDeployed (container) and ManuallyAdded (group type) both contain
    # "Manual". A substring match flagged the built-in group on every server.
    It 'does not flag the built-in ManuallyAdded group' {
        $global:MockGroups = @(
            [pscustomobject]@{ Name = 'Manually Added'; Type = 'ManuallyAdded'; Container = [pscustomobject]@{ Type = 'IndividualComputers' } }
        )
        (Invoke-Check 'Test-ProtectionGroupPostMigration').Detail |
            Should -Not -Match 'Pre-installed'
    }

    It 'does not flag any other container type' {
        $global:MockGroups = @('IndividualComputers', 'ActiveDirectory', 'CSV', 'CloudMachines', 'MongoDBComputers' |
            ForEach-Object { [pscustomobject]@{ Name = "PG-$_"; Type = 'Custom'; Container = [pscustomobject]@{ Type = $_ } } })
        (Invoke-Check 'Test-ProtectionGroupPostMigration').Detail |
            Should -Not -Match 'Pre-installed'
    }

    It 'says so when a group kind cannot be read' {
        $global:MockGroups = @([pscustomobject]@{ Name = 'Odd'; Type = 'Custom'; Container = $null })
        (Invoke-Check 'Test-ProtectionGroupPostMigration').Evidence -join ';' |
            Should -Match 'could not be read'
    }
}

Describe 'SEC-004 repository access accounts' {
    BeforeEach { Reset-MockState }

    # VBREPPermission exposes Users, not Accounts. Reading .Accounts returned $null
    # on every server, so the check could not fire even in principle.
    It 'flags a machine-local account and leaves the domain account alone' {
        $global:MockRepos = @([pscustomobject]@{ Name = 'Repo1'; Host = [pscustomobject]@{ Name = 'backup01.corp.local' } })
        $global:MockPerms = @{ 'Repo1' = @('BACKUP01\Administrator', 'CORP\Administrator') }
        $r = Invoke-Check 'Test-RepositoryLocalAccounts'
        $r.Status | Should -Be 'Action'
        ($r.Evidence -join ';') | Should -Match 'BACKUP01\\Administrator'
        ($r.Evidence -join ';') | Should -Not -Match 'CORP\\Administrator'
    }

    It 'treats builtin and dot-prefixed accounts as local' {
        $global:MockRepos = @([pscustomobject]@{ Name = 'Repo1'; Host = [pscustomobject]@{ Name = 'backup01.corp.local' } })
        $global:MockPerms = @{ 'Repo1' = @('BUILTIN\Administrators', '.\localguy', 'NT AUTHORITY\SYSTEM') }
        (Invoke-Check 'Test-RepositoryLocalAccounts').Evidence.Count | Should -Be 3
    }

    It 'catches a local account belonging to the repository host' {
        $global:MockRepos = @([pscustomobject]@{ Name = 'Hardened'; Host = [pscustomobject]@{ Name = 'repo.corp.local' } })
        $global:MockPerms = @{ 'Hardened' = @('repo\repoadmin') }
        (Invoke-Check 'Test-RepositoryLocalAccounts').Status | Should -Be 'Action'
    }

    It 'passes on domain accounts in every accepted form' {
        $global:MockRepos = @([pscustomobject]@{ Name = 'Repo1'; Host = [pscustomobject]@{ Name = 'backup01.corp.local' } })
        $global:MockPerms = @{ 'Repo1' = @('CORP\svc', 'corp.local\svc2', 'svc3@corp.local') }
        (Invoke-Check 'Test-RepositoryLocalAccounts').Status | Should -Be 'Pass'
    }

    It 'reports an unclassifiable prefix for review rather than guessing' {
        $global:MockRepos = @([pscustomobject]@{ Name = 'Repo1'; Host = [pscustomobject]@{ Name = 'backup01.corp.local' } })
        $global:MockPerms = @{ 'Repo1' = @('OTHERDOM\someone') }
        (Invoke-Check 'Test-RepositoryLocalAccounts').Status | Should -Be 'Manual'
    }

    # A Pass that names no numbers reads the same whether it inspected every account
    # or nothing at all - which is how the .Accounts defect survived.
    It 'states what it evaluated when reporting a Pass' {
        $global:MockRepos = @([pscustomobject]@{ Name = 'Repo1'; Host = [pscustomobject]@{ Name = 'backup01.corp.local' } })
        $global:MockPerms = @{ 'Repo1' = @('CORP\svc') }
        (Invoke-Check 'Test-RepositoryLocalAccounts').Detail | Should -Match '1 account entry'
    }
}

Describe 'AGT-001 agent versions' {
    BeforeEach { Reset-MockState }

    It 'flags an agent below v13' {
        $global:MockAgents = @(
            [pscustomobject]@{ Name = 'Old'; AgentVersion = '12.1.0.100' }
            [pscustomobject]@{ Name = 'New'; AgentVersion = '13.0.2.29' }
        )
        $r = Invoke-Check 'Test-AgentVersions'
        $r.Status | Should -Be 'Action'
        ($r.Evidence -join ';') | Should -Match 'Old'
    }

    # A version string that failed TryParse was neither flagged nor counted unread,
    # so it fell through into a Pass.
    It 'treats an unparseable version as unread, not as fine' {
        $global:MockAgents = @([pscustomobject]@{ Name = 'Weird'; AgentVersion = 'thirteen' })
        (Invoke-Check 'Test-AgentVersions').Status | Should -Be 'Manual'
    }

    It 'passes only when every version was read' {
        $global:MockAgents = @(
            [pscustomobject]@{ Name = 'A'; AgentVersion = '13.0.2.29' }
            [pscustomobject]@{ Name = 'B' }
        )
        (Invoke-Check 'Test-AgentVersions').Status | Should -Be 'Manual'
    }
}

Describe 'JOB-002 SureBackup SQL checker' {
    BeforeEach { Reset-MockState }

    # A regex over the serialised object returned False with the script enabled.
    # The signal is the VM's Role array.
    It 'flags an application group with a SQLServer role' {
        $global:MockAppGroups = @(
            [pscustomobject]@{ Name = 'AG1'; VM = @([pscustomobject]@{ Name = 'SQL01'; Role = @('SQLServer') }) }
        )
        $r = Invoke-Check 'Test-SureBackupSqlChecker'
        $r.Status | Should -Be 'Blocker'
        ($r.Evidence -join ';') | Should -Match 'SQL01'
    }

    It 'passes an application group with no SQL role' {
        $global:MockAppGroups = @(
            [pscustomobject]@{ Name = 'AG1'; VM = @([pscustomobject]@{ Name = 'Web01'; Role = @('DomainController') }) }
        )
        (Invoke-Check 'Test-SureBackupSqlChecker').Status | Should -Be 'Pass'
    }
}

Describe 'JOB-003 job and guest scripts' {
    BeforeEach { Reset-MockState }

    BeforeAll {
        function New-Sf { param($Pre, $Post)
            [pscustomobject]@{ PreScriptFilePath = $Pre; PostScriptFilePath = $Post
                               IsAtLeastOneScriptSet = [bool]($Pre -or $Post) } }
        function New-Gso2 { param($Mode, $Win)
            [pscustomobject]@{ ScriptingMode = $Mode; WinScriptFiles = $Win
                               LinScriptFiles = (New-Sf $null $null); JobLinScriptFiles = (New-Sf $null $null)
                               JobMacScriptFiles = $null; IsAtLeastOneScriptSet = $Win.IsAtLeastOneScriptSet } }
        function New-MockJob {
            param($Name, $JobLevelGso, $PreCmd, $PostCmd)
            $j = [pscustomobject]@{ Name = $Name; JobType = 'Backup'
                Info = [pscustomobject]@{ VssOptions = [pscustomobject]@{ GuestScriptsOptions = $JobLevelGso } } }
            $j | Add-Member -MemberType ScriptMethod -Name GetOptions -Value ([scriptblock]::Create(@"
                [pscustomobject]@{ JobScriptCommand = [pscustomobject]@{
                    PreScriptEnabled = `$$([bool]$PreCmd); PreScriptCommandLine = '$PreCmd'
                    PostScriptEnabled = `$$([bool]$PostCmd); PostScriptCommandLine = '$PostCmd' } }
"@))
            $j
        }
    }

    # The scripts set via "application handling for individual servers" live on the
    # job OBJECT, not on the job's own VssOptions. Reading only the job level gave a
    # clean result on a job with four scripts configured.
    It 'finds a per-machine guest script override' {
        $empty = New-Gso2 'Disabled' (New-Sf $null $null)
        $global:MockJobs = @(New-MockJob 'J1' $empty $null $null)
        $global:MockJobObjects = @(
            [pscustomobject]@{ Name = 'VM-A'; VssOptions = [pscustomobject]@{ GuestScriptsOptions = (New-Gso2 'IgnoreErrors' (New-Sf 'C:\s\pre.cmd' 'C:\s\post.cmd')) } }
            [pscustomobject]@{ Name = 'VM-B'; VssOptions = [pscustomobject]@{ GuestScriptsOptions = $empty } }
        )
        $r = Invoke-Check 'Test-JobScriptsAndFiles'
        $r.Status | Should -Be 'Manual'
        ($r.Evidence -join ';') | Should -Match 'J1 -> VM-A.*pre\.cmd'
        ($r.Evidence -join ';') | Should -Not -Match 'VM-B'
    }

    # JobScriptCommand was never read at all, so pre/post-job commands were invisible.
    It 'finds pre and post-job commands' {
        $empty = New-Gso2 'Disabled' (New-Sf $null $null)
        $global:MockJobs = @(New-MockJob 'J1' $empty 'C:\s\prejob.cmd' 'C:\s\postjob.cmd')
        $r = Invoke-Check 'Test-JobScriptsAndFiles'
        ($r.Evidence -join ';') | Should -Match 'Pre-job command -> C:\\s\\prejob\.cmd'
        ($r.Evidence -join ';') | Should -Match 'Post-job command -> C:\\s\\postjob\.cmd'
    }

    It 'counts only files, never a setting' {
        $empty = New-Gso2 'Disabled' (New-Sf $null $null)
        $global:MockJobs = @(New-MockJob 'J1' $empty 'C:\s\prejob.cmd' 'C:\s\postjob.cmd')
        $global:MockJobObjects = @(
            [pscustomobject]@{ Name = 'VM-A'; VssOptions = [pscustomobject]@{ GuestScriptsOptions = (New-Gso2 'IgnoreErrors' (New-Sf 'C:\s\pre.cmd' 'C:\s\post.cmd')) } }
        )
        $r = Invoke-Check 'Test-JobScriptsAndFiles'
        $r.Detail | Should -Match '4 script reference'
        ($r.Evidence -join ';') | Should -Not -Match 'ScriptingMode'
    }

    It 'passes when no job has any script' {
        $empty = New-Gso2 'Disabled' (New-Sf $null $null)
        $global:MockJobs = @(New-MockJob 'Clean' $empty $null $null)
        $global:MockJobObjects = @(
            [pscustomobject]@{ Name = 'VM-B'; VssOptions = [pscustomobject]@{ GuestScriptsOptions = $empty } }
        )
        (Invoke-Check 'Test-JobScriptsAndFiles').Status | Should -Be 'Pass'
    }
}

Describe 'DEP-002 Google Cloud' {
    BeforeEach { Reset-MockState }

    # The plug-in ships with VBR and is installed by default, so presence proves
    # nothing. Only configuration counts.
    It 'flags a configured Google Cloud account' {
        $global:MockGcpAccounts = @([pscustomobject]@{ Name = 'svc@proj.iam.gserviceaccount.com' })
        $r = Invoke-Check 'Test-GoogleCloudPlugin'
        $r.Status | Should -Be 'Warning'
        ($r.Evidence -join ';') | Should -Match 'gserviceaccount'
    }

    It 'passes when nothing is configured' {
        (Invoke-Check 'Test-GoogleCloudPlugin').Status | Should -Be 'Pass'
    }

    It 'states what it checked when reporting a Pass' {
        (Invoke-Check 'Test-GoogleCloudPlugin').Detail | Should -Match 'configuration source'
    }
}

# --------------------------------------------------------------------------------
# Counted clean results, and the checks that used to fall through an unread
# collection into one. Every Pass below asserts on what the check SAYS it looked
# at: a clean result that names no quantity reads identically whether the check
# examined everything and found nothing wrong or examined nothing at all. Six of
# these checks had never produced a non-empty result on real hardware, so the
# populated cases here are the first time their filtering logic has ever run.
# --------------------------------------------------------------------------------

Describe 'AGT-001 empty agent inventory' {
    BeforeEach { Reset-MockState }

    It 'says the inventory was read when there are no agents' {
        (Invoke-Check 'Test-AgentVersions').Detail | Should -Match 'read successfully and is empty'
    }
}

Describe 'AGT-003 Mac agent jobs' {
    BeforeEach { Reset-MockState }

    # A bare substring match on 'Mac' also matches the word "machine", so ordinary
    # Windows agent jobs were reported as Mac jobs. Same defect class as AGT-004
    # matching the built-in "Manually Added" group.
    It 'does not treat a Windows machine job as a Mac job' {
        $global:MockPolicies = @(
            [pscustomobject]@{ Name = 'Win agents'; OSPlatform = 'Windows'; Type = 'Workstation'; TypeToString = 'Windows Machine Backup' }
        )
        $r = Invoke-Check 'Test-MacAgentDomainAuth'
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match '1 agent job\(s\) were examined'
    }

    It 'still flags a genuine Mac agent job' {
        $global:MockPolicies = @(
            [pscustomobject]@{ Name = 'Win agents'; OSPlatform = 'Windows'; Type = 'Server';     TypeToString = 'Windows machine' }
            [pscustomobject]@{ Name = 'Mac laptops'; OSPlatform = 'macOS';  Type = 'Workstation'; TypeToString = 'Mac backup' }
        )
        $r = Invoke-Check 'Test-MacAgentDomainAuth'
        $r.Status | Should -Be 'Manual'
        ($r.Evidence -join ';') | Should -Match 'Mac laptops'
        ($r.Evidence -join ';') | Should -Not -Match 'Win agents'
        $r.Detail | Should -Match '1 of 2 agent job'
    }

    It 'states how many jobs it examined when reporting a Pass' {
        $global:MockPolicies = @(
            [pscustomobject]@{ Name = 'A'; OSPlatform = 'Windows'; Type = 'Server'; TypeToString = 'Windows' }
            [pscustomobject]@{ Name = 'B'; OSPlatform = 'Linux';   Type = 'Server'; TypeToString = 'Linux' }
        )
        (Invoke-Check 'Test-MacAgentDomainAuth').Detail | Should -Match '2 agent job\(s\) were examined'
    }

    It 'reports Manual rather than Pass when the jobs cannot be read' {
        $global:MockThrow = @('Get-VBRComputerBackupJob')
        $r = Invoke-Check 'Test-MacAgentDomainAuth'
        $r.Status | Should -Be 'Manual'
        $r.Detail | Should -Match 'could not be enumerated'
    }
}

Describe 'AGT-004 unreadable protection groups' {
    BeforeEach { Reset-MockState }

    # This check failed OPEN: an unread collection is empty, and the empty case
    # returned Pass, so a throwing cmdlet produced "no Protection Groups found".
    # Every other check in the tool degrades to Manual/Info instead.
    It 'reports Manual rather than Pass when the groups cannot be read' {
        $global:MockThrow = @('Get-VBRProtectionGroup')
        $r = Invoke-Check 'Test-ProtectionGroupPostMigration'
        $r.Status | Should -Be 'Manual'
        $r.Detail | Should -Match 'could not be enumerated'
    }

    It 'says the list was read when there are genuinely no groups' {
        $r = Invoke-Check 'Test-ProtectionGroupPostMigration'
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match 'read successfully and is empty'
    }
}

Describe 'JOB-001 CDP policies' {
    BeforeEach { Reset-MockState }

    It 'flags a configured CDP policy' {
        $global:MockCdp = @([pscustomobject]@{ Name = 'CDP-Tier1' })
        $r = Invoke-Check 'Test-CdpJobs'
        $r.Status | Should -Be 'Warning'
        ($r.Evidence -join ';') | Should -Match 'CDP-Tier1'
    }

    It 'says the list was read when reporting a Pass' {
        (Invoke-Check 'Test-CdpJobs').Detail | Should -Match 'read successfully and is empty'
    }
}

Describe 'DEP-003 Entra ID tenants' {
    BeforeEach { Reset-MockState }

    It 'flags a configured Entra ID tenant backup' {
        $global:MockTenants = @([pscustomobject]@{ Name = 'contoso.onmicrosoft.com' })
        $r = Invoke-Check 'Test-EntraIdBackups'
        $r.Status | Should -Be 'Manual'
        ($r.Evidence -join ';') | Should -Match 'contoso'
    }

    It 'says the inventory was read when reporting a Pass' {
        (Invoke-Check 'Test-EntraIdBackups').Detail | Should -Match 'read successfully and is empty'
    }
}

Describe 'STG-001 NetApp ONTAP' {
    BeforeEach { Reset-MockState }

    It 'flags an integrated ONTAP system' {
        $global:MockNetApp = @([pscustomobject]@{ Name = 'ontap-01' })
        $r = Invoke-Check 'Test-NetAppOntapRole'
        $r.Status | Should -Be 'Warning'
        ($r.Evidence -join ';') | Should -Match 'ontap-01'
    }

    It 'says the inventory was read when reporting a Pass' {
        (Invoke-Check 'Test-NetAppOntapRole').Detail | Should -Match 'read successfully'
    }
}

Describe 'STG-002 Universal Storage Plugin' {
    BeforeEach { Reset-MockState }

    It 'flags an integrated plug-in system and names the minimum versions' {
        $global:MockPluginHosts = @([pscustomobject]@{ Name = 'flashsystem-01' })
        $r = Invoke-Check 'Test-StoragePluginVersions'
        $r.Status | Should -Be 'Manual'
        ($r.Evidence -join ';') | Should -Match 'flashsystem-01'
        $r.Recommendation | Should -Match '2\.3\.80'
    }

    It 'says the inventory was read when reporting a Pass' {
        (Invoke-Check 'Test-StoragePluginVersions').Detail | Should -Match 'read successfully'
    }
}

Describe 'STG-003 HPE Nimble / Alletra' {
    BeforeEach { Reset-MockState }

    # The FIPS state has to be stated: the finding is now conditional on it, and leaving
    # it unset is the "could not be read" case, which defers rather than warning.
    It 'flags an integrated Nimble system' {
        $global:MockNimble = @([pscustomobject]@{ Name = 'nimble-01' })
        $global:MockSecurityOptions = [pscustomobject]@{ FipsCompliantModeEnabled = $false }
        $r = Invoke-Check 'Test-NimbleFips'
        $r.Status | Should -Be 'Warning'
        ($r.Evidence -join ';') | Should -Match 'nimble-01'
    }

    It 'says the inventory was read when reporting a Pass' {
        (Invoke-Check 'Test-NimbleFips').Detail | Should -Match 'read successfully'
    }
}

Describe 'JOB-002 counted and unreadable application groups' {
    BeforeEach { Reset-MockState }

    # JOB-002 is the only check that can emit a Blocker, so a clean result it did
    # not earn is the most expensive false Pass in the tool. Its cmdlet guard passes
    # when EITHER SureBackup cmdlet exists, so the groups could still be unreadable.
    It 'reports Manual rather than Pass when the groups cannot be read' {
        $global:MockThrow = @('Get-VBRApplicationGroup')
        $r = Invoke-Check 'Test-SureBackupSqlChecker'
        $r.Status | Should -Be 'Manual'
        $r.Detail | Should -Match 'could not be enumerated'
    }

    It 'states how many groups and VMs it examined when reporting a Pass' {
        $global:MockAppGroups = @(
            [pscustomobject]@{ Name = 'AG1'; VM = @(
                [pscustomobject]@{ Name = 'Web01'; Role = @('WebServer') }
                [pscustomobject]@{ Name = 'DC01';  Role = @('DomainController') }
            ) }
        )
        $r = Invoke-Check 'Test-SureBackupSqlChecker'
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match '1 SureBackup application group\(s\) containing 2 VM\(s\)'
    }

    It 'says the list was read when there are genuinely no groups' {
        (Invoke-Check 'Test-SureBackupSqlChecker').Detail | Should -Match 'read successfully and is empty'
    }
}

Describe 'SEC-002 counted credential review' {
    BeforeEach { Reset-MockState }

    # Note the real credential object exposes no usable Type, so the name-based
    # 'root' exclusion is what does the work in the field; the typed record here
    # covers the branch only.
    It 'states how many credentials it examined when reporting a Pass' {
        $global:MockCreds = @(
            [pscustomobject]@{ Name = 'administrator@corp.local'; Description = 'domain admin' }
            [pscustomobject]@{ Name = 'corp.local\svc-veeam';     Description = 'service account' }
        )
        $r = Invoke-Check 'Test-CredentialUpnFormat'
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match '2 stored credential\(s\) were examined'
        $r.Detail | Should -Match '2 are already in user@fqdn or fqdn\\user form'
    }

    It 'accounts for the records it set aside' {
        $global:MockCreds = @(
            [pscustomobject]@{ Name = 'administrator@corp.local'; Description = '' }
            [pscustomobject]@{ Name = 'root';                     Description = 'ESXi host' }
            [pscustomobject]@{ Name = 'keyuser'; Type = 'SSH';    Description = 'helper appliance' }
        )
        $r = Invoke-Check 'Test-CredentialUpnFormat'
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match '2 were set aside'
    }

    It 'still reports a down-level credential for review' {
        $global:MockCreds = @([pscustomobject]@{ Name = 'CORP\administrator'; Description = '' })
        $r = Invoke-Check 'Test-CredentialUpnFormat'
        $r.Status | Should -Be 'Manual'
        ($r.Evidence -join ';') | Should -Match 'CORP\\administrator'
    }

    It 'reports Manual rather than Pass when the credentials cannot be read' {
        $global:MockThrow = @('Get-VBRCredentials')
        $r = Invoke-Check 'Test-CredentialUpnFormat'
        $r.Status | Should -Be 'Manual'
        $r.Detail | Should -Match 'could not be enumerated'
    }

    It 'distinguishes an empty credential store from a clean one' {
        (Invoke-Check 'Test-CredentialUpnFormat').Detail | Should -Match 'read successfully and is empty'
    }
}

Describe 'ENV-002 licence model' {
    BeforeEach { Reset-MockState }

    # Shapes below use the members confirmed by reflection on a real licence object:
    # VBRSocketLicenseSummary   -> LicensedSocketsNumber (int)
    # VBRInstanceLicenseSummary -> LicensedInstancesNumber (double)
    # A socket licence cannot be obtained for testing - socket licensing is deprecated -
    # so the socket VALUES here are synthetic while the SHAPE is not.

    # THE DEFECT THIS PINS: an instance licence still returns ONE SocketLicenseSummary
    # entry, containing ZERO sockets. Testing the array's Count instead of the socket
    # figure inside it reported a socket licence on an instance-licensed server, telling
    # the operator to convert a licence that needed no conversion.
    It 'does not call an instance licence socket-based just because a socket summary exists' {
        $global:MockLicense = [pscustomobject]@{
            Type = 'Subscription'; Edition = 'EnterprisePlus'; CloudConnect = 'Disabled'
            SocketLicenseSummary   = @([pscustomobject]@{ LicensedSocketsNumber = 0; UsedSocketsNumber = 0; RemainingSocketsNumber = 0 })
            InstanceLicenseSummary = [pscustomobject]@{ LicensedInstancesNumber = 500; UsedInstancesNumber = 214 }
        }
        $r = Invoke-Check 'Test-VbrLicense'
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match 'Instance-based'
        ($r.Evidence -join ';') | Should -Match 'Licensed sockets counted=0'
        # Assert the real figure, not just that the check said "instance-based". If the
        # instance member name were wrong the check would fall back to the word
        # "present" and still return Pass, so without this the count is unverified -
        # a clean result carrying a number that nothing checks is the same trap as a
        # clean result carrying no number at all.
        $r.Detail | Should -Match 'instances=500'
    }

    # The fallback above is deliberate, not an accident: an instance summary that exists
    # but exposes no countable figure still means an instance licence, so the status must
    # stay Pass. This pins that it degrades to saying so rather than inventing a number.
    It 'still passes when the instance summary carries no countable figure' {
        $global:MockLicense = [pscustomobject]@{
            Type = 'Subscription'; Edition = 'EnterprisePlus'; CloudConnect = 'Disabled'
            SocketLicenseSummary   = @()
            InstanceLicenseSummary = [pscustomobject]@{ SomethingElse = 1 }
        }
        $r = Invoke-Check 'Test-VbrLicense'
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match 'instances=present'
    }

    It 'flags a genuine socket licence' {
        $global:MockLicense = [pscustomobject]@{
            Type = 'Perpetual'; Edition = 'EnterprisePlus'; CloudConnect = 'Disabled'
            SocketLicenseSummary   = @([pscustomobject]@{ LicensedSocketsNumber = 4; UsedSocketsNumber = 4; RemainingSocketsNumber = 0 })
            InstanceLicenseSummary = $null
        }
        $r = Invoke-Check 'Test-VbrLicense'
        $r.Status | Should -Be 'Action'
        $r.Detail | Should -Match '4 licensed socket'
    }

    It 'sums sockets across multiple summary entries' {
        $global:MockLicense = [pscustomobject]@{
            Type = 'Perpetual'; Edition = 'Standard'; CloudConnect = 'Disabled'
            SocketLicenseSummary   = @(
                [pscustomobject]@{ LicensedSocketsNumber = 2 }
                [pscustomobject]@{ LicensedSocketsNumber = 6 }
            )
            InstanceLicenseSummary = $null
        }
        (Invoke-Check 'Test-VbrLicense').Detail | Should -Match '8 licensed socket'
    }

    # Reported as unknown rather than guessed in either direction: guessing "socket"
    # prescribes needless work, guessing "instance" hides a real blocker.
    It 'reports Info when a socket summary exposes no countable figure and there is no instance summary' {
        $global:MockLicense = [pscustomobject]@{
            Type = 'Perpetual'; Edition = 'Standard'; CloudConnect = 'Disabled'
            SocketLicenseSummary   = @([pscustomobject]@{ SomethingElse = 1 })
            InstanceLicenseSummary = $null
        }
        (Invoke-Check 'Test-VbrLicense').Status | Should -Be 'Info'
    }

    It 'reports Info when no licence object comes back' {
        $global:MockLicense = $null
        (Invoke-Check 'Test-VbrLicense').Status | Should -Be 'Info'
    }
}

Describe 'DEP-001 Cloud Connect' {
    BeforeEach { Reset-MockState }

    # Read from the licence itself. The Cloud Connect cmdlets THROW without a provider
    # licence, so the Disabled path must never reach them - avoiding the exception rather
    # than catching it. Asserted by making them throw if touched.
    It 'passes on a non-Cloud-Connect licence without calling the Cloud Connect cmdlets' {
        $global:MockLicense = [pscustomobject]@{ Type = 'Subscription'; CloudConnect = 'Disabled' }
        $global:MockThrow = @('Get-VBRCloudTenant', 'Get-VBRCloudGateway')
        $r = Invoke-Check 'Test-CloudConnect'
        $r.Status | Should -Be 'Pass'
        ($r.Evidence -join ';') | Should -Match 'Disabled'
    }

    It 'blocks when the licence reports Cloud Connect enabled, and enumerates the evidence' {
        $global:MockLicense = [pscustomobject]@{ Type = 'Perpetual'; CloudConnect = 'Enabled' }
        $global:MockCloudTenants  = @([pscustomobject]@{ Name = 'tenant-a' }, [pscustomobject]@{ Name = 'tenant-b' })
        $global:MockCloudGateways = @([pscustomobject]@{ Name = 'cc-gw-01' })
        $r = Invoke-Check 'Test-CloudConnect'
        $r.Status | Should -Be 'Blocker'
        $r.Detail | Should -Match '2 tenant\(s\), 1 gateway\(s\)'
        ($r.Evidence -join ';') | Should -Match 'tenant-a'
    }

    It 'blocks on the Enterprise mode as well' {
        $global:MockLicense = [pscustomobject]@{ Type = 'Perpetual'; CloudConnect = 'Enterprise' }
        (Invoke-Check 'Test-CloudConnect').Status | Should -Be 'Blocker'
    }

    # Blocker-grade check, so an unreadable mode is never guessed in either direction.
    It 'reports Info on an unreadable Cloud Connect mode rather than guessing' {
        $global:MockLicense = [pscustomobject]@{ Type = 'Perpetual'; CloudConnect = 'Invalid' }
        (Invoke-Check 'Test-CloudConnect').Status | Should -Be 'Info'
    }

    It 'reports Info when the licence cannot be read at all' {
        $global:MockThrow = @('Get-VBRInstalledLicense')
        (Invoke-Check 'Test-CloudConnect').Status | Should -Be 'Info'
    }

    # Cloud Connect tenants can still be enumerated when licensed; the Blocker must not
    # depend on them, since the licence is the authoritative signal.
    It 'blocks even when no tenants or gateways are configured yet' {
        $global:MockLicense = [pscustomobject]@{ Type = 'Perpetual'; CloudConnect = 'Enabled' }
        (Invoke-Check 'Test-CloudConnect').Status | Should -Be 'Blocker'
    }
}

Describe 'DB-001 session-history retention' {
    BeforeEach { Reset-MockState; $global:MockHistory = [pscustomobject]@{ KeepAllSessions = $false; RetentionLimitWeeks = 13 } }

    # Confirmed live on the lab (13-week retention) against three cutoffs. The Pass
    # branch is therefore real evidence; these pin it against regression.
    It 'passes when retention is shorter than the time since the upgrade' {
        $r = Invoke-DbCheck -UpgradeDate (Get-Date).AddYears(-2)
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match 'shorter than'
    }

    # The branch three live runs could NOT reach: it needs a cutoff between 1 and 13
    # weeks ago, and every date tried was further back than the retention window.
    It 'flags retention that reaches back past the upgrade, and names a target' {
        $r = Invoke-DbCheck -UpgradeDate (Get-Date).AddDays(-49)   # 7 weeks
        $r.Status | Should -Be 'Action'
        $r.Detail | Should -Match 'reaches back to or past the v12 upgrade'
        $r.Recommendation | Should -Match 'RetentionLimitWeeks 6'
    }

    # THE DEFECT THIS PINS: PowerShell binds '-UpgradeDate 0' to DateTime.MinValue, so
    # the check reported "105690 week(s) since the upgrade on 0001-01-01" and returned a
    # confident Pass. A mistyped parameter cleared the check meant to catch this blocker.
    It 'refuses an implausible cutoff instead of passing on it' {
        $r = Invoke-DbCheck -UpgradeDate ([datetime] 0)
        $r.Status | Should -Be 'Manual'
        $r.Detail | Should -Match 'predates Veeam Backup & Replication v12'
        $r.Status | Should -Not -Be 'Pass'
    }

    # The date being asked for is the upgrade to v12, because what breaks migration is
    # session data written by v11 and earlier. A date before v12 existed cannot be it -
    # most likely the v11 upgrade date, or a mistyped year - and that is a far more
    # realistic mistake than DateTime.MinValue.
    It 'refuses a cutoff predating v12, not merely an absurd one' {
        $r = Invoke-DbCheck -UpgradeDate ([datetime] '2019-06-01')
        $r.Status | Should -Be 'Manual'
        $r.Detail | Should -Match 'upgraded to v12'
        $r.Status | Should -Not -Be 'Pass'
    }

    It 'names the v12 boundary when it defers for want of a date' {
        (Invoke-DbCheck -UpgradeDate $null).Detail | Should -Match 'v11 and earlier'
    }

    It 'refuses a cutoff in the future' {
        $r = Invoke-DbCheck -UpgradeDate (Get-Date).AddMonths(6)
        $r.Status | Should -Be 'Manual'
        $r.Detail | Should -Match 'is in the future'
    }

    It 'reports Action when history is set to keep everything' {
        $global:MockHistory = [pscustomobject]@{ KeepAllSessions = $true; RetentionLimitWeeks = 13 }
        $r = Invoke-DbCheck -UpgradeDate (Get-Date).AddYears(-2)
        $r.Status | Should -Be 'Action'
        $r.Detail | Should -Match 'keep ALL sessions'
    }

    It 'defers when no cutoff is supplied, stating the retention it read' {
        $r = Invoke-DbCheck -UpgradeDate $null
        $r.Status | Should -Be 'Manual'
        $r.Detail | Should -Match '13 week'
    }

    # Retention is whole weeks, so a cutoff under a week old has no value that would age
    # sessions out - advising a reduction would be an impossible instruction.
    It 'does not advise an impossible reduction for a cutoff less than a week old' {
        $r = Invoke-DbCheck -UpgradeDate (Get-Date).AddDays(-3)
        $r.Status | Should -Be 'Manual'
        $r.Detail | Should -Match 'less than a week ago'
    }

    It 'reports Info when the retention period cannot be read' {
        $global:MockHistory = [pscustomobject]@{ KeepAllSessions = $false }
        (Invoke-DbCheck -UpgradeDate (Get-Date).AddYears(-2)).Status | Should -Be 'Info'
    }

    It 'reports Info when the options object cannot be retrieved' {
        $global:MockHistory = $null
        (Invoke-DbCheck -UpgradeDate (Get-Date).AddYears(-2)).Status | Should -Be 'Info'
    }

    # The whole point of the rewrite: judge the SETTING, never enumerate the sessions.
    # The stub throws if the session cmdlet is touched, so any run reaching it fails here.
    It 'never reads the session list' {
        { Invoke-DbCheck -UpgradeDate (Get-Date).AddYears(-2) } | Should -Not -Throw
        { Invoke-DbCheck -UpgradeDate $null } | Should -Not -Throw
    }
}

Describe 'SEC-005 console role assignment format' {
    BeforeEach { Reset-MockState }

    # Shapes taken from real Users & Roles dialogs. Note the console shows the builtin
    # group as BUILTIN\Administrators while PowerShell has been seen returning it bare,
    # so both are covered.

    It 'passes when every assignment already uses an @ form, and counts them' {
        $global:MockRoles = @(
            [pscustomobject]@{ Name = 'backupadmin@corp.local';   Role = 'BackupAdmin'; Type = 'User' }
            [pscustomobject]@{ Name = 'Domain Admins@corp.local'; Role = 'BackupAdmin'; Type = 'Group' }
        )
        $r = Invoke-Check 'Test-RoleAssignmentUpnFormat'
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match 'All 2 console role assignment'
    }

    # THE 0.3.7 DEFECT: Type (User/Group) was read and never used, so every finding named
    # user@fqdn - including for a group, which sends the operator to do something that
    # fails. A group needs group@domain.
    It 'tells a group to use group@domain, not user@fqdn' {
        $global:MockRoles = @(
            [pscustomobject]@{ Name = 'CORP\DOMAIN ADMINS'; Role = 'BackupAdmin'; Type = 'Group' }
        )
        $r = Invoke-Check 'Test-RoleAssignmentUpnFormat'
        $r.Status | Should -Be 'Action'
        ($r.Evidence -join ';') | Should -Match 'group@domain'
        ($r.Evidence -join ';') | Should -Not -Match 'user@fqdn'
        # A space in the group name must survive into the finding.
        ($r.Evidence -join ';') | Should -Match 'DOMAIN ADMINS'
    }

    It 'tells a user to use user@fqdn' {
        $global:MockRoles = @(
            [pscustomobject]@{ Name = 'CORP\Administrator'; Role = 'BackupAdmin'; Type = 'User' }
        )
        $r = Invoke-Check 'Test-RoleAssignmentUpnFormat'
        $r.Status | Should -Be 'Action'
        ($r.Evidence -join ';') | Should -Match 'user@fqdn'
        ($r.Evidence -join ';') | Should -Not -Match 'group@domain'
    }

    # A builtin or machine-local principal cannot simply be re-typed with an @ - it has
    # no counterpart on a Linux appliance at all, so the advice has to differ.
    It 'says a builtin principal has no counterpart rather than telling them to convert it' {
        $global:MockRoles = @(
            [pscustomobject]@{ Name = 'BUILTIN\Administrators'; Role = 'BackupAdmin'; Type = 'Group' }
        )
        ($r = Invoke-Check 'Test-RoleAssignmentUpnFormat').Status | Should -Be 'Action'
        ($r.Evidence -join ';') | Should -Match 'no counterpart'
    }

    It 'treats a machine-local prefix as local, not as a domain' {
        $global:MockRoles = @(
            [pscustomobject]@{ Name = 'BACKUP01\svcveeam'; Role = 'BackupAdmin'; Type = 'User' }
        )
        ($r = Invoke-Check 'Test-RoleAssignmentUpnFormat').Evidence -join ';' | Should -Match 'no counterpart'
    }

    It 'reports an unqualified name as such' {
        $global:MockRoles = @(
            [pscustomobject]@{ Name = 'Administrators'; Role = 'BackupAdmin'; Type = 'Group' }
        )
        ($r = Invoke-Check 'Test-RoleAssignmentUpnFormat').Evidence -join ';' | Should -Match 'unqualified name'
    }

    It 'says so when the principal type is not reported' {
        $global:MockRoles = @(
            [pscustomobject]@{ Name = 'CORP\someone'; Role = 'BackupAdmin' }
        )
        ($r = Invoke-Check 'Test-RoleAssignmentUpnFormat').Evidence -join ';' | Should -Match 'type not reported'
    }

    # These are the exact strings Get-VBRUserRoleAssignment returned on the lab's Windows
    # VBR - builtin group, down-level user, down-level group. Note the cmdlet UPPERCASES
    # the name (the console shows it mixed-case) and the space survives. All
    # three are findings, each with its own reason, and this combination is validated live.
    It 'reports all three shapes on a typical Windows source with distinct reasons' {
        $global:MockRoles = @(
            [pscustomobject]@{ Name = 'BUILTIN\Administrators';   Role = 'BackupAdmin'; Type = 'Group' }
            [pscustomobject]@{ Name = 'CORP\Administrator';  Role = 'BackupAdmin'; Type = 'User' }
            [pscustomobject]@{ Name = 'CORP\DOMAIN ADMINS';  Role = 'BackupAdmin'; Type = 'Group' }
        )
        $r = Invoke-Check 'Test-RoleAssignmentUpnFormat'
        $r.Status | Should -Be 'Action'
        $r.Detail | Should -Match '3 console role assignment'
        $ev = $r.Evidence -join ';'
        $ev | Should -Match 'no counterpart'
        $ev | Should -Match 'the appliance needs user@fqdn'
        $ev | Should -Match 'the appliance needs group@domain'
    }

    # The finding count needs its denominator. Without it, "2 assignments are not in the
    # required form" reads the same whether two were examined and both were wrong or
    # three were examined and one was fine - and that ambiguity made a real discrepancy
    # against the console impossible to diagnose from the report.
    It 'states how many assignments it read, not just how many are wrong' {
        $global:MockRoles = @(
            [pscustomobject]@{ Name = 'BUILTIN\Administrators';  Role = 'BackupAdmin'; Type = 'Group' }
            [pscustomobject]@{ Name = 'good@corp.local';          Role = 'BackupAdmin'; Type = 'User' }
            [pscustomobject]@{ Name = 'Fine Group@corp.local';    Role = 'BackupAdmin'; Type = 'Group' }
        )
        (Invoke-Check 'Test-RoleAssignmentUpnFormat').Detail | Should -Match '1 of 3 console role assignment'
    }

    # A count of zero is not a clean result. "All 0 assignments already use the required
    # form" was a confident statement derived from nothing - the same fail-open as
    # AGT-004, hidden here because the Pass already carried a number and zero looked like
    # a count. A backup server always has at least one assignment.
    It 'defers rather than passing when no assignments come back' {
        $global:MockRoles = @()
        $r = Invoke-Check 'Test-RoleAssignmentUpnFormat'
        $r.Status | Should -Be 'Manual'
        $r.Status | Should -Not -Be 'Pass'
        $r.Detail | Should -Match 'always has at least one assignment'
    }
}

Describe 'STG-003 Nimble under FIPS-compliant mode' {
    BeforeEach {
        Reset-MockState
        $global:MockNimble = @([pscustomobject]@{ Name = 'nimble-01' })
    }

    # The restriction only bites when FIPS-compliant mode is in use, and that state is
    # readable (Get-VBRSecurityOptions -> FipsCompliantModeEnabled), so the check should
    # say whether THIS server is affected rather than warning identically everywhere.
    It 'asks for a decision when FIPS-compliant mode is enabled' {
        $global:MockSecurityOptions = [pscustomobject]@{ FipsCompliantModeEnabled = $true }
        $r = Invoke-Check 'Test-NimbleFips'
        $r.Status | Should -Be 'Manual'
        $r.Detail | Should -Match 'FIPS-compliant mode is enabled'
        # The restriction is VERSION-dependent per the UG, and both options must be
        # offered, since dropping FIPS is often not possible in a secure environment.
        $r.Detail | Should -Match 'may not be supported'
        $r.Recommendation | Should -Match 'Nimble OS version'
        $r.Recommendation | Should -Match 'FIPS-compliant mode'
        # It is NOT scoped to Backup from Storage Snapshots - that is a separate
        # consideration on the same UG page and out of KB4800 scope.
        $r.Detail | Should -Not -Match 'Backup from Storage Snapshots'
        ($r.Evidence -join ';') | Should -Match 'FIPS-compliant mode on this server: True'
    }

    It 'only warns when FIPS-compliant mode is off, and says why it could still matter' {
        $global:MockSecurityOptions = [pscustomobject]@{ FipsCompliantModeEnabled = $false }
        $r = Invoke-Check 'Test-NimbleFips'
        $r.Status | Should -Be 'Warning'
        $r.Detail | Should -Match 'not enabled on this server'
        $r.Detail | Should -Match 'enabling it on the appliance later'
    }

    It 'defers when the FIPS state cannot be read rather than assuming it is off' {
        $global:MockThrow = @('Get-VBRSecurityOptions')
        $r = Invoke-Check 'Test-NimbleFips'
        $r.Status | Should -Be 'Manual'
        $r.Detail | Should -Match 'could not be read'
    }

    It 'defers when the FIPS property is absent from the options object' {
        $global:MockSecurityOptions = [pscustomobject]@{ AuditLogsPath = 'C:\Logs' }
        (Invoke-Check 'Test-NimbleFips').Status | Should -Be 'Manual'
    }

    # No arrays means no restriction to consider, whatever FIPS is set to.
    It 'passes with no Nimble arrays even when FIPS is enabled' {
        $global:MockNimble = @()
        $global:MockSecurityOptions = [pscustomobject]@{ FipsCompliantModeEnabled = $true }
        $r = Invoke-Check 'Test-NimbleFips'
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Match 'read successfully'
    }

    It 'names every array it found' {
        $global:MockNimble = @(
            [pscustomobject]@{ Name = 'nimble-01' }
            [pscustomobject]@{ Name = 'alletra-6000-a' }
        )
        $global:MockSecurityOptions = [pscustomobject]@{ FipsCompliantModeEnabled = $true }
        $r = Invoke-Check 'Test-NimbleFips'
        $r.Detail | Should -Match '2 HPE Nimble/Alletra system'
        ($r.Evidence -join ';') | Should -Match 'alletra-6000-a'
    }
}
