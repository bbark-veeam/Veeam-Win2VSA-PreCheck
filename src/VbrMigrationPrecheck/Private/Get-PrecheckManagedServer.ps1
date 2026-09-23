# Shared reader for the managed-server inventory (Get-VBRServer).
#
# Lives in Private/ rather than beside one check because THREE checks in two files
# need it - DEP-004 and DEP-006 in Test-Deployment.ps1, and PRE-002 in
# Test-PreMigration.ps1. Going through Get-PrecheckCached means the server list is
# fetched once per run rather than per caller, which is the same arrangement every
# other shared cmdlet in the tool already uses (jobs, protection groups, policies,
# licence, Entra ID tenants, storage plug-in hosts).
#
# Returns an OBJECT carrying an explicit Ok flag, not a bare collection. Returning
# $null-for-unreadable and @()-for-empty looks equivalent and is not: PowerShell
# unrolls an empty array on return, so `return @()` arrives at the caller as $null
# and "could not be read" becomes indistinguishable from "read, found none". A
# pscustomobject is a single object and never unrolls, so the two stay distinct -
# which is the whole point, an unread collection reported as "none found" being the
# false-clean-result defect this tool has hit fifteen times.
function Get-PrecheckManagedServer {
    [CmdletBinding()] param()
    if (-not (Test-PrecheckCmdlet 'Get-VBRServer')) {
        return [pscustomobject]@{ Ok = $false; Server = @() }
    }
    try {
        $s = @(Get-PrecheckCached -Key 'Servers' -Getter { Get-VBRServer -ErrorAction Stop })
        return [pscustomobject]@{ Ok = $true; Server = $s }
    }
    catch { return [pscustomobject]@{ Ok = $false; Server = @() } }
}

# Exact enum comparison against VBRHostType, never a substring match. 'Scvmm' and
# 'HvCluster' are both VBRHostType values; matching loosely is the defect class that
# produced AGT-004 (ManuallyDeployed vs ManuallyAdded) and was tightened in PRE-003.
function Get-PrecheckServerOfType {
    [CmdletBinding()] param([object[]] $Server, [string] $Type)
    @($Server | Where-Object {
        $_.PSObject.Properties['Type'] -and "$($_.Type)" -eq $Type
    })
}
