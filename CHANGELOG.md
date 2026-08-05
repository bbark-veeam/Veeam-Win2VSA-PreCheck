# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions track `VERSION`.

**Bump the version with every change set, before handing anything over.** The tool
version is stamped into every report, so a stale version makes a report misattribute
itself to a build that did not produce it. While pre-1.0: bump **PATCH** (`0.2.0` →
`0.2.1`) for fixes and refinements, including corrections to check logic or report
wording; bump **MINOR** (`0.2.0` → `0.3.0`) for genuinely new capability, such as an
added check or a new way of running the tool. Four places must agree: `VERSION`,
`ModuleVersion` in the module manifest, the heading here, and the filename the build
produces.

## [Unreleased]
### Added
### Changed
### Fixed

## [0.4.2] - 2026-08-05
### Fixed
- **Four checks failed OPEN, returning a clean result when they could not read anything.**
  An unread collection is empty, and each of these reached its clean result by falling
  through that empty collection — so a cmdlet that was missing or that threw produced
  "none found" rather than saying it could not look. Every other check in the tool
  degrades to `Manual`/`Info` in that situation. Now they all do:
  - **AGT-004** returned `Pass` "No Protection Groups found" whenever protection groups
    were unreadable. The finding it suppressed is a post-migration instruction — rescan
    every protection group, and reconfigure any pre-installed-agent group with a new
    configuration file — so a false clean result here means the operator never learns to
    do it, and agent backups break after migration.
  - **JOB-002** could report a clean result without ever enumerating application groups:
    its cmdlet guard passes when *either* SureBackup cmdlet exists. This is the only
    check in the tool that can emit a `Blocker`, so it is the most expensive place in the
    tool to report something clean that was never examined.
  - **AGT-003** and **SEC-002** likewise passed on a collection they had failed to read.
- **AGT-003 reported ordinary Windows agent jobs as Veeam Agent for Mac jobs.** It matched
  `Mac` as a bare substring across the job's platform and type strings, and the word
  **"machine"** contains it. Now matched as whole words only. This is the same mistake that
  had AGT-004 flagging the built-in "Manually Added" protection group, and the rule the
  project wrote down after that one — compare exactly, never substring-match — is what it
  violated. The exact platform vocabulary is still unconfirmed, so this remains a word
  match rather than an enum comparison.

### Changed
- **Every clean result now states what it examined.** Ten remained that said only
  "No X found": AGT-001, AGT-003, AGT-004, DEP-003, JOB-001, JOB-002, SEC-002 and
  STG-001/002/003. A clean result naming no quantity reads identically whether the check
  inspected everything and found nothing wrong or inspected nothing at all — which is
  precisely how the SEC-004 defect survived for weeks. Where a meaningful denominator
  exists it is now given: AGT-003 states how many agent jobs it examined, JOB-002 how many
  application groups and VMs, and SEC-002 how many credentials it judged, how many were
  already in an accepted form, and how many it set aside as not applying to Kerberos paths.
  Where the collection is genuinely empty, the result says the list was read successfully
  and is empty — which a broken probe cannot claim.

### Added
- **Pester test suite — 64 tests, run against mocked Veeam cmdlets so no VBR server is
  needed.** `src/tests/Helpers.Tests.ps1` (13) and `src/tests/Regressions.Tests.ps1` (51).
  Run them with `Invoke-Pester -Path ./tests` from `src/`. A further set of build-invariant
  tests is kept in the development tree: they assert on that tree's build outputs and version
  files, which have no counterpart in this repository.
- Each check-level test corresponds to a defect found by running the tool against a live
  server. Every one of those defects was a plausible-looking member name or match that
  returned nothing, so the check reported a confident clean result — none was a crash, and
  none would have been caught by reading the code. The tests exist so that a future edit
  cannot quietly restore them.
- **The suite is mutation-validated: 25 defects were reintroduced one at a time — the ten
  historical ones and the fifteen fixed or counted here — and the suite failed on every
  one.** A suite that passes proves nothing on its own, so this is the bar for adding a test:
  reintroduce the defect and confirm the test fails.
- **Six checks now have their populated path exercised for the first time.** STG-001,
  STG-002, STG-003, JOB-001, DEP-003 and AGT-003 had never returned a non-empty result on
  real hardware, because the lab has no NetApp, no storage plug-in, no Nimble, no CDP, no
  Entra ID tenant and no Mac. Their filtering logic had therefore never run at all. Mocked
  shapes now cover it, which is how the AGT-003 substring defect was found.
- The developer README documents how to run the tests and maps each test group to the defect
  it pins down.
- **Two example HTML reports** in `examples/`, linked from the README, so the output
  can be seen before the tool is run: one from a server with nothing wrong with it
  (`REVIEW WARNINGS`, exit 0) and one from a server that cannot migrate (`MIGRATION BLOCKED`,
  exit 2). Generated from the development tree by driving the **real** orchestrator and checks
  against mocked cmdlets, so an example cannot drift from what the
  tool actually emits. The data is invented and generic. A test in the development tree asserts both
  exist, carry the current version, name no lab identifier, and are self-contained.
- **The clean example documents a structural property worth knowing: `READY` is
  unreachable.** SEC-001 (four-eyes) and SEC-003 (trusted-domain auth) return `Manual`
  unconditionally because neither state is exposed to PowerShell, and any `Manual` demotes
  the verdict — so the best result any real server can get is `REVIEW WARNINGS` with those
  two outstanding. The examples README says so explicitly rather than leaving operators to
  wonder what a passing server looks like.
- **Continuous integration** (`.github/workflows/tests.yml`): the suite runs on every push
  and pull request, on both Windows and Linux runners.
  Windows is the platform the tool runs on; Linux proves the suite does not depend on ambient
  machine identity, since SEC-004 reads `COMPUTERNAME`, `USERDOMAIN` and CIM, all of which are
  absent or different off Windows. The workflow fails if no tests are discovered — a green run
  that executed nothing is the same class of defect as a check reporting a clean result while
  measuring nothing.

## [0.4.1] - 2026-08-05
### Added
- **DEP-002 now detects Google Cloud *configuration* instead of deferring to the
  operator**, removing the tool's only permanently-manual detection. A `Manual` repeated
  across ~200 servers is pure cost, so this was worth closing.
  Reads `Get-VBRGoogleCloudAccount` and `Get-VBRGoogleCloudComputeAccount` — Google-
  specific cmdlets, so a hit is unambiguous — plus the existing job-name signal, which
  costs nothing because `Get-VBRJob` is already cached.
- **The Pass states what it examined** ("N Google Cloud configuration source(s) were
  checked…"), and names what it does *not* cover: Google Cloud external repositories.
  Per the pattern established for SEC-004 in 0.3.3.
- If every probe throws — the licence-dependent failure mode seen with the Cloud Connect
  cmdlets in DEP-001 — the check returns `Manual`, not Pass. One probe succeeding is
  enough to report a clean result.
- Six cases covered: nothing configured, a configured Google Cloud account, a configured
  Compute account, all probes throwing, one probe throwing, and the cmdlets being absent.

### Withdrawn before release
- **A registry-based approach was built and immediately removed.** It read the uninstall
  keys for an installed "Veeam … Google …" component. **The plug-in ships with VBR and is
  installed by default**, so that check would have raised a Warning on every server in the
  fleet — a false positive at scale, which is worse than the Manual it replaced. The
  0.4.0 artefact was deleted rather than published.
  The rule this violated is one the project already had: **scope by usage, not by shape.**
  It is the same reasoning behind SEC-002 not flagging a credential merely for sitting in
  the vault — a component being installed is not that component being used.

## [0.3.7] - 2026-08-05
### Fixed
- **SEC-005 told operators to convert a GROUP assignment to `user@fqdn`.** It read
  `Type` (`User` / `Group`) and never used it, so every finding named the user form. The
  documented appliance form differs by principal type (Veeam UG, *Configuring Users and
  Roles*): a domain user is `user@fqdn`, **a default domain security group is
  `group@domain`** — for example `Administrators@tech.local`. Each finding now names the
  form that applies to it, and the Pass text says both.
  Worth recording that `group@domain` is Veeam's *input syntax for naming a group*, not a
  real UPN: `userPrincipalName` is an attribute of the AD user class and groups do not
  have one. The shape the appliance wants is the same `@` form either way, which is why
  the detection is unchanged and only the remediation wording was wrong.
- A local or builtin principal now says what to do instead of merely what is wrong: it
  has no counterpart on the appliance, so assign the equivalent **domain** principal in
  the form matching its type.
- An assignment with no prefix and no reported type no longer asserts the user form.
- Four cases covered: the lab's bare `Administrators` group, the documented
  `Administrators@tech.local`, a mixed set of six spanning user/group × builtin/local/
  domain-prefixed/UPN, and an all-correct set including `Domain Admins@fqdn`.

## [0.3.6] - 2026-08-05
### Fixed
- **AGT-001 silently ignored a version string it could not parse.** A value that failed
  `[version]::TryParse` was neither counted as below-v13 nor as unread, so it fell
  through and contributed to a Pass. It now counts as unread, which sends the check to
  `Manual` — the same fail-safe already applied when no version property exists at all.
  Narrow but the same shape as the day's other defects: a silent skip feeding a
  confident clean result.
- Verified on real 13.0.2 hardware that AGT-001's version probe otherwise **works**:
  three discovered computers, three versions read, all ≥ v13. Its `Pass` was already
  unreachable unless every computer's version was readable, so the check's structure was
  sound. Recorded because four of the five unverified property probes examined today
  turned out to be broken and this one was expected to be as well.

## [0.3.5] - 2026-08-05
### Fixed
- **AGT-002 filtered on a property that does not exist.** It used `IsEnabled`;
  `VBRComputerBackupJob` has **`JobEnabled`**. Nothing ever matched, so the check
  returned Pass on every server even with a disabled policy present. Confirmed against
  a real 13.x object dump — the shape had never been captured before because no agent
  policies existed in the lab.
- **`ScheduleEnabled` is deliberately not used.** It is a separate property, and a
  policy can be `JobEnabled = True` with `ScheduleEnabled = False` — an enabled policy
  that simply has no schedule. Any fuzzy match on "Enabled" flags it wrongly.
- If policies are returned but `JobEnabled` cannot be read, the check now reports `Info`
  rather than Pass.
- Pass states what it evaluated: "All 3 policy/policies were evaluated and are enabled",
  distinguishable from "No Agent Backup Policies exist on this server."

### Changed
- **AGT-002 no longer implies it verified that configuration was applied.** The object
  carries no apply/sync/state property of any kind — checked against a full property
  dump — so whether a disabled policy was ever applied is genuinely unreadable. The
  finding now says so outright instead of leaving the reader to assume it was checked,
  and evidence carries each policy's `Mode` (`ManagedByAgent` / `ManagedByBackupServer`)
  and target protection group for context.
- Five cases covered: the lab's three policies (1 of 3 disabled, correctly named), all
  enabled, the enabled-but-unscheduled trap, no policies at all, and a policy object
  missing the property.

## [0.3.4] - 2026-08-05
### Fixed
- **AGT-004's pre-installed-agent detection could never match.** It compared
  `VBRProtectionGroup.Type` against `Pre-?installed`, but that enum holds only `Custom`
  and `ManuallyAdded` — so the "needs a new configuration file" finding was unreachable
  on every server. What the console calls *Computers with pre-installed Veeam backup
  agents* lives one level down on `Container.Type`
  (`VBRProtectionGroupContainerType` = `IndividualComputers` | `ActiveDirectory` | `CSV` |
  **`ManuallyDeployed`** | `CloudMachines` | `MongoDBComputers`), and the value is
  `ManuallyDeployed`. The phrase "pre-installed" appears nowhere in the object model,
  which is why no amount of guessing at the member name was going to land.
- Comparison is now an **exact enum match, not a substring**. `ManuallyDeployed`
  (container) and `ManuallyAdded` (group type) both contain "Manual", so a loose match
  reintroduces the original defect — the built-in "Manually Added" group being flagged
  on every server — in a new disguise.
- Evidence now states each group's kind, e.g. `Protection Group: PG-Individual
  [IndividualComputers]`, so the classification is checkable from the report instead of
  taken on trust. A group whose container cannot be read says so rather than being
  silently treated as ordinary.
- Six cases covered: the lab's built-in group, an individual + pre-installed pair, a
  pre-installed group alone, all four other container types (none flagged), a group with
  no container object, and no groups at all.

## [0.3.3] - 2026-08-03
### Changed
- **SEC-004's Pass now states what it evaluated**, so it can be told apart from a Pass
  that evaluated nothing: "1 account entry/entries across 2 repository/repositories were
  evaluated, and all are domain accounts" versus "2 repository/repositories were checked
  and none grants access to a named account."
  This came out of validating 0.3.2 in the lab. With one domain account granted on a
  repository the check returned a correct Pass — but the report was word-for-word
  identical to the Pass it would have returned had it read nothing at all, so the run
  could not confirm the fix. An unverifiable Pass is how the `.Accounts` defect
  survived: three checks returned confident clean results for weeks while measuring
  nothing, and no report distinguished them from checks that were working.
  Applied to SEC-004 only for now; the same treatment is worth considering for every
  check whose Pass is currently silent.

## [0.3.2] - 2026-08-03
### Fixed
- **SEC-004 could never fire on any server.** It read `$perm.Accounts`, and
  `VBREPPermission` has no such property — its members are `Users` (string[]),
  `PermissionType`, `RepositoryId`, `IsEncryptionEnabled`, `EncryptionKey`. The list was
  therefore always `$null`, the loop never ran, and the check returned Pass
  unconditionally. It now reads `Users`.
- SEC-004 can now tell a machine-local prefix from this server's own NetBIOS domain
  prefix, which it previously could not: `BACKUP01\Administrator` and
  `CORP\Administrator` are both a dotless label plus a backslash, and only the
  first breaks on the appliance. The check resolves the server's own domain
  (`Win32_ComputerSystem.Domain`, falling back to `USERDOMAIN`/`USERDNSDOMAIN`) and
  compares the prefix against the machine name, the repository host's short name, and
  the domain's NetBIOS label.
- A local account of the machine **hosting the repository** is now caught, not just one
  belonging to the backup server.
- Names that genuinely cannot be classified — an unrecognised NetBIOS prefix, or a bare
  user name with no prefix at all — return `Manual` naming them for review, rather than
  being guessed in either direction. Guessing "local" would tell an operator to strip
  valid domain accounts across the fleet; guessing "domain" would restore the false
  Pass this release removes.
- Eight cases covered, each in its own process: mixed local+domain (only the local one
  flagged), domain-only in all three forms, `BUILTIN\` / `.\` / `NT AUTHORITY\`, a local
  account on a second repository's host, an unknown NetBIOS prefix, a bare name, and an
  empty permission list.

## [0.3.1] - 2026-08-03
### Fixed
- **JOB-003 no longer counts a setting as a script.** `ScriptingMode` was reported
  alongside the script paths, so a job with four scripts read "5 script reference(s)
  found" and the fifth bullet was `ScriptingMode = IgnoreErrors`. An operator working
  through the list to copy files would have gone looking for a file that does not
  exist. Every entry the check now returns is a file to copy, and nothing else.
  `ScriptingMode` is dropped rather than excluded from the count: it says whether
  script errors are ignored, which has no bearing on which files migration fails to
  copy. Found by reading the rendered HTML, not the JSON.

## [0.3.0] - 2026-08-03
### Added
- **JOB-003 now reads all three surfaces that hold job scripts**, where it previously
  read one. Validated on a 13.1 lab job with all four script slots populated: it now
  finds all four and attributes each to the right job and machine.
  - **Pre/post-job commands** (`GetOptions().JobScriptCommand`) — the job's Advanced
    settings. Never read before, so these were invisible.
  - **Per-machine guest script overrides** — *Guest Processing → application handling
    for individual servers → Scripts* writes to the job **object**, not the job. This
    is where the missing scripts actually were.
  - **Job-level guest scripts** — already read; unchanged.
- Per-object options are read from the object's own `.VssOptions` property rather than
  `Get-VBRJobObjectVssOptions`, which is a round-trip per object. Measured on the lab:
  4 ms vs 56 ms for two objects, identical data. The cmdlet remains a fallback. This
  matters because the run is repeated across a large fleet.
- A pre/post-job entry is a **command line**, not a path, so it can carry arguments —
  including a password. Only the executable is reported, and when it cannot be
  separated from its arguments confidently (unquoted path containing spaces, or an
  interpreter such as `powershell.exe` where the script is itself an argument) the
  check says a command is enabled without echoing it. Ten cases covered, including
  quoted paths, unterminated quotes and interpreter invocations; none leaks an
  argument.

### Fixed
- **JOB-003's clear result is now an honest Pass.** With all three surfaces read, "no
  scripts configured" is a claim the check can actually make, so it no longer has to
  hedge to `Manual` on every server. It still names CSV files as undetectable rather
  than implying they were checked.
- Guest script evidence no longer prints the `IsAtLeastOneScriptSet` flag as though it
  were a file path — only `PreScriptFilePath` / `PostScriptFilePath` are read.

### Changed
- JOB-002 confidence raised from Low to **High**: both paths are now proven on real
  13.1. Removing the SQL Server role from the lab's application group flipped it from
  `Blocker` (with correct evidence) to `Pass`, a paired positive/negative test on one
  object.

## [0.2.2] - 2026-08-03
### Added
- README: **What the reports contain, and how to handle them** — states that the
  tool is read-only and handles no credential secrets, inventories the data classes
  each report discloses, and records the two fleet-scale consequences: the output
  folder keeps its inherited ACL, and a collection of reports aggregates into a
  description of the whole estate.

### Fixed
- **JOB-003 no longer reports a Pass it has not earned.** Its clear result claimed
  "no pre/post-job or pre-freeze/post-thaw scripts detected", but the check only
  reads guest processing options (`GuestScriptsOptions`) — job-level pre/post-job
  commands and CSV files are outside what it looks at. It now returns `Manual`,
  states exactly which of the two it verified, and asks for the rest by hand.
  Reading job-level commands is deliberately left out for now: a pre/post-job
  command is a full command line, so surfacing it verbatim would put whatever
  arguments it carries — including any password passed on it — into the report.

## [0.2.1] - 2026-08-03
### Added
- **KB4800's capture date is stamped into every output** alongside the tool version:
  the HTML and console headers read "Reference: KB4800 (captured 2026-07-24)" and the
  JSON carries `kbCaptured`. KB4800 is a living document whose guidance can change
  with a new release, so a report needs to state which reading of it applies —
  otherwise a report produced today cannot be interpreted safely months later. The
  date is a single constant in `New-PrecheckResult.ps1`, to be updated whenever the KB
  is re-read and the checks reconciled against it.
- **The tool version is stamped into every output.** The HTML header and console both
  show "Precheck version", and the JSON carries `toolVersion`. A phased migration runs
  for months and customers keep stale copies of the script, so a report that cannot
  say which build produced it is hard to act on — and the JSON is what aggregates
  across a fleet. The module reads it from the manifest; the standalone build emits it
  as a literal.

### Changed

### Fixed
- **Report and console counts did not reconcile with the stated total.** Both listed
  Blocker/Action/Warning/Manual/NextStep/Info/Pass but omitted `Skipped`, so a 25-check
  run showed parts totalling 22. `Skipped` is now included in both.

## [0.2.0] - 2026-08-03

Validated against a live VBR **13.1.0.411** lab for the first time. That exposed
several checks that had never worked, so much of this release is correctness rather
than new surface.

### Added
- **Five new checks (20 → 25).** Four `PRE-*` checks covering KB4800's separate
  "Pre-Migration Considerations", with a new advisory `NextStep` status shown in its
  own report section: PRE-001 Entra ID secondary target, PRE-002 machine reachability
  from the appliance, PRE-003 file-to-tape source hostname, PRE-004 appliance
  timezone for Hitachi / HPE XP. Conditional ones stay silent when they do not apply,
  and `NextStep` never downgrades the verdict.
  Plus **SEC-005 console role assignment format**: appliance console login requires
  `user@fqdn`, so `BUILTIN\…`, `MACHINE\user` and NetBIOS `DOMAIN\user` assignments
  stop working after migration. `Action`, not `Blocker` — the appliance install
  creates a veeamadmin account, so access is not lost, and the fix (adding UPN-form
  assignments that carry across) can be done before migrating.
- **`Build-SingleFile.ps1` → `dist/VbrMigrationPrecheck-<version>.ps1`.** The tool is
  developed as a module because 25 checks need structure, but it is *run* by the
  customer, unattended, on many servers — where a folder tree, a separate entry
  script, a `.psd1`/`.psm1` and Mark-of-the-Web on every file are all friction. The
  build emits one self-contained ~1,940-line script needing nothing beside it. The
  version is in the filename because copies are kept for months across a phased
  migration. `dist/` is git-ignored; the build is one command and self-verifying
  (parses, counts checks, and asserts the entry logic's variables survived).
- **Two reference documents** under `docs/reference/`, so cmdlet and object-model
  details stop being guessed: `vbr-v13-cmdlet-details.md` (syntax and parameters for
  the 29 cmdlets this tool uses) and `vbr-v13-object-model.md` (properties, methods
  and enum values captured with `Get-Member` from a live server).

### Changed
- **Check titles are neutral topics, so they read correctly at any status.** Titles
  were phrased as the *desired* state and read backwards on failure —
  `[BLOCKER] JOB-002 No SureBackup jobs use the SQL Server Checker Script` said none
  existed while blocking precisely because one did. The status carries the verdict;
  the title names the subject.
- **Category names tidied, 9 → 8**: single-check `Version` and `License` merge into
  **Environment**; `Database` → **Job history**; `Pre-Migration` → **Preparation**.
  Check IDs are unchanged, so existing references stay valid.
- **Customer-facing text no longer explains the tool's internals.** 21 `Detail`
  strings named the cmdlet that was unavailable, and SEC-001 went on to enumerate
  what `Get-VBRSecurityOptions` does and does not cover. A customer does not care
  which cmdlet backs a check, and volunteering what the product's API cannot do reads
  as criticism of it. These now describe the environment: "Session-history retention
  could not be read on this server". Cmdlets remain in the three *remediation*
  instructions that name a command an operator would actually run.
- **SEC-002 reports candidates instead of prescribing UPN conversion, and recognises
  `fqdn\user`.** It previously flagged every credential containing a backslash and
  told the operator to re-enter it in UPN form. One credential store feeds surfaces
  with different requirements, so format alone cannot decide — and testing settled
  what the Windows-server surface actually accepts:

  | Credential form | Adding a Windows server |
  |---|---|
  | `corp\administrator` (NetBIOS prefix) | **failed** |
  | `corp.local\administrator` (FQDN prefix) | worked |
  | `administrator@corp.local` (UPN) | worked |

  A prefix containing a dot is therefore already Kerberos-compatible and is not
  flagged. NetBIOS prefixes, machine prefixes and bare names remain review
  candidates, and non-Standard credential types (SSH, SSH private key, Kasten token,
  Managed service account) plus `root` are excluded — which also removes the
  credential records VBR auto-creates on every server. SEC-005 is deliberately
  stricter, accepting UPN only; both checks note the asymmetry so it is not
  "corrected" later.
- **DB-001 reads the retention setting instead of scanning the session table.**
  `Get-VBRBackupSession` has only `-Name`, `-Id` and `-State` parameter sets — no date
  filter, no ordering — so checking the rows meant materialising every session in the
  database and sorting it to obtain one date, on every server. KB4800's remedy is
  *"reduce the session history retention"*, so the setting is what matters:
  `Get-VBRHistoryOptions` → `KeepAllSessions` and `RetentionLimitWeeks`. Retention
  shorter than the time since the upgrade proves pre-upgrade sessions have already
  aged out, from two properties and no enumeration, and findings now name the setting
  and a target value. The cutoff parameter is the neutral `-UpgradeDate` (aliases
  `-V12UpgradeDate` / `-V13UpgradeDate`).
- **DEP-001 reads Cloud Connect status from the licence.**
  `Get-VBRInstalledLicense.CloudConnect` (`Enabled` / `Disabled` / `Enterprise` /
  `Invalid`) is a positive signal, so `Disabled` → `Pass` without ever calling the
  Cloud Connect cmdlets — which *throw* without a provider licence and previously
  surfaced as a noise item on every non-Cloud-Connect server. Tenants and gateways
  are enumerated only when the licence says Cloud Connect is present, for evidence.
  `Invalid` or unreadable → `Info` rather than guessing on a Blocker-grade check.
- **ENV-001 no longer references unreleased versions.** It previously told operators
  that migration support "returns on" a specific future release and treated builds
  above 13.1 as supported. This output is customer-facing and an in-development
  release can still change, so the 13.1 blocker points at the released 13.0.x train
  and any newer build returns `Manual` — confirm against KB4800 — rather than
  asserting either way.
- **JOB-003 makes no cmdlet call per job.** `Get-VBRJob` already returns the
  guest-processing options: `CBackupJob.Info` carries `VssOptions` as a
  `CGuestProcessingOptions`, the same type `Get-VBRJobVSSOptions -Job` returns.
  Measured live: **16.30 ms/job** for the cmdlet against **1.80 ms/job** for
  `GetOptions()`, a ~9× gap consistent with a service round-trip versus a local
  deserialise; the property read is free. The cmdlet remains as a fallback.
- **Shared data is fetched once per run.** Four cmdlets were called twice because two
  checks each need the same data — the licence (ENV-002, DEP-001), the job list
  (DEP-002, JOB-003), Entra ID tenants (DEP-003, PRE-001) and storage plug-in hosts
  (STG-002, PRE-004). A per-run cache halves those round-trips and stops
  `Test-PrecheckCmdlet` re-resolving the same name. It is cleared at the start of
  every run, so it cannot go stale or leak between servers.
- **A thrown check now names the function to fix**, rather than being labelled with a
  KB item ID it never evaluated. `Invoke-PrecheckSafe` drops from four parameters to
  two, and the orchestrator no longer carries a 25-entry ID lookup table duplicating
  what each check already declares.
- **All cmdlet names verified** against the official A-Z reference. Several did not
  exist: storage integrations take no `VBR` prefix (`Get-NetAppHost`,
  `Get-NimbleHost`, `Get-StoragePluginHost`), four-eyes has no cmdlet at all, repo
  access is `Get-VBREPPermission`, and version detection uses
  `Get-VBRBackupServerInfo`.
- **Comment hygiene.** Comment lines 474 → 273 (24% → 15% of the shipping code),
  total 1,968 → 1,732. Removed decision narrative already recorded here; kept
  non-obvious property facts and the notes that stop a future edit reintroducing a
  bug. Verified by snapshotting all 25 check results before and after — identical
  status, detail and evidence.

### Fixed
- **The run aborted entirely if a VBR session already existed.**
  `Connect-VBRServer` is fatal when a session is open — *"You are already connected to
  localhost:443. Close previous session first"* — so anyone running from the **Veeam
  PowerShell Toolkit**, which opens a session on launch, got only that error and no
  checks at all. An existing session is now detected and reused, and an "already
  connected" error is treated as success. Genuine failures still surface. The context
  records `OpenedSession` so the orchestrator only closes a session it opened,
  instead of dropping the operator's own.
- **JOB-002 was a false Pass on a Blocker.** Detection did
  `$ag | ConvertTo-Json -Depth 6` and regexed for `SqlChecker`; against a live
  application group with the SQL test script enabled, that returns **False** — the
  setting is not reachable in the serialised form at that depth. JOB-002 is the only
  check that emits a `Blocker`, so the tool cleared an environment whose SureBackup
  verification would fail on the appliance. It now walks
  `Get-VBRApplicationGroup` → `VM` → `Role`, since assigning the **SQLServer role**
  is what attaches the script, and names the application group *and* the VM.
- **ENV-002 could never classify a licence.** It probed `LicensedSocketsNumber`,
  `LicensedSockets` and `SocketsNumber`, none of which exist on
  `VBRInstalledLicense`, so it always fell through to `Info`. It now reads
  `SocketLicenseSummary` and `InstanceLicenseSummary`, and counts *sockets* rather
  than array entries — an instance-based licence still returns one summary entry
  containing zero sockets, so counting entries reported a socket licence and raised a
  false `Action`. A socket licence is asserted only on a positive count.
- **JOB-003 never detected guest scripts.** It probed `$opt.VmScriptSettings` and
  `$opt.JobScriptCommand`, neither of which exists on `CGuestProcessingOptions`.
  Guest freeze/thaw scripts live on `GuestScriptsOptions`, with an
  `IsAtLeastOneScriptSet` flag and per-platform `*ScriptFiles`. The check had been
  silently passing on every server.
- **AGT-004 flagged the default protection group as using pre-installed agents.** It
  stringified Type/Container/Name and matched `Manual`, so the built-in group named
  *"Manually Added"* matched — one guaranteed bogus finding per server. It now
  compares the `VBRProtectionGroupType` value.
- **DB-001 could never flag anything when given a cutoff date.**
  `$UpgradeDate.Value` returned `$null`, because PowerShell unwraps
  `[Nullable[datetime]]` to `DateTime`, so the check compared `CreationTime -lt $null`
  — silently false.
- **No run could complete at all on PowerShell 7.6.4.** The orchestrator died at the
  verdict step, before any summary or report: 7.6.4 throws `Argument types do not
  match` on `@(<List[object]>)`, the array subexpression operator itself failing,
  which `Get-PrecheckVerdict` hit on `Total = @($Results).Count`. The result set is
  converted with `.ToArray()` once after the check loop. (Unaffected on 7.4/7.5.)
- **SEC-001 wording finalised.** `Get-VBRSecurityOptions` exposes only FIPS, Linux
  trusted-host, audit-log and certificate settings — no four-eyes state and no MFA
  state — and no cmdlet anywhere reads four-eyes. The check states this as settled
  rather than pending, and points at Users & Roles → **Authorization**.
## [0.1.0] - 2026-07-24
### Added
- Initial scaffold of the `VbrMigrationPrecheck` PowerShell module.
- 20 read-only checks covering the Veeam KB4800 known limitations for migrating
  a Windows VBR v13.0.x server to the Veeam Software Appliance (VSA):
  version, license, Cloud Connect, Google Cloud plug-in, Entra ID, agents
  (versions / disabled policies / Mac domain auth / protection-group post-steps),
  storage (NetApp ONTAP role, plug-in versions, Nimble FIPS), jobs (CDP,
  SureBackup SQL checker, pre/post & freeze/thaw scripts), security (four-eyes,
  credential UPN format, trusted domains, repository local SIDs), and the
  pre-v12 session-history database blocker.
- Overall verdict (MIGRATION BLOCKED / ACTION REQUIRED / REVIEW WARNINGS / READY)
  with matching process exit code.
- Console summary + self-contained HTML report + JSON report + run log.
- `Run-Precheck.ps1` entry point with config-file support.
- Version rule: migration is supported from the **13.0.x** train; VBR **13.1 is a
  hard blocker**.

### Notes
- Several checks rely on cmdlet names/properties not yet validated against a live
  v13 environment; those fail safe (degrade to Manual/Info). See
  `CHECKS.md`.
