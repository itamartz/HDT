# Remove-HDTMedia deletes a folder, so the guards are the ones CLAUDE.md demands
# of anything that does - the same two-check shape Remove-HDTApplication uses.
# The id is judged TWICE: once as typed, and once as the path it resolved to,
# because what matters is where it ended up rather than how it looked.
#
# THE ISO PAIR IS THE PROTECTED-PATH RULE AT COMMAND LEVEL. output may be rooted
# anywhere, including somewhere that is not this share at all, so an ISO outside
# the media folder is NAMED and LEFT rather than deleted by a path built from a
# variable.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:root = 'X:\Share'

    $script:mediaYaml = {
        param([string] $Id = 'M1', [string] $Output = '')

        $iso = $Output
        if ([string]::IsNullOrEmpty($iso)) {
            $iso = 'Media\{0}\HDT_{1}.iso' -f $Id, $Id
        }

        return (@(
                '# HDT standalone media definition.'
                'schemaVersion: 1'
                ('id: {0}' -f $Id)
                ('name: Media {0}' -f $Id)
                'selectionProfile: everything'
                ('output: {0}' -f $iso)
                'enabled: true'
            ) -join "`r`n")
    }
}

Describe 'Remove-HDTMedia' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -File @{
            'X:\Share\Media\M1\media.yaml'          = (& $script:mediaYaml -Id 'M1')
            'X:\Share\Media\M1\HDT_M1.iso'          = 'pretend this is six gigabytes'
            'X:\Share\Media\M1\media.manifest.json' = '{ "schemaVersion": 1 }'
            'X:\Share\Media\M2\media.yaml'          = (& $script:mediaYaml -Id 'M2')
        }
    }

    Context 'the refusals, which come before anything is deleted' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Remove-HDTMedia' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'declares SupportsShouldProcess, because it deletes a folder' {
            (Get-Command -Name 'Remove-HDTMedia').Parameters.Keys | Should -Contain 'WhatIf'
            (Get-Command -Name 'Remove-HDTMedia').Parameters.Keys | Should -Contain 'Confirm'
        }

        It 'refuses an id carrying a separator, a wildcard, a space, . or .. - <_>' -ForEach @(
            'a media'
            '..\..\Windows'
            'Media/Win11'
            '*'
            '.'
            '..'
        ) {
            { Remove-HDTMedia -WorkspaceRoot $script:root -Id $_ -FileSystem $script:fileSystem -Confirm:$false } |
                Should -Throw -ExpectedMessage '*cannot be a media id*'

            $script:fileSystem.GetOperationName() | Should -Not -Contain 'RemoveItem'
        }

        It 'refuses an id that would resolve outside the share''s Media folder, and deletes nothing' {
            # THE TWO CHECKS OVERLAP ON PURPOSE and this input is caught by the
            # first of them, which is why the message asserted is the typed-id
            # one. Every way of escaping Media\ carries a separator, so nothing
            # reaches the resolved-path check that the typed check lets through -
            # it is a backstop, and a recursive delete is worth two cheap checks.
            { Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M1\..\..\Windows' `
                    -FileSystem $script:fileSystem -Confirm:$false } |
                Should -Throw -ExpectedMessage '*cannot be a media id*'

            $script:fileSystem.GetOperationName() | Should -Not -Contain 'RemoveItem'
            $script:fileSystem.TestPath('X:\Share\Media\M1\media.yaml') | Should -BeTrue
        }

        It 'refuses an id the share has no folder for' {
            { Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M9' -FileSystem $script:fileSystem -Confirm:$false } |
                Should -Throw -ExpectedMessage "*'M9'*"

            $script:fileSystem.GetOperationName() | Should -Not -Contain 'RemoveItem'
        }

        It 'refuses a folder under Media that holds no media.yaml, saying it is not a media definition' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\scratch\notes.txt' = 'somebody staged something here'
            }

            { Remove-HDTMedia -WorkspaceRoot $script:root -Id 'scratch' -FileSystem $fs -Confirm:$false } |
                Should -Throw -ExpectedMessage '*not a media definition*'

            $fs.GetOperationName() | Should -Not -Contain 'RemoveItem'
        }

        It 'deletes nothing when -WhatIf is passed' {
            $null = Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $script:fileSystem -WhatIf

            $script:fileSystem.TestPath('X:\Share\Media\M1\media.yaml') | Should -BeTrue
            $script:fileSystem.GetOperationName() | Should -Not -Contain 'RemoveItem'
        }
    }

    Context 'what it removes' {

        It 'removes the media folder and the document in it' {
            $null = Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $script:fileSystem -Confirm:$false

            $script:fileSystem.TestPath('X:\Share\Media\M1') | Should -BeFalse
            $script:fileSystem.TestPath('X:\Share\Media\M1\media.yaml') | Should -BeFalse
        }

        It 'removes an ISO that is inside the media folder, because it went with the folder' {
            $null = Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $script:fileSystem -Confirm:$false

            $script:fileSystem.TestPath('X:\Share\Media\M1\HDT_M1.iso') | Should -BeFalse
        }

        It 'removes the manifest with the folder' {
            $null = Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $script:fileSystem -Confirm:$false

            $script:fileSystem.TestPath('X:\Share\Media\M1\media.manifest.json') | Should -BeFalse
        }

        It 'reports the id and the folder it removed' {
            $answer = Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $script:fileSystem -Confirm:$false

            $answer.Id | Should -BeExactly 'M1'
            $answer.Path | Should -BeExactly 'X:\Share\Media\M1'
        }
    }

    Context 'an ISO written somewhere else' {

        BeforeEach {
            $script:elsewhere = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M3\media.yaml' = (& $script:mediaYaml -Id 'M3' -Output 'D:\Builds\field.iso')
                'D:\Builds\field.iso'          = 'pretend this is six gigabytes'
            }
        }

        It 'leaves an ISO written outside the media folder alone' {
            $null = Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M3' -FileSystem $script:elsewhere `
                -Confirm:$false -WarningAction SilentlyContinue

            $script:elsewhere.TestPath('D:\Builds\field.iso') | Should -BeTrue
            $script:elsewhere.TestPath('X:\Share\Media\M3') | Should -BeFalse
        }

        It 'names that ISO in a warning, so nobody has to go looking for it' {
            $warning = @()

            $null = Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M3' -FileSystem $script:elsewhere `
                -Confirm:$false -WarningVariable warning -WarningAction SilentlyContinue

            (@($warning) -join ' ') | Should -BeLike '*D:\Builds\field.iso*'
        }

        It 'reports it on the object too, so a console can say so before anybody agrees' {
            $answer = Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M3' -FileSystem $script:elsewhere `
                -WhatIf -WarningAction SilentlyContinue

            $answer.IsoLeftBehind | Should -BeExactly 'D:\Builds\field.iso'
        }
    }

    Context 'a document that will not read' {

        # FOUND BY RUNNING IT, not by a fake: a real round trip on a real share
        # added an eighth key by hand to prove the validator refuses it, and then
        # could not remove the item at all. The document is read here only to
        # learn where the ISO is, so a document that will not read is a missing
        # answer to that question - not a reason to refuse the delete. A broken
        # media.yaml is exactly the one somebody wants gone, and "you cannot
        # remove it because it is wrong" is a delete nobody can ever do.

        It 'removes a media definition whose document will not validate' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M4\media.yaml' = ((& $script:mediaYaml -Id 'M4') + "`r`nmediaPath: D:\somewhere")
            }

            $null = Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M4' -FileSystem $fs `
                -Confirm:$false -WarningAction SilentlyContinue

            $fs.TestPath('X:\Share\Media\M4') | Should -BeFalse
        }

        It 'removes a media definition whose document will not parse' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M5\media.yaml' = "schemaVersion: 1`r`n  id: [ this is not`r`n valid yaml"
            }

            $null = Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M5' -FileSystem $fs `
                -Confirm:$false -WarningAction SilentlyContinue

            $fs.TestPath('X:\Share\Media\M5') | Should -BeFalse
        }

        It 'says it could not tell where the ISO was, rather than saying nothing' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M4\media.yaml' = ((& $script:mediaYaml -Id 'M4') + "`r`nmediaPath: D:\somewhere")
            }

            $warning = @()

            $null = Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M4' -FileSystem $fs `
                -Confirm:$false -WarningVariable warning -WarningAction SilentlyContinue

            (@($warning) -join ' ') | Should -BeLike '*could not be read*'
        }
    }

    Context 'what it does not touch' {

        It 'leaves every other media definition on the share' {
            $null = Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $script:fileSystem -Confirm:$false

            $script:fileSystem.TestPath('X:\Share\Media\M2\media.yaml') | Should -BeTrue
        }

        It 'leaves the Media folder itself' {
            $null = Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $script:fileSystem -Confirm:$false

            $script:fileSystem.TestPath('X:\Share\Media') | Should -BeTrue
        }

        It 'removes exactly one thing, and it is the media folder' {
            $null = Remove-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $script:fileSystem -Confirm:$false

            $removal = @($script:fileSystem.Operations | Where-Object { $_.Operation -eq 'RemoveItem' })

            @($removal).Count | Should -Be 1
            $removal[0].Arguments[0] | Should -BeExactly 'X:\Share\Media\M1'
        }
    }
}
