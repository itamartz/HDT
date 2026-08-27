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
        param([string] $Kind, [string] $Archive, [string] $Destination, [string] $Vendor = '')

        $module = Get-Module -Name Hephaestus
        return & $module {
            param($K, $A, $D, $V)
            Get-HDTDriverExpandCommand -Kind $K -Archive $A -Destination $D -Vendor $V
        } $Kind $Archive $Destination $Vendor
    }

    # THE REAL FILE, AS THE USER DOWNLOADED IT. Captured from
    # Latitude-5420-X8RTR_Win11_1.0_A13.exe - 2.38 GB, and the version block is
    # the only thing that distinguishes it from an HP SoftPaq before it is run.
    $script:dellVersionInfo = @{
        CompanyName     = 'Dell Inc.'
        ProductName     = 'Command Deploy Driver Pack for Latitude , 1.0, A13'
        FileDescription = 'Dell Update Package: Command Deploy Driver Pack for Latitude , 1.0, A13'
        FileVersion     = '1.0'
    }

    $script:hpVersionInfo = @{
        CompanyName     = 'HP Inc.'
        ProductName     = 'HP Softpaq'
        FileDescription = 'HP Softpaq Self-Extracting Package'
        FileVersion     = '1.0'
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

    # THE DEFECT, AS THE USER HIT IT ON 2026-08-27. Every .exe was handed HP's
    # switches under a comment claiming "Dell's own .exe packs accept the same
    # shape". Nobody had run one. Verified against the real 2.38 GB
    # Latitude-5420 pack: '/s /e=<path>' exits 0 and extracts 269 .inf files in
    # 86 seconds, and HP's shape is not what it takes.
    It 'runs a Dell Update Package with Dell''s own switches' {
        $run = & $script:command 'Exe' 'D:\p\Latitude-5420-X8RTR_Win11_1.0_A13.exe' 'C:\out' 'Dell'

        $run.FilePath | Should -BeExactly 'D:\p\Latitude-5420-X8RTR_Win11_1.0_A13.exe'
        $run.Argument | Should -BeExactly '/s /e="C:\out"'
    }

    It 'still runs an HP SoftPaq with HP''s switches when the vendor is known' {
        (& $script:command 'Exe' 'D:\p\sp150000.exe' 'C:\out' 'Hp').Argument |
            Should -BeExactly '/s /e /f"C:\out"'
    }

    # AN UNKNOWN VENDOR KEEPS THE OLD BEHAVIOUR rather than guessing Dell,
    # because most .exe driver packs in the wild are SoftPaqs and a change of
    # default would be a silent regression for every share that works today.
    # What protects an unknown pack is not the guess: it is that the import runs
    # off the UI thread, under a timeout, and that what lands on disk decides
    # rather than the exit code.
    It 'falls back to the SoftPaq shape when the vendor cannot be read' {
        (& $script:command 'Exe' 'D:\p\mystery.exe' 'C:\out' '').Argument |
            Should -BeExactly '/s /e /f"C:\out"'
    }
}

Describe 'Get-HDTDriverSourceKind vendor detection' {

    It 'reads Dell out of the version block of a real Dell pack' {
        $fs = New-HDTFakeFileSystem -File @{ 'D:\p\Latitude-5420-X8RTR_Win11_1.0_A13.exe' = 'binary' }
        $fs.SeedVersionInfo('D:\p\Latitude-5420-X8RTR_Win11_1.0_A13.exe', $script:dellVersionInfo)

        $kind = & $script:ask 'D:\p\Latitude-5420-X8RTR_Win11_1.0_A13.exe' $fs

        $kind.Kind | Should -BeExactly 'Exe'
        $kind.Vendor | Should -BeExactly 'Dell'
    }

    It 'reads HP out of the version block of a SoftPaq' {
        $fs = New-HDTFakeFileSystem -File @{ 'D:\p\sp150000.exe' = 'binary' }
        $fs.SeedVersionInfo('D:\p\sp150000.exe', $script:hpVersionInfo)

        (& $script:ask 'D:\p\sp150000.exe' $fs).Vendor | Should -BeExactly 'Hp'
    }

    It 'answers an empty vendor for an exe carrying no version block' {
        $fs = New-HDTFakeFileSystem -File @{ 'D:\p\mystery.exe' = 'binary' }

        (& $script:ask 'D:\p\mystery.exe' $fs).Vendor | Should -BeExactly ''
    }

    It 'leaves a cab with no vendor, because a cab needs none' {
        # expand.exe takes the same switches whoever made the cab, so reading a
        # version block here would be work with nothing behind it.
        $fs = New-HDTFakeFileSystem -File @{ 'D:\p\dell.cab' = 'binary' }

        (& $script:ask 'D:\p\dell.cab' $fs).Vendor | Should -BeExactly ''
    }

    It 'finds the vendor of an archive discovered inside a folder' {
        # THE PATH THE CONSOLE ACTUALLY TAKES. Its Import Drivers menu opens a
        # FOLDER picker, so the .exe is never chosen directly - it is found one
        # level down, and the vendor has to survive that recursion.
        $fs = New-HDTFakeFileSystem -File @{ 'D:\Latitude 5420\Latitude-5420-X8RTR_Win11_1.0_A13.exe' = 'binary' }
        $fs.SeedVersionInfo('D:\Latitude 5420\Latitude-5420-X8RTR_Win11_1.0_A13.exe', $script:dellVersionInfo)

        $kind = & $script:ask 'D:\Latitude 5420' $fs

        $kind.Kind | Should -BeExactly 'Exe'
        $kind.Vendor | Should -BeExactly 'Dell'
    }
}
