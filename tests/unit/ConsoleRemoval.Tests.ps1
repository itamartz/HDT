# What a technician reads before something is deleted from a share, for all
# three things this window deletes.
#
# THREE HANDLERS MADE THIS DECISION SEPARATELY, and they are the three
# irreversible presses in the console: a task sequence, an operating system and
# an application. Each composed its own question, its own refusal and its own
# command line, which is three chances to get a destructive dialog wrong and no
# test on any of them. One instance being right was never the set being right.
#
# THE CONSEQUENCES BELONG IN THE QUESTION, NOT AFTER IT. Remove-* -WhatIf
# already knows which task sequences use the thing being removed; asking "are
# you sure?" without saying so asks somebody to confirm what they have not been
# told, at the last point where they could still stop.
#
# AND THE THREE CONSEQUENCES ARE NOT THE SAME SENTENCE. A sequence that INSTALLS
# a missing application still deploys - the machine just arrives without it. A
# sequence that APPLIES a missing operating system fails outright. An
# application that DEPENDS on a missing one will not install at all. Wording
# them alike would flatten a failure into an inconvenience.
#
# THE PARAMETER NAME IS NOT THE SAME EITHER: Remove-HDTTaskSequence and
# Remove-HDTOperatingSystem take -Workspace, and Remove-HDTApplication takes
# -WorkspaceRoot. The echoed line has to be one somebody can actually retype.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

Describe 'Get-HDTConsoleRemoval' {

    Context 'a task sequence' {

        BeforeAll {
            $script:sequence = Get-HDTConsoleRemoval -Kind 'TaskSequence' -Root 'C:\HDTLab\Share' -Id 'DEMO-05'
        }

        It 'can be removed' {
            $script:sequence.CanRemove | Should -BeTrue
        }

        It 'titles the dialog for what is being removed' {
            $script:sequence.Title | Should -BeExactly 'Remove Task Sequence'
        }

        It 'names the thing and the share it is leaving' {
            $script:sequence.Question | Should -Match "task sequence 'DEMO-05'"
            $script:sequence.Question | Should -Match 'C:\\HDTLab\\Share'
        }

        It 'says what goes with it and that there is no undo' {
            $script:sequence.Question | Should -Match 'its answer file'
            $script:sequence.Question | Should -Match 'cannot be undone'
        }

        It 'echoes the command with -Workspace, which is what it takes' {
            $script:sequence.Command |
                Should -BeExactly "Remove-HDTTaskSequence -Workspace 'C:\HDTLab\Share' -Id 'DEMO-05'"
        }
    }

    Context 'an operating system nothing applies' {

        BeforeAll {
            $script:os = Get-HDTConsoleRemoval -Kind 'OperatingSystem' -Root 'C:\ws' -Id 'Win11-LTSC-2024'
        }

        It 'says what goes with it' {
            $script:os.Question | Should -Match 'os\.yaml'
            $script:os.Question | Should -Match 'media was imported'
        }

        It 'echoes -Workspace, not -WorkspaceRoot' {
            $script:os.Command |
                Should -BeExactly "Remove-HDTOperatingSystem -Workspace 'C:\ws' -Id 'Win11-LTSC-2024'"
        }

        It 'warns about nothing when nothing applies it' {
            $script:os.Warning | Should -BeExactly ''
        }
    }

    # A SEQUENCE WITHOUT ITS OPERATING SYSTEM FAILS OUTRIGHT.
    Context 'an operating system some task sequences apply' {

        It 'says they will fail without it' {
            $answer = Get-HDTConsoleRemoval -Kind 'OperatingSystem' -Root 'C:\ws' -Id 'Win11' `
                -UsedBy @('DEMO-05', 'DEMO-06')

            $answer.Warning | Should -Match 'These task sequences apply it and will fail without it: DEMO-05, DEMO-06\.'
        }
    }

    Context 'an application' {

        BeforeAll {
            $script:app = Get-HDTConsoleRemoval -Kind 'Application' -Root 'C:\ws' -Id 'Acrobat'
        }

        It 'says what goes with it' {
            $script:app.Question | Should -Match 'app\.yaml'
            $script:app.Question | Should -Match 'installer copied beside it'
        }

        It 'echoes -WorkspaceRoot, which is the one this command takes' {
            $script:app.Command |
                Should -BeExactly "Remove-HDTApplication -WorkspaceRoot 'C:\ws' -Id 'Acrobat'"
        }
    }

    # A MACHINE ARRIVES WITHOUT IT - it does not fail.
    Context 'an application some task sequences install' {

        It 'says they install it, not that they will fail' {
            $answer = Get-HDTConsoleRemoval -Kind 'Application' -Root 'C:\ws' -Id 'Acrobat' -UsedBy @('DEMO-05')

            $answer.Warning | Should -Match 'These task sequences install it: DEMO-05\.'
            $answer.Warning | Should -Not -Match 'will fail'
        }
    }

    # THE ONE THAT BREAKS SILENTLY LATER.
    Context 'an application other applications depend on' {

        BeforeAll {
            $script:needed = Get-HDTConsoleRemoval -Kind 'Application' -Root 'C:\ws' -Id 'VCRedist' `
                -UsedBy @('DEMO-05') -RequiredBy @('TightVNC')
        }

        It 'says they will not install without it' {
            $script:needed.Warning |
                Should -Match 'These applications depend on it and will not install without it: TightVNC\.'
        }

        It 'keeps both consequences rather than only the first' {
            $script:needed.Warning | Should -Match 'DEMO-05'
            $script:needed.Warning | Should -Match 'TightVNC'
        }
    }

    # ONLY AN APPLICATION HAS DEPENDENTS.
    Context 'a dependency list on something that cannot have one' {

        It 'is ignored for a task sequence' {
            $answer = Get-HDTConsoleRemoval -Kind 'TaskSequence' -Root 'C:\ws' -Id 'DEMO-05' `
                -RequiredBy @('nonsense')

            $answer.Warning | Should -Not -Match 'nonsense'
        }
    }

    # AND IT SAYS SO RATHER THAN DOING NOTHING. A handler that returns quietly on
    # a row it cannot read is a menu item somebody presses twice and then reports
    # as broken.
    Context 'a row that does not name what to remove' {

        It 'refuses a row with no id' {
            (Get-HDTConsoleRemoval -Kind 'TaskSequence' -Root 'C:\ws' -Id '').CanRemove | Should -BeFalse
        }

        It 'refuses a row with no share' {
            (Get-HDTConsoleRemoval -Kind 'Application' -Root '' -Id 'Acrobat').CanRemove | Should -BeFalse
        }

        It 'names what the row was missing, per kind' {
            (Get-HDTConsoleRemoval -Kind 'TaskSequence' -Root '' -Id '').Refusal |
                Should -BeExactly 'that row does not name a share and a task sequence id, so there is nothing to remove.'

            (Get-HDTConsoleRemoval -Kind 'OperatingSystem' -Root '' -Id '').Refusal |
                Should -BeExactly 'that row does not name a share and an operating system id, so there is nothing to remove.'

            (Get-HDTConsoleRemoval -Kind 'Application' -Root '' -Id '').Refusal |
                Should -BeExactly 'that row does not name a share and an application id, so there is nothing to remove.'
        }

        It 'offers no command to run' {
            (Get-HDTConsoleRemoval -Kind 'Application' -Root '' -Id '').Command | Should -BeExactly ''
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTConsoleRemoval -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTConsoleRemoval'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
