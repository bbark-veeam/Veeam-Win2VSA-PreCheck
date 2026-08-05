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
    try {
        foreach ($c in Get-VBRCredentials -ErrorAction SilentlyContinue) {
            $u = [string]$c.Name
            if (-not $u) { continue }

            # Standard type only. Excludes SSH, SSH private key, Kasten auth token,
            # Managed Service Account, and anything new that appears later.
            $type = if ($c.PSObject.Properties['Type']) { [string]$c.Type } else { '' }
            if ($type -and $type -ne 'Standard') { continue }

            # Linux / appliance / ESXi root, incl. VBR's own auto-created records.
            if ($u -ieq 'root') { continue }

            # Already UPN-shaped (or an SSO/IdP suffix form) - not a candidate.
            if ($u -match '@') { continue }

            # FQDN\user is an accepted Kerberos form alongside user@fqdn - the Add
            # Windows Server wizard asks for "USER@FQDN or FQDN\USER". A prefix
            # containing a dot is therefore already acceptable; a prefix without one
            # is a NetBIOS domain or a machine name, and neither can authenticate
            # with Kerberos.
            $prefix = if ($u -match '\\') { $u.Split('\')[0] } else { '' }
            if ($prefix -and $prefix.Contains('.')) { continue }

            $shape = if ($prefix) { 'NetBIOS or machine prefix' } else { 'bare user name' }
            $desc  = if ($c.PSObject.Properties['Description']) { [string]$c.Description } else { '' }
            $candidates += "$u  [$shape]$(if ($desc) { "  - $desc" })"
        }
    } catch { }

    if ($candidates.Count -eq 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail 'All stored domain credentials are already in a Kerberos-compatible form (user@fqdn or fqdn\user), so nothing needs review for Kerberos-authenticated connections.'
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
