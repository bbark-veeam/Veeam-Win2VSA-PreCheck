# Export-PrecheckReport
# Writes the precheck results to disk as JSON (machine-readable, feeds the
# migration runbook / ticketing) or a self-contained HTML page (share with the
# customer / account team). No external assets - safe to email.

function Export-PrecheckReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Results,
        [Parameter(Mandatory)] $Verdict,
        $Context,
        [ValidateSet('Json', 'Html')]
        [string] $Format = 'Json',
        [Parameter(Mandatory)] [string] $Path
    )

    $generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')

    if ($Format -eq 'Json') {
        $payload = [PSCustomObject]@{
            tool          = 'VbrMigrationPrecheck'
            # Version matters most here: JSON is what aggregates across a fleet, and
            # a phased migration means reports arrive from several tool builds.
            toolVersion   = if ($script:PrecheckVersion) { $script:PrecheckVersion } else { 'unknown' }
            kb            = 'https://www.veeam.com/kb4800'
            # KB4800 is a living document; record when it was mapped to these checks.
            kbCaptured    = if ($script:PrecheckKbCaptured) { $script:PrecheckKbCaptured } else { 'unknown' }
            generatedAt   = $generated
            server        = if ($Context) { $Context.Server } else { $null }
            productBuild  = if ($Context) { $Context.ProductString } else { $null }
            verdict       = $Verdict.Label
            exitCode      = $Verdict.ExitCode
            counts        = $Verdict.Counts
            results       = $Results
        }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
        return $Path
    }

    # --- HTML -----------------------------------------------------------------
    $enc = { param($s) if ($null -eq $s) { '' } else { [System.Net.WebUtility]::HtmlEncode([string]$s) } }

    $badge = @{
        Blocker = '#c0392b'; Action = '#8e44ad'; Warning = '#d68910'
        Manual  = '#2980b9'; NextStep = '#1f6feb'; Info = '#7f8c8d'; Pass = '#27ae60'; Skipped = '#95a5a6'
    }
    $verdictColor = switch ($Verdict.Label) {
        'MIGRATION BLOCKED' { '#c0392b' }
        'ACTION REQUIRED'   { '#8e44ad' }
        'REVIEW WARNINGS'   { '#d68910' }
        default             { '#27ae60' }
    }

    $limitationResults = $Results | Where-Object { $_.Status -ne 'NextStep' }
    $nextSteps         = @($Results | Where-Object { $_.Status -eq 'NextStep' } | Sort-Object Id)

    $rows = foreach ($r in ($limitationResults | Sort-Object -Property @{E = 'Rank'; Descending = $true}, Id)) {
        $ev = ''
        if ($r.Evidence -and $r.Evidence.Count -gt 0) {
            $items = ($r.Evidence | ForEach-Object { "<li>$(& $enc $_)</li>" }) -join ''
            $ev = "<ul class='ev'>$items</ul>"
        }
        $color = $badge[$r.Status]
@"
<tr>
  <td><span class="pill" style="background:$color">$(& $enc $r.Status)</span></td>
  <td class="mono">$(& $enc $r.Id)</td>
  <td>
    <div class="title">$(& $enc $r.Title)</div>
    <div class="detail">$(& $enc $r.Detail)</div>
    $(if ($r.Recommendation) { "<div class='rec'>&#8594; $(& $enc $r.Recommendation)</div>" })
    $ev
  </td>
  <td class="cat">$(& $enc $r.Category)</td>
</tr>
"@
    }

    # Pre-migration next steps block (only rendered when any apply).
    $nextStepsHtml = ''
    if ($nextSteps.Count -gt 0) {
        $nsItems = foreach ($r in $nextSteps) {
            $ev = ''
            if ($r.Evidence -and $r.Evidence.Count -gt 0) {
                $items = ($r.Evidence | ForEach-Object { "<li>$(& $enc $_)</li>" }) -join ''
                $ev = "<ul class='ev'>$items</ul>"
            }
@"
<li class="nsitem">
  <div class="title"><span class="mono">$(& $enc $r.Id)</span> &nbsp; $(& $enc $r.Title)</div>
  <div class="detail">$(& $enc $r.Detail)</div>
  $(if ($r.Recommendation) { "<div class='rec'>&#8594; $(& $enc $r.Recommendation)</div>" })
  $ev
</li>
"@
        }
        $nextStepsHtml = @"
  <div class="nextsteps">
    <h2>Pre-Migration Next Steps ($($nextSteps.Count))</h2>
    <p class="nsintro">KB4800 preparation actions that apply to this environment &mdash; complete these before starting the migration.</p>
    <ul class="nslist">
      $($nsItems -join "`n")
    </ul>
  </div>
"@
    }

    $c = $Verdict.Counts
    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>VBR to VSA Migration Precheck</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif; margin: 0; background:#f4f6f8; color:#1c2833; }
  @media (prefers-color-scheme: dark){ body{ background:#12171d; color:#e6eaee } .card,.legend,table{ background:#1b222b !important } td,th{ border-color:#2b333d !important } .detail{ color:#9aa7b4 !important } }
  header { background:#0b3d5c; color:#fff; padding:22px 28px; }
  header h1 { margin:0 0 4px; font-size:20px; }
  header .meta { font-size:13px; opacity:.85 }
  .wrap { max-width:1100px; margin:0 auto; padding:20px 28px 60px; }
  .verdict { display:inline-block; padding:10px 18px; border-radius:8px; color:#fff; font-weight:700; font-size:18px; background:$verdictColor; margin:18px 0 8px; }
  .counts { font-size:13px; color:#566573; margin-bottom:18px; }
  .nextsteps { margin-top:26px; border:1px solid #1f6feb; border-radius:10px; padding:6px 20px 14px; background:#eef4ff; }
  @media (prefers-color-scheme: dark){ .nextsteps{ background:#12203a !important; border-color:#1f6feb } }
  .nextsteps h2 { font-size:16px; color:#1f6feb; margin:14px 0 2px; }
  .nsintro { font-size:13px; color:#566573; margin:0 0 8px; }
  .nslist { list-style:none; margin:0; padding:0; }
  .nsitem { padding:10px 0; border-top:1px solid #d5e2fb; }
  .nsitem:first-child { border-top:none; }
  .card { background:#fff; border-radius:10px; box-shadow:0 1px 3px rgba(0,0,0,.12); overflow:hidden; }
  table { width:100%; border-collapse:collapse; background:#fff; }
  th,td { text-align:left; padding:11px 14px; border-bottom:1px solid #e5e9ed; vertical-align:top; font-size:14px; }
  th { background:#eef2f5; font-size:12px; text-transform:uppercase; letter-spacing:.04em; color:#566573; }
  .pill { color:#fff; padding:3px 9px; border-radius:20px; font-size:11px; font-weight:700; letter-spacing:.03em; white-space:nowrap; }
  .mono { font-family:ui-monospace, Menlo, Consolas, monospace; font-size:12px; color:#566573; white-space:nowrap; }
  .title { font-weight:600; }
  .detail { color:#566573; margin-top:3px; }
  .rec { margin-top:5px; color:#0b6; font-weight:600; }
  .ev { margin:6px 0 0; padding-left:18px; color:#7f8c8d; font-size:13px; }
  .cat { color:#7f8c8d; font-size:13px; white-space:nowrap; }
  footer { max-width:1100px; margin:0 auto; padding:0 28px 40px; color:#7f8c8d; font-size:12px; }
</style></head>
<body>
<header>
  <h1>Windows VBR &#8594; Veeam Software Appliance &mdash; Migration Precheck</h1>
  <div class="meta">Server: $(& $enc ($(if ($Context) { $Context.Server } else { 'n/a' }))) &nbsp;|&nbsp;
    Build: $(& $enc ($(if ($Context) { $Context.ProductString } else { 'n/a' }))) &nbsp;|&nbsp;
    Generated: $(& $enc $generated) &nbsp;|&nbsp;
    Precheck version: $(& $enc $(if ($script:PrecheckVersion) { $script:PrecheckVersion } else { 'unknown' })) &nbsp;|&nbsp;
    Reference: KB4800 (captured $(& $enc $(if ($script:PrecheckKbCaptured) { $script:PrecheckKbCaptured } else { 'unknown' })))</div>
</header>
<div class="wrap">
  <div class="verdict">$(& $enc $Verdict.Label)</div>
  <div class="counts">$($Verdict.Total) checks &nbsp;&bull;&nbsp; Blocker $($c.Blocker) &nbsp;&bull;&nbsp; Action $($c.Action) &nbsp;&bull;&nbsp; Warning $($c.Warning) &nbsp;&bull;&nbsp; Manual $($c.Manual) &nbsp;&bull;&nbsp; NextStep $($c.NextStep) &nbsp;&bull;&nbsp; Info $($c.Info) &nbsp;&bull;&nbsp; Pass $($c.Pass) &nbsp;&bull;&nbsp; Skipped $($c.Skipped)</div>
  <div class="card">
    <table>
      <thead><tr><th>Status</th><th>ID</th><th>Check</th><th>Category</th></tr></thead>
      <tbody>
        $($rows -join "`n")
      </tbody>
    </table>
  </div>
$nextStepsHtml
</div>
<footer>
  Generated by VbrMigrationPrecheck. This report evaluates the known limitations in Veeam KB4800 and is provided as guidance;
  it does not guarantee migration success. Verify Info/Manual items by hand.
</footer>
</body></html>
"@

    $html | Set-Content -Path $Path -Encoding UTF8
    return $Path
}
