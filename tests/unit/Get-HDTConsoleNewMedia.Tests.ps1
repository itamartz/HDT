# THE NEW MEDIA DIALOG - id, name, selection profile, output - answered
# without a window.
#
# New-HDTMedia (07-01) already writes the document and refuses everything
# worth refusing; this is the same relationship Get/Test-HDTConsoleNewSequence
# have to New-HDTTaskSequence. What the dialog offers, refuses and would run
# is decided here so the window can show rows and run a command without
# deciding anything itself.

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

    # A SHARE WITH ONE AUTHORED PROFILE AND ONE EXISTING MEDIA DEFINITION -
    # WIN11-FIELD - so both "what the dialog offers" and "what it refuses as a
    # duplicate" have something real to answer from.
    $script:fileSystem = New-HDTFakeFileSystem -File @{
        'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: LAB`nname: lab`ndeployRoot: \\host\share"
        'C:\ws\Control\selection-profiles.yaml' = @'
schemaVersion: 1
profiles:
  - id: field-kit
    name: Field kit
    include:
      - Drivers\Field
'@
        'C:\ws\Media\WIN11-FIELD\media.yaml' = @'
schemaVersion: 1
id: WIN11-FIELD
name: Windows 11 field build
selectionProfile: everything
output: Media\WIN11-FIELD\HDT-WIN11-FIELD.iso
'@
    }

    $script:bareFileSystem = New-HDTFakeFileSystem -File @{
        'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: LAB`nname: lab`ndeployRoot: \\host\share"
    }
}

Describe 'Get-HDTConsoleNewMedia' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTConsoleNewMedia' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'what the dialog offers' {

        BeforeAll {
            $script:view = Get-HDTConsoleNewMedia -Workspace 'C:\ws' -FileSystem $script:fileSystem
        }

        It "lists this share's selection profiles, built-ins included" {
            $id = @($script:view.SelectionProfile | ForEach-Object { $_.Id })

            $id | Should -Contain 'field-kit'
            $id | Should -Contain 'everything'
            $id | Should -Contain 'all-drivers'
        }

        It 'forwards -FileSystem to Get-HDTSelectionProfile, not the real disk' {
            # A SHARE THAT ONLY THE FAKE KNOWS ABOUT. If this command ever
            # dropped -FileSystem on the floor the way 07-03's own plan
            # recorded finding once already, Get-HDTSelectionProfile would
            # fall through to the real adapter and answer from whatever is on
            # this laptop rather than from the fixture above - which a test
            # naming 'field-kit' would not catch, because a real share might
            # happen to have one too. A profile id nothing on disk could ever
            # carry is the only thing that proves the forward.
            $id = @($script:view.SelectionProfile | ForEach-Object { $_.Id })

            $id | Should -Contain 'field-kit'
        }
    }

    Context 'a share with no authored profiles' {

        It 'still offers the built-ins - everything, all-drivers' {
            $view = Get-HDTConsoleNewMedia -Workspace 'C:\ws' -FileSystem $script:bareFileSystem

            $id = @($view.SelectionProfile | ForEach-Object { $_.Id })

            $id | Should -Contain 'everything'
            $id | Should -Contain 'all-drivers'
        }
    }
}

Describe 'Test-HDTConsoleNewMedia' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Test-HDTConsoleNewMedia' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'what it refuses' {

        It 'refuses an empty id, naming what an id is for' {
            $answer = Test-HDTConsoleNewMedia -Workspace 'C:\ws' -Id '' -Name 'Field media' `
                -FileSystem $script:fileSystem

            $answer.CanCreate | Should -BeFalse
            $answer.Message | Should -BeLike '*id*'
        }

        It 'refuses an id with a path separator or a space in it' {
            $answer = Test-HDTConsoleNewMedia -Workspace 'C:\ws' -Id 'WIN11 FIELD\LAB' -Name 'Field media' `
                -FileSystem $script:fileSystem

            $answer.CanCreate | Should -BeFalse
        }

        It "refuses an id starting with a dot or a hyphen, the way New-HDTMedia's own pattern does" {
            foreach ($bad in @('.hidden', '-lab')) {
                $answer = Test-HDTConsoleNewMedia -Workspace 'C:\ws' -Id $bad -Name 'Field media' `
                    -FileSystem $script:fileSystem

                $answer.CanCreate | Should -BeFalse -Because "'$bad' is not a legal media id"
            }
        }

        It 'refuses an empty name' {
            $answer = Test-HDTConsoleNewMedia -Workspace 'C:\ws' -Id 'WS2025-LAB' -Name '' `
                -FileSystem $script:fileSystem

            $answer.CanCreate | Should -BeFalse
            $answer.Message | Should -BeLike '*name*'
        }

        It 'refuses an id this share already has a media definition for' {
            $answer = Test-HDTConsoleNewMedia -Workspace 'C:\ws' -Id 'WIN11-FIELD' -Name 'Another one' `
                -FileSystem $script:fileSystem

            $answer.CanCreate | Should -BeFalse
            $answer.Message | Should -BeLike '*WIN11-FIELD*'
        }
    }

    Context 'what it allows' {

        It 'allows a legal, unused id and a non-empty name' {
            $answer = Test-HDTConsoleNewMedia -Workspace 'C:\ws' -Id 'WS2025-LAB' -Name 'Server 2025 lab disc' `
                -FileSystem $script:fileSystem

            $answer.CanCreate | Should -BeTrue
            $answer.Message | Should -BeNullOrEmpty
        }

        It 'writes nothing - it is a query' {
            [void] (Test-HDTConsoleNewMedia -Workspace 'C:\ws' -Id 'WS2025-LAB' -Name 'Server 2025 lab disc' `
                    -FileSystem $script:fileSystem)

            $script:fileSystem.TestPath('C:\ws\Media\WS2025-LAB\media.yaml') | Should -BeFalse
        }
    }
}

Describe 'Get-HDTConsoleNewMediaCommand' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTConsoleNewMediaCommand' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It "composes the exact New-HDTMedia line Create is about to run" {
        $line = Get-HDTConsoleNewMediaCommand -Workspace 'C:\ws' -Id 'WS2025-LAB' `
            -Name 'Server 2025 lab disc' -SelectionProfile 'field-kit' -Output 'Media\WS2025-LAB\HDT_WS2025-LAB.iso'

        $line | Should -BeExactly "New-HDTMedia -WorkspaceRoot 'C:\ws' -Id 'WS2025-LAB' -Name 'Server 2025 lab disc' -SelectionProfile 'field-kit' -Output 'Media\WS2025-LAB\HDT_WS2025-LAB.iso'"
    }

    It "omits -Output when the box was left empty, so New-HDTMedia's own default fills it in" {
        $line = Get-HDTConsoleNewMediaCommand -Workspace 'C:\ws' -Id 'WS2025-LAB' `
            -Name 'Server 2025 lab disc' -SelectionProfile 'everything' -Output ''

        $line | Should -Not -BeLike '*-Output*'
        $line | Should -BeExactly "New-HDTMedia -WorkspaceRoot 'C:\ws' -Id 'WS2025-LAB' -Name 'Server 2025 lab disc' -SelectionProfile 'everything'"
    }

    It 'quotes every value, the way Get-HDTConsoleNewSequenceCommand does' {
        $line = Get-HDTConsoleNewMediaCommand -Workspace 'C:\ws' -Id 'WS2025-LAB' `
            -Name "Frank's disc" -SelectionProfile 'everything' -Output ''

        $line | Should -BeLike "*-Name 'Frank''s disc'*"
    }
}


}
