# Connect-VbrPrecheck
# Loads the Veeam.Backup.PowerShell module and opens a session to the Windows
# VBR server being evaluated for migration. Returns a lightweight context object
# that Invoke-VbrMigrationPrecheck passes to every check.
#
# Design notes:
#  * Runs best ON the VBR server itself (default -Server localhost) - the richest
#    and most reliable place to read configuration. Remote works too if the
#    console/module is installed locally and the account can authenticate.
#  * v13's module requires PowerShell 7.0+. PowerShell 5.1 / ISE will fail to
#    import Veeam.Backup.PowerShell - we fail fast with a clear message.
#  * Connect-VBRServer against a Windows VBR uses the classic path (no port
#    switch needed). This tool targets the WINDOWS source server, NOT the VSA
#    appliance - do not point it at a v13 appliance (that would need :443 Identity
#    service and is not the object of the precheck).

function Connect-VbrPrecheck {
    [CmdletBinding()]
    param(
        [string] $Server = 'localhost',
        [PSCredential] $Credential
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "PowerShell 7.0+ is required (Veeam.Backup.PowerShell will not load under $($PSVersionTable.PSVersion)). Run this from 'pwsh', not Windows PowerShell / ISE."
    }

    Write-PrecheckLog "Importing Veeam.Backup.PowerShell module..." -Level STEP
    try {
        Import-Module Veeam.Backup.PowerShell -DisableNameChecking -ErrorAction Stop -Verbose:$false
    }
    catch {
        throw "Could not import Veeam.Backup.PowerShell. Run this on a machine with the VBR v13 console/module installed. Original error: $($_.Exception.Message)"
    }

    # Reuse an existing session if there is one. The Veeam PowerShell Toolkit opens
    # a session on launch, so connecting again would be redundant - and worse, the
    # caller would then disconnect at the end and drop the session the operator was
    # working in. OpenedSession records who owns it.
    $existing = $null
    if (Test-PrecheckCmdlet 'Get-VBRServerSession') {
        try { $existing = Get-VBRServerSession -ErrorAction SilentlyContinue } catch { }
    }

    $openedSession = $false
    if ($existing) {
        $connectedTo = if ($existing.PSObject.Properties['Server'] -and $existing.Server) { "$($existing.Server)" } else { $Server }
        Write-PrecheckLog "Reusing the existing VBR session ($connectedTo) - not connecting or disconnecting." -Level INFO
    }
    else {
        Write-PrecheckLog "Connecting to VBR server '$Server'..." -Level STEP
        $connectArgs = @{ Server = $Server; ErrorAction = 'Stop' }
        if ($Credential) { $connectArgs.Credential = $Credential }
        try {
            Connect-VBRServer @connectArgs | Out-Null
            $openedSession = $true
        }
        catch {
            # Connect-VBRServer is fatal when a session already exists ("You are
            # already connected to <server>. Close previous session first"). Treat
            # that as success and reuse it - the detection above cannot be relied on
            # alone, since Get-VBRServerSession may be missing or return nothing.
            if ($_.Exception.Message -match 'already connected') {
                Write-PrecheckLog "Already connected - reusing the existing session." -Level INFO
            }
            else { throw }
        }
    }

    # Capture whatever product version we can resolve up front so the version
    # check and the report header can reuse it.
    $version = Get-VbrProductVersion

    $ctx = [PSCustomObject]@{
        Server        = $Server
        ConnectedAt   = Get-Date
        ProductBuild  = $version.Build
        ProductString = $version.DisplayName
        PSVersion     = $PSVersionTable.PSVersion.ToString()
        OpenedSession = $openedSession
    }

    Write-PrecheckLog "Connected. Detected VBR build: $($version.DisplayName)" -Level INFO
    return $ctx
}

# Disconnect-VbrPrecheck - convenience wrapper so callers/tests do not have to
# remember the Veeam verb.
function Disconnect-VbrPrecheck {
    [CmdletBinding()]
    param()
    if (Test-PrecheckCmdlet 'Disconnect-VBRServer') {
        try { Disconnect-VBRServer -ErrorAction SilentlyContinue } catch { }
    }
}
