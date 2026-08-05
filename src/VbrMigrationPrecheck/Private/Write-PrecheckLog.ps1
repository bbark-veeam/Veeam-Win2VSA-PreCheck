# Write-PrecheckLog
# Minimal, dependency-free console/file logger shared by the orchestrator and
# checks. Level colouring keeps the interactive run readable; the same lines are
# appended to $script:PrecheckLogFile when the orchestrator has set one.

function Write-PrecheckLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG', 'STEP')]
        [string] $Level = 'INFO'
    )

    $ts   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"

    if ($Level -eq 'DEBUG' -and -not $script:PrecheckVerbose) {
        # Debug lines still go to the file, just not the console.
    } else {
        $color = switch ($Level) {
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red' }
            'STEP'  { 'Cyan' }
            'DEBUG' { 'DarkGray' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }

    if ($script:PrecheckLogFile) {
        try { Add-Content -Path $script:PrecheckLogFile -Value $line -ErrorAction Stop } catch { }
    }
}
