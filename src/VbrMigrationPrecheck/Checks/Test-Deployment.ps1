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
        -Detail 'No Microsoft Entra ID tenant backups found.'
}
