# What an import source IS, and what expands it.
#
# VENDORS DO NOT SHIP .inf TREES. Dell's WinPE packs arrive as a .cab; HP's
# arrive as a self-extracting SoftPaq .exe. Pointing an import at the download
# is not a mistake somebody makes once - it is the ordinary case, and the first
# version of Import-HDTDriver refused it as "no .inf files", which was true and
# useless: a Dell cab sat in the driver store, a profile would have ticked it,
# and the boot image would have injected nothing.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:ask = {
        param([string] $Path, [object] $FileSystem)

        $module = Get-Module -Name Hephaestus
        return & $module {
            param($P, $F)
            Get-HDTDriverSourceKind -Path $P -FileSystem $F
        } $Path $FileSystem
    }

    $script:command = {
        param([string] $Kind, [string] $Archive, [string] $Destination)

        $module = Get-Module -Name Hephaestus
        return & $module {
            param($K, $A, $D)
            Get-HDTDriverExpandCommand -Kind $K -Archive $A -Destination $D
        } $Kind $Archive $Destination
    }
}

Describe 'Get-HDTDriverSourceKind' {

    It 'calls an expanded tree a folder' {
        $fs = New-HDTFakeFileSystem -File @{ 'D:\p\dell\network\e.inf' = '[Version]' }

        (& $script:ask 'D:\p\dell' $fs).Kind | Should -BeExactly 'Folder'
    }

    # THE ONE THAT WAS REFUSED. A Dell WinPE pack, as downloaded.
    It 'recognises a cab picked directly' {
        $fs = New-HDTFakeFileSystem -File @{ 'D:\p\WinPE11.0-Drivers-A10-XCXDW.cab' = 'binary' }

        $kind = & $script:ask 'D:\p\WinPE11.0-Drivers-A10-XCXDW.cab' $fs

        $kind.Kind | Should -BeExactly 'Cab'
        $kind.Archive | Should -BeExactly 'D:\p\WinPE11.0-Drivers-A10-XCXDW.cab'
    }

    It 'recognises an HP SoftPaq' {
        $fs = New-HDTFakeFileSystem -File @{ 'D:\p\sp150000.exe' = 'binary' }

        (& $script:ask 'D:\p\sp150000.exe' $fs).Kind | Should -BeExactly 'Exe'
    }

    # A BROWSE DIALOG MAKES PICKING THE FOLDER THE EASIER GESTURE, and somebody
    # who downloaded a SoftPaq into its own folder meant the SoftPaq.
    It 'looks inside a folder holding one archive and nothing else' {
        $fs = New-HDTFakeFileSystem -File @{ 'D:\p\dell\WinPE11.0-Drivers.cab' = 'binary' }

        $kind = & $script:ask 'D:\p\dell' $fs

        $kind.Kind | Should -BeExactly 'Cab'
        $kind.Archive | Should -BeExactly 'D:\p\dell\WinPE11.0-Drivers.cab'
    }

    # AN EXPANDED PACK OFTEN KEEPS ITS ORIGINAL .cab. Expanding again would nest
    # a second copy inside the first.
    It 'prefers the tree when an archive sits beside it' {
        $fs = New-HDTFakeFileSystem -File @{
            'D:\p\dell\network\e.inf' = '[Version]'
            'D:\p\dell\original.cab'  = 'binary'
        }

        (& $script:ask 'D:\p\dell' $fs).Kind | Should -BeExactly 'Folder'
    }

    It 'will not guess between two archives' {
        $fs = New-HDTFakeFileSystem -File @{
            'D:\p\both\one.cab' = 'binary'
            'D:\p\both\two.exe' = 'binary'
        }

        (& $script:ask 'D:\p\both' $fs).Kind | Should -BeExactly 'Empty'
    }

    It 'calls a folder with nothing useful in it empty' {
        $fs = New-HDTFakeFileSystem -File @{ 'D:\p\empty\readme.txt' = 'nothing' }

        (& $script:ask 'D:\p\empty' $fs).Kind | Should -BeExactly 'Empty'
    }

    It 'calls a source that is not there empty' {
        (& $script:ask 'D:\p\gone' (New-HDTFakeFileSystem)).Kind | Should -BeExactly 'Empty'
    }
}

Describe 'Get-HDTDriverExpandCommand' {

    # '-F:*' IS THE PART PEOPLE MISS. Without it expand copies the cab's first
    # file and stops, which looks like a successful import of one driver.
    It 'expands a cab with every file in it' {
        $run = & $script:command 'Cab' 'D:\p\dell.cab' 'C:\S\Drivers\WinPE\Dell'

        $run.FilePath | Should -BeExactly 'expand.exe'
        $run.Argument | Should -BeExactly '-F:* "D:\p\dell.cab" "C:\S\Drivers\WinPE\Dell"'
    }

    # THE PATH IS ATTACHED TO /f WITH NO SPACE - HP's own convention, and the
    # reason a naive '/f <path>' extracts to the current directory instead.
    It 'runs a SoftPaq with HP''s own switches' {
        $run = & $script:command 'Exe' 'D:\p\sp150000.exe' 'C:\out'

        $run.FilePath | Should -BeExactly 'D:\p\sp150000.exe'
        $run.Argument | Should -BeExactly '/s /e /f"C:\out"'
    }

    It 'names no process for a zip, which the file system expands' {
        (& $script:command 'Zip' 'D:\p\pack.zip' 'C:\out').FilePath | Should -BeExactly ''
    }
}
