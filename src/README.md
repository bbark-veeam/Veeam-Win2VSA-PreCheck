# Source — for maintainers, not for running the precheck

**If you came here to run the precheck, you are in the wrong folder.** Use
`VbrMigrationPrecheck.ps1` in the repository root — one file, nothing to install. See the
[README](../README.md).

**This folder is the source of truth. The script in the repository root is generated from
it.**

The precheck is developed as a module because 25 checks in one file are hard to
navigate, and it is *distributed* as a single script because customers run it
unattended on a large number of servers and copying a folder tree causes mistakes.

```
VbrMigrationPrecheck/     the module
  Private/                shared helpers (result shape, logging, cmdlet probing, caching)
  Checks/                 one file per category, one function per check
  Public/                 connect, orchestrate, export
Run-Precheck.ps1          entry point for the module layout (development)
Build-SingleFile.ps1      concatenates the module into the standalone script
config/                   optional config file (see config.example.json)
```

## Making a change

Edit the module, then rebuild:

```powershell
./Build-SingleFile.ps1
```

That writes `dist/VbrMigrationPrecheck-<version>.ps1`, which replaces
`VbrMigrationPrecheck.ps1` in the repository root. The build parses the result, counts
functions and check IDs, and fails loudly rather than emitting something subtly wrong.

**Do not edit the generated script.** Changes there are lost on the next build, and its
header says so.

## Tests

```powershell
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0   # once
Invoke-Pester -Path ./tests -Output Detailed
```

64 tests. They run against mocked Veeam cmdlets, so no VBR server is needed. They also
run in CI on every push, on both Windows and Linux.

Each one corresponds to a real defect found in this tool. Almost every one was a
plausible-looking member name or match that returned nothing, so the check reported a
confident clean result — hardly any was a crash, and none would have been caught by
reading the code. The tests exist so a future edit cannot quietly restore them:

| Test group | The defect it pins down |
|---|---|
| AGT-001 | an unparseable version string fell through into a Pass |
| AGT-002 | filtered on `IsEnabled`, which does not exist; `ScheduleEnabled` is a different property |
| AGT-003 | matched `Mac` as a substring, so the word "ma**c**hine" made Windows jobs look like Mac jobs |
| AGT-004 | read the group's `Type` instead of `Container.Type`; `ManuallyAdded` vs `ManuallyDeployed` |
| SEC-002 | passed on a credential list it had failed to read; the clean result now counts what it judged |
| SEC-004 | read `.Accounts`, which does not exist on `VBREPPermission`; local vs domain prefixes |
| JOB-001 | populated path had never run — no CDP policy has ever existed in the lab |
| JOB-002 | a regex over the serialised object returned False with the script enabled; and it could report clean without enumerating anything |
| JOB-003 | read only the job-level guest options, missing per-machine overrides and `JobScriptCommand` |
| DEP-002 | detection must key on Google Cloud *configuration*, not the plug-in being installed |
| DEP-003, STG-001/002/003 | populated paths had never run — the lab has no Entra ID tenant, NetApp, storage plug-in or Nimble |
| `Get-PrecheckScriptPath` | a pre/post-job command line can carry a password; only the executable is reported |

Two patterns are worth knowing before you change a check:

- **Never let an unread collection become a clean result.** An empty collection and an
  unreadable one look identical, and four checks used to fall through the second into a
  Pass. Track whether the read succeeded and degrade to `Manual`/`Info` if it did not.
  `$global:MockThrow` in the tests simulates this — it is how a licence-dependent or
  permission-denied cmdlet actually behaves, and it is distinct from a missing cmdlet.
- **Every clean result states what it examined.** A Pass naming no quantity reads the
  same whether the check inspected everything or nothing, which is how the SEC-004
  defect survived for weeks. Assert on that text in the test.

A test suite that passes proves nothing on its own. When adding one, reintroduce the
defect and confirm the test fails — that is how all 25 of these were validated.

## Adding a check

Drop a `Test-*.ps1` function into `Checks/` and register it in `$script:PrecheckRegistry`
in `Public/Invoke-VbrMigrationPrecheck.ps1`.

## Two rules worth knowing before you change a check

**Never return a false Pass.** When a cmdlet or property cannot be read, degrade to
`Manual` or `Info` with the correct guidance. A check that defers to a human costs one
line of reading; a check that wrongly reports "clear" hides the thing the tool exists to
find.

**Verify the property name against a real object.** Most defects found in this tool have
been plausible-sounding member names that returned nothing and so produced a confident
clean result — `IsEnabled` instead of `JobEnabled`, `.Accounts` instead of `.Users`, a
protection group's `Type` instead of its `Container.Type`. Two techniques settle it
quickly:

```powershell
# the full vocabulary of an enum, with no objects and no lab setup needed
[Veeam.Backup.PowerShell.Infos.VBRProtectionGroupContainerType].GetEnumNames()

# the real shape of an object, then diff two that differ in one respect
Get-VBRComputerBackupJob | ForEach-Object {
    $_.PSObject.Properties | Sort-Object Name |
        ForEach-Object { "{0,-32} = {1}" -f $_.Name, $_.Value }
}
```

**And state what a Pass evaluated.** "3 policies were checked and all are enabled" can be
told apart from a check that looked at nothing; "no disabled policies found" cannot.
