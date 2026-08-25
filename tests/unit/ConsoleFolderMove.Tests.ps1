# Moving a row into a folder: which commands that takes, per category.
#
# MOVING IS A ONE-KEY EDIT TO THE DOCUMENT, NOT A FILE OPERATION. A task
# sequence stays at TaskSequences\<id> because its id is the path the engine
# resolves it from, and every rule and boot image naming it would break if the
# folder moved it on disk. The folder is a property; the window draws the tree
# from it.
#
# THE SETTER AND THE SAVER HAVE TO BE A PAIR, and that is the decision worth
# testing. Each saver checks the lines against its own document's keys, so
# Save-HDTSequenceDocument refuses an operating system document that
# Set-HDTOperatingSystemProperty just wrote correctly. Pairing them wrong fails
# AFTER the edit, which reads as "the setter is broken" and is not.
#
# AN APPLICATION WRITES ITSELF, and is the exception that makes this a decision
# rather than a lookup: Set-HDTApplication takes a share root and an id rather
# than lines, and saves. There is nothing to read first and no saver to pair, so
# a caller that treated all three categories alike would hand an application a
# document path it does not have.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {

    function New-HDTTestFolderRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter()] [string] $Name = 'DEMO-05',
            [Parameter()] [string] $HeaderRoot = 'C:\HDTLab\Share',
            [Parameter()] [string] $DocumentPath = 'C:\HDTLab\Share\Control\DEMO-05\sequence.yaml',
            [Parameter()] [switch] $NoFolder,
            [Parameter()] [string] $Folder = 'Clients\Bare metal'
        )

        $row = [pscustomobject] @{
            Name       = $Name
            HeaderRoot = $HeaderRoot
            Subject    = [pscustomobject] @{ Path = $DocumentPath }
        }

        # A row that has never been in a folder carries no Folder property at
        # all, which is not the same as carrying an empty one.
        if (-not $NoFolder) {
            $row | Add-Member -MemberType NoteProperty -Name Folder -Value $Folder
        }

        return $row
    }
}

Describe 'Get-HDTConsoleFolderMove' {

    Context 'a task sequence' {

        BeforeAll {
            $script:sequence = Get-HDTConsoleFolderMove -Row (New-HDTTestFolderRow) -Category 'TaskSequence'
        }

        It 'edits the document rather than moving anything on disk' {
            $script:sequence.Kind | Should -BeExactly 'Document'
        }

        It 'pairs the sequence setter with the sequence saver' {
            $script:sequence.Setter | Should -BeExactly 'Set-HDTTaskSequenceProperty'
            $script:sequence.Saver | Should -BeExactly 'Save-HDTSequenceDocument'
        }

        It 'names the document the row came from' {
            $script:sequence.DocumentPath | Should -BeExactly 'C:\HDTLab\Share\Control\DEMO-05\sequence.yaml'
        }

        It 'reports the folder it is in now, so the box opens on it' {
            $script:sequence.Current | Should -BeExactly 'Clients\Bare metal'
        }

        It 'echoes the setter with the folder left to fill in' {
            ($script:sequence.CommandFormat -f 'Servers') |
                Should -BeExactly "Set-HDTTaskSequenceProperty -Line `$line -Folder 'Servers'"
        }
    }

    Context 'an operating system' {

        BeforeAll {
            $script:os = Get-HDTConsoleFolderMove -Category 'OperatingSystem' `
                -Row (New-HDTTestFolderRow -Name 'Win11-LTSC-2024' -Folder 'Windows' `
                    -DocumentPath 'C:\HDTLab\Share\Control\Win11-LTSC-2024\os.yaml')
        }

        It 'pairs the operating system setter with the operating system saver' {
            # Not Save-HDTSequenceDocument. That refuses this document AFTER the
            # setter has already written it correctly.
            $script:os.Setter | Should -BeExactly 'Set-HDTOperatingSystemProperty'
            $script:os.Saver | Should -BeExactly 'Save-HDTOperatingSystemDocument'
        }

        It 'is still a document edit' {
            $script:os.Kind | Should -BeExactly 'Document'
        }

        It 'echoes the operating system setter' {
            ($script:os.CommandFormat -f 'Servers') |
                Should -BeExactly "Set-HDTOperatingSystemProperty -Line `$line -Folder 'Servers'"
        }
    }

    # THE EXCEPTION. Set-HDTApplication takes a share and an id and saves itself.
    Context 'an application' {

        BeforeAll {
            $script:app = Get-HDTConsoleFolderMove -Category 'Application' `
                -Row (New-HDTTestFolderRow -Name 'Acrobat' -Folder 'Readers' `
                    -DocumentPath 'C:\HDTLab\Share\Control\Acrobat\application.yaml')
        }

        It 'writes itself rather than through a saver' {
            $script:app.Kind | Should -BeExactly 'Application'
            $script:app.Saver | Should -BeExactly ''
        }

        It 'names the one command it takes' {
            $script:app.Setter | Should -BeExactly 'Set-HDTApplication'
        }

        It 'carries the share and the id that command takes instead of lines' {
            $script:app.WorkspaceRoot | Should -BeExactly 'C:\HDTLab\Share'
            $script:app.Id | Should -BeExactly 'Acrobat'
        }

        It 'echoes the share and the id, not a $line variable it never used' {
            ($script:app.CommandFormat -f 'Readers') |
                Should -BeExactly "Set-HDTApplication -WorkspaceRoot 'C:\HDTLab\Share' -Id 'Acrobat' -Folder 'Readers'"
        }
    }

    # A ROW THAT HAS NEVER BEEN IN A FOLDER CARRIES NO Folder PROPERTY, and
    # reading one off it under StrictMode throws inside a click handler.
    Context 'a row that has never been in a folder' {

        It 'reports no current folder rather than failing' {
            $answer = Get-HDTConsoleFolderMove -Row (New-HDTTestFolderRow -NoFolder) -Category 'TaskSequence'

            $answer.Current | Should -BeExactly ''
        }
    }

    Context 'a category the window does not move' {

        It 'refuses rather than guessing a setter' {
            $answer = Get-HDTConsoleFolderMove -Row (New-HDTTestFolderRow) -Category 'BootImage'

            $answer.Kind | Should -BeExactly 'None'
            $answer.Setter | Should -BeExactly ''
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTConsoleFolderMove -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTConsoleFolderMove'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
