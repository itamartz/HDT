# The IRegistryService contract, read subset (PROJECT constraint 4, DESIGN
# 3.2.1, DESIGN 12.2.1).
#
# Every implementation - the hand-written fake, the real Get-ItemProperty adapter
# - must pass this file unchanged. Adding an implementation is a one-row change
# to $script:HDTImplementation below, not a new test file.
#
# SCOPE, and why the method names are what they are: this is the READ subset,
# which is all fact gathering needs (the SecureBoot state key). Phase 03 extends
# the SAME interface with the write half for the autologon lifecycle in DESIGN
# 4.5 - SetValue as a recorded operation, RemoveValue, RemoveKey. TestPath and
# GetValue are named so that extension is additive: nothing here has to be
# renamed when the writes arrive.
#
# Absence is normal, not exceptional. A BIOS machine has no
# SecureBoot\State key at all, so GetValue returns $null for a missing key or a
# missing name and never throws. A fact gatherer that had to catch would be a
# fact gatherer that swallows real errors too.
#
# The registry is built at discovery time, not in BeforeAll: Pester 5 expands
# -ForEach while discovering, so a BeforeAll would produce zero test cases.

# The skip goes on a Context INSIDE the Describe, never on the Describe itself.
# Verified against Pester 5.7.1: -Skip: on a -ForEach Describe is bound where
# Describe is called, before -ForEach binds the row's keys, so $Skip is unset
# there and every row runs regardless. $IsWindows does not exist under Windows
# PowerShell 5.1, hence [System.Environment]::OSVersion.Platform.
# WHERE THE WRITE HALF WRITES, and why it is not negotiable: the real row writes
# ONLY under HKCU:\Software\HDT-Contract-Test-<guid>, a key it creates and
# removes in AfterAll. HKLM is never written by this suite. A contract test that
# needed elevation would be a contract test that gets skipped, and a contract
# test that wrote to HKLM would be one nobody dares run on their own machine.
$script:HDTWriteRoot = 'HKCU:\Software\HDT-Contract-Test-{0}' -f ([guid]::NewGuid().ToString('N'))

$script:HDTImplementation = @(
    @{
        Name         = 'FakeRegistryService'
        Factory      = { New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' = @{ ProductName = 'FixtureOS' }
            } }
        JournalFactory = { param($Journal) New-HDTFakeRegistryService -Journal $Journal }
        KnownPath    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        KnownName    = 'ProductName'
        MissingPath  = 'HKLM:\SOFTWARE\HDTNoSuchKey'
        WriteRoot    = $script:HDTWriteRoot
        Logs         = $false
        Skip         = $false
    }
    @{
        Name         = 'RegistryService'
        Factory      = { New-HDTRegistryService }
        JournalFactory = { param($Journal) New-HDTRegistryService -Journal $Journal }
        KnownPath    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        KnownName    = 'ProductName'
        MissingPath  = 'HKLM:\SOFTWARE\HDTNoSuchKey'
        WriteRoot    = $script:HDTWriteRoot

        # Only the real adapter writes a log at all - the fake records
        # Operations and nothing else - so the assertions about what a log line
        # SAYS are marked here rather than assumed. The assertion about what it
        # must NEVER say runs against both.
        Logs         = $true
        Skip         = -not ([System.Environment]::OSVersion.Platform -eq 'Win32NT')
    }
)

Describe 'IRegistryService contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    }

    Context 'implementation' -Skip:$Skip {

        BeforeEach {
            $script:registry = & $Factory $script:repoRoot
        }

        It 'exposes every method the contract requires' {
            # Method, ScriptMethod: Get-Member -MemberType Method does NOT list a
            # ScriptMethod, and the real adapters are pscustomobjects carrying
            # ScriptMethod members. Do not "tidy" ScriptMethod away.
            $method = @($script:registry | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('TestPath', 'GetValue', 'NewKey', 'SetValue', 'RemoveValue', 'RemoveKey')) {
                $method | Should -Contain $name -Because "IRegistryService requires $name"
            }
        }

        It 'reports a key that exists' {
            $script:registry.TestPath($KnownPath) | Should -BeTrue
        }

        It 'reports a key that does not exist' {
            $script:registry.TestPath($MissingPath) | Should -BeFalse
        }

        It 'returns the value of a name that exists' {
            $script:registry.GetValue($KnownPath, $KnownName) | Should -Not -BeNullOrEmpty
        }

        It 'returns null for a name that does not exist under an existing key' {
            $script:registry.GetValue($KnownPath, 'HDTNoSuchValueName') | Should -BeNullOrEmpty
        }

        It 'returns null for a name under a key that does not exist' {
            $script:registry.GetValue($MissingPath, 'HDTNoSuchValueName') | Should -BeNullOrEmpty
        }

        It 'does not throw for a missing key' {
            # A BIOS machine genuinely has no SecureBoot\State key. Absence is a
            # fact, not a failure.
            { $script:registry.GetValue($MissingPath, 'UEFISecureBootEnabled') } | Should -Not -Throw
            { $script:registry.TestPath($MissingPath) } | Should -Not -Throw
        }

        It 'treats HKEY_LOCAL_MACHINE as a synonym for HKLM:' {
            $long = $KnownPath -replace '^HKLM:\\', 'HKEY_LOCAL_MACHINE\'

            $script:registry.TestPath($long) | Should -BeTrue
            $script:registry.GetValue($long, $KnownName) |
                Should -Be $script:registry.GetValue($KnownPath, $KnownName)
        }

        It 'records each call in Operations' {
            $script:registry.TestPath($KnownPath) | Out-Null
            $script:registry.GetValue($KnownPath, $KnownName) | Out-Null

            @($script:registry.Operations).Count | Should -Be 2
            @($script:registry.GetOperationName()) | Should -Be @('TestPath', 'GetValue')
        }

        It 'records a call that returned null' {
            # Provenance needs the attempt, not only the successes.
            $script:registry.GetValue($MissingPath, 'UEFISecureBootEnabled') | Out-Null

            @($script:registry.Operations).Count | Should -Be 1
            @($script:registry.Operations[0].Arguments)[0] | Should -Be $MissingPath
        }
    }

    # The write half (03-03), for the autologon lifecycle of DESIGN 4.5.
    Context 'write half' -Skip:$Skip {

        BeforeEach {
            $script:registry = & $Factory $script:repoRoot
            $script:key = '{0}\{1}' -f $WriteRoot, ([guid]::NewGuid().ToString('N'))
        }

        AfterAll {
            # Only ever removes the suite's own HKCU scratch root. The fake row
            # never created it, so this is a no-op there.
            Remove-Item -LiteralPath $WriteRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'creates a key that did not exist' {
            $script:registry.TestPath($script:key) | Should -BeFalse
            $script:registry.NewKey($script:key)

            $script:registry.TestPath($script:key) | Should -BeTrue
        }

        It 'creates a key idempotently' {
            $script:registry.NewKey($script:key)

            { $script:registry.NewKey($script:key) } | Should -Not -Throw
        }

        It 'round-trips a string value' {
            $script:registry.SetValue($script:key, 'DefaultUserName', 'Administrator', 'String')

            $script:registry.GetValue($script:key, 'DefaultUserName') | Should -BeExactly 'Administrator'
        }

        It 'round-trips a dword value' {
            # AutoLogonCount is a DWord. Winlogon ignores the string '3'.
            $script:registry.SetValue($script:key, 'AutoLogonCount', 3, 'DWord')

            $script:registry.GetValue($script:key, 'AutoLogonCount') | Should -Be 3
        }

        It 'creates the key implicitly when setting a value' {
            # New-ItemProperty fails on a key that does not exist.
            $script:registry.SetValue($script:key, 'AutoAdminLogon', '1', 'String')

            $script:registry.TestPath($script:key) | Should -BeTrue
        }

        It 'overwrites an existing value' {
            $script:registry.SetValue($script:key, 'AutoLogonCount', 3, 'DWord')
            $script:registry.SetValue($script:key, 'AutoLogonCount', 2, 'DWord')

            $script:registry.GetValue($script:key, 'AutoLogonCount') | Should -Be 2
        }

        It 'reports a missing value as null' {
            $script:registry.NewKey($script:key)

            $script:registry.GetValue($script:key, 'AutoAdminLogon') | Should -BeNullOrEmpty
        }

        # -- A SET IS NOT A DELETE ------------------------------------------
        #
        # THE DEFECT OF 2026-08-30, run-20260830-204613, step 12. On the registry
        # provider `New-Item -Force` does not mean "create it if it is missing";
        # it means "DELETE THIS KEY TREE AND MAKE AN EMPTY ONE". The real adapter
        # used it to make SetValue create its key, so every SetValue silently
        # wiped the key it was writing to - and arming autologon a second time
        # aimed that at a live
        # HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon: Shell,
        # Userinit, the Notify and GPExtensions subkeys, all of it. It then
        # failed part-way through the delete with an ArgumentException from
        # RegistryKey.DeleteSubKeyTree, surfacing as
        # "Exception calling SetValue with 4 argument(s)".
        #
        # THE FIRST RESTART SURVIVED IT because WinPE's Winlogon key is a shallow
        # RAM-hive copy that deletes cleanly, which is exactly why this is a
        # CONTRACT test: the fake's SetValue always created the key without
        # touching what was in it, so it was right and the adapter was wrong, and
        # nothing that ran only against the fake could ever have said so.
        It 'keeps the key''s other values when setting one' {
            $script:registry.SetValue($script:key, 'Shell', 'explorer.exe', 'String')
            $script:registry.SetValue($script:key, 'AutoAdminLogon', '1', 'String')

            $script:registry.GetValue($script:key, 'Shell') | Should -BeExactly 'explorer.exe'
        }

        It 'keeps the key''s child keys when setting a value' {
            $child = '{0}\Notify' -f $script:key
            $script:registry.NewKey($child)

            $script:registry.SetValue($script:key, 'AutoAdminLogon', '1', 'String')

            $script:registry.TestPath($child) | Should -BeTrue
        }

        It 'keeps a key''s values and children when it is created again' {
            # NewKey ran on the same -Force, so "create a key that is already
            # there" emptied it too.
            $child = '{0}\Notify' -f $script:key
            $script:registry.SetValue($script:key, 'Shell', 'explorer.exe', 'String')
            $script:registry.NewKey($child)

            $script:registry.NewKey($script:key)

            $script:registry.GetValue($script:key, 'Shell') | Should -BeExactly 'explorer.exe'
            $script:registry.TestPath($child) | Should -BeTrue
        }

        It 'creates a key whose parents do not exist yet' {
            # What -Force was there for, and what the replacement still has to
            # do: the whole chain, not just the leaf.
            $nested = '{0}\One\Two\Three' -f $script:key

            $script:registry.NewKey($nested)

            $script:registry.TestPath($nested) | Should -BeTrue
        }

        It 'creates a value''s key even when its parents do not exist yet' {
            $nested = '{0}\One\Two\Three' -f $script:key

            $script:registry.SetValue($nested, 'AutoAdminLogon', '1', 'String')

            $script:registry.GetValue($nested, 'AutoAdminLogon') | Should -BeExactly '1'
        }

        It 'removes a value' {
            $script:registry.SetValue($script:key, 'AutoAdminLogon', '1', 'String')
            $script:registry.RemoveValue($script:key, 'AutoAdminLogon')

            $script:registry.GetValue($script:key, 'AutoAdminLogon') | Should -BeNullOrEmpty
        }

        It 'removes a value without error when it is absent' {
            # DESIGN 4.5.3 teardown runs on machines in unknown states. A
            # teardown that throws on the first absent value does not finish.
            $script:registry.NewKey($script:key)

            { $script:registry.RemoveValue($script:key, 'AutoAdminLogon') } | Should -Not -Throw
        }

        It 'removes a value without error when the key is absent' {
            { $script:registry.RemoveValue($script:key, 'AutoAdminLogon') } | Should -Not -Throw
        }

        It 'removes a key' {
            $script:registry.SetValue($script:key, 'AutoAdminLogon', '1', 'String')
            $script:registry.RemoveKey($script:key, $false)

            $script:registry.TestPath($script:key) | Should -BeFalse
        }

        It 'removes a key and its children with recurse' {
            $child = '{0}\Child' -f $script:key
            $script:registry.SetValue($child, 'Leg', 1, 'DWord')
            $script:registry.RemoveKey($script:key, $true)

            $script:registry.TestPath($script:key) | Should -BeFalse
            $script:registry.TestPath($child) | Should -BeFalse
        }

        It 'removes a key without error when it is absent' {
            { $script:registry.RemoveKey($script:key, $false) } | Should -Not -Throw
        }

        It 'refuses a key with children when recurse was not asked for' {
            # FOUND WHILE SWEEPING THE REMOVE PATHS, and it is a hang rather than
            # an error. `Remove-Item -Recurse:$false` on a registry key that has
            # children asks the HOST whether to delete them anyway, and neither
            # -Force nor -Confirm:$false answers it: in WinPE's interactive host
            # a teardown would stop dead on a question nobody is there to answer,
            # and under -NonInteractive it throws a PSInvalidOperationException
            # that names the host instead of the key. The fake has always refused
            # deterministically; the adapter now does too.
            # THE PARENT IS CREATED EXPLICITLY, because the two implementations
            # disagree about whether creating a child creates its ancestors - the
            # registry does, the fake seeds only the path it was given - and that
            # is not what this test is about.
            $child = '{0}\Child' -f $script:key
            $script:registry.NewKey($script:key)
            $script:registry.SetValue($child, 'Leg', 1, 'DWord')

            { $script:registry.RemoveKey($script:key, $false) } | Should -Throw

            $script:registry.TestPath($script:key) | Should -BeTrue
        }

        It 'records every write' {
            $script:registry.NewKey($script:key)
            $script:registry.SetValue($script:key, 'AutoAdminLogon', '1', 'String')
            $script:registry.RemoveValue($script:key, 'AutoAdminLogon')
            $script:registry.RemoveKey($script:key, $false)

            @($script:registry.GetOperationName()) | Should -Be @('NewKey', 'SetValue', 'RemoveValue', 'RemoveKey')
        }

        It 'honours -Journal' {
            $journal = [System.Collections.ArrayList]::new()
            $registry = & $JournalFactory $journal
            $registry.SetValue($script:key, 'AutoAdminLogon', '1', 'String')
            $registry.RemoveKey($script:key, $false)

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('RegistryService.SetValue', 'RegistryService.RemoveKey')
        }

        It 'names itself in ServiceName' {
            $script:registry.ServiceName | Should -BeExactly 'RegistryService'
        }
    }

    # WHAT A WRITE IS ALLOWED TO SAY ABOUT ITSELF.
    #
    # The adapter used to log the name, the type and the LENGTH of every value
    # and never the value, so that DESIGN 4.5.2's guarantee about the deployment
    # password could not depend on a future caller remembering. That protected
    # one value by making every registry write in the engine unreadable - a real
    # run's tattoo reads "registry value 'Make' ... was written as String (9
    # character(s))", which answers nothing.
    #
    # The silence is now an enforced guarantee, and this is where the guarantee
    # is asserted rather than the mechanism: what a secret-named value may never
    # put in a log is asked of EVERY implementation, and what an ordinary value
    # must put there is asked of the ones that write a log at all.
    Context 'what a write says about itself' -Skip:$Skip {

        BeforeEach {
            $script:registry = & $Factory $script:repoRoot
            $script:key = '{0}\{1}' -f $WriteRoot, ([guid]::NewGuid().ToString('N'))

            $script:logFileSystem = New-HDTFakeFileSystem
            $script:logContext = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:logFileSystem -Clock (New-HDTFakeClock -UtcNow ([datetime]::new(
                        2026, 8, 30, 22, 19, 34, [System.DateTimeKind]::Utc))) -Level Debug

            # The fake has no LogContext to set, which is the whole reason the
            # Logs column exists. Asking the object rather than the row name
            # keeps a third implementation from having to be listed here.
            if ($null -ne $script:registry.PSObject.Properties['LogContext']) {
                $script:registry.LogContext = $script:logContext
            }

            # THE MARKER IS SYNTHETIC ON PURPOSE. A fixture that looks like a
            # password is a password as far as the next person grepping this
            # repository is concerned.
            $script:marker = 'MARKER-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 12)

            $script:logText = {
                $all = ''
                foreach ($leaf in @('HDT.jsonl', 'HDT.log')) {
                    $path = 'X:\HDT\Logs\{0}' -f $leaf
                    if ($script:logFileSystem.TestPath($path)) {
                        $all += [string] $script:logFileSystem.ReadAllText($path)
                    }
                }

                return $all
            }
        }

        AfterAll {
            Remove-Item -LiteralPath $WriteRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'writes no cleartext of a value whose name says it is a secret' {
            # DefaultPassword is the name Winlogon reads the autologon password
            # from, written here into the suite's own HKCU scratch key rather
            # than into a real Winlogon - see the note at the top of this file.
            $script:registry.SetValue($script:key, 'DefaultPassword', $script:marker, 'String')

            (& $script:logText) | Should -Not -BeLike ('*{0}*' -f $script:marker)
        }

        It 'writes no cleartext of a value the caller marked, whatever it is called' {
            $script:registry.SetValue($script:key, 'Blob', $script:marker, 'String', $true)

            (& $script:logText) | Should -Not -BeLike ('*{0}*' -f $script:marker)
        }

        It 'stores the value it was asked to store, marked or not' {
            # A REDACTION IS ABOUT THE LOG AND NOTHING ELSE. An implementation
            # that protected the log by not writing the value would disarm
            # autologon rather than protect it.
            $script:registry.SetValue($script:key, 'Blob', $script:marker, 'String', $true)

            $script:registry.GetValue($script:key, 'Blob') | Should -BeExactly $script:marker
        }

        It 'says the value it wrote' -Skip:(-not $Logs) {
            $script:registry.SetValue($script:key, 'Make', 'Dell Inc.', 'String')

            (& $script:logText) | Should -BeLike "*'Dell Inc.'*"
        }

        It 'says out loud that it withheld a secret, rather than leaving a blank' -Skip:(-not $Logs) {
            # VISIBLE, NEVER SILENT: a reader has to be able to tell a value
            # withheld on purpose from one that was never set. The LENGTH stays,
            # because a password of the wrong length is a different fault from
            # no password at all.
            $script:registry.SetValue($script:key, 'DefaultPassword', $script:marker, 'String')

            (& $script:logText) | Should -BeLike ('*<redacted, {0} character(s)>*' -f $script:marker.Length)
        }

        It 'still names the value, its key and its type when it withholds one' -Skip:(-not $Logs) {
            $script:registry.SetValue($script:key, 'DefaultPassword', $script:marker, 'String')

            $text = & $script:logText
            $text | Should -BeLike '*DefaultPassword*'
            $text | Should -BeLike ('*{0}*' -f $script:key)
            $text | Should -BeLike '*String*'
        }
    }
}
