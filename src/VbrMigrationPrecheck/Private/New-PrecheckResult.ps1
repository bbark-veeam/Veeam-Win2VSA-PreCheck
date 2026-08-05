# New-PrecheckResult
# Factory for the single result object every check returns. Keeping one shape
# here means the orchestrator, console renderer, and JSON/HTML exporters can all
# rely on the same fields.
#
# Status vocabulary (also drives the overall verdict and the exit code):
#   Pass     - no issue found for this limitation.
#   Blocker  - migration is NOT supported / WILL fail until resolved. Hard stop.
#   Action   - must be remediated BEFORE migration or it will fail.
#   Warning  - migration proceeds, but configuration is lost/changed/disabled.
#   Manual   - a manual step is required (pre- or post-migration) that cannot be
#              automated; operator must confirm it was done.
#   NextStep - an advisory PRE-migration preparation action (from KB4800's
#              "Pre-Migration Considerations"). Not a blocker; surfaced in the
#              report's "Pre-Migration Next Steps" section, and typically only
#              when the related limitation applies to this environment.
#   Info     - could not be auto-evaluated (cmdlet/property absent); verify by hand.
#   Skipped  - check not applicable to this deployment.

# When KB4800 was last read and mapped to these checks. Stamped into every report so
# a report stays honestly bounded: the KB is a living document and its guidance can
# change with a new release, long after a given report was produced.
# UPDATE THIS whenever KB4800 is re-read and the checks are reconciled against it.
$script:PrecheckKbCaptured = '2026-07-24'

$script:PrecheckStatusRank = @{
    Blocker  = 6
    Action   = 5
    Warning  = 4
    Manual   = 3
    NextStep = 2
    Info     = 1
    Pass     = 0
    Skipped  = 0
}

function New-PrecheckResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Blocker', 'Action', 'Warning', 'Manual', 'NextStep', 'Info', 'Skipped')]
        [string] $Status,
        [string]   $Detail = '',
        [string]   $Recommendation = '',
        # Concrete objects/names that triggered the finding (job names, repo
        # names, credential names, dates...). Rendered as a bullet list.
        [object[]] $Evidence = @(),
        # KB4800 anchor / doc reference for the operator to read more.
        [string]   $Reference = 'https://www.veeam.com/kb4800'
    )

    [PSCustomObject]@{
        Id             = $Id
        Category       = $Category
        Title          = $Title
        Status         = $Status
        Rank           = $script:PrecheckStatusRank[$Status]
        Detail         = $Detail
        Recommendation = $Recommendation
        Evidence       = @($Evidence)
        Reference      = $Reference
    }
}
