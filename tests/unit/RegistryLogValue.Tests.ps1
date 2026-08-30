# What a registry write is allowed to say about itself in the log.
#
# THE DEFECT. New-HDTRegistryService logged the name, the type and the LENGTH of
# every value it wrote and never the value:
#
#   registry value 'Make' under 'HKLM:\SOFTWARE\Hephaestus\Deployment' was
#   written as String (9 character(s)), which is a new value
#
# The reason was sound - any caller may put a secret through SetValue, and
# DESIGN 4.5.2 guarantees the deployment password reaches no log, which must not
# depend on every future caller remembering. The TRADE was wrong: it made every
# registry write in the engine unreadable to protect one value, and
# "Make = Dell Inc." has no secret in it.
#
# SO THE SILENCE BECAME AN ENFORCED GUARANTEE. Test-HDTSecretRegistryValue says
# which value names are secret - an explicit deny-list of the names Winlogon and
# the autologon path use, unioned with Test-HDTSecretVariable so a
# variable-shaped name a site invents is caught too - and
# Format-HDTRegistryLogValue is what the adapter writes. The adapter itself gets
# no branch: it calls one helper and writes what comes back, which is what keeps
# this testable here rather than only against a real registry.
#
# REDACTION IS VISIBLE, NEVER SILENT. A value that was withheld reads
# "<redacted, 12 character(s)>", so nobody has to wonder whether the value was
# empty, absent or deliberately not shown - the three things a blank could mean.
#
# NO REALISTIC PASSWORD IN THIS FILE, for the reason SecretVariable.Tests.ps1
# gives: a fixture that looks like a credential is a credential as far as the
# next person grepping this repository is concerned.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:module = Get-Module -Name 'Hephaestus'

    # Both are private, reached through the module's own scope rather than
    # exported for the tests' convenience.
    $script:isSecret = {
        param([string] $Name)

        return & $script:module { param($N) Test-HDTSecretRegistryValue -Name $N } $Name
    }

    $script:describe = {
        param([string] $Name, [object] $Value, [bool] $Sensitive)

        return & $script:module {
            param($N, $V, $S)

            Format-HDTRegistryLogValue -Name $N -Value $V -Sensitive:$S
        } $Name $Value $Sensitive
    }
}

Describe 'Test-HDTSecretRegistryValue' {

    Context 'the deny-list, which is the part that does not depend on a pattern' {

        It 'says <_> is a secret' -ForEach @(
            'DefaultPassword', 'defaultpassword', 'DefaultPasswordEncrypted') {

            & $script:isSecret $PSItem | Should -BeTrue
        }

        It 'covers the value name Winlogon reads the autologon password from' {
            # DESIGN 4.5.2 stores it as an LSA secret and RemoveValue clears the
            # registry one unconditionally - but the deny-list does not depend
            # on that staying true, because it is the one value whose disclosure
            # is a privilege escalation on the machine it administers.
            & $script:isSecret 'DefaultPassword' | Should -BeTrue
        }
    }

    Context 'the pattern, which catches the name nobody declared' {

        It 'says <_> is a secret' -ForEach @(
            'HDTAdminPassword', 'ProductKey', 'ApiKey', 'VpnCredential', 'UnlockPin', 'AccessToken') {

            & $script:isSecret $PSItem | Should -BeTrue
        }
    }

    Context 'and it is not allowed to redact the log into uselessness' {

        It 'says <_> is not a secret' -ForEach @(
            'Make', 'Model', 'SerialNumber', 'AutoAdminLogon', 'DefaultUserName',
            'DefaultDomainName', 'AutoLogonCount', 'HDTResume', 'DeployRoot', 'ProductName') {

            & $script:isSecret $PSItem | Should -BeFalse
        }

        It 'says an empty name is not a secret, rather than redacting everything' {
            & $script:isSecret '' | Should -BeFalse
        }
    }
}

Describe 'Format-HDTRegistryLogValue' {

    Context 'an ordinary value, which is every value the old adapter hid' {

        It 'shows the value' {
            $shown = & $script:describe 'Make' 'Dell Inc.' $false

            [string] $shown.Display | Should -BeExactly "'Dell Inc.'"
            [bool] $shown.Redacted | Should -BeFalse
            [bool] $shown.Truncated | Should -BeFalse
            [int] $shown.Length | Should -Be 9
        }

        It 'shows a number as what it is' {
            $shown = & $script:describe 'AutoLogonCount' 3 $false

            [string] $shown.Display | Should -BeExactly "'3'"
            [int] $shown.Length | Should -Be 1
        }

        It 'says a value is empty rather than showing two quotes and leaving it at that' {
            # An empty value and a withheld one read identically once written
            # and mean opposite things, which is the distinction
            # Protect-HDTSecretValue already draws for variables.
            $shown = & $script:describe 'DefaultDomainName' '' $false

            [string] $shown.Display | Should -BeExactly '<empty>'
            [bool] $shown.Redacted | Should -BeFalse
            [int] $shown.Length | Should -Be 0
        }

        It 'says a null value is absent rather than empty' {
            $shown = & $script:describe 'Whatever' $null $false

            [string] $shown.Display | Should -BeExactly '<null>'
            [bool] $shown.Redacted | Should -BeFalse
        }
    }

    Context 'a value whose name says it is a secret' {

        It 'withholds it' {
            $shown = & $script:describe 'DefaultPassword' 'MARKER-01-abcdef' $false

            [string] $shown.Display | Should -Not -BeLike '*MARKER*'
            [bool] $shown.Redacted | Should -BeTrue
        }

        It 'says out loud that it withheld it, and how much there was' {
            # VISIBLE, NEVER SILENT. A reader has to be able to tell a value
            # that was withheld from one that was never set.
            $shown = & $script:describe 'DefaultPassword' 'MARKER-01-abcdef' $false

            [string] $shown.Display | Should -BeExactly '<redacted, 16 character(s)>'
        }

        It 'withholds nothing when there was nothing to withhold' {
            $shown = & $script:describe 'DefaultPassword' '' $false

            [string] $shown.Display | Should -BeExactly '<empty>'
            [bool] $shown.Redacted | Should -BeFalse
        }
    }

    Context 'a value the caller marked, whatever it is called' {

        It 'withholds it on the caller word alone' {
            # THE NAME IS NOT ALWAYS ENOUGH. A caller writing a secret under a
            # name no pattern would catch says so, and does not have to argue
            # with the classifier about it.
            $shown = & $script:describe 'Blob' 'MARKER-02-abcdef' $true

            [string] $shown.Display | Should -BeExactly '<redacted, 16 character(s)>'
            [bool] $shown.Redacted | Should -BeTrue
        }
    }

    Context 'the whole phrase the adapter prints' {

        # SENTENCE EXISTS SO THE ADAPTER HAS NO BRANCH. The length belongs
        # beside an ordinary value and is already inside a redaction, so an
        # adapter that appended it unconditionally wrote
        # "<redacted, 19 character(s)> (19 character(s))" - which is what the
        # first cut of this change actually logged.

        It 'puts the length beside an ordinary value' {
            [string] (& $script:describe 'Make' 'Dell Inc.' $false).Sentence |
                Should -BeExactly "'Dell Inc.' (9 character(s))"
        }

        It 'does not say the length twice about a redaction' {
            [string] (& $script:describe 'DefaultPassword' 'MARKER-01-abcdef' $false).Sentence |
                Should -BeExactly '<redacted, 16 character(s)>'
        }

        It 'says nothing about the length of a value there was none of' {
            [string] (& $script:describe 'DefaultDomainName' '' $false).Sentence | Should -BeExactly '<empty>'
            [string] (& $script:describe 'Whatever' $null $false).Sentence | Should -BeExactly '<null>'
        }

        It 'lets a truncated value keep its own count' {
            [string] (& $script:describe 'Blob' ('x' * 3000) $false).Sentence |
                Should -BeLike '*<truncated, 3000 character(s) in all>'
        }
    }

    Context 'a value too long to put in a log line' {

        It 'truncates it and says how much there was in all' {
            # GENEROUSLY, per the logging rule - a value is shown in full until
            # it would swamp the record around it. A REG_BINARY or a
            # multi-kilobyte string is the case; a command line is not.
            $long = 'x' * 3000
            $shown = & $script:describe 'Blob' $long $false

            [bool] $shown.Truncated | Should -BeTrue
            [int] $shown.Length | Should -Be 3000
            [string] $shown.Display | Should -BeLike '*<truncated, 3000 character(s) in all>'
            ([string] $shown.Display).Length | Should -BeLessThan 700
        }

        It 'leaves a value that fits entirely alone' {
            $shown = & $script:describe 'Blob' ('x' * 512) $false

            [bool] $shown.Truncated | Should -BeFalse
            [string] $shown.Display | Should -BeExactly ("'{0}'" -f ('x' * 512))
        }

        It 'redacts before it truncates, so a long secret is never half-shown' {
            $shown = & $script:describe 'DefaultPassword' ('MARKER-03-' + ('x' * 3000)) $false

            [string] $shown.Display | Should -Not -BeLike '*MARKER*'
            [string] $shown.Display | Should -Not -BeLike '*xxxx*'
            [bool] $shown.Redacted | Should -BeTrue
        }
    }
}
