# New-HDTMedia creates the object MDT's Deployment Workbench keeps under
# Advanced Configuration -> Media: a selection profile, an output path and an
# enabled tick. It builds nothing; Update-HDTMediaContent does that.
#
# NOTHING HERE TOUCHES A DISK, and the workspace root is deliberately a drive
# this session has not mounted. A command that dropped -FileSystem on a call to
# another HDT command would read the real filesystem and pass or fail on whether
# this machine happens to have a share at that path - which is not a test of
# anything. X:\ makes that failure loud.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:root = 'X:\Share'

    # An authored profile, so the "a profile the share actually has" leg is not
    # only about the built-ins.
    $script:profileYaml = @(
        'schemaVersion: 1'
        'profiles:'
        '  - id: field-kit'
        '    name: Field kit'
        '    include:'
        '      - Applications\7Zip-24.09'
    ) -join "`r`n"
}

Describe 'New-HDTMedia' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -Directory @('X:\Share', 'X:\Share\Media', 'X:\Share\Control')
    }

    It 'is exported by Hephaestus' {
        Get-Command -Name 'New-HDTMedia' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'what it writes' {

        It 'writes Media\<id>\media.yaml under the workspace root' {
            $null = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'Windows 11 field media' `
                -FileSystem $script:fileSystem

            $script:fileSystem.TestPath('X:\Share\Media\WIN11-FIELD\media.yaml') | Should -BeTrue
        }

        It 'writes a document Assert-HDTMediaDocument accepts' {
            $null = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'Windows 11 field media' `
                -FileSystem $script:fileSystem

            $text = $script:fileSystem.ReadAllText('X:\Share\Media\WIN11-FIELD\media.yaml')

            InModuleScope Hephaestus -Parameters @{ Yaml = $text } {
                param($Yaml)

                $path = 'X:\Share\Media\WIN11-FIELD\media.yaml'
                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $path

                { Assert-HDTMediaDocument -Document $document -Path $path -Id 'WIN11-FIELD' } | Should -Not -Throw
            }
        }

        It 'writes a document Get-HDTMedia reads back with every value it was given' {
            $null = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'Windows 11 field media' `
                -Description 'Engineers laptop build, no network' -SelectionProfile 'all-drivers' `
                -Output 'D:\Builds\field.iso' -Enabled $false -FileSystem $script:fileSystem

            $media = Get-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -FileSystem $script:fileSystem

            $media.Id | Should -BeExactly 'WIN11-FIELD'
            $media.Name | Should -BeExactly 'Windows 11 field media'
            $media.Description | Should -BeExactly 'Engineers laptop build, no network'
            $media.SelectionProfile | Should -BeExactly 'all-drivers'
            $media.Output | Should -BeExactly 'D:\Builds\field.iso'
            $media.Enabled | Should -BeFalse
        }

        It 'heads the document with a comment saying what it is' {
            # The comments are why Set-HDTMedia splices rather than
            # re-serialising: a round trip through the YAML writer would take
            # them out, and this file is one an administrator hand-edits.
            $null = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M' -FileSystem $script:fileSystem

            $text = $script:fileSystem.ReadAllText('X:\Share\Media\WIN11-FIELD\media.yaml')
            $text | Should -Match '^#'
            $text | Should -Match 'Update-HDTMediaContent'
        }

        It 'creates the Media folder when the share has not got one' {
            $bare = New-HDTFakeFileSystem -Directory @('X:\Share')

            $null = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M' -FileSystem $bare

            $bare.TestPath('X:\Share\Media\WIN11-FIELD') | Should -BeTrue
        }

        It 'returns the media object it created, carrying WorkspaceRoot' {
            $media = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M' -FileSystem $script:fileSystem

            $media | Should -Not -BeNullOrEmpty
            $media.WorkspaceRoot | Should -BeExactly $script:root
            $media.DocumentPath | Should -BeExactly 'X:\Share\Media\WIN11-FIELD\media.yaml'
        }
    }

    Context 'the defaults, which are MDT s' {

        It 'defaults selectionProfile to everything, which is what MDT defaults a media item to' {
            $media = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M' -FileSystem $script:fileSystem

            $media.SelectionProfile | Should -BeExactly 'everything'
        }

        It 'defaults output to Media\<id>\HDT_<id>.iso' {
            $media = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M' -FileSystem $script:fileSystem

            $media.Output | Should -BeExactly 'Media\WIN11-FIELD\HDT_WIN11-FIELD.iso'
        }

        It 'defaults enabled to true' {
            $media = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M' -FileSystem $script:fileSystem

            $media.Enabled | Should -BeTrue
        }

        It 'writes no description key when none was given, rather than an empty one' {
            $null = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M' -FileSystem $script:fileSystem

            $text = $script:fileSystem.ReadAllText('X:\Share\Media\WIN11-FIELD\media.yaml')

            @($text -split "`r?`n" | Where-Object { $_ -match '^description\s*:' }) |
                Should -BeNullOrEmpty -Because 'a key present and blank reads as a failed template substitution'
        }
    }

    Context 'the refusals' {

        It 'refuses an id that already has a media.yaml, naming Set-HDTMedia' {
            $null = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M' -FileSystem $script:fileSystem

            { New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M again' -FileSystem $script:fileSystem } |
                Should -Throw -ExpectedMessage '*Set-HDTMedia*'
        }

        It 'refuses an id that is not a folder name, before it becomes a path - <_>' -ForEach @(
            'a media'
            '..\..\Windows'
            'Media/Win11'
            '*'
            '.'
            '..'
        ) {
            # THE MESSAGE IS ASSERTED, not just the throw. Written as a bare
            # Should -Throw these six passed before New-HDTMedia existed at all -
            # CommandNotFoundException is an exception too.
            { New-HDTMedia -WorkspaceRoot $script:root -Id $_ -Name 'M' -FileSystem $script:fileSystem } |
                Should -Throw -ExpectedMessage '*not a legal media id*'

            $script:fileSystem.GetOperationName() | Should -Not -Contain 'WriteAllText'
        }

        It 'refuses a selectionProfile the share does not have, naming the ones it does' {
            { New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M' `
                    -SelectionProfile 'no-such-profile' -FileSystem $script:fileSystem } |
                Should -Throw -ExpectedMessage '*everything*'
        }

        It 'accepts a built-in profile id without any selection-profiles.yaml on the share' {
            # A hand-made share with no Control\selection-profiles.yaml still has
            # the built-ins, and a media item on it must be creatable.
            $bare = New-HDTFakeFileSystem -Directory @('X:\Share')

            $media = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M' `
                -SelectionProfile 'all-drivers' -FileSystem $bare

            $media.SelectionProfile | Should -BeExactly 'all-drivers'
        }

        It 'accepts an authored profile id from Control\selection-profiles.yaml' {
            $authored = New-HDTFakeFileSystem -File @{
                'X:\Share\Control\selection-profiles.yaml' = $script:profileYaml
            }

            $media = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M' `
                -SelectionProfile 'field-kit' -FileSystem $authored

            $media.SelectionProfile | Should -BeExactly 'field-kit'
        }

        It 'reads the selection profiles through the injected filesystem, never the real one' {
            # THE DEFECT THIS EXISTS TO PREVENT: Get-HDTSelectionProfile defaults
            # -FileSystem to the REAL adapter, so a call that omits it reads the
            # actual disk while every other line of the command reads the fake.
            # The authored profile is only on the fake, so if the call went to
            # disk this refuses 'field-kit' and the test fails.
            $authored = New-HDTFakeFileSystem -File @{
                'X:\Share\Control\selection-profiles.yaml' = $script:profileYaml
            }

            $null = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M' `
                -SelectionProfile 'field-kit' -FileSystem $authored

            $authored.GetOperationName() | Should -Contain 'ReadAllText'
        }

        It 'refuses an output that is not an .iso' {
            { New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M' `
                    -Output 'Media\WIN11-FIELD\field.wim' -FileSystem $script:fileSystem } |
                Should -Throw -ExpectedMessage '*.iso*'
        }

        It 'does not write when -WhatIf is passed' {
            $null = New-HDTMedia -WorkspaceRoot $script:root -Id 'WIN11-FIELD' -Name 'M' `
                -FileSystem $script:fileSystem -WhatIf

            $script:fileSystem.TestPath('X:\Share\Media\WIN11-FIELD\media.yaml') | Should -BeFalse
            $script:fileSystem.GetOperationName() | Should -Not -Contain 'WriteAllText'
        }
    }
}
