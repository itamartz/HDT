# Getting drivers ONTO the share: the folder, and the copy that fills it.
#
# THIS IS WHAT A SELECTION PROFILE HAS NOTHING TO TICK WITHOUT. The profile
# editor's tree offers folders the share actually has, so a share whose Drivers\
# is empty is one where a profile can be created and cannot be filled - which is
# exactly what the lab share looked like.
#
# IT IS MDT'S Import Drivers, MINUS THE INDEX. Workbench copies the .inf tree in
# AND builds a catalog from it; the catalog is M5 and is not here. What is here
# is the half that makes a boot image possible: the folders exist, the profile
# can name them, and Add-WindowsDriver -Recurse does the rest.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\HDTLab\Share'

    # A vendor pack as it arrives: an .inf tree with the cabs and sys files
    # beside it, nested, because that is what a Dell WinPE pack looks like.
    function New-HDTTestVendorSource {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param()

        return New-HDTFakeFileSystem -File @{
            'D:\packs\dell\network\e1d68x64.inf' = '[Version]'
            'D:\packs\dell\network\e1d68x64.sys' = 'binary'
            'D:\packs\dell\storage\iaStorAC.inf' = '[Version]'
            'D:\packs\dell\storage\iaStorAC.cat' = 'binary'
            'D:\packs\dell\readme.txt'           = 'not a driver'
        }
    }
}

Describe 'New-HDTDriverFolder' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'New-HDTDriverFolder' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'creates the folder under Drivers' {
        $fs = New-HDTFakeFileSystem

        $result = New-HDTDriverFolder -Root $script:root -Path 'WinPE' -FileSystem $fs -Confirm:$false

        $fs.TestPath('C:\HDTLab\Share\Drivers\WinPE') | Should -BeTrue
        $result.Path | Should -BeExactly 'WinPE'
        $result.FullPath | Should -BeExactly 'C:\HDTLab\Share\Drivers\WinPE'
    }

    # MDT'S Make\Model IS TWO LEVELS AND SO IS A VENDOR'S WinPE PACK. Creating
    # them one at a time would be two clicks for one idea.
    It 'creates a nested folder in one call' {
        $fs = New-HDTFakeFileSystem

        $null = New-HDTDriverFolder -Root $script:root -Path 'Dell\Latitude 7450' -FileSystem $fs -Confirm:$false

        $fs.TestPath('C:\HDTLab\Share\Drivers\Dell\Latitude 7450') | Should -BeTrue
    }

    # A SHARE WHOSE Drivers\ IS MISSING ENTIRELY IS THE LAB SHARE. It predates
    # the code that creates it, and the first folder anybody adds has to work.
    It 'creates Drivers itself when the share has not got one' {
        $fs = New-HDTFakeFileSystem

        $null = New-HDTDriverFolder -Root $script:root -Path 'WinPE' -FileSystem $fs -Confirm:$false

        $fs.TestPath('C:\HDTLab\Share\Drivers') | Should -BeTrue
    }

    It 'says so rather than failing when the folder is already there' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\HDTLab\Share\Drivers\WinPE\e.inf' = '[Version]' }

        $result = New-HDTDriverFolder -Root $script:root -Path 'WinPE' -FileSystem $fs -Confirm:$false

        $result.Created | Should -BeFalse
    }

    # THE TRAVERSAL, REFUSED HERE TOO. A folder named '..\..\Windows' would put a
    # directory outside the share and then invite a profile to include it.
    It 'refuses a path that climbs out of the share' {
        $fs = New-HDTFakeFileSystem

        $record = $null
        try { New-HDTDriverFolder -Root $script:root -Path '..\..\Windows' -FileSystem $fs -Confirm:$false | Out-Null }
        catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $fs.GetOperationName() | Should -Not -Contain 'CreateDirectory'
    }

    It 'refuses a rooted path' {
        $fs = New-HDTFakeFileSystem

        { New-HDTDriverFolder -Root $script:root -Path 'C:\Windows\System32' -FileSystem $fs -Confirm:$false } |
            Should -Throw
    }

    It 'supports ShouldProcess, because it writes to the share' {
        (Get-Command -Name 'New-HDTDriverFolder').Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It 'creates nothing under -WhatIf' {
        $fs = New-HDTFakeFileSystem

        $null = New-HDTDriverFolder -Root $script:root -Path 'WinPE' -FileSystem $fs -WhatIf

        $fs.TestPath('C:\HDTLab\Share\Drivers\WinPE') | Should -BeFalse
    }
}

Describe 'Remove-HDTDriverFolder' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Remove-HDTDriverFolder' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'removes the folder it was given' {
        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Drivers\WinPE\Dell\pack.cab' = 'binary'
            'C:\HDTLab\Share\Drivers\WinPE\HP\e.inf'      = '[Version]'
        }

        $result = Remove-HDTDriverFolder -Root $script:root -Path 'WinPE\Dell' -FileSystem $fs -Confirm:$false

        $result.Removed | Should -BeTrue
        $fs.TestPath('C:\HDTLab\Share\Drivers\WinPE\Dell') | Should -BeFalse
    }

    It 'leaves the folders beside it alone' {
        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Drivers\WinPE\Dell\pack.cab' = 'binary'
            'C:\HDTLab\Share\Drivers\WinPE\HP\e.inf'      = '[Version]'
        }

        $null = Remove-HDTDriverFolder -Root $script:root -Path 'WinPE\Dell' -FileSystem $fs -Confirm:$false

        $fs.TestPath('C:\HDTLab\Share\Drivers\WinPE\HP\e.inf') | Should -BeTrue
    }

    # THE ONE THAT MATTERS. 'Delete Drivers\' is a keystroke away from "delete
    # this vendor folder" and would take every pack on the share with it.
    It 'refuses the driver store itself' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\HDTLab\Share\Drivers\WinPE\e.inf' = '[Version]' }

        { Remove-HDTDriverFolder -Root $script:root -Path '\' -FileSystem $fs -Confirm:$false } |
            Should -Throw

        $fs.TestPath('C:\HDTLab\Share\Drivers\WinPE\e.inf') | Should -BeTrue
    }

    It 'refuses a path that climbs out of the store' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\HDTLab\Share\Drivers\WinPE\e.inf' = '[Version]' }

        { Remove-HDTDriverFolder -Root $script:root -Path '..\..\Windows' -FileSystem $fs -Confirm:$false } |
            Should -Throw

        $fs.GetOperationName() | Should -Not -Contain 'RemoveItem'
    }

    It 'refuses a rooted path' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\HDTLab\Share\Drivers\WinPE\e.inf' = '[Version]' }

        { Remove-HDTDriverFolder -Root $script:root -Path 'C:\Windows\System32' -FileSystem $fs -Confirm:$false } |
            Should -Throw

        $fs.GetOperationName() | Should -Not -Contain 'RemoveItem'
    }

    It 'says so rather than failing when the folder is already gone' {
        $fs = New-HDTFakeFileSystem

        (Remove-HDTDriverFolder -Root $script:root -Path 'WinPE\Gone' -FileSystem $fs -Confirm:$false).Removed |
            Should -BeFalse
    }

    It 'removes nothing under -WhatIf' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\HDTLab\Share\Drivers\WinPE\e.inf' = '[Version]' }

        $null = Remove-HDTDriverFolder -Root $script:root -Path 'WinPE' -FileSystem $fs -WhatIf

        $fs.TestPath('C:\HDTLab\Share\Drivers\WinPE\e.inf') | Should -BeTrue
    }

    It 'confirms by default, because there is no undo but the vendor download' {
        $meta = (Get-Command -Name 'Remove-HDTDriverFolder').ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }

        [string] $meta.ConfirmImpact | Should -BeExactly 'High'
    }
}

Describe 'Import-HDTDriver' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Import-HDTDriver' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'copies the vendor tree into the folder it was given' {
        $fs = New-HDTTestVendorSource

        $null = Import-HDTDriver -Root $script:root -Path 'WinPE\Dell WinPE 11 x64' `
            -Source 'D:\packs\dell' -FileSystem $fs -Confirm:$false

        $fs.TestPath('C:\HDTLab\Share\Drivers\WinPE\Dell WinPE 11 x64\network\e1d68x64.inf') | Should -BeTrue
        $fs.TestPath('C:\HDTLab\Share\Drivers\WinPE\Dell WinPE 11 x64\storage\iaStorAC.inf') | Should -BeTrue
    }

    # THE WHOLE TREE, NOT THE .inf FILES. A driver is an .inf AND the .sys, .cat
    # and .dll beside it; copying the .inf alone produces a folder DISM refuses.
    It 'brings everything beside the inf, because a lone inf installs nothing' {
        $fs = New-HDTTestVendorSource

        $null = Import-HDTDriver -Root $script:root -Path 'Dell' -Source 'D:\packs\dell' `
            -FileSystem $fs -Confirm:$false

        $fs.TestPath('C:\HDTLab\Share\Drivers\Dell\network\e1d68x64.sys') | Should -BeTrue
        $fs.TestPath('C:\HDTLab\Share\Drivers\Dell\storage\iaStorAC.cat') | Should -BeTrue
    }

    # IT COUNTS THE .inf FILES, which is the number an administrator recognises
    # a pack by - and the number the console shows on the row.
    It 'reports how many drivers arrived' {
        $fs = New-HDTTestVendorSource

        $result = Import-HDTDriver -Root $script:root -Path 'Dell' -Source 'D:\packs\dell' `
            -FileSystem $fs -Confirm:$false

        $result.DriverCount | Should -Be 2
        $result.Path | Should -BeExactly 'Dell'
    }

    # A SOURCE WITH NO .inf IN IT IS ALMOST ALWAYS THE WRONG FOLDER - somebody
    # picked the download rather than the extracted pack - so it is said out
    # loud rather than left as a silently empty driver folder.
    # IT REFUSES RATHER THAN WARNS, and that is a deliberate change from the
    # first version. A warning is invisible in a WPF app: the console imported a
    # folder holding nothing but a Dell .cab, said nothing an administrator saw,
    # and left a driver folder that a selection profile will happily include and
    # a boot image build will happily inject nothing from - found on a bench.
    It 'refuses a source that holds no drivers at all' {
        $fs = New-HDTFakeFileSystem -File @{ 'D:\packs\empty\readme.txt' = 'nothing here' }

        $record = $null
        try {
            Import-HDTDriver -Root $script:root -Path 'Empty' -Source 'D:\packs\empty' `
                -FileSystem $fs -Confirm:$false | Out-Null
        } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        [string] $record.Exception.Message | Should -BeLike '*no .inf*'
    }

    It 'copies nothing when it refuses' {
        $fs = New-HDTFakeFileSystem -File @{ 'D:\packs\empty\readme.txt' = 'nothing here' }

        $record = $null
        try {
            Import-HDTDriver -Root $script:root -Path 'Empty' -Source 'D:\packs\empty' `
                -FileSystem $fs -Confirm:$false | Out-Null
        } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $fs.TestPath('C:\HDTLab\Share\Drivers\Empty\readme.txt') | Should -BeFalse
    }

    # DELL AND HP SHIP WinPE PACKS AS A .cab, and pointing at the download rather
    # than the extracted folder is the commonest way to get this wrong - so the
    # refusal names what it DID find and says what to do about it, instead of
    # only saying what it wanted.
    It 'names the archive it found, because that is the actual mistake' {
        $fs = New-HDTFakeFileSystem -File @{
            'D:\packs\dell-winpe\WinPE11.0-Drivers-A10-XCXDW.cab' = 'binary'
        }

        $record = $null
        try {
            Import-HDTDriver -Root $script:root -Path 'WinPE\Dell' -Source 'D:\packs\dell-winpe' `
                -FileSystem $fs -Confirm:$false | Out-Null
        } catch { $record = $_ }

        [string] $record.Exception.Message | Should -BeLike '*WinPE11.0-Drivers-A10-XCXDW.cab*'
        [string] $record.Exception.Message | Should -BeLike '*expand*'
    }

    It 'refuses a source that is not there' {
        $fs = New-HDTFakeFileSystem

        { Import-HDTDriver -Root $script:root -Path 'Dell' -Source 'D:\nope' `
                -FileSystem $fs -Confirm:$false } | Should -Throw
    }

    It 'refuses a destination that climbs out of the share' {
        $fs = New-HDTTestVendorSource

        { Import-HDTDriver -Root $script:root -Path '..\..\Windows' -Source 'D:\packs\dell' `
                -FileSystem $fs -Confirm:$false } | Should -Throw
    }

    It 'copies nothing under -WhatIf' {
        $fs = New-HDTTestVendorSource

        $null = Import-HDTDriver -Root $script:root -Path 'Dell' -Source 'D:\packs\dell' `
            -FileSystem $fs -WhatIf

        $fs.TestPath('C:\HDTLab\Share\Drivers\Dell\network\e1d68x64.inf') | Should -BeFalse
    }

    # WHAT DELL ACTUALLY SHIPS. The console imported one of these, copied the
    # cab into the driver store, warned into a stream no window shows, and left
    # a folder a profile would tick and a build would inject nothing from.
    It 'expands a Dell cab instead of copying it' {
        $fs = New-HDTFakeFileSystem -File @{
            'D:\packs\WinPE11.0-Drivers-A10-XCXDW.cab' = 'binary'
        }

        # The expansion is what puts .inf files there, so the fake has to do the
        # one thing expand.exe would: leave a tree behind.
        $process = New-HDTFakeProcessService
        $process | Add-Member -MemberType ScriptMethod -Name Start -Force -Value {
            param([string] $FilePath, [string] $Argument, [string] $WorkingDirectory, [int] $TimeoutMillisecond)

            $this.Record('Start', @($FilePath, $Argument, $WorkingDirectory, $TimeoutMillisecond))
            $script:expandInto = $WorkingDirectory

            return [pscustomobject] @{ ExitCode = 0 }
        }

        # Seed what the expansion would produce, at the destination.
        $fs.WriteAllText('C:\HDTLab\Share\Drivers\WinPE\Dell\network\e1d68x64.inf', '[Version]')

        $result = Import-HDTDriver -Root $script:root -Path 'WinPE\Dell' `
            -Source 'D:\packs\WinPE11.0-Drivers-A10-XCXDW.cab' `
            -FileSystem $fs -Process $process -Confirm:$false

        $call = @($process.Operations | Where-Object { $_.Operation -eq 'Start' })[0]

        [string] $call.Arguments[0] | Should -BeExactly 'expand.exe'
        [string] $call.Arguments[1] | Should -BeLike '-F:*WinPE11.0-Drivers-A10-XCXDW.cab*'
        $result.DriverCount | Should -Be 1
    }

    # THE .cab ITSELF IS NEVER LEFT IN THE STORE. Copying it in was the bug.
    It 'leaves the archive out of the driver store' {
        $fs = New-HDTFakeFileSystem -File @{ 'D:\packs\dell.cab' = 'binary' }

        $process = New-HDTFakeProcessService
        $process | Add-Member -MemberType ScriptMethod -Name Start -Force -Value {
            param([string] $FilePath, [string] $Argument, [string] $WorkingDirectory, [int] $TimeoutMillisecond)
            $this.Record('Start', @($FilePath, $Argument, $WorkingDirectory, $TimeoutMillisecond))
            return [pscustomobject] @{ ExitCode = 0 }
        }

        $fs.WriteAllText('C:\HDTLab\Share\Drivers\Dell\e.inf', '[Version]')

        $null = Import-HDTDriver -Root $script:root -Path 'Dell' -Source 'D:\packs\dell.cab' `
            -FileSystem $fs -Process $process -Confirm:$false

        $fs.TestPath('C:\HDTLab\Share\Drivers\Dell\dell.cab') | Should -BeFalse
    }

    # AN ARCHIVE THAT IS NOT A DRIVER PACK LEAVES NOTHING BEHIND. A firmware
    # bundle expands to no .inf, and a folder left there would be ticked.
    It 'removes the folder when an archive expands to no drivers' {
        $fs = New-HDTFakeFileSystem -File @{ 'D:\packs\firmware.cab' = 'binary' }

        $process = New-HDTFakeProcessService
        $process | Add-Member -MemberType ScriptMethod -Name Start -Force -Value {
            param([string] $FilePath, [string] $Argument, [string] $WorkingDirectory, [int] $TimeoutMillisecond)
            $this.Record('Start', @($FilePath, $Argument, $WorkingDirectory, $TimeoutMillisecond))
            return [pscustomobject] @{ ExitCode = 0 }
        }

        $record = $null
        try {
            Import-HDTDriver -Root $script:root -Path 'Firmware' -Source 'D:\packs\firmware.cab' `
                -FileSystem $fs -Process $process -Confirm:$false | Out-Null
        } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        [string] $record.Exception.Message | Should -BeLike '*Nothing was left on the share*'
        $fs.TestPath('C:\HDTLab\Share\Drivers\Firmware') | Should -BeFalse
    }

    # THE POINT OF ALL OF IT: after an import, the profile editor's tree has
    # something to tick, and a profile can name it.
    It 'leaves a folder a selection profile can include' {
        $fs = New-HDTTestVendorSource

        $null = Import-HDTDriver -Root $script:root -Path 'WinPE\Dell WinPE 11 x64' `
            -Source 'D:\packs\dell' -FileSystem $fs -Confirm:$false

        @(Get-HDTShareContentFolder -Root $script:root -FileSystem $fs |
                ForEach-Object { $_.Path }) | Should -Contain 'Drivers\WinPE\Dell WinPE 11 x64'

        { New-HDTSelectionProfile -Line ([string[]] @()) -Id 'dell' -Name 'Dell' `
                -Include 'Drivers\WinPE\Dell WinPE 11 x64' `
                -Root $script:root -FileSystem $fs } | Should -Not -Throw
    }
}
