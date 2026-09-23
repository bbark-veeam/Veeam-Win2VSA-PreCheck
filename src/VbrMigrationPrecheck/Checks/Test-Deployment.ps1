# Deployment-shape checks: configurations that block or partially block a whole
# deployment from migrating.
# KB4800: "Cloud Connectivity", "Google Cloud Integration", "Entra ID Tenant Backups",
# "Hyper-V SCVMM High Availability", "Veeam Plug-in for oVirt", "Hyper-V workgroup
# clusters" (the last three added to KB4800 on 2026-09-10).

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
        # ⚠️ THE LICENCE FILE ITSELF IS THE BLOCKER. Tenants and gateways are evidence
        # only, and their ABSENCE proves nothing. Do not make this conditional on finding
        # any Cloud Connect architecture: Brad has seen this exact licence file block a
        # real migration on a server with NO Cloud Connect architecture at all - no
        # tenants, no gateways, no repositories. Requiring usage before blocking would
        # have missed that, which is a false clean result on the highest-severity check
        # in the tool.
        #
        # Measured corroboration: on one server across six runs an EnterprisePlus
        # subscription reported CloudConnect = Disabled; installing a Cloud Connect
        # licence on that same server - same type, same edition - flipped it to
        # Enterprise. The property is not an artefact of the licence edition.
        #
        # So state plainly that the licence alone decides, and distinguish "none
        # configured" from "could not be read". "0 found" on its own reads like a Cloud
        # Connect deployment with nothing in it, which invites the reader to doubt a
        # finding that is in fact correct.
        $tenants  = @()
        $gateways = @()
        $readTenants  = $false
        $readGateways = $false
        try { if (Test-PrecheckCmdlet 'Get-VBRCloudTenant')  { $tenants  = @(Get-VBRCloudTenant  -ErrorAction Stop); $readTenants  = $true } } catch { }
        try { if (Test-PrecheckCmdlet 'Get-VBRCloudGateway') { $gateways = @(Get-VBRCloudGateway -ErrorAction Stop); $readGateways = $true } } catch { }

        $configured =
            if (-not $readTenants -and -not $readGateways) {
                'Its tenants and gateways could not be read, which does not affect this result: the licence is what determines it.'
            }
            elseif ($tenants.Count -eq 0 -and $gateways.Count -eq 0) {
                'No tenants or gateways are configured on it. That does not change the result: the license file itself prevents migration, whether or not any Cloud Connect architecture has been built.'
            }
            else {
                "$($tenants.Count) tenant(s) and $($gateways.Count) gateway(s) are configured."
            }

        $ev = @("License CloudConnect mode: $ccMode",
                "Tenants: $(if ($readTenants) { $tenants.Count } else { 'could not be read' })",
                "Gateways: $(if ($readGateways) { $gateways.Count } else { 'could not be read' })") +
              @($tenants  | ForEach-Object { "Tenant: $($_.Name)" }) +
              @($gateways | ForEach-Object { "Gateway: $($_.Name)" })

        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Blocker `
            -Detail "This server is Cloud Connect licensed - the installed license reports CloudConnect = $ccMode. $configured Cloud Connect deployments cannot be migrated to the Veeam Software Appliance." `
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

function Test-ScvmmHighAvailability {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'DEP-004'; $cat = 'Deployment'; $title = 'Hyper-V SCVMM'

    # KB4800 (2026-09-10): the Veeam Software Appliance does not support the Hyper-V
    # SCVMM High Availability feature.
    #
    # ⚠️ Whether the HA FEATURE is in use is not exposed anywhere on the PowerShell
    # surface - there is no Get-VBRHvScvmm at all (only Add-/Set-), so SCVMM is
    # reachable only as a host type on Get-VBRServer. This check therefore reports
    # SCVMM PRESENCE and asks the operator to confirm the feature, rather than
    # claiming a configuration it cannot read. Presence is provable; use is not.
    #
    # It fires on every SCVMM-managed Hyper-V estate by construction. That is
    # intended: Manual never changes the exit code, and staying silent on a server
    # that may carry an unsupported feature is the worse failure.
    $inv = Get-PrecheckManagedServer
    if (-not $inv.Ok) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'The managed-server inventory could not be read, so whether an SCVMM server is connected to this deployment is unknown.' `
            -Recommendation 'Confirm by hand whether System Center Virtual Machine Manager is added to this deployment. The Veeam Software Appliance does not support the Hyper-V SCVMM High Availability feature.'
    }
    $servers = @($inv.Server)

    $scvmm = Get-PrecheckServerOfType -Server $servers -Type 'Scvmm'
    if ($scvmm.Count -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "$($scvmm.Count) System Center Virtual Machine Manager server(s) are connected to this deployment. The Veeam Software Appliance does not support the Hyper-V SCVMM High Availability feature. Whether that feature is actually in use is NOT readable from Veeam PowerShell, so this is flagged for confirmation rather than reported as a finding." `
            -Recommendation 'Confirm in SCVMM whether the High Availability feature is in use. If it is, that configuration is not supported on the Veeam Software Appliance and must be resolved with Veeam Support before migrating.' `
            -Evidence ($scvmm | ForEach-Object { "SCVMM server: $($_.Name)" })
    }

    # The limitation is scoped to SCVMM being added to Veeam, so both of these are a
    # clean pass and the detail says which one applies: a deployment with no Hyper-V at
    # all, and a Hyper-V deployment managed without SCVMM.
    $hyperV = @(Get-PrecheckServerOfType -Server $servers -Type 'HvServer') +
              @(Get-PrecheckServerOfType -Server $servers -Type 'HvCluster')
    $scope = if ($hyperV.Count -eq 0) {
        'No Hyper-V host or cluster is connected to this deployment at all.'
    } else {
        "$($hyperV.Count) Hyper-V host(s)/cluster(s) are connected, but none is managed through SCVMM."
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
        -Detail "$($servers.Count) managed server(s) were enumerated and none is an SCVMM server. $scope The limitation applies only where SCVMM is added to Veeam, so it does not apply here."
}

function Test-OVirtPlugin {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'DEP-005'; $cat = 'Deployment'; $title = 'Veeam Plug-in for oVirt'

    # KB4800 (2026-09-10): oVirt plug-in configuration cannot be migrated, because the
    # plug-in is not available for VSA 13.0.x - the only version that supports
    # migration. (13.1 has the plug-in but not migration, so there is no version where
    # both work; affected customers are told to stay on Windows for now.)
    #
    # ⚠️⚠️ THIS CHECK ORIGINALLY READ Get-VBRPluginJob AND WOULD NEVER HAVE FIRED.
    # Measured 2026-09-23 on a 13.1.1.18 appliance carrying three hypervisor plug-in
    # jobs (Nutanix AHV, Proxmox VE, HPE Morpheus): Get-VBRPluginJob returned ZERO.
    # That cmdlet covers the standalone ENTERPRISE DATABASE plug-ins - Oracle RMAN, SAP
    # HANA, MSSQL - not hypervisor integrations. A plausible cmdlet name returning
    # nothing while reporting a confident clean result is this tool's signature defect,
    # and it was caught only because the shape was measured before release.
    #
    # WHAT ACTUALLY IDENTIFIES A HYPERVISOR PLUG-IN JOB, measured on that server:
    #   Get-VBRJob  ->  JobType      = VmbApiPolicyTempJob   (all three plug-ins)
    #                   BackupPlatform = ECustomPlatform     (all three, a CPlatform
    #                                    CLASS - not an enum - so it cannot name which)
    #                   TypeToString = "Proxmox Backup"      <- the platform, a STRING
    #
    # So TypeToString is the discriminator. Two consequences:
    #   1. It is a free-form string, NOT an enum, so oVirt's exact value cannot be
    #      reflected. Six enums were dumped in full and none carries an oVirt member.
    #      Do NOT guess the value from the Proxmox one - that is the AGT-003
    #      'Mac'-matches-"machine" mistake. A real oVirt sighting is still required
    #      before this can become the Blocker its KB severity justifies.
    #   2. ⚠️ The CONSOLE'S Type column is NOT TypeToString. The console shows
    #      "Proxmox VE Backup"; the property says "Proxmox Backup". Never build a
    #      check from a screenshot.
    $jobsOk = $false
    $platformJobs = @()
    if (Test-PrecheckCmdlet 'Get-VBRJob') {
        try {
            $allJobs = @(Get-PrecheckCached -Key 'Jobs' -Getter { Get-VBRJob -ErrorAction Stop })
            # Exact enum comparison, never a substring - the PRE-003 rule.
            $platformJobs = @($allJobs | Where-Object {
                $_.PSObject.Properties['JobType'] -and "$($_.JobType)" -eq 'VmbApiPolicyTempJob'
            })
            $jobsOk = $true
        }
        catch { }
    }

    # Second signal, and it closes the old blind spot: plug-in infrastructure
    # registered with NO job. Measured - a Nutanix cluster registers as
    # ExternalInfrastructureServer. That type is shared with Azure and others, so it
    # cannot name oVirt either; it is reported as a candidate, not a finding.
    $inv = Get-PrecheckManagedServer
    $extHosts = if ($inv.Ok) { @(Get-PrecheckServerOfType -Server $inv.Server -Type 'ExternalInfrastructureServer') } else { @() }

    if (-not $jobsOk -or -not $inv.Ok) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'Whether a plug-in platform is configured on this server could not be determined - the job list or the managed-server inventory could not be read.' `
            -Recommendation 'Confirm by hand whether the Veeam Plug-in for oVirt is in use. Its configuration cannot be migrated, because the plug-in is not available for the Veeam Software Appliance 13.0.x releases that support migration.' `
            -Evidence @("Job list: $(if ($jobsOk) { 'read' } else { 'could not be read' })",
                        "Managed-server inventory: $(if ($inv.Ok) { 'read' } else { 'could not be read' })")
    }

    $ev = @()
    foreach ($j in $platformJobs) {
        $plat = if ($j.PSObject.Properties['TypeToString'] -and $j.TypeToString) { "$($j.TypeToString)" } else { 'platform not readable' }
        $ev += "Plug-in job: $($j.Name) [$plat]"
    }
    foreach ($h in $extHosts) { $ev += "External infrastructure host: $($h.Name)" }

    if ($ev.Count -gt 0) {
        # Any oVirt-shaped wording upgrades the language, but the status stays Manual:
        # the vocabulary is unconfirmed in both directions.
        $looksOVirt = @($ev | Where-Object { $_ -match 'oVirt|RHV|Red\s*Hat' })
        $lead = if ($looksOVirt.Count -gt 0) {
            'Configuration that appears to belong to the Veeam Plug-in for oVirt was found on this server.'
        } else {
            "$($platformJobs.Count) plug-in platform job(s) and $($extHosts.Count) external-infrastructure host(s) are configured on this server. None names oVirt, but the exact wording oVirt uses has not been confirmed against a live oVirt deployment, so this is listed for a human to confirm rather than cleared."
        }
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "$lead Any configuration associated with the Veeam Plug-in for oVirt will NOT migrate, because the plug-in is not available for the Veeam Software Appliance 13.0.x releases that support migration." `
            -Recommendation 'Confirm whether any item below belongs to the Veeam Plug-in for oVirt. If so, it cannot be migrated: either remove all oVirt configuration before migrating and rebuild it after upgrading the appliance, or stay on the Windows deployment until a release supports both the plug-in and migration. Items belonging to other plug-in platforms (Proxmox, Nutanix, HPE Morpheus) are unaffected by this limitation.' `
            -Evidence ($ev | Sort-Object -Unique)
    }

    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
        -Detail "No plug-in platform configuration found. The job list and the managed-server inventory were both read: no job carries the plug-in platform job type, and no external-infrastructure host is registered. The Veeam Plug-in for oVirt is therefore not configured here."
}

function Test-HyperVWorkgroupCluster {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'DEP-006'; $cat = 'Deployment'; $title = 'Hyper-V workgroup cluster'

    # KB4800 (2026-09-10): Linux-based backup servers do not support Hyper-V workgroup
    # clusters; the configuration is Windows-only.
    #
    # ⚠️ "Workgroup" means the cluster is NOT domain-joined, and that is not something
    # this check can read. Do NOT infer it from the name: SEC-004 learned that lesson
    # the hard way - a dotted name and a NetBIOS-style label are indistinguishable as
    # shapes, and guessing either way is harmful at fleet scale. So presence of a
    # Hyper-V cluster is reported, and domain membership is left to the operator.
    #
    # Most Hyper-V clusters ARE domain-joined and therefore unaffected, so the finding
    # says so plainly rather than implying every cluster is a problem.
    $inv = Get-PrecheckManagedServer
    if (-not $inv.Ok) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail 'The managed-server inventory could not be read, so whether a Hyper-V cluster is connected to this deployment is unknown.' `
            -Recommendation 'Confirm by hand whether any Hyper-V cluster in this deployment is a workgroup (non-domain-joined) cluster. Those are not supported on a Linux-based backup server.'
    }
    $servers = @($inv.Server)

    $clusters = Get-PrecheckServerOfType -Server $servers -Type 'HvCluster'
    if ($clusters.Count -gt 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "$($clusters.Count) Hyper-V cluster(s) are connected to this deployment. Linux-based backup servers do not support Hyper-V WORKGROUP clusters. Whether a cluster is domain-joined is NOT readable from Veeam PowerShell, so this is flagged for confirmation - a domain-joined Hyper-V cluster is unaffected and needs no action." `
            -Recommendation 'Confirm whether any cluster below is a workgroup (non-domain-joined) cluster. If one is, it cannot be managed from the Veeam Software Appliance and must be domain-joined or excluded before migrating. Domain-joined clusters require no action.' `
            -Evidence ($clusters | ForEach-Object { "Hyper-V cluster: $($_.Name)" })
    }

    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
        -Detail "$($servers.Count) managed server(s) were enumerated and none is a Hyper-V cluster, so the workgroup-cluster limitation does not apply to this deployment."
}
