# Guard used at the top of every check: the Veeam.Backup.PowerShell surface varies
# by installed feature, so a check must never assume a cmdlet exists. True only
# when all named cmdlets resolve.

function Test-PrecheckCmdlet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromRemainingArguments)]
        [string[]] $Name
    )
    foreach ($n in $Name) {
        # Cmdlet availability cannot change during a run, so resolve each name once.
        if (-not $script:PrecheckCmdletCache.ContainsKey($n)) {
            $script:PrecheckCmdletCache[$n] = [bool](Get-Command -Name $n -ErrorAction SilentlyContinue)
        }
        if (-not $script:PrecheckCmdletCache[$n]) { return $false }
    }
    return $true
}

# Per-run cache for data several checks share (licence, job list, Entra ID
# tenants, storage plug-in hosts). Cleared at the start of every run, so it cannot
# go stale or leak between servers. ContainsKey, not a null test, so an empty
# result is cached rather than re-fetched.

$script:PrecheckCache       = @{}
$script:PrecheckCmdletCache = @{}

function Clear-PrecheckCache {
    [CmdletBinding()] param()
    $script:PrecheckCache       = @{}
    $script:PrecheckCmdletCache = @{}
}

function Get-PrecheckCached {
    # A getter that throws is not cached, so a transient failure stays transient.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]      $Key,
        [Parameter(Mandatory)] [scriptblock] $Getter
    )
    if (-not $script:PrecheckCache.ContainsKey($Key)) {
        $script:PrecheckCache[$Key] = & $Getter
    }
    # Plain return, not `return ,$value`: callers use @(...), and the comma form
    # makes that yield one element containing the collection.
    return $script:PrecheckCache[$Key]
}

# Stops one failing check from aborting the run. A check that throws is a defect,
# so the result is labelled with the function to fix rather than a KB item ID.
function Invoke-PrecheckSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [scriptblock] $Body
    )
    try {
        & $Body
    }
    catch {
        Write-PrecheckLog "Check $Title errored: $($_.Exception.Message)" -Level WARN
        New-PrecheckResult -Id "FAILED" -Category 'Check error' -Title $Title -Status Info `
            -Detail "$Title did not complete, so its KB4800 item was NOT evaluated: $($_.Exception.Message)" `
            -Recommendation 'This is a tool defect - report it. Meanwhile evaluate this limitation manually against KB4800.'
    }
}
