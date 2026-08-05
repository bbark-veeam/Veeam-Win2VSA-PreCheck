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

    function global:Get-VBRDiscoveredComputer      { param($ErrorAction) $global:MockAgents }
    function global:Get-VBRComputerBackupJob       { param($ErrorAction) $global:MockPolicies }
    function global:Get-VBRProtectionGroup         { param($ErrorAction) $global:MockGroups }
    function global:Get-VBRBackupRepository        { param($ErrorAction) $global:MockRepos }
    function global:Get-VBRUserRoleAssignment      { param($ErrorAction) $global:MockRoles }
    function global:Get-VBRJob                     { param($ErrorAction) $global:MockJobs }
    function global:Get-VBRJobObject               { param($Job, $ErrorAction) $global:MockJobObjects }
    function global:Get-VBRApplicationGroup        { param($ErrorAction) $global:MockAppGroups }
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
