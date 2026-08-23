# WHETHER THE NEW APPLICATION DIALOG'S ANSWERS CAN BE USED, decided without a
# window - the same arrangement Import Operating System has, for the same
# reason: Import-HDTApplication refuses a bad id, a source that is not there and
# an id the share already has, but it refuses them at the END, after four boxes
# have been filled in and Import has been pressed.
#
# IT DECIDES NOTHING THE IMPORT DOES NOT. Every rule here mirrors one in
# Import-HDTApplication. A rule that existed only in the dialog would be a rule
# the command line has not got, and the console would be describing a toolkit
# that does not exist (DESIGN 12).
#
# THE SOURCE IS A FOLDER, WHICH IS THE DIFFERENCE FROM MEDIA. An operating
# system is imported from one .wim; an application is imported from the folder
# holding its installer, because what gets copied to the share is everything the
# install command line needs beside it.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:newFileSystem = {
        New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml'                   = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
            'C:\ws\Applications\7Zip-24.09\app.yaml' = "schemaVersion: 1`nid: 7Zip-24.09`nname: 7-Zip`ninstall: setup.exe`n"
            'C:\media\7Zip\7z2409-x64.msi'           = 'not really an msi'
        }
    }
}

Describe 'Test-HDTConsoleImportApplication' {

    Context 'a box nobody has filled in yet' {

        # AN EMPTY BOX IS NOT A REFUSAL, and saying so in the red line was this
        # dialog's own defect: a window that complains about work in progress
        # teaches a technician that the red text is noise, and then the message
        # that matters arrives in the same colour as the ones that did not.
        #
        # WHAT A BOX IS FOR IS ON ITS ?. The message line is for what is WRONG,
        # and a disabled Add is what says "not yet".

        It 'says nothing on an empty dialog' {
            $answer = Test-HDTConsoleImportApplication -Workspace 'C:\ws' -FileSystem (& $script:newFileSystem)

            $answer.CanImport | Should -BeFalse
            [string] $answer.Message | Should -BeExactly ''
        }

        It 'says nothing while <Missing> is still empty' -ForEach @(
            @{ Missing = 'the source'; Id = 'Notepad'; Source = ''; Install = 'setup.exe /quiet' }
            @{ Missing = 'the install command'; Id = 'Notepad'; Source = 'C:\media\7Zip'; Install = '' }
            @{ Missing = 'the id'; Id = ''; Source = 'C:\media\7Zip'; Install = 'setup.exe /quiet' }
        ) {
            $answer = Test-HDTConsoleImportApplication -Workspace 'C:\ws' -Id $Id -SourcePath $Source `
                -Install $Install -FileSystem (& $script:newFileSystem)

            $answer.CanImport | Should -BeFalse
            [string] $answer.Message | Should -BeExactly ''
        }
    }

    Context 'the source folder' {

        It 'refuses one that is not there, naming it' {
            $answer = Test-HDTConsoleImportApplication -Workspace 'C:\ws' -Id 'Notepad' `
                -SourcePath 'C:\media\NoSuch' -FileSystem (& $script:newFileSystem)

            $answer.CanImport | Should -BeFalse
            [string] $answer.Message | Should -BeLike '*C:\media\NoSuch*'
        }

        It 'suggests an id from the folder the installer sits in' {
            # MDT's wizard fills the destination in from the source; an id is a
            # folder name and the payload is already in one.
            $answer = Test-HDTConsoleImportApplication -Workspace 'C:\ws' -SourcePath 'C:\media\7Zip' `
                -FileSystem (& $script:newFileSystem)

            [string] $answer.SuggestedId | Should -BeExactly '7Zip'
        }
    }

    Context 'the id' {

        It 'refuses <Bad>, which cannot be a folder name' -ForEach @(
            @{ Bad = '7 Zip' }
            @{ Bad = '.hidden' }
            @{ Bad = 'C:\Windows' }
            @{ Bad = '7Zip/24' }
        ) {
            $answer = Test-HDTConsoleImportApplication -Workspace 'C:\ws' -Id $Bad -SourcePath 'C:\media\7Zip' `
                -Install 'setup.exe /quiet' -FileSystem (& $script:newFileSystem)

            $answer.CanImport | Should -BeFalse
            [string] $answer.Message | Should -BeLike '*folder name*'
        }

        It 'refuses one the share already has, and says what to do instead' {
            $answer = Test-HDTConsoleImportApplication -Workspace 'C:\ws' -Id '7Zip-24.09' -SourcePath 'C:\media\7Zip' `
                -Install 'setup.exe /quiet' -FileSystem (& $script:newFileSystem)

            $answer.CanImport | Should -BeFalse
            [string] $answer.Message | Should -BeLike '*already*'
        }
    }

    Context 'answers that will work' {

        It 'offers Import, and names where it will land' {
            $answer = Test-HDTConsoleImportApplication -Workspace 'C:\ws' -Id 'Notepad-Plus' -SourcePath 'C:\media\7Zip' `
                -Install 'setup.exe /quiet' -FileSystem (& $script:newFileSystem)

            $answer.CanImport | Should -BeTrue
            [string] $answer.Message | Should -BeExactly ''
            [string] $answer.Path | Should -BeExactly 'C:\ws\Applications\Notepad-Plus'
        }
    }
}


}
