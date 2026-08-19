# WHETHER THE NEW DEPLOYMENT SHARE DIALOG'S ANSWERS CAN BE USED.
#
# The same arrangement the other three dialogs have, and for the same reason:
# New-HDTWorkspace refuses a bad id and a folder that already holds a share, but
# it refuses them at the END, after the boxes have been filled in and Create has
# been pressed.
#
# IT DECIDES NOTHING New-HDTWorkspace DOES NOT. A rule that existed only here
# would be a rule the command line has not got, and the console would be
# describing a toolkit that does not exist (DESIGN 12).
#
# A BOX NOBODY HAS FILLED IN YET IS NOT A REFUSAL, which is the rule the New
# Application and Import Operating System dialogs were fixed to follow: the
# message line is for what is WRONG, and a disabled Create is what says "not
# yet".

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:newFileSystem = {
        New-HDTFakeFileSystem -File @{
            'C:\shares\Existing\workspace.yaml' = "schemaVersion: 1`nid: HDT`nname: Existing share`n"
            'C:\shares\NotAShare\notes.txt'     = 'mine'
        } -Directory @('C:\shares', 'C:\shares\Existing', 'C:\shares\NotAShare', 'C:\shares\Empty')
    }
}

Describe 'Test-HDTConsoleNewWorkspace' {

    Context 'a dialog nobody has filled in' {

        It 'says nothing, and does not offer Create' {
            $answer = Test-HDTConsoleNewWorkspace -FileSystem (& $script:newFileSystem)

            $answer.CanCreate | Should -BeFalse
            [string] $answer.Message | Should -BeExactly ''
        }

        It 'says nothing while the id is still empty' {
            $answer = Test-HDTConsoleNewWorkspace -Path 'C:\shares\New' -FileSystem (& $script:newFileSystem)

            $answer.CanCreate | Should -BeFalse
            [string] $answer.Message | Should -BeExactly ''
        }
    }

    Context 'the folder' {

        It 'suggests an id from it, so nobody has to invent one' {
            $answer = Test-HDTConsoleNewWorkspace -Path 'C:\shares\Contoso-Lab' -FileSystem (& $script:newFileSystem)

            [string] $answer.SuggestedId | Should -BeExactly 'Contoso-Lab'
        }

        It 'refuses one that already holds a share, naming what is there' {
            # New-HDTWorkspace refuses to write over a workspace.yaml, and this
            # is the same refusal said before anything is typed into the rest.
            $answer = Test-HDTConsoleNewWorkspace -Path 'C:\shares\Existing' -Id 'HDT-NEW' `
                -FileSystem (& $script:newFileSystem)

            $answer.CanCreate | Should -BeFalse
            [string] $answer.Message | Should -BeLike '*already*'
        }

        It 'accepts a folder that exists but holds no share' {
            $answer = Test-HDTConsoleNewWorkspace -Path 'C:\shares\NotAShare' -Id 'HDT-NEW' `
                -FileSystem (& $script:newFileSystem)

            $answer.CanCreate | Should -BeTrue
        }

        It 'accepts one that is not there yet, because creating it is the point' {
            $answer = Test-HDTConsoleNewWorkspace -Path 'C:\shares\Brand-New' -Id 'HDT-NEW' `
                -FileSystem (& $script:newFileSystem)

            $answer.CanCreate | Should -BeTrue
        }
    }

    Context 'the id' {

        # EXACTLY WHAT New-HDTWorkspace REFUSES, AND NOTHING MORE. A leading
        # hyphen is not on this list because the command accepts one: a dialog
        # that refused it would be refusing a share the prompt can create, which
        # is the console describing a toolkit that does not exist.
        It 'refuses <Bad>, which New-HDTWorkspace would refuse too' -ForEach @(
            @{ Bad = 'HDT LAB' }
            @{ Bad = 'HDT/LAB' }
            @{ Bad = 'HDT.LAB' }
            @{ Bad = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
        ) {
            $answer = Test-HDTConsoleNewWorkspace -Path 'C:\shares\New' -Id $Bad `
                -FileSystem (& $script:newFileSystem)

            $answer.CanCreate | Should -BeFalse
            [string] $answer.Message | Should -Not -BeNullOrEmpty
        }
    }

    Context 'answers that will work' {

        It 'offers Create, and says nothing' {
            $answer = Test-HDTConsoleNewWorkspace -Path 'C:\shares\Brand-New' -Id 'HDT-LAB' `
                -FileSystem (& $script:newFileSystem)

            $answer.CanCreate | Should -BeTrue
            [string] $answer.Message | Should -BeExactly ''
        }
    }
}

Describe 'Test-HDTConsoleOpenWorkspace' {

    # OPENING IS THE OTHER HALF, and it has one question: is there a share
    # there? A folder without a workspace.yaml is not one, and adding it to the
    # tree would put a row in the window that can only ever say it failed.

    It 'accepts a folder holding a workspace.yaml' {
        (Test-HDTConsoleOpenWorkspace -Path 'C:\shares\Existing' -FileSystem (& $script:newFileSystem)).CanOpen |
            Should -BeTrue
    }

    It 'refuses one that does not, and says what is missing' {
        $answer = Test-HDTConsoleOpenWorkspace -Path 'C:\shares\NotAShare' -FileSystem (& $script:newFileSystem)

        $answer.CanOpen | Should -BeFalse
        [string] $answer.Message | Should -BeLike '*workspace.yaml*'
    }

    It 'refuses a folder that is not there at all, naming it' {
        $answer = Test-HDTConsoleOpenWorkspace -Path 'C:\shares\Nope' -FileSystem (& $script:newFileSystem)

        $answer.CanOpen | Should -BeFalse
        [string] $answer.Message | Should -BeLike '*C:\shares\Nope*'
    }

    It 'refuses one that is already open in this window, rather than showing it twice' {
        $answer = Test-HDTConsoleOpenWorkspace -Path 'C:\shares\Existing' -Open @('C:\shares\existing') `
            -FileSystem (& $script:newFileSystem)

        $answer.CanOpen | Should -BeFalse
        [string] $answer.Message | Should -BeLike '*already*'
    }

    It 'says nothing at all before a folder has been chosen' {
        $answer = Test-HDTConsoleOpenWorkspace -FileSystem (& $script:newFileSystem)

        $answer.CanOpen | Should -BeFalse
        [string] $answer.Message | Should -BeExactly ''
    }
}
