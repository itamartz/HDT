# What a double-click on a tree row opens, if anything.
#
# TWO KINDS OF ROW OPEN, AND THE ROW SAYS WHICH IT IS. A task sequence opens the
# editor; the boot image opens the Windows PE window, which is Deployment
# Workbench's deployment share Properties. The routing is on the Kind the node
# already carries - Get-HDTConsoleTreeNode made that decision once, and a
# handler working it out again from the row's shape would be a second opinion
# that can drift from the first.
#
# CanOpen IS NOT AN INVITATION TO OPEN THE EDITOR. It says the row carries a
# subject, and an operating system now carries one so the details pane can write
# its document - which is not the same as having a second window to show. An
# OS's properties ARE the details pane. Opening a sequence editor on an os.yaml
# would put the step tree of a document that has no steps on screen.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {

    function New-HDTTestOpenRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true)] [string] $Kind,
            [Parameter()] [bool] $CanOpen = $true,
            [Parameter()] [object] $Subject = 'a-subject'
        )

        return [pscustomobject] @{ Kind = $Kind; CanOpen = $CanOpen; Subject = $Subject }
    }
}

Describe 'Get-HDTConsoleOpenAction' {

    Context 'a task sequence' {

        It 'opens the sequence editor' {
            (Get-HDTConsoleOpenAction -Row (New-HDTTestOpenRow -Kind 'TaskSequence')).Open |
                Should -BeExactly 'SequenceEditor'
        }

        It 'hands over the subject the editor opens' {
            (Get-HDTConsoleOpenAction -Row (New-HDTTestOpenRow -Kind 'TaskSequence' -Subject 'DEMO-05')).Subject |
                Should -BeExactly 'DEMO-05'
        }
    }

    Context 'the boot image' {

        It 'opens the Windows PE window instead' {
            (Get-HDTConsoleOpenAction -Row (New-HDTTestOpenRow -Kind 'BootImage')).Open |
                Should -BeExactly 'BootImage'
        }
    }

    # THE ONE CanOpen DOES NOT MEAN.
    Context 'an operating system, which carries a subject but has no window' {

        It 'opens nothing' {
            # Its properties ARE the details pane; there is no second window.
            (Get-HDTConsoleOpenAction -Row (New-HDTTestOpenRow -Kind 'OperatingSystem')).Open |
                Should -BeExactly 'None'
        }
    }

    Context 'an application, which also carries a subject' {

        It 'opens nothing' {
            (Get-HDTConsoleOpenAction -Row (New-HDTTestOpenRow -Kind 'Application')).Open |
                Should -BeExactly 'None'
        }
    }

    Context 'a row that cannot be opened at all' {

        It 'opens nothing even when its kind would' {
            $answer = Get-HDTConsoleOpenAction -Row (New-HDTTestOpenRow -Kind 'TaskSequence' -CanOpen $false)

            $answer.Open | Should -BeExactly 'None'
        }

        It 'opens nothing for a folder' {
            (Get-HDTConsoleOpenAction -Row (New-HDTTestOpenRow -Kind 'Folder' -CanOpen $false)).Open |
                Should -BeExactly 'None'
        }
    }

    Context 'no row at all' {

        It 'opens nothing rather than failing' {
            (Get-HDTConsoleOpenAction -Row $null).Open | Should -BeExactly 'None'
        }
    }

    # A ROW BUILT SOMEWHERE OTHER THAN Get-HDTConsoleTreeNode may carry no
    # CanOpen at all, and reading one that is not there is a terminating error
    # on the dispatcher.
    Context 'a row with no CanOpen property' {

        It 'opens nothing rather than throwing' {
            $row = [pscustomobject] @{ Kind = 'MonitorRun'; Name = 'run-0007' }

            (Get-HDTConsoleOpenAction -Row $row).Open | Should -BeExactly 'None'
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTConsoleOpenAction -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTConsoleOpenAction'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
