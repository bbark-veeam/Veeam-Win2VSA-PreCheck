@{
    RootModule        = 'VbrMigrationPrecheck.psm1'
    ModuleVersion     = '0.4.4'
    GUID              = 'b7e2c1a4-8f3d-4a6e-9c21-5d0f7a2b9e10'
    Author            = 'Brad Barker'
    CompanyName       = 'Veeam'
    Copyright         = '(c) Brad Barker. MIT License.'
    Description       = 'Read-only pre-check validation for migrating a Windows-based Veeam Backup & Replication (v13.0.x) server to the Linux-based Veeam Software Appliance (VSA). Evaluates the known limitations documented in Veeam KB4800 and reports whether migration is possible.'

    # The Veeam module requires PowerShell 7.0+ (its own .psd1 sets the minimum).
    PowerShellVersion = '7.0'

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
