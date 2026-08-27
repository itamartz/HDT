# Which models a share can dress, and which it cannot.
#
# THE POINT IS TO ASK BEFORE THE DEPLOYMENT, NOT AFTER. A model with no driver
# group deploys perfectly well - it just deploys without its network card, and
# that is discovered by somebody standing in front of the machine.
#
# AN EMPTY FOLDER IS NOT COVERAGE, and it is the commonest way this goes wrong:
# somebody made the folder, the import failed or was never run, and every tree in
# the console shows a group that injects nothing. It has to read differently from
# a folder nobody created, because the two want different fixes.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\HDTLab\Share'

    # The real make and model off the lab hardware: 'Dell inc' is
    # Win32_ComputerSystem.Manufacturer verbatim, spacing and casing included -
    # which is the point, because the folder is named after whatever the machine
    # reports and not after what somebody would have typed.
    $script:covered = 'Dell Pro 3 16 P316265'
    $script:bare = 'Latitude 5420'
    $script:missing = 'OptiPlex 7010'

    $script:newStore = {
        New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Drivers\Win11\Dell inc\Dell Pro 3 16 P316265\net.inf' = '[Version]'
        } -Directory @(
            # PRESENT AND EMPTY - the case that looks like success in a tree.
            'C:\HDTLab\Share\Drivers\Win11\Dell inc\Latitude 5420'
        )
    }
}

Describe 'Get-HDTDriverCoverage' {

    It 'covers a model whose group holds drivers' {
        $row = @(Get-HDTDriverCoverage -Root $script:root -Make 'Dell inc' `
                -Model @($script:covered) -FileSystem (& $script:newStore))[0]

        $row.Present | Should -BeTrue
        $row.DriverCount | Should -BeGreaterThan 0
        $row.Covered | Should -BeTrue
    }

    It 'does not cover a model whose group is there but empty' {
        $row = @(Get-HDTDriverCoverage -Root $script:root -Make 'Dell inc' `
                -Model @($script:bare) -FileSystem (& $script:newStore))[0]

        # PRESENT AND NOT COVERED, which is a different problem from absent and
        # wants a different fix - run the import, rather than create the folder.
        $row.Present | Should -BeTrue
        $row.DriverCount | Should -Be 0
        $row.Covered | Should -BeFalse
    }

    It 'does not cover a model with no group at all' {
        $row = @(Get-HDTDriverCoverage -Root $script:root -Make 'Dell inc' `
                -Model @($script:missing) -FileSystem (& $script:newStore))[0]

        $row.Present | Should -BeFalse
        $row.Covered | Should -BeFalse
    }

    It 'expands the same pattern a rule would, so it looks where the deployment will' {
        $row = @(Get-HDTDriverCoverage -Root $script:root -Make 'Dell inc' `
                -Model @($script:covered) -FileSystem (& $script:newStore))[0]

        $row.Group | Should -BeExactly 'Win11\Dell inc\Dell Pro 3 16 P316265'
    }

    It 'takes a pattern of its own, because the store is the administrator''s shape' {
        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Drivers\Dell Pro 3 16 P316265\net.inf' = '[Version]'
        }

        $row = @(Get-HDTDriverCoverage -Root $script:root -Model @($script:covered) `
                -Pattern '%HDTModel%' -FileSystem $fs)[0]

        $row.Covered | Should -BeTrue
    }

    It 'answers a row per model, in the order it was given them' {
        $row = @(Get-HDTDriverCoverage -Root $script:root -Make 'Dell inc' `
                -Model @($script:covered, $script:bare, $script:missing) `
                -FileSystem (& $script:newStore))

        $row.Count | Should -Be 3
        $row[0].Model | Should -BeExactly $script:covered
        $row[2].Model | Should -BeExactly $script:missing
    }

    It 'answers nothing for an empty fleet rather than throwing' {
        @(Get-HDTDriverCoverage -Root $script:root -Model @() -FileSystem (& $script:newStore)).Count |
            Should -Be 0
    }

    It 'skips a blank model rather than reporting the whole store as its group' {
        # '' expands to the folder ABOVE the models, which exists and is full of
        # drivers - so a blank row would report itself covered and hide a hole in
        # somebody's inventory.
        @(Get-HDTDriverCoverage -Root $script:root -Make 'Dell inc' -Model @('', '   ') `
                -FileSystem (& $script:newStore)).Count | Should -Be 0
    }
}
