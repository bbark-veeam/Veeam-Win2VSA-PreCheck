#Requires -Version 7.0
# Pure-function tests: no Veeam connection, no mocks.

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'VbrMigrationPrecheck') -Force
    $script:Mod = Get-Module VbrMigrationPrecheck
}

Describe 'Get-PrecheckScriptPath' {

    # A pre/post-job entry is a COMMAND LINE, so it can carry a password. The check
    # reports the executable only, and reports nothing when it cannot separate the
    # two confidently.
    It 'returns a bare path unchanged' {
        & $script:Mod { Get-PrecheckScriptPath 'C:\Scripts\prejob.cmd' } |
            Should -Be 'C:\Scripts\prejob.cmd'
    }

    It 'takes the quoted executable and discards arguments' {
        & $script:Mod { Get-PrecheckScriptPath '"C:\Program Files\Tool\run.exe" -password Hunter2' } |
            Should -Be 'C:\Program Files\Tool\run.exe'
    }

    It 'strips arguments from an unquoted path' {
        & $script:Mod { Get-PrecheckScriptPath 'C:\s\backup.cmd -password Hunter2' } |
            Should -Be 'C:\s\backup.cmd'
    }

    It 'refuses an interpreter, because the script is itself an argument' {
        & $script:Mod { Get-PrecheckScriptPath 'powershell.exe -File C:\s\x.ps1 -Password Hunter2' } |
            Should -BeNullOrEmpty
    }

    It 'refuses an unquoted path containing spaces, which cannot be split reliably' {
        & $script:Mod { Get-PrecheckScriptPath 'C:\Program Files\Tool\run.exe -password Hunter2' } |
            Should -BeNullOrEmpty
    }

    It 'refuses an unterminated quote' {
        & $script:Mod { Get-PrecheckScriptPath '"C:\unterminated.cmd -password Hunter2' } |
            Should -BeNullOrEmpty
    }

    It 'handles empty and whitespace input' {
        & $script:Mod { Get-PrecheckScriptPath '' }    | Should -BeNullOrEmpty
        & $script:Mod { Get-PrecheckScriptPath '   ' } | Should -BeNullOrEmpty
    }

    It 'never returns a value containing an argument' {
        $lines = @(
            'C:\s\a.cmd -password Hunter2'
            '"C:\Program Files\T\r.exe" -u admin -p Hunter2'
            'powershell.exe -File x.ps1 -Password Hunter2'
            'pwsh -c "Invoke-Thing -Secret Hunter2"'
        )
        foreach ($l in $lines) {
            $got = & $script:Mod { param($x) Get-PrecheckScriptPath $x } $l
            if ($got) { $got | Should -Not -Match 'Hunter2' }
        }
    }
}

Describe 'Get-PrecheckGuestScripts' {

    BeforeAll {
        function New-ScriptFiles {
            param($Pre, $Post)
            [pscustomobject]@{
                PreScriptFilePath     = $Pre
                PostScriptFilePath    = $Post
                IsAtLeastOneScriptSet = [bool]($Pre -or $Post)
            }
        }
        function New-Gso {
            param($Mode, $Win)
            [pscustomobject]@{
                ScriptingMode         = $Mode
                WinScriptFiles        = $Win
                LinScriptFiles        = (New-ScriptFiles $null $null)
                JobLinScriptFiles     = (New-ScriptFiles $null $null)
                JobMacScriptFiles     = $null
                IsAtLeastOneScriptSet = $Win.IsAtLeastOneScriptSet
                CredsId               = '00000000-0000-0000-0000-000000000000'
            }
        }
    }

    It 'returns the configured Win pre/post paths' {
        $gso = New-Gso 'IgnoreErrors' (New-ScriptFiles 'C:\s\pre.cmd' 'C:\s\post.cmd')
        $out = & $script:Mod { param($g) Get-PrecheckGuestScripts -GuestScriptsOptions $g -Label 'J' } $gso
        $out.Count | Should -Be 2
        ($out -join ';') | Should -Match 'PreScriptFilePath -> C:\\s\\pre\.cmd'
        ($out -join ';') | Should -Match 'PostScriptFilePath -> C:\\s\\post\.cmd'
    }

    # Regression: ScriptingMode was reported alongside the paths, so four scripts
    # were counted as five and a reader went looking for a file that did not exist.
    It 'does not report ScriptingMode as though it were a script' {
        $gso = New-Gso 'IgnoreErrors' (New-ScriptFiles 'C:\s\pre.cmd' 'C:\s\post.cmd')
        $out = & $script:Mod { param($g) Get-PrecheckGuestScripts -GuestScriptsOptions $g -Label 'J' } $gso
        ($out -join ';') | Should -Not -Match 'ScriptingMode'
    }

    # Regression: enumerating every property emitted the boolean flag as a path.
    It 'does not report IsAtLeastOneScriptSet as though it were a path' {
        $gso = New-Gso 'IgnoreErrors' (New-ScriptFiles 'C:\s\pre.cmd' $null)
        $out = & $script:Mod { param($g) Get-PrecheckGuestScripts -GuestScriptsOptions $g -Label 'J' } $gso
        ($out -join ';') | Should -Not -Match 'IsAtLeastOneScriptSet'
    }

    It 'returns nothing when no script is set' {
        $gso = New-Gso 'Disabled' (New-ScriptFiles $null $null)
        $out = & $script:Mod { param($g) Get-PrecheckGuestScripts -GuestScriptsOptions $g -Label 'J' } $gso
        $out.Count | Should -Be 0
    }

    It 'returns nothing for a null options object' {
        $out = & $script:Mod { Get-PrecheckGuestScripts -GuestScriptsOptions $null -Label 'J' }
        $out.Count | Should -Be 0
    }
}
