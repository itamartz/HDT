# Renaming a driver folder, and everything that names it.
#
# THE CONSOLE COULD MAKE A DRIVER FOLDER AND DELETE ONE, AND NOT RENAME ONE, so
# an administrator fixing a typo left for Explorer - where the rename moves the
# directory and NOTHING ELSE. A driver folder is named in three other places and
# none of them fails loudly when it goes missing:
#
#   selection-profiles.yaml   a profile pointing at the old name injects nothing
#                             into a boot image and says nothing about it
#   driver-state.yaml         a driver somebody turned OFF comes quietly back
#   workspace.yaml            the boot image's own driver folder
#
# They fail as a boot image with no network card, discovered on a bench.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\HDTLab\Share'

    $script:newStore = {
        New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Drivers\WinPE\Dell\net.inf'      = '[Version]'
            'C:\HDTLab\Share\Drivers\WinPE\Dell Precision\x.inf' = '[Version]'
            'C:\HDTLab\Share\Drivers\Win11\Acme\y.inf'        = '[Version]'

            'C:\HDTLab\Share\Control\selection-profiles.yaml' = @(
                '# The WinPE pack, and this comment must survive a rename.'
                'schemaVersion: 1'
                'profiles:'
                '  - id: winpe'
                '    name: WinPE'
                '    include:'
                '      - Drivers\WinPE\Dell'
                '      - Drivers\WinPE\Dell Precision'
            ) -join "`r`n"

            'C:\HDTLab\Share\Control\driver-state.yaml' = @(
                'schemaVersion: 1'
                'disabled:'
                '  - WinPE\Dell\net.inf'
            ) -join "`r`n"
        }
    }
}

Describe 'Rename-HDTDriverFolder' {

    It 'renames the folder on the share' {
        $fs = & $script:newStore

        $answer = Rename-HDTDriverFolder -Root $script:root -Path 'WinPE\Dell' -NewName 'Dell WinPE' -FileSystem $fs -Confirm:$false

        $answer.Renamed | Should -BeTrue
        $answer.NewPath | Should -BeExactly 'WinPE\Dell WinPE'
        $fs.TestPath('C:\HDTLab\Share\Drivers\WinPE\Dell WinPE') | Should -BeTrue
    }

    It 'rewrites the selection profile that named it' {
        # A PROFILE LEFT POINTING AT THE OLD NAME INJECTS NOTHING, silently.
        $fs = & $script:newStore

        $null = Rename-HDTDriverFolder -Root $script:root -Path 'WinPE\Dell' -NewName 'Dell WinPE' -FileSystem $fs -Confirm:$false

        $text = [string] $fs.ReadAllText('C:\HDTLab\Share\Control\selection-profiles.yaml')

        $text | Should -Match ([regex]::Escape('Drivers\WinPE\Dell WinPE'))
    }

    It 'does not rewrite a folder that merely starts with the same letters' {
        # 'Dell' must not touch 'Dell Precision'. A substring match here
        # corrupts a document while looking like it worked.
        $fs = & $script:newStore

        $null = Rename-HDTDriverFolder -Root $script:root -Path 'WinPE\Dell' -NewName 'Dell WinPE' -FileSystem $fs -Confirm:$false

        [string] $fs.ReadAllText('C:\HDTLab\Share\Control\selection-profiles.yaml') |
            Should -Match ([regex]::Escape('Drivers\WinPE\Dell Precision'))
    }

    It 'carries the disabled drivers with it' {
        # OTHERWISE A DRIVER SOMEBODY TURNED OFF COMES BACK, on the next build,
        # with nothing said about it.
        $fs = & $script:newStore

        $null = Rename-HDTDriverFolder -Root $script:root -Path 'WinPE\Dell' -NewName 'Dell WinPE' -FileSystem $fs -Confirm:$false

        [string] $fs.ReadAllText('C:\HDTLab\Share\Control\driver-state.yaml') |
            Should -Match ([regex]::Escape('WinPE\Dell WinPE\net.inf'))
    }

    It 'leaves an administrator''s comments alone' {
        # The documents are YAML so they can be commented, and a rename that
        # re-serialised them would delete every comment in the file.
        $fs = & $script:newStore

        $null = Rename-HDTDriverFolder -Root $script:root -Path 'WinPE\Dell' -NewName 'Dell WinPE' -FileSystem $fs -Confirm:$false

        [string] $fs.ReadAllText('C:\HDTLab\Share\Control\selection-profiles.yaml') |
            Should -Match 'this comment must survive a rename'
    }

    Context 'what it refuses' {

        It 'refuses a path where a name belongs' {
            # A separator would MOVE the folder, which is a different operation
            # with different consequences.
            $fs = & $script:newStore

            { Rename-HDTDriverFolder -Root $script:root -Path 'WinPE\Dell' -NewName 'Other\Dell' -FileSystem $fs -Confirm:$false } |
                Should -Throw -ExpectedMessage '*not a folder name*'
        }

        It 'refuses to climb out of the store' {
            $fs = & $script:newStore

            { Rename-HDTDriverFolder -Root $script:root -Path 'WinPE\Dell' -NewName '..' -FileSystem $fs -Confirm:$false } |
                Should -Throw
        }

        It 'refuses the driver store itself' {
            $fs = & $script:newStore

            { Rename-HDTDriverFolder -Root $script:root -Path '' -FileSystem $fs -NewName 'x' -Confirm:$false } |
                Should -Throw
        }

        It 'refuses to rename onto a folder that already exists' {
            # Renaming onto it would MERGE two driver folders into one, and
            # nothing would say so afterwards.
            $fs = & $script:newStore

            { Rename-HDTDriverFolder -Root $script:root -Path 'WinPE\Dell' -NewName 'Dell Precision' -FileSystem $fs -Confirm:$false } |
                Should -Throw -ExpectedMessage '*already exists*'
        }

        It 'answers quietly for a folder that is not there' {
            $fs = & $script:newStore

            (Rename-HDTDriverFolder -Root $script:root -Path 'WinPE\Nowhere' -NewName 'x' -FileSystem $fs -Confirm:$false).Renamed |
                Should -BeFalse
        }

        It 'does nothing, and does not fail, when the name has not changed' {
            # Somebody pressing Rename and then OK without typing has not made
            # a mistake.
            $fs = & $script:newStore

            (Rename-HDTDriverFolder -Root $script:root -Path 'WinPE\Dell' -NewName 'Dell' -FileSystem $fs -Confirm:$false).Renamed |
                Should -BeFalse
        }
    }

    It 'writes nothing when -WhatIf is given' {
        $fs = & $script:newStore

        $null = Rename-HDTDriverFolder -Root $script:root -Path 'WinPE\Dell' -NewName 'Dell WinPE' -FileSystem $fs -WhatIf

        $fs.TestPath('C:\HDTLab\Share\Drivers\WinPE\Dell') | Should -BeTrue
        $fs.TestPath('C:\HDTLab\Share\Drivers\WinPE\Dell WinPE') | Should -BeFalse
    }

    It 'is fine on a share with no profile and no disabled drivers' {
        # Which is every new share: neither document exists until somebody
        # writes a profile or turns a driver off.
        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Drivers\WinPE\Dell\net.inf' = '[Version]'
        }

        $answer = Rename-HDTDriverFolder -Root $script:root -Path 'WinPE\Dell' -NewName 'Dell WinPE' -FileSystem $fs -Confirm:$false

        $answer.Renamed | Should -BeTrue
        $answer.ProfileUpdated | Should -BeFalse
        $answer.StateUpdated | Should -BeFalse
    }
}
