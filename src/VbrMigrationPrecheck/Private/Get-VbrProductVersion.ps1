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
