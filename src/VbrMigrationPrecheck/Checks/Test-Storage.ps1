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
            -Recommendation 'If HPE Nimble/Alletra 5000/6000 is integrated, confirm the Nimble OS version on each array is supported when the Linux-based backup server runs in FIPS-compliant mode.'
    }

    $hosts = @(Get-NimbleHost -ErrorAction SilentlyContinue)
    if ($hosts.Count -eq 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail 'The storage inventory on this server was read successfully and contains no HPE Nimble or Alletra 5000/6000 systems, so FIPS-compliant mode does not need review.'
    }

    # UG, HPE Alletra 5000/6000, Nimble limitations: "Some versions of Nimble OS may not
    # be supported when the Linux-based backup server operates in FIPS-compliant mode."
    # So it is VERSION-dependent, and the mode that matters is the LINUX server's - i.e.
    # the appliance being migrated TO. It is NOT scoped to Backup from Storage Snapshots;
    # that is a separate consideration on the same page (Nimble Connection Manager on
    # Windows proxies) and is out of KB4800 scope.
    #
    # The restriction only bites when FIPS-compliant mode is in use, and that state is
    # readable: Get-VBRSecurityOptions exposes FipsCompliantModeEnabled. Reading it turns
    # one undifferentiated warning on every Nimble server into a finding that says whether
    # this server is actually affected.
    #
    # NOTE the mode that ultimately matters is the one on the TARGET appliance, which
    # cannot be read from here. The setting on this server is the best available signal of
    # intent, and it errs safe: nobody is asked to make a decision who is not already
    # running FIPS.
    $fips = $null
    if (Test-PrecheckCmdlet 'Get-VBRSecurityOptions') {
        try {
            $so = Get-PrecheckCached -Key 'SecurityOptions' -Getter { Get-VBRSecurityOptions -ErrorAction Stop }
            if ($so -and $so.PSObject.Properties['FipsCompliantModeEnabled']) {
                $fips = [bool]$so.FipsCompliantModeEnabled
            }
        } catch { }
    }

    $ev = @($hosts | ForEach-Object { "Storage: $($_.Name)" }) +
          @("FIPS-compliant mode on this server: $(if ($null -eq $fips) { 'could not be read' } else { $fips })")

    if ($fips) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "$($hosts.Count) HPE Nimble/Alletra system(s) are integrated and FIPS-compliant mode is enabled on this server. Some Nimble OS versions may not be supported when the Linux-based backup server runs in FIPS-compliant mode, so the Nimble OS version on each array needs checking against that before migrating." `
            -Recommendation 'Confirm the Nimble OS version on each array is supported with FIPS-compliant mode on a Linux-based backup server. Where it is not, the choice is between FIPS-compliant mode - often not optional in a secure environment - and continuing to use that array with the appliance.' `
            -Evidence $ev
    }

    if ($null -eq $fips) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Manual `
            -Detail "$($hosts.Count) HPE Nimble/Alletra system(s) are integrated, and whether FIPS-compliant mode is enabled could not be read on this server. Some Nimble OS versions may not be supported when the Linux-based backup server runs in FIPS-compliant mode." `
            -Recommendation 'Check whether FIPS-compliant mode is in use. If it is, confirm the Nimble OS version on each array is supported with FIPS-compliant mode on a Linux-based backup server before migrating.' `
            -Evidence $ev
    }

    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Warning `
        -Detail "$($hosts.Count) HPE Nimble/Alletra system(s) are integrated. FIPS-compliant mode is not enabled on this server, so nothing is affected today - but some Nimble OS versions may not be supported when the Linux-based backup server runs in FIPS-compliant mode, so enabling it on the appliance later would mean checking the Nimble OS versions first." `
        -Recommendation 'If FIPS-compliant mode will be enabled on the Veeam Software Appliance, confirm first that the Nimble OS version on each array is supported with FIPS-compliant mode on a Linux-based backup server.' `
        -Evidence $ev
}
