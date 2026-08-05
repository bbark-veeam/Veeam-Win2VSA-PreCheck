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
