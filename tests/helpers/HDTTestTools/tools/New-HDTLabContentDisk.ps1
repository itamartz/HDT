function New-HDTLabContentDisk {
    <#
        .SYNOPSIS
            Builds a VHDX carrying a workspace, the engine and its dependencies,
            ready to attach to a lab VM.

        .DESCRIPTION
            WHY THE CONTENT IS ON A DISK RATHER THAN A SHARE. PROJECT.md
            requires HDT test VMs to sit on the isolated 'HDT Lab' switch, and
            SPIKES S6 records that a VM on an isolated switch cannot reach a
            share on the host - S6 used an External switch to get around it,
            which the lab rules do not allow for a routine test.

            A locally attached content disk removes SMB, DHCP and the host
            firewall from the exit criterion entirely, so a failure means the
            IMAGING CODE failed. It is also DESIGN 6.2's Local provider shape,
            one milestone early.

            The disk is created, mounted, initialised GPT, given one NTFS
            partition and a drive letter, filled from -Source, and DISMOUNTED
            AGAIN before it returns - a VHDX still attached to the host cannot
            be attached to a VM.

            -Source maps a destination path RELATIVE TO THE ROOT OF THE DISK to
            a source file or directory on the host. Directories are copied
            recursively. The harness writes the workspace layout by hand here;
            the engine reading it builds every path with Get-HDTWorkspacePath,
            and tests/e2e asserts the two agree.

        .PARAMETER Path
            Where the VHDX goes. Must be under C:\HDTLab.

        .PARAMETER SizeByte
            Its size. 8 GB holds the module, powershell-yaml, a workspace and a
            4 GB install.wim.

        .PARAMETER Source
            Destination-relative-path -> host source path.

        .OUTPUTS
            A hashtable with Path and SourceCount.

        .EXAMPLE
            New-HDTLabContentDisk -Path 'C:\HDTLab\vms\HDT-M3-Deploy\content.vhdx' -SizeByte 8589934592 -Source @{
                'HDT\Modules\Hephaestus' = 'C:\src\HDT\src\Hephaestus'
                'Share\rules.yaml'       = 'C:\src\HDT\samples\workspace\rules.yaml'
            }
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [long] $SizeByte,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Source
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $scratchRoot = 'C:\HDTLab'

    if (-not ($Path -like ('{0}\*' -f $scratchRoot))) {
        throw ("'{0}' is not under {1}. Lab disks live in the lab area and nowhere else (PROJECT.md, 'Scratch areas')." -f $Path, $scratchRoot)
    }

    if ([System.IO.Path]::GetExtension($Path) -ne '.vhdx') {
        throw ("'{0}' is not a .vhdx. HDT test VMs are Generation 2 (PROJECT.md, 'Hyper-V lab safety rules', rule 6)." -f $Path)
    }

    foreach ($key in @($Source.Keys)) {
        $from = [string] $Source[$key]
        if (-not (Test-Path -LiteralPath $from)) {
            throw ("the content source '{0}' for '{1}' does not exist. A content disk built from a missing source would fail inside the VM, where nobody can see it." -f $from, $key)
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Path, ('Build a {0} byte content disk from {1} source(s)' -f $SizeByte, $Source.Count))) {
        return $null
    }

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try { Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue | Out-Null } catch { $null = $_ }
        Remove-Item -LiteralPath $Path -Force
    }

    Hyper-V\New-VHD -Path $Path -SizeBytes $SizeByte -Dynamic | Out-Null

    $letter = ''

    try {
        Mount-DiskImage -ImagePath $Path -StorageType VHDX -Access ReadWrite | Out-Null

        $number = [int] (Get-DiskImage -ImagePath $Path).Number
        $row = @(Get-Disk | Where-Object { $_.Number -eq $number })

        # The same guard the scratch disk uses. A mount that misbehaved must not
        # let this format the developer's disk.
        Assert-HDTLabScratchDisk -Disk $(if ($row.Count -eq 1) { $row[0] } else { $null })

        Initialize-Disk -Number $number -PartitionStyle GPT

        $partition = New-Partition -DiskNumber $number -UseMaximumSize -AssignDriveLetter
        $letter = [string] $partition.DriveLetter

        Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel 'HDT Content' -Force -Confirm:$false | Out-Null

        foreach ($key in @($Source.Keys)) {
            $relative = [string] $key
            $from = [string] $Source[$key]
            $to = Join-Path -Path ('{0}:\' -f $letter) -ChildPath $relative

            if (Test-Path -LiteralPath $from -PathType Container) {
                New-Item -Path $to -ItemType Directory -Force | Out-Null
                Copy-Item -Path (Join-Path -Path $from -ChildPath '*') -Destination $to -Recurse -Force
            } else {
                $toParent = Split-Path -Parent $to
                if (-not (Test-Path -LiteralPath $toParent -PathType Container)) {
                    New-Item -Path $toParent -ItemType Directory -Force | Out-Null
                }
                Copy-Item -LiteralPath $from -Destination $to -Force
            }
        }
    } finally {
        # ALWAYS. A VHDX still attached to the host cannot be attached to a VM,
        # and a half-built one left mounted is a disk number the next run gets.
        try { Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue | Out-Null } catch { $null = $_ }
    }

    return @{
        Path        = $Path
        SourceCount = $Source.Count
    }
}
