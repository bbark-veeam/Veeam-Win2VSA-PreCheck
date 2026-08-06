# Checks Reference — KB4800 coverage map

> **KB4800 as captured 2026-07-24.** It is a living document, so its guidance can
> change with a new release. Every report states this date, from the
> `$script:PrecheckKbCaptured` constant in `VbrMigrationPrecheck/Private/New-PrecheckResult.ps1`
> — update it there whenever the KB is re-read and these checks are reconciled
> against it.

Each row maps a check to the [KB4800](https://www.veeam.com/kb4800) limitation it
evaluates, the primary cmdlet(s) it uses, the status it can emit, and a
**field-confidence** rating for how reliably the automated detection works
against a real environment (see the caveat at the bottom).

| ID | Category | Limitation (KB4800) | Primary cmdlet(s) | Possible status | Confidence |
|----|----------|--------------------|-------------------|-----------------|------------|
| ENV-001 | Environment | Source must be on the **13.0.x** train; **13.1 cannot migrate**. Builds newer than 13.1 return `Manual` — the check makes no claim about releases that have not shipped | `Get-VBRBackupServerInfo` / registry / core DLL | Pass / Action / Blocker / Manual / Info | High — validated live in both directions (13.1 → Blocker, 13.0.2 → Pass) |
| ENV-002 | Environment | VSA supports only instance-based VUL; socket must convert | `Get-VBRInstalledLicense` | Pass / Action / Info | High — instance path validated live; socket path shape-confirmed by reflection, values synthetic (socket licensing is deprecated, so a socket licence cannot be obtained to test) |
| DEP-001 | Deployment | Cloud Connect deployments cannot migrate. Read from the licence itself (`.CloudConnect` = Enabled/Disabled/Enterprise/Invalid); tenants and gateways enrich the evidence | `Get-VBRInstalledLicense`, `Get-VBRCloudTenant`, `Get-VBRCloudGateway` | Pass / Blocker / Info | High — validated live in both directions (Disabled → Pass, Enterprise → Blocker) |
| DEP-002 | Deployment | Google Cloud plug-in config will not migrate (Windows-only). Detected from CONFIGURATION (`Get-VBRGoogleCloudAccount`, `Get-VBRGoogleCloudComputeAccount`) plus a job-name signal. The plug-in ships with VBR so installation proves nothing; external repositories are not examined | `Get-VBRGoogleCloud*Account`, `Get-VBRJob` | Pass / Warning / Manual | Medium |
| DEP-003 | Deployment | Entra ID tenant backup **data** not migrated | `Get-VBREntraIDTenant` | Pass / Manual / Info | Medium — mock-tested |
| AGT-001 | Agents | All agents must be v13+ to connect | `Get-VBRDiscoveredComputer` | Pass / Action / Manual | High — validated |
| AGT-002 | Agents | Disabled agent policies must be applied/synced first. Keyed on `JobEnabled` (NOT `IsEnabled`, which does not exist; NOT `ScheduleEnabled`, which is a different thing). Whether config was applied is not exposed at all — see note | `Get-VBRComputerBackupJob` | Pass / Action / Info | High — validated |
| AGT-003 | Agents | Mac agent domain accounts must become local (no Kerberos/NTLM) | `Get-VBRComputerBackupJob` | Pass / Manual | Low - mock-tested; platform vocabulary still unconfirmed |
| AGT-004 | Agents | Post-migration: rescan all PGs; pre-installed-agent PGs need new config file. Keyed on `Container.Type -eq ManuallyDeployed` — see note | `Get-VBRProtectionGroup` | Pass / Manual | High — validated |
| STG-001 | Storage | NetApp ONTAP: only NAS filer role migrates | `Get-NetAppHost` (no VBR prefix) | Pass / Warning / Info | Medium - mock-tested |
| STG-002 | Storage | IBM / Hitachi / HPE XP / **NEC Storage V Series** plug-in minimum versions post-migration | `Get-StoragePluginHost` (no VBR prefix) | Pass / Manual / Info | Medium - mock-tested |
| STG-003 | Storage | HPE Nimble/Alletra: some Nimble OS versions may be unsupported when the **Linux-based** backup server runs FIPS-compliant mode — see note. Status is conditional on `FipsCompliantModeEnabled` | `Get-NimbleHost`, `Get-VBRSecurityOptions` | Pass / Manual / Warning / Info | Medium - mock-tested; a Nimble-integrated server is booked for w/c 2026-08-10 |
| JOB-001 | Jobs | CDP job config not migrated (manual re-create) | `Get-VBRCDPPolicy` | Pass / Warning / Info | Medium - mock-tested |
| JOB-002 | Jobs | SureBackup SQL Server Checker Script fails on VSA | `Get-VBRApplicationGroup` | Pass / Blocker / Manual | High — both paths validated |
| JOB-003 | Jobs | Pre/post-job + pre-freeze/post-thaw scripts & CSVs copied manually. Reads all three surfaces — see note below. CSV files remain undetectable and are named as such | `Get-VBRJob`, `Get-VBRJobObject` | Pass / Manual | High — validated |
| SEC-001 | Security | Four-eyes authorization disabled during migration | none exists → manual | Manual | n/a — permanently manual; a test pins it so it cannot become a Pass |
| SEC-002 | Security | Non-UPN **Standard** credentials to review for Kerberos-authenticated connections | `Get-VBRCredentials` | Pass / Manual | Medium — see note |
| SEC-003 | Security | Trusted-domain authentication unsupported | (manual) | Manual | n/a — permanently manual; a test pins it so it cannot become a Pass |
| SEC-004 | Security | Local (non-domain) repo access accounts → "SID not found" | `Get-VBREPPermission` -Repository → `.Users` | Pass / Action / Manual / Info | High — validated, both the flagging and the clean path |
| SEC-005 | Security | Console role assignments must be UPN (appliance console login) — see note | `Get-VBRUserRoleAssignment` | Pass / Action / Manual | High — validated live: all three source shapes flagged with distinct reasons, and both appliance remediation forms confirmed on real appliances |
| DB-001 | Job history | Job-history sessions predating the **upgrade to v12** fail migration (the limiting factor is v11-and-earlier session data). **Scoped to a Microsoft SQL configuration database** — see note | `Get-VBRHistoryOptions`, registry `DatabaseConfigurations` | Pass / Action / Manual / Info | High — Pass and Action validated live; the PostgreSQL scoping is shape-confirmed on a real server |

### Pre-Migration Considerations (KB4800) → `NextStep`

These are preparation *actions* to take before starting the migration, not
pass/fail limitations. They emit the advisory `NextStep` status in category **Preparation**, and appear in the
report's dedicated **Pre-Migration Next Steps** section. A conditional one stays
silent (`Skipped`) when its feature is absent — so a next step only appears when
it actually applies. (Considerations #4 CDP, #5 disabled agent policies, #6 agent
v13, #7 local repo accounts are already enforced as limitation checks above.)

| ID | Consideration (KB4800) | Cmdlet(s) | Emits |
|----|------------------------|-----------|-------|
| PRE-001 | Configure a secondary target for Entra ID tenant backups first | `Get-VBREntraIDTenant` (→ `New-/Set-VBREntraIDBackupSecondaryTarget`) | NextStep / Skipped |
| PRE-002 | Verify all managed machines are reachable from the VSA (net/FW/DNS) | `Get-VBRServer` | NextStep (always) |
| PRE-003 | File-to-tape: use the source server **short** hostname, resolvable | `Get-VBRTapeJob` | NextStep / Skipped |
| PRE-004 | Match VSA timezone to this Windows machine (Hitachi / HPE XP / NEC) | `Get-StoragePluginHost` + `Get-TimeZone` | NextStep / Skipped |

> **On DB-001's date (`-UpgradeDate`): supply the date this environment was upgraded
> to v12.** That is the boundary that matters, because **what breaks migration is
> session data written by v11 and earlier** — sessions predating the move to v12.
> A later date (the v13 upgrade, say) errs safe but **over-flags**: it also counts
> legitimate v12-era sessions, so it can prescribe a retention reduction that is not
> actually needed, which across a large estate is needless work. The `V13UpgradeDate`
> alias is kept for anyone who only knows that date, not as the recommended input.
>
> A supplied date is rejected if it **predates v12's existence** — most likely the v11
> upgrade date or a mistyped year, neither of which can be a v12 upgrade date.
> With no date, DB-001 reports the **retention window it read** for the operator to
> compare by hand — it does not enumerate sessions, because `Get-VBRBackupSession` has no
> date filter or ordering, so reading it would materialise every session on the server.
>
> The date is **sanity-checked before anything is concluded from it**, because PowerShell
> binds `-UpgradeDate 0` to `DateTime.MinValue` without complaint — which produced
> "105690 week(s) since the upgrade on 0001-01-01" and a confident `Pass`, a mistyped
> parameter clearing the very check meant to catch this blocker.

> **Cmdlet names verified** against the official A-Z reference
> (`docs/reference/vbr-v13-cmdlets.md`, 1481 cmdlets). Every cmdlet named above
> exists in v13. What remains unvalidated for Low/Medium rows is the exact
> *property* each check reads off the returned object (e.g. the agent-version
> property on `Get-VBRDiscoveredComputer`), not the cmdlet name itself.

## Status meanings

- **Blocker** — migration is not supported / will fail; hard stop until resolved.
- **Action** — must be remediated before migration or it will fail.
- **Warning** — migration proceeds, but configuration is lost/changed/disabled.
- **Manual** — a manual pre/post step is required that can't be automated; confirm it.
- **NextStep** — advisory pre-migration preparation action (KB4800 considerations); never a blocker; shown in the Pre-Migration Next Steps section.
- **Info** — could not be auto-evaluated (cmdlet/property absent); verify by hand.
- **Pass** — no issue found. **Skipped** — not applicable.

## Overall verdict → exit code

| Verdict | Condition | Exit code |
|---------|-----------|-----------|
| MIGRATION BLOCKED | any Blocker | 2 |
| ACTION REQUIRED | any Action, no Blocker | 1 |
| REVIEW WARNINGS | only Warning/Manual/Info | 0 |
| READY | all Pass/Skipped | 0 |

## Note on DB-001 — the failure is scoped to a Microsoft SQL configuration database

KB4800, verbatim: *"If the Windows-based Veeam Backup & Replication deployment, **whose
database is hosted on Microsoft SQL**, was at any time in the past upgraded from a version
older than v12, and there are still job history sessions in the database from prior to
that upgrade, the migration to Veeam Software Appliance will fail."*

So on a **PostgreSQL** configuration database the limitation cannot apply, and DB-001
returns `Pass` outright rather than asking the operator to compare a retention window
against an upgrade date that could never produce a finding. PostgreSQL became available in
v11 (by manual migration) and the default at v12 install, so this is common.

The engine is read from the registry:
`HKLM\SOFTWARE\Veeam\Veeam Backup and Replication\DatabaseConfigurations` →
**`SqlActiveConfiguration`**.

**⚠️ Two ways to read this wrong, both observed on a real server:**

1. **Do not infer the engine from the `MsSql` / `PostgreSql` subkeys.** *Both exist*, and on
   a PostgreSQL server the `MsSql` branch still carries populated `SqlDatabaseName` and
   `SqlServerName` values. Reading those reports Microsoft SQL on a PostgreSQL deployment.
   Only the active marker discriminates.
2. **Do not use the `EntraIdSql*` values** in the parent key. They look like an answer —
   `EntraIdSqlServiceName = postgresql-x64-17`, `EntraIdSqlHostPort = 5432` — but they
   describe the **Entra ID backup database**, a different database entirely. A server with
   an MSSQL configuration database and Entra ID backups on PostgreSQL would be cleared by
   mistake, turning a genuine migration-failure cause into a `Pass`.

Only a positive `PostgreSql` reading narrows the check. Microsoft SQL, an unreadable
registry, or an unrecognised value all fall through to the full logic, so being wrong here
costs a deferral rather than a missed failure. `Get-VBRBackupServerInfo` was checked first
and does not expose the database — it returns only `Name`, `Build` and `PatchLevel`.

## Note on DEP-001 — the licence file is the blocker, not the architecture

**Do not make this conditional on finding tenants, gateways or repositories.** Their
absence proves nothing. This exact licence has blocked a real migration on a server with
**no Cloud Connect architecture at all** — no tenants, no gateways, no repositories.
Requiring evidence of use before blocking would have missed it, and that would be a false
clean result on the only Blocker-grade check of its kind.

The design was questioned once on the strength of a report showing `CloudConnect =
Enterprise` with zero tenants and zero gateways, which looked like a licence entitlement
being mistaken for a deployment. Measurement settled it the other way:

| | Before the Cloud Connect licence | After |
|---|---|---|
| Licence type / edition | Subscription / EnterprisePlus | Subscription / EnterprisePlus |
| `CloudConnect` | `Disabled` (six consecutive runs) | `Enterprise` |
| DEP-001 | `Pass` | `Blocker` |

Same server, same licence type and edition. The property is therefore **not** an artefact
of the licence edition — it changed only because a Cloud Connect licence was installed.

Because an operator with no Cloud Connect architecture will reasonably doubt the finding,
the report says so explicitly: *"No tenants or gateways are configured on it. That does not
change the result: the license file itself prevents migration, whether or not any Cloud
Connect architecture has been built."* The evidence also distinguishes **"could not be
read"** from **zero**, so an unreadable enumeration is never presented as an empty one.

## Note on PRE-003 — the consideration is narrower than the check can currently see

KB4800's consideration is about the case where **the backup server itself is a source for a
file-to-tape job**. File-to-tape is unstructured backup to tape: when the backup server is
the source, it is being treated much like a Windows file server to read files from, which
is why the original server's **short hostname** must be used when selecting the source
during migration, and why it has to be resolvable from the appliance.

That is a different thing from backup-to-tape, which identifies backup files natively
within a repository and sends those to tape. Backup-to-tape is not affected.

**Two limitations follow, and both are honest gaps rather than defects:**

1. **The job-type vocabulary is unconfirmed.** `VBRTapeJob`'s shape has never been
   captured — no lab has had tape jobs — so the check identifies file-to-tape by matching
   the substring `File` across the job's type strings. At least three tape job kinds exist
   (`BackupToTape`, `FileToTape`, `ObjectToTape`, plus a legacy `TapeFilesJob`), and since
   backup-to-tape operates on backup *files*, a type string such as "Backup files to tape"
   would be matched and misreported. **No collision has been demonstrated** — but none has
   been ruled out either, and this is the same shape as the AGT-003 `Mac`/"machine"
   defect. Treat the detection as unvalidated.

2. **Whether the backup server is actually the source is not read.** The check reports any
   file-to-tape job and hedges — "*if* this backup server is their source". A server whose
   file-to-tape jobs all source from other file servers gets a next step that does not
   apply to it.

**If a tape environment ever becomes available, capture:** the real `Type`/`TypeToString`
values (so the match can become an exact comparison, or move to the job object's .NET type
name), whether `Get-VBRTapeJob` offers a server-side type filter, and how a job exposes its
**source objects** — the last would let the check state that this server *is* a source
rather than asking the operator to check, removing the hedge entirely. That is the same
improvement STG-003 got by reading `FipsCompliantModeEnabled` instead of deferring.

## Note on STG-003 — the FIPS restriction is version-dependent, and about the *Linux* server

Verbatim, from the Veeam User Guide → *HPE Alletra 5000, 6000, Nimble* limitations
(`storage_limitations_nimble.html?ver=13`). **That page is JS-rendered, so it cannot be
fetched — it has to be read in a browser**, which is why the text is captured here:

> Some versions of Nimble OS may not be supported when the Linux-based backup server
> operates in FIPS-compliant mode.

Three things follow, and two of them corrected an earlier reading of this check:

1. **It is version-dependent, not categorical.** The arrays are not unsupported under FIPS;
   *some Nimble OS versions* may not be. So the remediation is to check the array's OS
   version, and only then to choose between FIPS-compliant mode and continuing to use that
   array.
2. **The mode that matters is on the *Linux-based* backup server** — the appliance being
   migrated *to*. The check reads `FipsCompliantModeEnabled` from
   `Get-VBRSecurityOptions` on the **source**, which is a signal of intent rather than the
   condition itself, and it errs safe: nobody is asked to make a decision who is not
   already running FIPS. The finding says which server the reading came from.
3. **It is not scoped to Backup from Storage Snapshots.** BfSS appears in a *different*
   bullet on the same page, and confusing the two produced a finding that named the wrong
   feature.

Because the restriction is conditional, so is the status: FIPS enabled → `Manual` (a
decision only the customer can make); FIPS disabled → `Warning` (nothing affected today,
but enabling it later would mean checking the OS versions first); FIPS unreadable →
`Manual`, saying so.

### The other two Nimble limitations on that page are deliberately NOT checks

Under the scope rule, KB4800 is the boundary and other sources may only *scope* a
limitation it already calls out. KB4800 calls out the FIPS/OS-version item, so the UG text
above legitimately scopes it. The page's other two bullets are not in KB4800 and are not
migration limitations, so no check is built from them:

- **Nimble Connection Manager on Windows-based backup proxies** (for BfSS over iSCSI) — a
  configuration *recommendation* that applies equally before and after migration.
- **Volume Collection replication for backup from secondary arrays** — a prerequisite of
  that feature, not something migration changes.

## Note on SEC-005 — the required form differs for a user and a group

The appliance wants an `@` form for both, but **not the same `@` form**, and handing an
operator the wrong one sends them to do something that fails:

| Principal | Appliance form | Example |
|---|---|---|
| Domain user | `user@fqdn` | `bbarker@corp.local` |
| Default domain security group | **`group@domain`** | `Administrators@tech.local` |
| Local / builtin (`BUILTIN\…`, `MACHINE\…`) | no counterpart exists — assign a domain principal instead | — |

Source: Veeam User Guide, *Configuring Users and Roles* — "To add a default domain
security group, use the group@domain format, for example, Administrators@tech.local."

**Confirmed on working appliances (2026-08-05), not just documented.** One appliance holds four
domain security groups assigned as Backup Administrator, every one in `group@domain` form with
Type `Group`. On another, a user whose only grant was membership of such a group signed in
successfully — so a group assignment does not merely save, it authorises login, and group-based
access has a real equivalent on the appliance.

Two details from the same environments, worth knowing when reading a report: the name may be
returned **uppercased** where the console displays it mixed-case, and a **space in a group name
is preserved** (so `Domain Admins@example.local` is a valid value).

`group@domain` is Veeam's **input syntax for naming a group, not a UPN.**
`userPrincipalName` is an attribute of the AD *user* class; groups do not have one. That
distinction matters when a lookup fails: the text before `@` must be the group's actual
name, so `Administrators@corp.local` and `Domain Admins@corp.local` are different groups
and not interchangeable.

Detection is the same for both — anything without `@` is flagged — so only the
remediation wording is type-dependent. Until 0.3.7 every finding named `user@fqdn`,
which is unachievable for a group.

## Note on AGT-002 — three "enabled" notions, and one thing that cannot be read

`VBRComputerBackupJob` carries more than one enabled-ish property, and picking the
wrong one is silent either way:

| Property | Meaning | Used? |
|---|---|---|
| **`JobEnabled`** | the policy itself is enabled/disabled | **yes — this is the KB4800 item** |
| `ScheduleEnabled` | the policy has a schedule | no. A policy can be `JobEnabled = True` with `ScheduleEnabled = False` — enabled, just unscheduled. Matching it flags working policies |
| `IsEnabled` | **does not exist** | no. Until 0.3.5 the check filtered on this name, matched nothing, and returned Pass on every server |

**What the object does not expose at all: whether a disabled policy's configuration was
ever applied.** A full property dump of a real 13.x policy shows no apply, sync, state
or deployment member of any kind. KB4800's concern is specifically a disabled policy
whose configuration was never applied successfully, so the check cannot narrow to just
the failing ones — it reports every disabled policy and says plainly that the applied
state is not something it can read, rather than leaving the reader to assume it was
verified.

`Mode` (`ManagedByAgent` / `ManagedByBackupServer`) and the target protection group are
carried in the evidence as context for triage.

## Note on AGT-004 — the API does not use the word "pre-installed"

The console offers *Computers with pre-installed Veeam backup agents*. Nothing in the
object model is called that, and until 0.3.4 the check looked for it on the wrong
property — `VBRProtectionGroup.Type`, which holds only `Custom` and `ManuallyAdded`,
making the finding unreachable on every server.

The kind of a protection group is on its **container**:

| `Container.Type` (`VBRProtectionGroupContainerType`) | Console equivalent |
|---|---|
| `IndividualComputers` | Individual computers |
| `ActiveDirectory` | Microsoft Active Directory objects |
| `CSV` | Computers from a CSV file |
| **`ManuallyDeployed`** | **Computers with pre-installed Veeam backup agents** ← the one KB4800 calls out |
| `CloudMachines` | Cloud machines |
| `MongoDBComputers` | MongoDB computers |

Two consequences worth keeping:

- **Compare the enum exactly; never substring-match.** `ManuallyDeployed` (container)
  and `ManuallyAdded` (group type) both contain "Manual", and a loose match reproduces
  the original defect — the built-in "Manually Added" group flagged on every server.
- **Container type cannot be filtered server-side.** `Get-VBRProtectionGroup -Type`
  accepts only `Custom` / `ManuallyAdded`, so the kind has to be read per group after
  retrieval.

Evidence states each group's kind, so the classification can be checked from the report
rather than trusted. A group whose container cannot be read says so.

## Note on SEC-004 — local vs domain cannot be read off the name

Until 0.3.2 this check read `$perm.Accounts`. `VBREPPermission` has no such property,
so the account list was always `$null` and the check returned **Pass on every server,
unconditionally** — it could not fire even in principle. The property is `Users`.

The harder half is that the two forms that matter look identical:

| Account | Prefix | Survives migration? |
|---|---|---|
| `BACKUP01\Administrator` | machine name | **No** — SID does not exist on the appliance |
| `CORP\Administrator` | NetBIOS domain | Yes |

Both are a dotless label plus a backslash, so the shape alone decides nothing. The
check resolves the server's own identity — `Win32_ComputerSystem.Domain`, falling back
to `USERDOMAIN`/`USERDNSDOMAIN` — and treats a prefix as **local** when it matches the
machine name, the repository host's short name, `.`, `BUILTIN` or `NT AUTHORITY`; as
**domain** when it contains a dot, matches the server's own domain label, or the name
is a UPN.

Anything left over (an unrecognised NetBIOS prefix, or a bare user name) returns
`Manual` naming it for review. Both possible guesses are harmful at fleet scale:
guessing *local* tells the operator to strip valid domain accounts from 200 servers,
and guessing *domain* restores the false Pass.

## Note on JOB-003 — three surfaces, one of which was invisible

Job scripts are not stored in one place. Until 0.3.0 this check read only the first
of three, and returned a clean result on a lab job that had **all four script slots
populated** — the kind of false negative that reads as correct code:

| Where the operator sets it | Where it is stored | Read since |
|---|---|---|
| Job → *Storage* → **Advanced** → *Scripts* (pre-job / post-job) | `$job.GetOptions().JobScriptCommand` | 0.3.0 |
| Job → *Guest Processing* → application handling **for individual servers** → *Scripts* | the job **object**: `$obj.VssOptions.GuestScriptsOptions` | 0.3.0 |
| Job-level guest processing default | `$job.Info.VssOptions.GuestScriptsOptions` | always |

The per-machine override was the one that mattered: `IsAtLeastOneScriptSet` is
accurate *at each level independently*, so the job default correctly reported
`False` while the override on the same job reported `True`. Reading the job level
alone therefore gave a confident, wrong answer.

Per-object options are read from the object's own `.VssOptions` property, not
`Get-VBRJobObjectVssOptions` — the cmdlet is a round-trip per object (measured 4 ms
vs 56 ms for two objects, identical data), and this tool is run across a large fleet.

**Pre/post-job entries are command lines, not paths**, so they can carry arguments
including a password. The check reports the executable only, and reports "enabled,
command line not shown" when the two cannot be separated confidently — an unquoted
path containing spaces, or an interpreter such as `powershell.exe` where the script
is itself an argument.

## The UPN question, settled by measurement (supersedes a plain reading of KB4800)

KB4800 says, verbatim: *"The Veeam Software Appliance exclusively uses Kerberos for handling
domain credentials. As such, all domain usernames must be formatted in UPN format
(user@fqdn)."* Taken literally that would make `fqdn\user` a finding everywhere. **It is not,
and SEC-002 deliberately does not flag it.** The two surfaces behave differently, and this
was established by testing each one rather than by reading:

| Surface | `user@fqdn` | `fqdn\user` | `NETBIOS\user` |
|---|---|---|---|
| **Console sign-in** (SEC-005) | ✅ required | ❌ rejected at the login form | ❌ rejected |
| **Datacenter credentials**, used to reach managed servers (SEC-002) | ✅ | ✅ **works, and persists** | ❌ |

Evidence for each cell:

- **Sign-in rejects `fqdn\user` outright**, with *"Specify a username in the UPN format
  (username@domain.com)."* So console access genuinely is UPN-only.
- **On the appliance, Users & Roles accepts `fqdn\user` on input but rewrites it to UPN** —
  a group entered as `<domain>\Domain Admins` reappears as `Domain Admins@<domain>`, and a
  user entered as `<domain>\<user>` as `<user>@<domain>`, simply from closing and reopening
  the dialog.
  **⚠️ That is APPLIANCE behaviour, observed on a VSA — do not read it as a reason SEC-005
  will not see dotted-prefix assignments.** SEC-005 runs on the **Windows source**, where
  no such rewrite has been observed, so an `fqdn\user` assignment there can persist and is
  a genuine finding.
  **It may also be a reason the finding matters MORE.** The rewrite looks like a UI-layer
  conversion — the appliance may never write the prefixed form to its database at all. The
  migration performs a **database injection**, which bypasses that UI entirely, so a
  prefixed assignment carried over from the Windows source could land in the appliance
  database unconverted and simply not work for sign-in. Nothing in the UI would have had
  the chance to fix it. **Unproven** — a physical migration is the way to settle it, and it
  is the reason not to advise leaving a prefixed assignment in place and expecting it to
  convert itself.
- **Datacenter credentials do NOT get rewritten.** A credential stored as
  `<domain>\administrator` is still in that form after repeated reboots and reloads, and it
  works for connecting to managed servers. NetBIOS-prefixed does not.

**Consequences, and why the two checks must stay asymmetric:**

1. **SEC-002 treats a prefix containing a dot as acceptable** and flags only NetBIOS, machine
   prefixes and bare names. Flagging `fqdn\user` would tell operators to change a credential
   that works — needless work on every server that uses that form.
2. **SEC-005 requires the `@` form**, because sign-in does.
3. The code in both carries a comment saying *do not harmonise the two*. That is why.

**Do not "correct" SEC-002 to match the KB sentence above.** The sentence is a fair summary of
the principle — Kerberos, therefore UPN — but the product accepts `fqdn\user` on the
credential surface, and the tool is deliberately more precise than the summary.

## Note on SEC-002 — why it reports rather than prescribes

Credential format cannot be judged from the credential string alone, because
**Datacenter Credentials is a single flat store shared by surfaces with conflicting
documented requirements**:

- Veeam's permissions documentation gives down-level format for a *Source/Target
  VMware vSphere Host* and for a *Windows Server added to the backup
  infrastructure*: "use the MACHINE\USER format for local accounts or DOMAIN\USER
  format for domain accounts".
- **But for Windows servers the console is more specific, and testing confirms it.**
  The *New Windows Server* wizard states: "Select a **Kerberos domain account** with
  administrator privileges. Use **USER@FQDN or FQDN\USER** format for the account
  name." Adding a Windows server to a v13 appliance was then tested with all three
  forms:

  | Credential form | Result |
  |---|---|
  | `corp\administrator` (NetBIOS prefix) | **failed** |
  | `corp.local\administrator` (FQDN prefix) | worked |
  | `administrator@corp.local` (UPN) | worked |

  So the permissions table's "DOMAIN\USER" wording is misleading for this surface: a
  **NetBIOS** prefix is rejected, an **FQDN** prefix is accepted. SEC-002 therefore
  treats a prefix containing a dot as already Kerberos-compatible and does not flag
  it.

- **SEC-005 is deliberately stricter.** Console *login* on the appliance takes UPN
  only — the sign-in form rejects any prefixed form, including `fqdn\user`. The two
  checks differ on purpose and should not be harmonised.
- The Kerberos requirement for **guest OS processing** is the opposite direction:
  "Local accounts do not support Kerberos authentication. To authenticate with
  Microsoft Windows guest OS using Kerberos, specify an Active Directory account."

So the same credential string is correct in one usage and wrong in another. An
earlier version of this check flagged every credential containing a backslash and
recommended re-entering it in UPN format — which, applied to a vSphere host or
Windows infrastructure-server credential, would have instructed the operator to
break a correctly-configured connection.

SEC-002 therefore lists **candidates for human review** and prescribes nothing. It
reports Standard-type credentials in `DOMAIN\user` or bare-user form, excluding:

| Excluded | Reason |
|---|---|
| SSH credentials, SSH private key, Kasten authentication token, Managed service account | Not Standard type; cannot sit on a Windows Kerberos path |
| `root` | Linux / ESXi / appliance accounts — also removes the credential records VBR auto-creates on every server, which would be per-server noise at fleet scale |
| Anything containing `@` | Already UPN-shaped. Note `administrator@vsphere.local` (vCenter SSO local) and `@system` (Cloud Director) are *not* UPNs, but neither is on a Kerberos path |

A future revision can narrow this to an actionable finding once credential **usage**
is resolved (which credential each job's guest processing and each component
connection actually references).

## Confidence caveat (read before trusting Low/Medium rows)

The checks were authored against KB4800 and the documented Veeam v13 cmdlet
surface, but **the exact cmdlet names and object properties for several features
have not yet been validated against a live v13 environment.** Low/Medium-confidence
checks are deliberately conservative: when a cmdlet or property is missing they
degrade to **Manual/Info** with the correct guidance rather than a false Pass, so
the tool never silently tells you a real blocker is clear.

The three ratings mean different things, and the difference matters:

- **validated** — exercised against a live Windows VBR 13.0.x server, in both the
  finding and the no-finding direction where that was possible.
- **mock-tested** — the detection logic is exercised by the test suite against a
  mocked object shape, in both directions, but **has never seen a real object of
  this kind.** The lab has no NetApp, no storage plug-in, no Nimble, no CDP policy,
  no Entra ID tenant and no Mac agent, so STG-001/002/003, JOB-001, DEP-003 and
  AGT-003 fall here. A mocked shape proves the logic does what it intends; it
  cannot prove the shape matches the product. Treat the *property and value
  vocabulary* of these checks as unconfirmed.
- neither — the logic has not been exercised in either direction. **No check is currently in this state:
  all 25 are exercised by the test suite in both directions.** That
  raises the floor; it does not by itself raise any row's rating, because a mocked shape
  still cannot prove the shape matches the product.

**Why the distinction is not pedantic:** of the property probes this tool has
written against an unvalidated object shape, **four of five turned out to be
broken** — each returning nothing while reporting a confident clean result. A
plausible member name is not evidence. The counted clean results exist so that if
one of these is wrong, the report says how little it examined instead of implying
it examined everything.
