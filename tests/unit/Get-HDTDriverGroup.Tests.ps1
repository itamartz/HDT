# The driver groups a share actually has.
#
# A DRIVER GROUP IS A FOLDER UNDER Drivers\ - MDT's selection profile, by
# another name - and until this existed nothing could list them. The console's
# Windows PE window asked an administrator to TYPE the group name into a box,
# which is a box you can spell wrong: Update-HDTBootImage then warns that there
# is nothing at that path and builds an image with no drivers in it, which is a
# boot image that cannot see the disk.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\HDTLab\Share'
}

Describe 'Get-HDTDriverGroup' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTDriverGroup' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'lists one group per folder under Drivers, in name order' {
        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Drivers\winpe-nic\e1d68x64.inf'          = '[Version]'
            'C:\HDTLab\Share\Drivers\boot-critical\stor.inf'          = '[Version]'
            'C:\HDTLab\Share\Drivers\Dell Latitude 7450\wifi.inf'     = '[Version]'
        }

        $group = @(Get-HDTDriverGroup -Root $script:root -FileSystem $fs)

        @($group | ForEach-Object { $_.Name }) |
            Should -Be @('boot-critical', 'Dell Latitude 7450', 'winpe-nic')
    }

    It 'carries the folder each group is' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\HDTLab\Share\Drivers\winpe-nic\e1d68x64.inf' = '[Version]' }

        @(Get-HDTDriverGroup -Root $script:root -FileSystem $fs)[0].Path |
            Should -BeExactly 'C:\HDTLab\Share\Drivers\winpe-nic'
    }

    It 'ignores a file sitting beside the groups' {
        # A readme, a driver-index.json, a stray .inf somebody dropped at the
        # top. None of them is a group, and a name-based filter would have to
        # guess - 'Dell Latitude 7450 v2.1' has a dot in it.
        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Drivers\winpe-nic\e1d68x64.inf' = '[Version]'
            'C:\HDTLab\Share\Drivers\driver-index.json'      = '{}'
            'C:\HDTLab\Share\Drivers\readme.txt'             = 'notes'
        }

        @(Get-HDTDriverGroup -Root $script:root -FileSystem $fs | ForEach-Object { $_.Name }) |
            Should -Be @('winpe-nic')
    }

    It 'answers nothing for a share with no Drivers folder at all' {
        # A SHARE BEING AUTHORED, NOT AN ERROR. New-HDTWorkspace creates the
        # folder, but a window opened on a hand-made share must not refuse to
        # draw its Drivers tab.
        $fs = New-HDTFakeFileSystem -File @{ 'C:\HDTLab\Share\workspace.yaml' = 'schemaVersion: 1' }

        @(Get-HDTDriverGroup -Root $script:root -FileSystem $fs).Count | Should -Be 0
    }

    It 'answers nothing for a Drivers folder with no groups in it' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\HDTLab\Share\Drivers\readme.txt' = 'nothing imported yet' }

        @(Get-HDTDriverGroup -Root $script:root -FileSystem $fs).Count | Should -Be 0
    }
}
