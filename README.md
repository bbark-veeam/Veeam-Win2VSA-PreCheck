# Veeam Windows VBR → VSA Migration Precheck

A **read-only** PowerShell script that checks a Windows Veeam Backup & Replication
server against the known limitations in [KB4800](https://www.veeam.com/kb4800) before
you migrate it to the Veeam Software Appliance (VSA).

It answers one question per check: *will this configuration survive the migration, and
if not, what has to change first?* Findings are ranked, and the exit code reflects the
verdict so the script can be run unattended.

One file, no dependencies, nothing to install.

---

## Download

**You need exactly one file: [`VbrMigrationPrecheck.ps1`](VbrMigrationPrecheck.ps1).**

```powershell
# On the VBR server
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/bbark-veeam/Veeam-Win2VSA-PreCheck/main/VbrMigrationPrecheck.ps1' `
                  -OutFile .\VbrMigrationPrecheck.ps1
```

Or download it from the [latest release](../../releases/latest).

> **Do not clone the repository to run the precheck.** The `src/` folder is the module the
> script is *built from*, kept here so the tool can be maintained and reviewed. It is not
> a second way to run the precheck, and copying a folder tree onto a backup server is the
> mistake this single-file distribution exists to prevent.

---

## Requirements

- **PowerShell 7.0 or later**
- Run it **on the Windows VBR server itself** (some checks read local state and will
  say so when they cannot)
- An account that can read the VBR configuration — the same rights you would use for
  the console
- The source server should be on the **13.0.x** train. 13.1 cannot be migrated, and the
  script reports that as a hard blocker.

## Running it

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\VbrMigrationPrecheck.ps1
```

`Set-ExecutionPolicy Bypass -Scope Process` applies to that shell only. It is needed
because a file downloaded from the internet carries Windows' Mark of the Web. You can
remove the mark instead:

```powershell
Unblock-File .\VbrMigrationPrecheck.ps1
```

### Useful parameters

```powershell
# Supply the date this environment was upgraded, so session-history retention
# can be judged automatically instead of by hand.
.\VbrMigrationPrecheck.ps1 -UpgradeDate 2024-06-01

# Write reports somewhere specific (default: an 'output' folder beside the script)
.\VbrMigrationPrecheck.ps1 -OutputPath D:\PrecheckReports

# Console summary only
.\VbrMigrationPrecheck.ps1 -ReportFormat None
```

| Parameter | Purpose |
|---|---|
| `-Server` | VBR server to evaluate. Default `localhost`. Run on the server itself where possible. |
| `-Credential` | Alternate credentials for the VBR connection. |
| `-UpgradeDate` | The date this environment was upgraded, for the job-history check. Aliases: `-V12UpgradeDate`, `-V13UpgradeDate`. |
| `-OutputPath` | Where reports are written. |
| `-ReportFormat` | `None`, `Json`, `Html`, or `All` (default). |
| `-VerboseLog` | Extra detail in the log file. |

### Re-run close to each server's migration date

A server that is 13.0.x today can be patched *into* 13.1 before its migration wave
arrives, which turns it into a hard blocker. KB4800 is also a living document. Every
report is stamped with the script version and the date KB4800 was last reconciled
against these checks, so an old report is identifiable as old.

## Output

Three artefacts are written to the output folder, plus a console summary:

| File | Contents |
|---|---|
| `precheck-<timestamp>.html` | The readable report — start here |
| `precheck-<timestamp>.json` | The same results, for collecting across servers |
| `precheck-<timestamp>.log` | Run log |

### How results are classified

| Status | Meaning |
|---|---|
| **Blocker** | Not supported / will fail — hard stop until resolved. |
| **Action** | Must be remediated before migration. |
| **Warning** | Migration proceeds, but configuration is lost, changed, or disabled. |
| **Manual** | A manual step is required, or something that cannot be read automatically; confirm it. |
| **NextStep** | Advisory pre-migration preparation. Never a blocker. |
| **Info** | Could not be evaluated on this server; verify by hand. |
| **Pass** / **Skipped** | No issue found / not applicable. |

### Verdict and exit code

| Verdict | Condition | Exit code |
|---|---|---|
| MIGRATION BLOCKED | any Blocker | 2 |
| ACTION REQUIRED | any Action, no Blocker | 1 |
| REVIEW WARNINGS | only Warning / Manual / Info | 0 |
| READY | all Pass / Skipped | 0 |

A check that cannot read a feature **degrades to Manual or Info with the correct
guidance — never to a false Pass.** Where a clear result is reported, it states what was
actually examined, so "nothing found" can be told apart from "nothing looked at".

See **[CHECKS.md](CHECKS.md)** for what every check covers, which cmdlets it uses, and
the reasoning behind the ones that report rather than prescribe.

---

## What it reads, and what it writes

**It is read-only.** No Veeam cmdlet that changes configuration is called. The only
files written are the two reports and the log, all inside the output folder.

**It never reads credential secrets.** `-Credential` is passed straight to
`Connect-VBRServer` and is not logged or serialised. No check touches the password
members Veeam exposes on a credential object.

**The reports are an inventory of your backup infrastructure** and should be treated as
internal. They can contain:

| Disclosed | From |
|---|---|
| Server name and product build | report header |
| Licence edition, type, instance/socket counts | ENV-002 |
| Credential **account names** — never passwords — and descriptions | SEC-002 |
| Console user and group role assignments | SEC-005 |
| Repository access account names | SEC-004 |
| Job, application-group, VM, CDP-policy and tape-job names | JOB-\*, PRE-003 |
| Managed server and agent host names / FQDNs | AGT-\*, PRE-002 |
| Storage host names | STG-\* |
| Guest script file paths | JOB-003 |
| Entra ID tenant names | DEP-003, PRE-001 |

Two consequences worth planning for:

- **The output folder inherits its permissions.** The script creates the folder if
  missing and does nothing else to its ACL, so on a default Windows install the reports
  may be readable by any local user. Point `-OutputPath` at a folder that is already
  restricted.
- **Collected reports aggregate.** One report describes one server; a folder of two
  hundred describes the estate.

All values in the HTML report are HTML-encoded, so a name containing markup renders as
text. A check's detail and the log can include a Veeam exception message verbatim when
something fails, which is useful for diagnosis but means the log inherits whatever
detail the product put in that message.

---

## Licence

MIT — see [LICENSE](LICENSE).

This is an independent tool, not an official Veeam product, and carries no warranty or
Veeam support. KB4800 is the authority on what is and is not supported; where this
script and the KB disagree, the KB is right.

## Version history

See [CHANGELOG.md](CHANGELOG.md). The version is stamped inside the script and into every
report, so a report always identifies the build that produced it.
