# Editing a field on the details pane: which document it writes, with which pair
# of commands.
#
# WHICH DOCUMENT A ROW EDITS IS THE ROW'S KIND, and the pair of commands follows
# from it. A task sequence and an imported operating system have the same flat
# header and two different validators, so the wrong pair writes a file the other
# one then refuses to read. Save-HDTWorkspaceDocument checks the lines against
# workspace.yaml's keys and refuses a sequence for declaring 'description'.
#
# A SHARE POINTS AT ITS workspace.yaml UNDER ANOTHER NAME. A workspace
# projection carries the root it was opened from as well as the document, so it
# has WorkspacePath and NO Path at all - and under Set-StrictMode reading a
# property that is not there is a terminating error, on the dispatcher, which
# takes the window down. That is not hypothetical: it survived in the handler
# because a click arrives with no strict mode on the stack, and only showed up
# when a probe that sets strict mode drove the same control.
#
# THE REBUILD IS THE EXPENSIVE HALF - it re-reads every open share and
# revalidates every sequence in it. The tree row reads 'id - name', so it is only
# stale when the NAME changed; paying that cost for a description edit buys
# nothing.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {

    function New-HDTTestDetailRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true)] [string] $Kind,
            [Parameter()] [string] $Name = 'DEMO-05',
            [Parameter()] [string] $HeaderRoot = 'C:\HDTLab\Share',
            [Parameter()] [string] $Path = 'C:\HDTLab\Share\Control\DEMO-05\sequence.yaml',
            [Parameter()] [string] $WorkspacePath = ''
        )

        # A SHARE'S PROJECTION CARRIES NO Path. Giving the double one would hide
        # exactly the defect this command exists to prevent.
        $subject = if ($Kind -eq 'Share') {
            [pscustomobject] @{ WorkspacePath = $WorkspacePath }
        } else {
            [pscustomobject] @{ Path = $Path }
        }

        return [pscustomobject] @{ Kind = $Kind; Name = $Name; HeaderRoot = $HeaderRoot; Subject = $subject }
    }
}

Describe 'Get-HDTConsoleRowDocument' {

    Context 'a task sequence row' {

        BeforeAll {
            $script:sequence = Get-HDTConsoleRowDocument -Row (New-HDTTestDetailRow -Kind 'TaskSequence') -Property 'name'
        }

        It 'is a row this pane edits' {
            $script:sequence.Supported | Should -BeTrue
        }

        It 'pairs the sequence setter with the sequence saver' {
            $script:sequence.Setter | Should -BeExactly 'Set-HDTTaskSequenceProperty'
            $script:sequence.Saver | Should -BeExactly 'Save-HDTSequenceDocument'
        }

        It 'edits the document the row points at' {
            $script:sequence.DocumentPath | Should -BeExactly 'C:\HDTLab\Share\Control\DEMO-05\sequence.yaml'
        }
    }

    Context 'an operating system row' {

        It 'pairs the operating system setter with its own saver' {
            # Not Save-HDTSequenceDocument: same flat header, different validator.
            $answer = Get-HDTConsoleRowDocument -Property 'description' `
                -Row (New-HDTTestDetailRow -Kind 'OperatingSystem' -Path 'C:\ws\Control\Win11\os.yaml')

            $answer.Setter | Should -BeExactly 'Set-HDTOperatingSystemProperty'
            $answer.Saver | Should -BeExactly 'Save-HDTOperatingSystemDocument'
            $answer.DocumentPath | Should -BeExactly 'C:\ws\Control\Win11\os.yaml'
        }
    }

    # THE ONE THAT TOOK THE WINDOW DOWN.
    Context 'a share row, whose projection has no Path at all' {

        BeforeAll {
            $script:share = Get-HDTConsoleRowDocument -Property 'name' `
                -Row (New-HDTTestDetailRow -Kind 'Share' -WorkspacePath 'C:\HDTLab\Share\workspace.yaml')
        }

        It 'reads the workspace path rather than a Path that is not there' {
            $script:share.DocumentPath | Should -BeExactly 'C:\HDTLab\Share\workspace.yaml'
        }

        It 'pairs the workspace setter with the workspace saver' {
            $script:share.Setter | Should -BeExactly 'Set-HDTWorkspaceProperty'
            $script:share.Saver | Should -BeExactly 'Save-HDTWorkspaceDocument'
        }
    }

    # AN APPLICATION WRITES ITSELF: no saver to pair, and a share and an id
    # rather than a document path.
    Context 'an application row' {

        BeforeAll {
            $script:app = Get-HDTConsoleRowDocument -Property 'name' `
                -Row (New-HDTTestDetailRow -Kind 'Application' -Name 'Acrobat')
        }

        It 'is the one that writes itself' {
            $script:app.IsApplication | Should -BeTrue
            $script:app.Saver | Should -BeExactly ''
        }

        It 'carries the share and the id it takes instead of lines' {
            $script:app.WorkspaceRoot | Should -BeExactly 'C:\HDTLab\Share'
            $script:app.Id | Should -BeExactly 'Acrobat'
        }
    }

    # AN IMPORTED UPDATE WRITES ITSELF TOO. Set-HDTWindowsUpdate takes a share
    # and an id, the way Set-HDTApplication does, and there is no
    # Save-HDTWindowsUpdateDocument to pair it with.
    Context 'a Windows update row' {

        BeforeAll {
            $script:update = Get-HDTConsoleRowDocument -Property 'name' `
                -Row (New-HDTTestDetailRow -Kind 'WindowsUpdate' -Name 'KB5094126-x64')
        }

        It 'is a row this pane edits' {
            $script:update.Supported | Should -BeTrue
        }

        It 'names its own setter and no saver' {
            $script:update.Setter | Should -BeExactly 'Set-HDTWindowsUpdate'
            $script:update.Saver | Should -BeExactly ''
        }

        It 'carries the share and the id it takes instead of lines' {
            $script:update.WorkspaceRoot | Should -BeExactly 'C:\HDTLab\Share'
            $script:update.Id | Should -BeExactly 'KB5094126-x64'
        }

        # THE TREE ROW READS 'KB - name', so a rename makes it stale and a
        # description does not.
        It 'rebuilds the tree for a rename and not for a description' {
            $script:update.NeedsRebuild | Should -BeTrue

            (Get-HDTConsoleRowDocument -Property 'description' `
                    -Row (New-HDTTestDetailRow -Kind 'WindowsUpdate' -Name 'KB5094126-x64')).NeedsRebuild |
                Should -BeFalse
        }

        It 'echoes the share, the id and the value it was given' {
            ($script:update.CommandFormat -f '2026-06 cumulative') |
                Should -BeExactly "Set-HDTWindowsUpdate -WorkspaceRoot 'C:\HDTLab\Share' -Id 'KB5094126-x64' -Name '2026-06 cumulative'"
        }
    }

    # THE SET, NOT THE ONE JUST ADDED. Every kind this pane edits writes through
    # EITHER a setter-and-saver pair against a document path, OR a command that
    # takes a share and an id - and a kind wired for neither is a row whose boxes
    # accept typing and drop it. That is the failure this file exists to catch,
    # so it is asserted over every kind rather than over the newest.
    Context 'every kind this pane edits' {

        It 'is wired for one of the two ways of writing, and never for neither' {
            foreach ($kind in @('TaskSequence', 'OperatingSystem', 'Share', 'Application', 'WindowsUpdate')) {
                $answer = Get-HDTConsoleRowDocument -Property 'name' `
                    -Row (New-HDTTestDetailRow -Kind $kind -WorkspacePath 'C:\HDTLab\Share\workspace.yaml')

                $answer.Supported | Should -BeTrue -Because ("{0} is a row the pane draws boxes on" -f $kind)
                $answer.Setter | Should -Not -BeNullOrEmpty -Because ("{0} must name the command that writes it" -f $kind)

                $writesItself = [string]::IsNullOrEmpty([string] $answer.Saver)

                if ($writesItself) {
                    $answer.WorkspaceRoot | Should -Not -BeNullOrEmpty -Because ("{0} writes itself, so it needs a share" -f $kind)
                    $answer.Id | Should -Not -BeNullOrEmpty -Because ("{0} writes itself, so it needs an id" -f $kind)
                } else {
                    $answer.DocumentPath | Should -Not -BeNullOrEmpty -Because ("{0} is read, spliced and saved, so it needs a path" -f $kind)
                }
            }
        }
    }

    Context 'a row this pane does not edit' {

        It 'refuses rather than guessing a document' {
            $answer = Get-HDTConsoleRowDocument -Row (New-HDTTestDetailRow -Kind 'BootImage') -Property 'name'

            $answer.Supported | Should -BeFalse
            $answer.Setter | Should -BeExactly ''
        }

        It 'refuses a monitoring row' {
            (Get-HDTConsoleRowDocument -Row (New-HDTTestDetailRow -Kind 'MonitorRun') -Property 'name').Supported |
                Should -BeFalse
        }
    }

    # THE KEY IS 'name' IN THE DOCUMENT AND THE PARAMETER IS -Name.
    Context 'the parameter the echoed command names' {

        It 'capitalises the document key' {
            (Get-HDTConsoleRowDocument -Row (New-HDTTestDetailRow -Kind 'TaskSequence') -Property 'name').Parameter |
                Should -BeExactly 'Name'
        }

        It 'capitalises only the first letter of a camel-cased key' {
            (Get-HDTConsoleRowDocument -Row (New-HDTTestDetailRow -Kind 'TaskSequence') -Property 'timeoutMinutes').Parameter |
                Should -BeExactly 'TimeoutMinutes'
        }

        It 'echoes the setter, the parameter and the value together' {
            $answer = Get-HDTConsoleRowDocument -Row (New-HDTTestDetailRow -Kind 'TaskSequence') -Property 'description'

            ($answer.CommandFormat -f 'a bare metal client') |
                Should -BeExactly "Set-HDTTaskSequenceProperty -Line `$line -Description 'a bare metal client'"
        }
    }

    # THE REBUILD IS THE EXPENSIVE HALF.
    Context 'whether the tree has to be rebuilt' {

        It 'rebuilds when the name changed, because the row reads id - name' {
            (Get-HDTConsoleRowDocument -Row (New-HDTTestDetailRow -Kind 'TaskSequence') -Property 'name').NeedsRebuild |
                Should -BeTrue
        }

        It 'does not rebuild for a field the tree does not show' {
            (Get-HDTConsoleRowDocument -Row (New-HDTTestDetailRow -Kind 'TaskSequence') -Property 'description').NeedsRebuild |
                Should -BeFalse
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTConsoleRowDocument -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTConsoleRowDocument'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
