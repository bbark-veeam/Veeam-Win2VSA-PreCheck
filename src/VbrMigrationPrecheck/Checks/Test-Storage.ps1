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
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail 'No NetApp ONTAP storage integration found.'
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
            -Detail 'No Universal Storage Plugin integrations detected (IBM FlashSystem / Hitachi / HPE XP).'
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
            -Detail 'No HPE Nimble / Alletra 5000/6000 integration detected.'
    }
    return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Warning `
        -Detail "$($hosts.Count) HPE Nimble/Alletra system(s) detected. Some Nimble OS versions may be unsupported when the Veeam Software Appliance runs in FIPS-compliant mode." `
        -Recommendation 'Verify Nimble OS version support against FIPS mode before migrating (or before enabling FIPS on the VSA).' `
        -Evidence ($hosts | ForEach-Object { "Storage: $($_.Name)" })
}
