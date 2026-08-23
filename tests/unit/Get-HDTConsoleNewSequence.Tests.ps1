# THE NEW TASK SEQUENCE WIZARD - MDT's, answered without a window.
#
# MDT ASKS SEVEN PAGES OF QUESTIONS and then writes one file. What it asks is the
# interesting part, and it is decided here: which templates, which images, what
# each field writes, and what makes an answer refusable. The window shows the
# rows and runs the command; it decides none of it.

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

    $script:fileSystem = New-HDTFakeFileSystem -File @{
        'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: LAB`nname: lab`ndeployRoot: \\host\share"
        'C:\ws\TaskSequences\TAKEN\sequence.yaml' = "schemaVersion: 1`nid: TAKEN`nname: already here`nsteps: []"
        'C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml' = @'
schemaVersion: 1
id: Win11-LTSC-2024
name: Windows 11 Enterprise LTSC 2024
type: wim
sourcePath: sources\install.wim
defaultIndex: 1
images:
  - index: 1
    name: Windows 11 Enterprise LTSC
'@
    }
}

Describe 'Get-HDTConsoleNewSequence' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTConsoleNewSequence' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'what the wizard offers' {

        BeforeAll {
            $script:view = Get-HDTConsoleNewSequence -Workspace 'C:\ws' -FileSystem $script:fileSystem
        }

        It 'offers the templates this toolkit ships' {
            @($script:view.Template | ForEach-Object { $_.Id }) | Should -Contain 'client'
        }

        It 'offers the images this share holds' {
            @($script:view.Image | ForEach-Object { $_.Id }) | Should -Contain 'Win11-LTSC-2024'
        }

        It 'shows an image by the name somebody gave it' {
            @($script:view.Image | Where-Object { $_.Id -eq 'Win11-LTSC-2024' })[0].Display |
                Should -BeExactly 'Windows 11 Enterprise LTSC 2024'
        }

        It "names the settings MDT's wizard asks for, and the variable each writes" {
            $byKey = @{}
            foreach ($row in @($script:view.Setting)) { $byKey[$row.Key] = $row }

            $byKey['HDTFullName'].Label | Should -BeLike '*name*'
            $byKey['HDTOrgName'].Label | Should -BeLike '*rgani*'
            $byKey['HDTAdminPassword'].Label | Should -BeLike '*assword*'
        }

        It 'says the administrator password is readable in the file' {
            # IT IS NOT A SECRET AND THE WIZARD MUST NOT IMPLY ONE. A value WinPE
            # uses with no human present cannot be protected by a key that ships
            # in the same boot image; the control is to treat the workspace and
            # the media as credentials, and the page has to say so.
            $row = @($script:view.Setting | Where-Object { $_.Key -eq 'HDTAdminPassword' })[0]

            $row.Hint | Should -BeLike '*readable*'
        }

        It 'shows the command it would run' {
            $script:view.CommandFormat | Should -BeLike '*New-HDTTaskSequence*'
        }
    }

    Context 'what it refuses' {

        It 'refuses an empty id' {
            $answer = Test-HDTConsoleNewSequence -Workspace 'C:\ws' -Id '' -Name 'Windows 11' `
                -FileSystem $script:fileSystem

            $answer.CanCreate | Should -BeFalse
            $answer.Message | Should -BeLike '*id*'
        }

        It 'refuses an id that is already a folder in this share' {
            # New-HDTTaskSequence refuses it too, at the moment it would write.
            # Saying so on the page is the difference between a wizard that
            # finishes and one that fails on its last press.
            $answer = Test-HDTConsoleNewSequence -Workspace 'C:\ws' -Id 'TAKEN' -Name 'Windows 11' `
                -FileSystem $script:fileSystem

            $answer.CanCreate | Should -BeFalse
            $answer.Message | Should -BeLike '*TAKEN*'
        }

        It 'refuses an id with a character a folder cannot carry' {
            $answer = Test-HDTConsoleNewSequence -Workspace 'C:\ws' -Id 'WIN 11\LTSC' -Name 'Windows 11' `
                -FileSystem $script:fileSystem

            $answer.CanCreate | Should -BeFalse
        }

        It 'refuses an empty name' {
            $answer = Test-HDTConsoleNewSequence -Workspace 'C:\ws' -Id 'WIN11' -Name '' `
                -FileSystem $script:fileSystem

            $answer.CanCreate | Should -BeFalse
            $answer.Message | Should -BeLike '*name*'
        }

        It 'accepts an id and a name this share does not have' {
            $answer = Test-HDTConsoleNewSequence -Workspace 'C:\ws' -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fileSystem

            $answer.CanCreate | Should -BeTrue
            $answer.Message | Should -BeNullOrEmpty
        }

        It 'says where it would write, so the page can show it' {
            $answer = Test-HDTConsoleNewSequence -Workspace 'C:\ws' -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fileSystem

            $answer.Path | Should -BeLike '*TaskSequences\WIN11\sequence.yaml'
        }
    }

    Context 'a share with no catalog' {

        It 'still offers the templates, because a sequence can be created before an image is imported' {
            $view = Get-HDTConsoleNewSequence -Workspace 'C:\nowhere' -FileSystem (New-HDTFakeFileSystem)

            @($view.Template).Count | Should -BeGreaterThan 0
            @($view.Image).Count | Should -Be 0
        }
    }
}


}
