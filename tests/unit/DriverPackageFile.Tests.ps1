# Walking a driver package: what is in it, how big it is, and how many of the
# files are the ones that matter.
#
# 1302 FILES IS NOT THE NUMBER A TECHNICIAN WANTS. The Latitude 5490 pack on the
# lab share is 126 .inf files, 1302 files and 3.72 GB - and the driver step's log
# reported only the 1302, which is .sys, .cat, .dll, .exe and vendor
# documentation. The count that maps to DEVICES is the .inf count, and it was the
# one number the log did not have.
#
# IT IS ALSO THE DENOMINATOR. The staging copy ran for 48 seconds in silence
# because nothing knew how many files there were to copy. A pre-walk is cheap -
# directory metadata - and it turns "still working" into "37%".
#
# AND IT IS HOW PART 3 FINDS THE STAGED .inf FILES to cross-match, from the local
# copy on the OS volume rather than back across SMB.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:walk = {
        param([object] $FileSystem, [string] $Path)

        $module = Get-Module -Name Hephaestus
        return @(& $module {
                param($F, $P)
                Get-HDTDriverPackageFile -Path $P -FileSystem $F
            } $FileSystem $Path)
    }
}

Describe 'Get-HDTDriverPackageFile' {

    BeforeEach {
        $script:fs = New-HDTFakeFileSystem -File @{
            'W:\Drivers\Pack\net\e1d.inf'          = 'inf'
            'W:\Drivers\Pack\net\e1d.sys'          = 'syssys'
            'W:\Drivers\Pack\net\e1d.cat'          = 'cat'
            'W:\Drivers\Pack\chipset\deep\a.inf'   = 'a'
            'W:\Drivers\Pack\chipset\deep\a.sys'   = 'aa'
            'W:\Drivers\Pack\readme.txt'           = 'hello'
        }
    }

    It 'finds every file in the tree, however deep' {
        $row = & $script:walk $script:fs 'W:\Drivers\Pack'

        $row.Count | Should -Be 6
    }

    It 'counts the .inf files apart from everything else' {
        # THE NUMBER THAT MAPS TO DEVICES. 1302 files is .sys, .cat, .dll and
        # documentation; 126 .inf files is what Windows reads.
        $row = & $script:walk $script:fs 'W:\Drivers\Pack'

        @($row | Where-Object { $_.IsInf }).Count | Should -Be 2
    }

    It 'recognises an .inf whatever case the vendor shipped it in' {
        $fs = New-HDTFakeFileSystem -File @{ 'W:\P\NET.INF' = 'x'; 'W:\P\a.Inf' = 'y' }

        @((& $script:walk $fs 'W:\P') | Where-Object { $_.IsInf }).Count | Should -Be 2
    }

    It 'totals the bytes' {
        $row = & $script:walk $script:fs 'W:\Drivers\Pack'

        # 'inf' + 'syssys' + 'cat' + 'a' + 'aa' + 'hello' = 3+6+3+1+2+5.
        ($row | Measure-Object -Property Length -Sum).Sum | Should -Be 20
    }

    It 'reports each file relative to the package root, which is the shape it lands in' {
        $row = & $script:walk $script:fs 'W:\Drivers\Pack'

        @($row | ForEach-Object { $_.RelativePath }) | Should -Contain 'chipset\deep\a.inf'
    }

    It 'reports the full path, which is what a parser opens' {
        $row = & $script:walk $script:fs 'W:\Drivers\Pack'

        @($row | ForEach-Object { $_.FullPath }) | Should -Contain 'W:\Drivers\Pack\chipset\deep\a.inf'
    }

    It 'answers nothing for a folder that is not there rather than throwing' {
        # The caller decides whether a missing package is a failure; this is a
        # walk, and a walk of nothing is empty.
        @(& $script:walk $script:fs 'W:\Drivers\Nope') | Should -HaveCount 0
    }

    It 'answers nothing for an empty folder' {
        $fs = New-HDTFakeFileSystem -File @{ 'W:\Other\x.txt' = 'x' }
        $fs.CreateDirectory('W:\Empty')

        @(& $script:walk $fs 'W:\Empty') | Should -HaveCount 0
    }
}
