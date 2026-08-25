# WHETHER A BOX IS AN ANSWER OR JUST A RULE BEING SHOWN BACK.
#
# THIS IS THE HALF OF SEEDING THAT KEEPS PROVENANCE HONEST. Get-HDTWizardSeed
# puts what the rules resolved into the boxes, which is what MDT does and what
# HDT did not. But every value the wizard collects re-enters the engine as the
# Wizard SOURCE - the highest precedence in DESIGN 3.1 - so a seeded box nobody
# touched would be collected as though a technician had typed it. The deployment
# would be right and the report would say a name was TYPED AT THE BENCH when a
# rule on the share produced it.
#
# So the harvest asks this first, and a value that came back exactly as it went
# in is not collected at all. The rule stands and keeps its own provenance.
# Change the box and the answer is yours, recorded as Wizard, which is then true.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Test-HDTWizardAnswerChanged' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Test-HDTWizardAnswerChanged' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'says a value identical to the seed is not an answer' {
        Test-HDTWizardAnswerChanged -Seeded 'WORKGROUP' -Answered 'WORKGROUP' | Should -BeFalse
    }

    It 'says an edited value is an answer' {
        Test-HDTWizardAnswerChanged -Seeded 'WORKGROUP' -Answered 'LAB' | Should -BeTrue
    }

    It 'says a box that was never seeded is an answer' {
        # A NULL SEED IS "NOBODY PUT ANYTHING HERE", which is every box the
        # rules could not fill. Whatever is in it now came from the technician.
        Test-HDTWizardAnswerChanged -Seeded $null -Answered 'LAB' | Should -BeTrue
    }

    It 'says a box that was never seeded and is still empty is not an answer' {
        # An empty box is not a decision to set a variable to nothing. The
        # engine's own resolution already covers "nobody said".
        Test-HDTWizardAnswerChanged -Seeded $null -Answered '' | Should -BeFalse
    }

    It 'says CLEARING a seeded box IS an answer' {
        # AND THIS ONE IS THE OPPOSITE OF THE LINE ABOVE, deliberately. A rule
        # supplied a workgroup and the technician deleted it: that is a decision
        # about this machine, and swallowing it would put the rule's value
        # straight back and make the box a lie.
        Test-HDTWizardAnswerChanged -Seeded 'WORKGROUP' -Answered '' | Should -BeTrue
    }

    It 'ignores whitespace either side, because a stray space is not a decision' {
        Test-HDTWizardAnswerChanged -Seeded 'WORKGROUP' -Answered '  WORKGROUP  ' | Should -BeFalse
    }

    It 'treats a change of case as a real edit' {
        # A technician who retyped WORKGROUP as Workgroup meant to, and the
        # variable engine is case-insensitive about NAMES, not about VALUES -
        # a computer name's case is what the machine ends up carrying.
        Test-HDTWizardAnswerChanged -Seeded 'WORKGROUP' -Answered 'Workgroup' | Should -BeTrue
    }
}
