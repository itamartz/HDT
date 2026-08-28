# A driver package, copied onto the machine rather than injected into it.
#
# ELEVEN MINUTES, MEASURED. On a Latitude 5490 the PnP fallback injected 82
# drivers in 649 seconds - a median of 9.0s each - because every
# Add-WindowsDriver call opens the offline image at W:\, adds one driver and
# COMMITS it. Eighty-two open-and-commit cycles, which is what a technician
# watched as "the dismount running over and over". Nine seconds is not the cost
# of copying an .inf; it is the cost of the servicing session round it.
#
# SO HDT COPIES, WHICH IS WHAT MDT DOES. ZTIDrivers puts the matched packages
# under the OS volume and lets Windows install them from there at first boot;
# the answer file's DriverPaths is what points PnP at the folder. A file copy of
# the same 82 packages is seconds.
#
# AND IT IS THE SHAPE THE NEXT VERSION NEEDS. Driver folders are becoming WIM
# packages expanded onto the target - the destination is identical, only the
# source changes - so this is the step that survives that change and per-driver
# DISM injection is the one that does not.
#
# THE WHOLE FOLDER, NOT THE .inf. A driver is an .inf plus the .sys, .cat and
# .dll files beside it; copying the .inf alone stages something Windows cannot
# install and says nothing about it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:newStore = {
        New-HDTFakeFileSystem -File @{
            'Z:\Deploy\Drivers\Win11\Dell\Net\net.inf'          = '[Version]'
            'Z:\Deploy\Drivers\Win11\Dell\Net\net.sys'          = 'binary'
            'Z:\Deploy\Drivers\Win11\Dell\Net\net.cat'          = 'catalog'
            'Z:\Deploy\Drivers\Win11\Dell\Net\x64\extra.dll'    = 'nested'
            'Z:\Deploy\Drivers\Win11\Dell\Video\video.inf'      = '[Version]'
        }
    }
}

Describe 'Copy-HDTDriverPackage' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Copy-HDTDriverPackage' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'what it copies' {

        It 'copies every file in the package, not only the inf' {
            $fs = & $script:newStore

            $null = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem $fs

            foreach ($leaf in 'net.inf', 'net.sys', 'net.cat') {
                $fs.TestPath(('W:\Drivers\Win11\Dell\Net\{0}' -f $leaf)) | Should -BeTrue -Because "$leaf is part of the package"
            }
        }

        It 'keeps the folders below it' {
            # A DRIVER'S ARCHITECTURE SUBFOLDER IS PART OF THE PACKAGE. Flatten
            # it and the .inf names a file that is no longer where it says.
            $fs = & $script:newStore

            $null = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem $fs

            $fs.TestPath('W:\Drivers\Win11\Dell\Net\x64\extra.dll') | Should -BeTrue
        }

        It 'copies the content, not just the name' {
            $fs = & $script:newStore

            $null = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem $fs

            [string] $fs.ReadAllText('W:\Drivers\Win11\Dell\Net\net.inf') | Should -BeExactly '[Version]'
        }

        It 'takes nothing from a sibling folder' {
            $fs = & $script:newStore

            $null = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem $fs

            $fs.TestPath('W:\Drivers\Win11\Dell\Video\video.inf') | Should -BeFalse
        }

        It 'answers with how many files it copied' {
            # THE STEP LOGS THIS. A package that copied nothing is a package
            # that will not install, and the count is what says so.
            $fs = & $script:newStore

            $answer = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem $fs

            $answer.FileCount | Should -Be 4
        }
    }

    Context 'what it refuses' {

        It 'refuses a source that is not there' {
            # RATHER THAN STAGING NOTHING QUIETLY. A driver folder that moved
            # between the match and the copy is a machine that deploys without
            # its network card and says so nowhere.
            $fs = & $script:newStore

            { Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Nobody' `
                    -Destination 'W:\Drivers\Nobody' -FileSystem $fs } | Should -Throw
        }
    }
}
