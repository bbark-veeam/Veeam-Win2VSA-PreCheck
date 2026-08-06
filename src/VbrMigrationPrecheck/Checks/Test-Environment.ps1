# Environment checks: product version/patch and license model.
# KB4800: "Version Requirements" and "License Requirements".

function Test-VbrVersion {
    [CmdletBinding()] param([Parameter(Mandatory)] $Ctx)

    $id = 'ENV-001'; $cat = 'Environment'; $title = 'Source VBR version'
    $build = $Ctx.ProductBuild

    if (-not $build) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Info `
            -Detail "Could not resolve the installed VBR build (detected string: '$($Ctx.ProductString)')." `
            -Recommendation 'Confirm manually that the server runs the latest available Veeam Backup & Replication 13.0.x patch, and deploy the target Veeam Software Appliance at that same version - the source and target versions must match. Migration is NOT validated on 13.1 or later.'
    }

    $detail = "Detected build $build ('$($Ctx.ProductString)')."

    if ($build.Major -lt 13) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Action `
            -Detail "$detail This is older than 13.0." `
            -Recommendation 'Upgrade the Windows VBR server to the latest 13.0.x patch before attempting migration, then deploy the target Veeam Software Appliance at that same version - the source and target versions must match.'
    }
    if ($build.Major -eq 13 -and $build.Minor -eq 0) {
        return New-PrecheckResult -Id $id -Category $cat -Title $title -Status Pass `
            -Detail "$detail This is within the supported 13.0.x train. The target Veeam Software Appliance must be running this same version, $build." `
            -Recommendation "Deploy or update the target Veeam Software Appliance to $build - the source and target versions must match. Confirm first that $build is the latest available 13.0.x patch; if it is not, patch this server and match the appliance to whatever it then reports."
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
