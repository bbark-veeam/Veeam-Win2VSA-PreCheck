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
        -Detail 'No CDP policies found.'
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
    if (Test-PrecheckCmdlet 'Get-VBRApplicationGroup') {
        try {
            foreach ($ag in Get-VBRApplicationGroup -ErrorAction SilentlyContinue) {
                foreach ($vm in @($ag.VM)) {
                    if (-not $vm) { continue }
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
        } catch { }
    }

    if ($hits.Count -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Blocker `
            -Detail "SureBackup Application Group(s) appear to use the SQL Server Checker Script, which is available ONLY on Windows deployments and will FAIL on the VSA." `
            -Recommendation 'Remove/replace the SQL Server Checker Script in these Application Groups before migration (or accept those SureBackup tests will fail).' `
            -Evidence $hits
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
        -Detail 'No SureBackup Application Groups using the SQL Server Checker Script were detected.'
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
