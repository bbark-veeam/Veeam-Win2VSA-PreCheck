@{
    RootModule        = 'VbrMigrationPrecheck.psm1'
    ModuleVersion     = '0.7.2'
    GUID              = 'b7e2c1a4-8f3d-4a6e-9c21-5d0f7a2b9e10'
    Author            = 'Brad Barker'
    CompanyName       = 'Veeam'
    Copyright         = '(c) Brad Barker. MIT License.'
    Description       = 'Read-only pre-check validation for migrating a Windows-based Veeam Backup & Replication (v13.0.x) server to the Linux-based Veeam Software Appliance (VSA). Evaluates the known limitations documented in Veeam KB4800 and reports whether migration is possible.'

    # 7.0 is this tool's floor. Do NOT raise it to match one server's Veeam module:
    # the module declares its OWN minimum and that minimum VARIES BY VBR BUILD. Measured:
    # a 13.0.2 server's module loads on PowerShell 7.4.14, while a 13.1 server's module
    # refuses below 7.6. Since the migration candidates are 13.0.x, hard-coding 7.6 here
    # would refuse to run on precisely the servers this tool exists for.
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Connect-VbrPrecheck',
        'Invoke-VbrMigrationPrecheck',
        'Export-PrecheckReport',
        'Export-PrecheckRoleAssignmentScript'
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
