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

    # THE SHIPPED TEMPLATES, SEEDED INTO THE FAKE, and this used to be missing.
    #
    # Get-HDTConsoleNewSequence takes an injected file system and forwarded it
    # everywhere EXCEPT to Get-HDTSequenceTemplate, which therefore defaulted to
    # the real adapter and read src\Hephaestus\Templates off the developer's own
    # disk. These tests passed because of that: the fake held no templates and
    # the assertion was satisfied by a directory nobody had seeded. Fixing the
    # forwarding on 2026-08-28 turned them red, correctly.
    #
    # THE CONTENT IS THE REAL FILE, read here and handed to the fake, so the
    # fixture is what the toolkit actually ships rather than a plausible
    # invention - and the command under test still touches nothing but the fake.
    $script:templateRoot = Join-Path -Path $script:HDTModuleRoot -ChildPath 'Templates'

    $script:templateFile = @{}

    foreach ($one in @(Get-ChildItem -LiteralPath $script:templateRoot -Filter '*.yaml' -File)) {
        $script:templateFile[$one.FullName] = [System.IO.File]::ReadAllText($one.FullName)
    }

    $script:fileSystem = New-HDTFakeFileSystem -File ($script:templateFile + @{
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
        })
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
            $line = Get-HDTConsoleNewSequenceCommand -Workspace 'C:\ws' -Id 'WIN11' `
                -Name 'Windows 11' -Template 'client'

            $line | Should -BeLike '*New-HDTTaskSequence*'
        }
    }

    # WHAT THE FOOTER SAYS AND WHAT THE BUTTON DOES ARE ONE THING OR THEY ARE A
    # LIE. DESIGN 12: an administrator learns the automation surface by clicking
    # around, and scripts anything they can do in the UI - so a line that omits
    # half of what Create writes sends them away with a sequence that has no
    # operating system and no administrator password, and nothing on screen said
    # so. This window collects seven answers; the line has to carry all seven.
    Context 'the line an administrator would copy' {

        BeforeAll {
            $script:typed = [ordered] @{
                HDTOSImage       = 'Win11-LTSC-2024'
                HDTFullName      = 'HDT Lab'
                HDTOrgName       = 'Hephaestus'
                HDTAdminPassword = 'P@ssw0rd-lab'
            }

            $script:setting = @(Get-HDTConsoleNewSequence -Workspace 'C:\ws' `
                    -FileSystem $script:fileSystem).Setting

            $script:line = Get-HDTConsoleNewSequenceCommand -Workspace 'C:\ws' -Id 'WIN11' `
                -Name 'Windows 11' -Template 'client' -Variable $script:typed -Setting $script:setting
        }

        It 'names the command, the share, the id, the name and the template' {
            $script:line | Should -BeLike "New-HDTTaskSequence -Workspace 'C:\ws' -Id 'WIN11' -Name 'Windows 11' -Template client*"
        }

        It 'carries every variable the button will write' {
            $script:line | Should -BeLike '*-Variable*'
            $script:line | Should -BeLike "*HDTOSImage = 'Win11-LTSC-2024'*"
            $script:line | Should -BeLike "*HDTFullName = 'HDT Lab'*"
            $script:line | Should -BeLike "*HDTOrgName = 'Hephaestus'*"
        }

        It 'names the administrator password without printing it' {
            # THE ONE KEY Get-HDTConsoleNewSequence MARKS Secret. It is readable
            # in the file it lands in, and that is a deliberate decision this
            # toolkit inherits from MDT - but a footer is selectable, copied and
            # photographed, and none of those is the file. The key has to appear,
            # because a line that silently dropped it would be the same defect
            # again; the value must not.
            $script:line | Should -BeLike '*HDTAdminPassword*'
            $script:line | Should -Not -BeLike '*P@ssw0rd-lab*'
        }

        It 'omits the variable block entirely when nothing else was typed' {
            # AN EMPTY HASH IS NOT AN ANSWER SOMEBODY GAVE. New-HDTTaskSequence
            # is called without -Variable in that case, and the line says so.
            $bare = Get-HDTConsoleNewSequenceCommand -Workspace 'C:\ws' -Id 'WIN11' `
                -Name 'Windows 11' -Template 'client' -Variable ([ordered] @{})

            $bare | Should -Not -BeLike '*-Variable*'
        }

        It 'doubles a quote in a name, so the line can be pasted as it stands' {
            $odd = Get-HDTConsoleNewSequenceCommand -Workspace 'C:\ws' -Id 'WIN11' `
                -Name "Frank's laptop" -Template 'client'

            $odd | Should -BeLike "*-Name 'Frank''s laptop'*"
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
            # THE TEMPLATES BUT NO SHARE. They ship with the module, not with the
            # workspace, so a folder nobody has imported an image into still
            # offers all of them - which is the point of this test and the reason
            # the fake carries the templates and nothing else.
            $view = Get-HDTConsoleNewSequence -Workspace 'C:\nowhere' `
                -FileSystem (New-HDTFakeFileSystem -File $script:templateFile)

            @($view.Template).Count | Should -BeGreaterThan 0
            @($view.Image).Count | Should -Be 0
        }
    }
}


}
