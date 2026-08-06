@{
    RootModule        = 'VbrMigrationPrecheck.psm1'
    ModuleVersion     = '0.5.2'
    GUID              = 'b7e2c1a4-8f3d-4a6e-9c21-5d0f7a2b9e10'
    Author            = 'Brad Barker'
    CompanyName       = 'Veeam'
    Copyright         = '(c) Brad Barker. MIT License.'
    Description       = 'Read-only pre-check validation for migrating a Windows-based Veeam Backup & Replication (v13.0.x) server to the Linux-based Veeam Software Appliance (VSA). Evaluates the known limitations documented in Veeam KB4800 and reports whether migration is possible.'

    # Veeam.Backup.PowerShell for v13 requires PowerShell 7.6 - its own manifest sets
    # that minimum, and the import fails outright below it with:
    #   "The version of PowerShell on this computer is '7.4.x'. The module ... requires a
    #    minimum PowerShell version of '7.6' to run."
    # Stating 7.0 here told operators a 7.4 machine was fine, then failed at import.
    PowerShellVersion = '7.6'

    FunctionsToExport = @(
        'Connect-VbrPrecheck',
        'Invoke-VbrMigrationPrecheck',
        'Export-PrecheckReport'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Veeam', 'VBR', 'VSA', 'Migration', 'Precheck', 'KB4800')
            LicenseUri   = ''
            ProjectUri   = ''
            ReleaseNotes = 'Initial scaffold: KB4800 known-limitation checks for Windows VBR -> VSA migration.'
        }
    }
}
