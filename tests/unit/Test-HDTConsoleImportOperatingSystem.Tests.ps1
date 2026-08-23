# WHETHER THE ANSWERS ON THE IMPORT DIALOG CAN BE USED, decided in a command
# rather than in the window.
#
# Import-HDTOperatingSystem refuses a bad id, a source that is not there and an
# id already on the share - but it refuses them at the END, after a technician
# has filled in four boxes and pressed Import. This is the same set of questions
# asked WHILE they type, so the refusal appears beside the box that caused it
# and Import is simply not available until it would work.
#
# IT DECIDES NOTHING THE IMPORT DOES NOT. Every rule here mirrors one in
# Import-HDTOperatingSystem; a rule that existed only in the dialog would be a
# rule the command line does not have, and the console would be lying about what
# HDT can do.

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
            'C:\ws\workspace.yaml'                           = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
            'C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml' = "schemaVersion: 1`nid: Win11-LTSC-2024`nname: Windows 11`ntype: wim`nsourcePath: sources\install.wim`nimages: []`n"
            'C:\media\WS2025\sources\install.wim'            = 'not really a wim'
        }
    }
}

Describe 'Test-HDTConsoleImportOperatingSystem' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Test-HDTConsoleImportOperatingSystem' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'says yes to answers the import would accept' {
        $answer = Test-HDTConsoleImportOperatingSystem -Workspace 'C:\ws' -Id 'WS2025-Std' `
            -SourcePath 'C:\media\WS2025\sources\install.wim' -FileSystem (& $script:newFileSystem)

        [bool] $answer.CanImport | Should -BeTrue
        [string] $answer.Message | Should -BeNullOrEmpty
        [string] $answer.Path | Should -BeExactly 'C:\ws\OperatingSystems\WS2025-Std'
    }

    It 'says nothing at all before anything has been typed' {
        # AN EMPTY DIALOG IS NOT A MISTAKE. A window that opens already
        # complaining teaches a technician to ignore the message line.
        $answer = Test-HDTConsoleImportOperatingSystem -Workspace 'C:\ws' -Id '' -SourcePath '' `
            -FileSystem (& $script:newFileSystem)

        [bool] $answer.CanImport | Should -BeFalse
        [string] $answer.Message | Should -BeNullOrEmpty
    }

    It 'says nothing while <Missing> is still empty' -ForEach @(
        @{ Missing = 'the source'; Id = 'WS2025-Std'; Source = '' }
        @{ Missing = 'the id'; Id = ''; Source = 'C:\media\WS2025\sources\install.wim' }
    ) {
        # A BOX NOBODY HAS FILLED IN YET IS NOT A REFUSAL, and the red line has
        # to mean something: a dialog that complains about work in progress
        # teaches a technician its message line is noise, and then the message
        # that matters - media that is not there, an id the share already has -
        # arrives in the same colour as the ones that did not. What a box is FOR
        # is on its hint; a disabled Import is what says "not yet".
        $answer = Test-HDTConsoleImportOperatingSystem -Workspace 'C:\ws' -Id $Id -SourcePath $Source `
            -FileSystem (& $script:newFileSystem)

        [bool] $answer.CanImport | Should -BeFalse
        [string] $answer.Message | Should -BeNullOrEmpty
    }

    It 'refuses an id that is not a folder name: <_>' -ForEach @('Win 11', 'Win/11', '..', 'C:\x') {
        $answer = Test-HDTConsoleImportOperatingSystem -Workspace 'C:\ws' -Id $_ `
            -SourcePath 'C:\media\WS2025\sources\install.wim' -FileSystem (& $script:newFileSystem)

        [bool] $answer.CanImport | Should -BeFalse
        [string] $answer.Message | Should -Not -BeNullOrEmpty
    }

    It 'refuses an id the share already has, naming it' {
        $answer = Test-HDTConsoleImportOperatingSystem -Workspace 'C:\ws' -Id 'Win11-LTSC-2024' `
            -SourcePath 'C:\media\WS2025\sources\install.wim' -FileSystem (& $script:newFileSystem)

        [bool] $answer.CanImport | Should -BeFalse
        [string] $answer.Message | Should -BeLike '*Win11-LTSC-2024*'
    }

    It 'refuses a source that is not there' {
        $answer = Test-HDTConsoleImportOperatingSystem -Workspace 'C:\ws' -Id 'WS2025-Std' `
            -SourcePath 'C:\media\nothing\install.wim' -FileSystem (& $script:newFileSystem)

        [bool] $answer.CanImport | Should -BeFalse
        [string] $answer.Message | Should -BeLike '*install.wim*'
    }

    It 'refuses a source that is not an image file' {
        # THE IMAGE LIST IS READ FROM THE MEDIA, so a folder or a setup.exe is
        # an import that fails at GetImageInfo - after the folder has been made.
        $fileSystem = & $script:newFileSystem
        $answer = Test-HDTConsoleImportOperatingSystem -Workspace 'C:\ws' -Id 'WS2025-Std' `
            -SourcePath 'C:\media\WS2025\sources' -FileSystem $fileSystem

        [bool] $answer.CanImport | Should -BeFalse
        [string] $answer.Message | Should -BeLike '*.wim*'
    }

    It 'suggests the id from the media rather than making somebody invent one' {
        # MDT's wizard fills the destination folder in from the source. The id
        # is a folder name and the media is already in one.
        $answer = Test-HDTConsoleImportOperatingSystem -Workspace 'C:\ws' -Id '' `
            -SourcePath 'C:\media\WS2025\sources\install.wim' -FileSystem (& $script:newFileSystem)

        [string] $answer.SuggestedId | Should -BeExactly 'WS2025'
    }
}


}
