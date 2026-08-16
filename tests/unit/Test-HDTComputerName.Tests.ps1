# THE COMPUTER NAME RULE, IN ONE PLACE.
#
# It already existed, inline in Invoke-HDTApplyUnattendStep, where it was put
# after a real deployment produced a machine called WIN-N91191NN153: rules.yaml
# built the name from a Hyper-V serial, the result was 35 characters, and
# WINDOWS SETUP DISCARDED IT WITHOUT COMPLAINT while every step reported
# Completed (SPIKES S9.11).
#
# The wizard now asks a technician for the same value, so the rule needs a
# second caller - and a rule with two callers and one copy each is a rule that
# drifts. Extracted here, with the step and the wizard both calling it.
#
# TWO RULES, AND THE DIFFERENCE BETWEEN THEM IS THE POINT:
#
#   NetBIOS REFUSES ten characters and only ten - . \ / : * ? " < > | - and
#   this command refuses exactly those. That is the documented rule, and a
#   wizard that refused more without saying why is a wizard arguing with
#   Microsoft's own documentation in front of a technician who has read it.
#
#   DNS is stricter, and a name may be a perfectly legal NetBIOS name that DNS
#   cannot carry. An underscore is the everyday case: HDT_01 is a valid
#   computer name that misbehaves on domain join and DNS registration. So it
#   is ACCEPTED AND FLAGGED rather than refused - a warning states a real
#   consequence, and a refusal would state a rule that does not exist.
#
# THIS REPLACED A STRICTER RULE, deliberately and with DESIGN 4.5 updated to
# match. The old one refused anything but letters, digits and hyphens, which
# conflated the two rules above and refused legal names.
#
# IT DOES NOT TRUNCATE AND MUST NEVER LEARN TO. A silently shortened name is
# the same failure with a different spelling.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Test-HDTComputerName' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Test-HDTComputerName' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'what it accepts' {

        It 'accepts <_>' -ForEach @('HDT-01', 'PC1', 'A', 'WIN11CLIENT', 'a-b-c', '0123456789ABCDE', 'HDT-LAB-001') {
            [bool] (Test-HDTComputerName -Name $PSItem).IsValid | Should -BeTrue
        }

        It 'accepts a name of exactly 15 characters, because 15 is the limit and not the first refusal' {
            $name = 'ABCDEFGHIJKLMNO'
            $name.Length | Should -Be 15

            [bool] (Test-HDTComputerName -Name $name).IsValid | Should -BeTrue
        }

        It 'says nothing when the name is fine' {
            [string] (Test-HDTComputerName -Name 'HDT-01').Reason | Should -BeNullOrEmpty
            [string] (Test-HDTComputerName -Name 'HDT-01').Severity | Should -BeExactly 'None'
        }

        It 'reports a clean name as DNS safe' {
            [bool] (Test-HDTComputerName -Name 'HDT-01').IsDnsSafe | Should -BeTrue
        }
    }

    Context 'a legal name that DNS will not carry' {

        # THE CASE THE OLD RULE GOT WRONG. HDT_01 is a valid NetBIOS name -
        # underscore is not one of the ten - and the previous rule refused it,
        # telling a technician who had read Microsoft's list something that
        # contradicted it. It is accepted now, and flagged, because the
        # consequence is real and specific: DNS labels cannot carry an
        # underscore, so domain join and DNS registration misbehave.

        It 'accepts <_>' -ForEach @('HDT_01', 'HDT#01', 'HDT$01', 'HDT&01', 'HDT(01)', 'HDT{01}', 'HDT!01', 'HDT@01', 'HDT+01', 'HDT,01') {
            [bool] (Test-HDTComputerName -Name $PSItem).IsValid | Should -BeTrue
        }

        It 'flags <_> as not DNS safe' -ForEach @('HDT_01', 'HDT#01', 'HDT!01', 'HDT@01') {
            $result = Test-HDTComputerName -Name $PSItem

            [bool] $result.IsDnsSafe | Should -BeFalse
            [string] $result.Severity | Should -BeExactly 'Warning'
        }

        It 'says what the consequence is, not merely that it disapproves' {
            [string] (Test-HDTComputerName -Name 'HDT_01').Reason | Should -BeLike '*DNS*'
        }

        It 'still refuses it when it is also too long, because a refusal outranks a warning' {
            $result = Test-HDTComputerName -Name 'HDT_0123456789012345'

            [bool] $result.IsValid | Should -BeFalse
            [string] $result.Severity | Should -BeExactly 'Error'
        }
    }

    Context 'what it refuses' {

        It 'refuses 16 characters' {
            $result = Test-HDTComputerName -Name 'ABCDEFGHIJKLMNOP'

            [bool] $result.IsValid | Should -BeFalse
            [string] $result.Reason | Should -BeLike '*15*'
        }

        It 'refuses the 35-character name a real deployment produced' {
            # SPIKES S9.11, and the reason this rule exists at all.
            $result = Test-HDTComputerName -Name 'PC-4C4C4544-0031-3610-8052-B7C04F5'

            [bool] $result.IsValid | Should -BeFalse
        }

        It 'names the length it was given, so the message is actionable' {
            [string] (Test-HDTComputerName -Name 'ABCDEFGHIJKLMNOP').Reason | Should -BeLike '*16*'
        }

        It 'refuses <_>, which NetBIOS does not allow' -ForEach @(
            'HDT.01', 'HDT\01', 'HDT/01', 'HDT:01', 'HDT*01', 'HDT?01', 'HDT"01', 'HDT<01', 'HDT>01', 'HDT|01') {

            # THE TEN, AND ONLY THE TEN. Microsoft's list, and a technician who
            # has read it must not be told something else by this wizard.
            $result = Test-HDTComputerName -Name $PSItem

            [bool] $result.IsValid | Should -BeFalse
            [string] $result.Severity | Should -BeExactly 'Error'
        }

        It 'names the character it refused, so the message says which one' {
            [string] (Test-HDTComputerName -Name 'HDT|01').Reason | Should -BeLike '*|*'
        }

        It 'refuses a name that is only an illegal character' {
            [bool] (Test-HDTComputerName -Name '.').IsValid | Should -BeFalse
        }

        It 'refuses a space, which is not in the ten but is not a computer name either' {
            [bool] (Test-HDTComputerName -Name 'HDT 01').IsValid | Should -BeFalse
        }

        It 'refuses an empty name' {
            # A technician looking at an empty box has not answered the
            # question, and the page must not let them past it.
            [bool] (Test-HDTComputerName -Name '').IsValid | Should -BeFalse
        }

        It 'refuses a name that is only whitespace' {
            [bool] (Test-HDTComputerName -Name '   ').IsValid | Should -BeFalse
        }

        It 'refuses a name that is too long AND illegal, reporting the length first' {
            # Both are wrong; one message at a time is what a technician can act
            # on, and the length is the one they can see for themselves.
            [string] (Test-HDTComputerName -Name 'THIS_NAME_IS_MUCH_TOO_LONG').Reason | Should -BeLike '*15*'
        }
    }

    Context 'what it never does' {

        It 'returns the name it was given, untouched' {
            # IT DOES NOT TRUNCATE. A silently shortened name is the same
            # failure as the one this rule exists to stop, with a different
            # spelling - so nothing here may ever return a repaired name.
            [string] (Test-HDTComputerName -Name 'ABCDEFGHIJKLMNOP').Name | Should -BeExactly 'ABCDEFGHIJKLMNOP'
        }
    }
}
