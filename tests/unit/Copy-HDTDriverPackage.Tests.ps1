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

    Context 'the counts a technician actually reads' {

        # 1302 FILES IS NOT THE NUMBER THAT MAPS TO DEVICES. The Latitude 5490
        # pack on the lab share is 126 .inf files, 1302 files and 3.72 GB, and
        # the driver step's log reported only the 1302 - .sys, .cat, .dll and the
        # vendor's documentation. An administrator judging whether the right pack
        # went on needs the .inf count, and judging whether the copy is worth
        # waiting for needs the bytes.

        It 'counts the .inf files apart from the rest' {
            $fs = & $script:newStore

            $answer = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem $fs

            $answer.InfCount | Should -Be 1
            $answer.FileCount | Should -Be 4
        }

        It 'totals the bytes it moved' {
            $fs = & $script:newStore

            $answer = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem $fs

            # '[Version]' + 'binary' + 'catalog' + 'nested' = 9+6+7+6.
            $answer.ByteCount | Should -Be 28
        }
    }

    Context 'saying something while it runs' {

        # 48 SECONDS OF SILENCE ON A REAL DEPLOYMENT. Staging the Latitude pack
        # took 48078 ms and wrote one log line, at the end. The progress card's
        # elapsed clock is derived from the first and last record in the log, so
        # a step that writes nothing does not merely fail to move its own bar -
        # it stops the clock for the whole deployment.
        #
        # THE DENOMINATOR IS EXACT, which is why this one can be honest. The walk
        # knows how many files there are before the copy starts, so the
        # percentage is counted rather than guessed from elapsed time.

        It 'reports progress as it copies' {
            $fs = & $script:newStore
            $seen = New-Object -TypeName System.Collections.ArrayList

            $null = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem $fs `
                -OnProgress { param($P) [void] $seen.Add($P) }

            @($seen).Count | Should -BeGreaterThan 0
        }

        It 'hands the callback a done, a total and a percent' {
            $fs = & $script:newStore
            $seen = New-Object -TypeName System.Collections.ArrayList

            $null = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem $fs `
                -OnProgress { param($P) [void] $seen.Add($P) }

            $last = @($seen)[-1]

            $last.Total | Should -Be 4
            $last.Done | Should -Be 4
            $last.Percent | Should -Be 100
        }

        It 'never reports a percent above a hundred' {
            # The denominator comes from a walk taken before the copy; if the two
            # ever disagreed a bar would run off the end of the card.
            $fs = & $script:newStore
            $seen = New-Object -TypeName System.Collections.ArrayList

            $null = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem $fs `
                -OnProgress { param($P) [void] $seen.Add($P) }

            @($seen | Where-Object { $_.Percent -gt 100 }) | Should -HaveCount 0
            @($seen | Where-Object { $_.Percent -lt 0 }) | Should -HaveCount 0
        }


        # A FILE COUNT IS NOT THE WORK. The caller throttles on what this hands
        # it, so a package whose bytes sit in one firmware blob reported ninety
        # per cent while three per cent of it had moved - and then nothing at all
        # for the copy that was the whole of the duration. Bytes are what a
        # driver package actually costs to stage.
        It 'hands the callback the bytes as well as the files' {
            $fs = & $script:newStore
            $seen = New-Object -TypeName System.Collections.ArrayList

            $result = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem $fs `
                -OnProgress { param($P) [void] $seen.Add($P) }

            $last = @($seen)[-1]

            [long] $last.TotalByte | Should -Be ([long] $result.ByteCount)
            [long] $last.DoneByte | Should -Be ([long] $result.ByteCount)
            [int] $last.BytePercent | Should -Be 100
        }

        # THE ONLY THING A BLOCKING COPY CAN SAY WHILE IT RUNS. IFileSystem.
        # CopyItem takes one file and returns when it is finished; there is no
        # reporting from inside it. So the file that is about to take the time
        # has to be named BEFORE it is copied, or its name reaches the log only
        # once it has stopped taking any.
        It 'calls back before a file as well as after it, and says which' {
            $fs = & $script:newStore
            $seen = New-Object -TypeName System.Collections.ArrayList

            $null = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem $fs `
                -OnProgress { param($P) [void] $seen.Add($P) }

            $starting = @($seen | Where-Object { [string] $_.Phase -eq 'Starting' })
            $copied = @($seen | Where-Object { [string] $_.Phase -eq 'Copied' })

            $starting.Count | Should -Be 4
            $copied.Count | Should -Be 4

            @($seen)[0].Phase | Should -Be 'Starting'
            @($seen)[0].File | Should -Not -BeNullOrEmpty
            [long] @($seen)[0].Length | Should -BeGreaterThan 0

            # NOTHING IS CLAIMED FOR A FILE THAT HAS NOT MOVED YET. A Starting
            # record that counted its own file would put the bar ahead of the
            # work by exactly the file that is about to take the longest.
            [long] @($seen)[0].DoneByte | Should -Be 0
            [int] @($seen)[0].BytePercent | Should -Be 0
        }

        It 'copies exactly the same files whether or not anybody is listening' {
            $quiet = & $script:newStore
            $loud = & $script:newStore

            $a = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem $quiet

            $b = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem $loud -OnProgress { param($P) }

            $b.FileCount | Should -Be $a.FileCount
            $b.ByteCount | Should -Be $a.ByteCount
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
