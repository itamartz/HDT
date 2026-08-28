# One argument, rendered for the console log, with secrets removed.
#
# THIS IS THE FILE THAT MAKES THE REDACTION PROVABLE. The logic lived in a
# closure inside Get-HDTHandlerCall, where the only way to exercise a -Password
# was to invoke a real command that has one - and the tests written that way
# failed with "a parameter cannot be found that matches parameter name
# 'Password'". They looked like redaction coverage and demonstrated nothing.
#
# WHY IT MATTERS MORE THAN IT LOOKS. The console log lives on the SHARE, which
# every machine being deployed can read, and the console is where
# HDTAdminPassword is set (DESIGN 4.5.2). A value written verbatim here is the
# local administrator password in a file the whole fleet can open. That is the
# one secret this application handles.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # A SUPPRESSION NEEDS A FUNCTION TO SIT ON. ConvertTo-SecureString with a
    # literal is the only way to build a SecureString from a known test
    # constant, and the analyzer flags every call - but the attribute has no
    # effect above an It block or on a scriptblock's param, only in a real
    # function's param block (PSScriptAnalyzerSettings.psd1 records the same
    # four placements). Get-HDTWizardCredential.Tests.ps1 does exactly this.
    #
    # THE CONSTANT IS A FIXTURE, NOT A CREDENTIAL. It authenticates to nothing,
    # and it exists to be the value the redaction assertions below search for.
    function New-HDTTestSecret {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory SecureString; it changes no state.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
            Justification = 'The only way to build a SecureString from a known test constant; it authenticates to nothing.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Text',
            Justification = 'A test fixture constant, not a credential.')]
        [CmdletBinding()]
        [OutputType([System.Security.SecureString])]
        param(
            [Parameter()]
            [AllowEmptyString()]
            [string] $Text = 'unlikely-secret-value'
        )

        return (ConvertTo-SecureString -String $Text -AsPlainText -Force)
    }

    $script:show = {
        param([string] $Name, [object] $Value)

        $module = Get-Module -Name Hephaestus
        return & $module { param($N, $V) Format-HDTConsoleLogValue -Name $N -Value $V } $Name $Value
    }
}

Describe 'Format-HDTConsoleLogValue' {

    Context 'what it keeps' {

        It 'quotes an ordinary value so a path with spaces reads as one thing' {
            & $script:show 'Root' 'C:\HDTLab\Share' | Should -BeExactly "'C:\HDTLab\Share'"
        }

        It 'renders a switch as the flag alone' {
            & $script:show 'PerDriver' $true | Should -BeExactly '$true'
        }

        It 'says null rather than nothing, which reads as a missing argument' {
            & $script:show 'Root' $null | Should -BeExactly '$null'
        }

        It 'names a collection by its size rather than spelling it out' {
            & $script:show 'Path' @('a', 'b', 'c') | Should -BeExactly '@(3 item(s))'
        }

        It 'names a hashtable by its keys, which is what identifies the call' {
            (& $script:show 'Argument' @{ Root = 'x'; Path = 'y' }) | Should -Match 'Root'
        }

        It 'does not mistake a string for a collection of characters' {
            # A string IS IEnumerable, so the type check has to come first or
            # every path in the log renders as '@(1 item(s))'.
            & $script:show 'Root' 'abc' | Should -BeExactly "'abc'"
        }

        It 'truncates a value too long to belong on one line' {
            $long = 'x' * 400

            $answer = & $script:show 'Root' $long

            $answer.Length | Should -BeLessThan 130
            $answer | Should -Match ([regex]::Escape('...'))
        }
    }

    Context 'what it refuses to write down' {

        It 'redacts by parameter name, for every name a secret goes by' -ForEach @(
            @{ Name = 'Password' }
            @{ Name = 'AdminPassword' }
            @{ Name = 'HDTAdminPassword' }
            @{ Name = 'Pwd' }
            @{ Name = 'Secret' }
            @{ Name = 'Credential' }
            @{ Name = 'Token' }
            @{ Name = 'Key' }
            @{ Name = 'Passphrase' }
        ) {
            & $script:show $Name 'hunter2-must-never-appear' | Should -BeExactly '<redacted>'
        }

        It 'redacts a SecureString under a name nobody thought of' {
            # THE ONE THE NAME LIST CANNOT CATCH. A list only holds words
            # somebody remembered; the type check is what covers the rest.
            $secure = New-HDTTestSecret

            & $script:show 'Thing' $secure | Should -BeExactly '<redacted>'
        }

        It 'redacts a PSCredential under a name nobody thought of' {
            $secure = New-HDTTestSecret
            $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList 'lab\admin', $secure

            & $script:show 'Account' $credential | Should -BeExactly '<redacted>'
        }

        It 'never lets the value itself appear, whatever it is' {
            $answer = & $script:show 'AdminPassword' 'hunter2-must-never-appear'

            $answer | Should -Not -Match 'hunter2'
        }

        It 'redacts whatever the casing of the name' {
            & $script:show 'adminPASSWORD' 'hunter2-must-never-appear' | Should -BeExactly '<redacted>'
        }
    }
}
