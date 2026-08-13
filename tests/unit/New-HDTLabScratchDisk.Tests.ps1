# The scratch VHDX helper the integration suite mounts and writes to, asserted
# through its refusals - so this file mounts nothing and creates nothing.
#
# THE ASSERTION THAT MATTERS is 'refuses to return a disk that is the system
# disk'. An integration test that was handed the developer's own disk would
# clear it. The guard is proven by INJECTING A DISK ROW rather than by mounting
# anything, which is why Assert-HDTLabScratchDisk exists as its own command.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    # This host's own disk, as tests/fixtures/disk/host-nvme-disk.json captured
    # it: IsBoot and IsSystem both true. Read off the fixture rather than
    # retyped, so the shape cannot drift from the real projection.
    #
    # ASSIGNED FIRST, WRAPPED SECOND (helpers README F12). Under Windows
    # PowerShell 5.1 ConvertFrom-Json does not enumerate a top-level array, so
    # @(ConvertFrom-Json ...)[0] is THE WHOLE ARRAY rather than the first row -
    # and an Object[] has no IsBoot property, so the guard saw nothing to refuse
    # and these tests passed under pwsh 7 while failing under 5.1. Caught by the
    # dual-engine run, which is exactly what it is for.
    $captured = ConvertFrom-Json ([System.IO.File]::ReadAllText((Join-Path -Path $script:repoRoot `
                    -ChildPath 'tests/fixtures/disk/host-nvme-disk.json')))
    $script:hostDisk = @($captured)[0]

    $script:scratchRow = [pscustomobject] @{
        Number = 3; FriendlyName = 'Msft Virtual Disk'; SerialNumber = 'FIXTURE-SERIAL-0002'
        SizeBytes = 42949672960; BusType = 'File Backed Virtual'; PartitionStyle = 'RAW'
        IsBoot = $false; IsSystem = $false; IsReadOnly = $false; IsOffline = $false
        OperationalStatus = 'Online'
    }
}

Describe 'Assert-HDTLabScratchDisk' {

    It 'is exported by HDTTestTools' {
        Get-Command -Name 'Assert-HDTLabScratchDisk' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'refuses to return a disk that is the boot disk' {
        { Assert-HDTLabScratchDisk -Disk $script:hostDisk } | Should -Throw '*boot*'
    }

    It 'refuses to return a disk that is the system disk' {
        $row = [pscustomobject] @{
            Number = 0; IsBoot = $false; IsSystem = $true; SizeBytes = 42949672960
            BusType = 'NVMe'; FriendlyName = 'Not a scratch disk'
        }

        { Assert-HDTLabScratchDisk -Disk $row } | Should -Throw '*system*'
    }

    It 'names the disk it refused' {
        { Assert-HDTLabScratchDisk -Disk $script:hostDisk } | Should -Throw '*SAMSUNG*'
    }

    It 'accepts a mounted scratch VHDX' {
        { Assert-HDTLabScratchDisk -Disk $script:scratchRow } | Should -Not -Throw
    }

    It 'refuses a null disk rather than treating it as safe' {
        # A mount that misbehaved yields no row at all, and "no row" must not
        # read as "not the system disk".
        { Assert-HDTLabScratchDisk -Disk $null } | Should -Throw
    }
}

Describe 'New-HDTLabScratchDisk' {

    It 'is exported by HDTTestTools' {
        Get-Command -Name 'New-HDTLabScratchDisk' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'refuses a path outside C:\HDTLab' {
        { New-HDTLabScratchDisk -Path 'C:\Temp\scratch.vhdx' -SizeByte 42949672960 } |
            Should -Throw '*C:\HDTLab*'
    }

    It 'refuses a path that is not a .vhdx' {
        { New-HDTLabScratchDisk -Path 'C:\HDTLab\scratch\integration\scratch.vhd' -SizeByte 42949672960 } |
            Should -Throw '*vhdx*'
    }

    It 'refuses a size under 1GB' {
        { New-HDTLabScratchDisk -Path 'C:\HDTLab\scratch\integration\scratch.vhdx' -SizeByte 536870912 } |
            Should -Throw '*1*GB*'
    }

    It 'names the lab safety rule it is enforcing' {
        { New-HDTLabScratchDisk -Path 'C:\Temp\scratch.vhdx' -SizeByte 42949672960 } |
            Should -Throw '*PROJECT.md*'
    }

    It 'carries SupportsShouldProcess' {
        # It creates a 40 GB file and mounts it as a disk. CLAUDE.md rule 6.
        (Get-Command -Name 'New-HDTLabScratchDisk').Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It 'calls Assert-HDTLabScratchDisk before it returns a disk number' {
        $path = Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/tools/New-HDTLabScratchDisk.ps1'
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue

        (Get-Content -LiteralPath $path -Raw) | Should -BeLike '*Assert-HDTLabScratchDisk*'
    }
}

Describe 'Remove-HDTLabScratchDisk' {

    It 'is exported by HDTTestTools' {
        Get-Command -Name 'Remove-HDTLabScratchDisk' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'refuses a path outside C:\HDTLab' {
        { Remove-HDTLabScratchDisk -Path 'C:\Windows\System32\config\SYSTEM' -Confirm:$false } |
            Should -Throw '*C:\HDTLab*'
    }

    It 'carries SupportsShouldProcess' {
        (Get-Command -Name 'Remove-HDTLabScratchDisk').Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It 'is not an error to remove a scratch disk that is not there' {
        # AfterAll runs on failure too, and a teardown that throws on an absent
        # file is a teardown that does not finish.
        { Remove-HDTLabScratchDisk -Path 'C:\HDTLab\scratch\integration\never-created.vhdx' -Confirm:$false } |
            Should -Not -Throw
    }
}
