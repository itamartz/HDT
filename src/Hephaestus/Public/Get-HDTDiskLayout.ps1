function Get-HDTDiskLayout {
    <#
        .SYNOPSIS
            Returns a named disk layout, or every layout HDT knows.

        .DESCRIPTION
            DESIGN 9.1's two named layouts, as DATA rather than as code:

              uefi-standard  GPT: EFI System 260 MB FAT32, Windows,
                             WinRE recovery 1 GB at the end
              bios-standard  MBR: System Reserved 500 MB active NTFS,
                             Windows remainder

            NEITHER DECLARES A MICROSOFT RESERVED PARTITION, AND THAT IS THE
            POINT. SPIKES S6: Initialize-Disk -PartitionStyle GPT creates its own
            16 MB MSR. PSD's PSDPartition.ps1 initialises GPT and then creates an
            MSR by hand a few lines later, which is how the spike ended up with a
            DUPLICATE 16 MB partition. HDT records the 16 MB as an ALLOWANCE
            (ReservedSizeByte), subtracts it from the space Windows can have, and
            never creates a partition for it.

            THE ESP IS CREATED AS BASIC DATA AND RETYPED AFTERWARDS. A partition
            created directly as an EFI System partition cannot readily be given a
            drive letter to format through, so the layout carries both
            CreateGptType (basic data) and GptType (the ESP type), and
            DiskPartition creates, letters, formats, then retypes. THIS IS THE
            FIELD RECIPE AND IT IS UNVERIFIED BY CODE - 04-04's integration task
            is where it first runs against a real disk. If Set-Partition -GptType
            after Format-Volume does not behave, the finding goes into SPIKES.md
            and this layout changes, not the test.

            DESIGN 9.1 SAYS LAYOUTS LIVE IN workspace.yaml. That document does
            not exist yet - M4 introduces it for the boot image - so the
            built-ins live here and -Definition is the hook a workspace.yaml
            diskLayouts: block will arrive through. A supplied definition
            overrides a built-in of the same name and extends the set otherwise,
            so nothing has to be rewritten when M4 lands.

        .PARAMETER Name
            The layout to return. Matched case-insensitively. Omitted, every
            layout is returned in declaration order.

        .PARAMETER Definition
            Name -> layout definition, overriding and extending the built-ins.
            A definition is a mapping with PartitionStyle (GPT or MBR) and
            Partition, a list of mappings carrying Role (System, Windows or
            Recovery), SizeByte, UseMaximumSize, FileSystem, Label, DriveLetter,
            GptType, CreateGptType and IsActive.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - Name, PartitionStyle,
            ReservedSizeByte, AlignmentSizeByte and Partition.

        .EXAMPLE
            Get-HDTDiskLayout -Name uefi-standard

            The layout a UEFI machine gets unless the sequence pins another.

        .EXAMPLE
            Get-HDTDiskLayout | Format-Table Name, PartitionStyle

            Every layout this engine knows.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Name,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Definition
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # The GPT type GUIDs, written once. Basic data is what a partition is created
    # as; the other two are what it is retyped to.
    $basicDataType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    $espType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    $recoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'

    $allowedRole = @('System', 'Windows', 'Recovery')
    $allowedStyle = @('GPT', 'MBR')

    # -- the built-ins, one ordered literal ------------------------------------

    $builtIn = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

    $builtIn['uefi-standard'] = @{
        PartitionStyle    = 'GPT'
        # SPIKES S6: Initialize-Disk creates this. It is subtracted, never created.
        ReservedSizeByte  = 16777216
        AlignmentSizeByte = 1048576
        Partition         = @(
            # DESIGN 9.1: "EFI System 260 MB FAT32".
            @{ Role = 'System'; SizeByte = 272629760; UseMaximumSize = $false; FileSystem = 'FAT32'
                Label = 'System'; DriveLetter = 'S'; GptType = $espType; CreateGptType = $basicDataType; IsActive = $false
            },
            # DESIGN 9.1: "Windows (remainder minus recovery)".
            @{ Role = 'Windows'; SizeByte = 0; UseMaximumSize = $false; FileSystem = 'NTFS'
                Label = 'Windows'; DriveLetter = 'W'; GptType = ''; CreateGptType = ''; IsActive = $false
            },
            # DESIGN 9.1: "WinRE recovery 1 GB at the end". It carries
            # UseMaximumSize so the alignment slack lands here rather than being
            # left unallocated at the end of the disk.
            @{ Role = 'Recovery'; SizeByte = 1073741824; UseMaximumSize = $true; FileSystem = 'NTFS'
                Label = 'Windows RE tools'; DriveLetter = 'R'; GptType = $recoveryType; CreateGptType = ''; IsActive = $false
            }
        )
    }

    $builtIn['bios-standard'] = @{
        PartitionStyle    = 'MBR'
        # Initialize-Disk -PartitionStyle MBR creates nothing of its own.
        ReservedSizeByte  = 0
        AlignmentSizeByte = 1048576
        Partition         = @(
            # DESIGN 9.1: "System Reserved 500 MB active NTFS".
            @{ Role = 'System'; SizeByte = 524288000; UseMaximumSize = $false; FileSystem = 'NTFS'
                Label = 'System Reserved'; DriveLetter = 'S'; GptType = ''; CreateGptType = ''; IsActive = $true
            },
            # DESIGN 9.1: "Windows remainder". No recovery partition on BIOS.
            @{ Role = 'Windows'; SizeByte = 0; UseMaximumSize = $true; FileSystem = 'NTFS'
                Label = 'Windows'; DriveLetter = 'W'; GptType = ''; CreateGptType = ''; IsActive = $false
            }
        )
    }

    if ($null -ne $Definition) {
        foreach ($key in @($Definition.Keys)) {
            $builtIn[[string] $key] = $Definition[$key]
        }
    }

    # -- materialise and validate ---------------------------------------------

    $layout = New-Object -TypeName System.Collections.ArrayList

    foreach ($key in @($builtIn.Keys)) {
        $layoutName = [string] $key
        $source = $builtIn[$key]

        if (-not ($source -is [System.Collections.IDictionary])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $layoutName `
                        -Message ("disk layout '{0}' must be a mapping with PartitionStyle and Partition keys." -f $layoutName)))
        }

        $style = ''
        if ($source.Contains('PartitionStyle')) { $style = [string] $source['PartitionStyle'] }

        if ($allowedStyle -notcontains $style) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $layoutName `
                        -Message ("disk layout '{0}': '{1}' is not a partition style HDT can create. The styles are {2}." -f $layoutName, $style, ($allowedStyle -join ', '))))
        }

        $reserved = 0
        if ($source.Contains('ReservedSizeByte')) { $reserved = [long] $source['ReservedSizeByte'] }

        $alignment = 1048576
        if ($source.Contains('AlignmentSizeByte')) { $alignment = [long] $source['AlignmentSizeByte'] }

        $partition = New-Object -TypeName System.Collections.ArrayList
        $sourcePartition = @()
        if ($source.Contains('Partition')) { $sourcePartition = @($source['Partition']) }

        if ($sourcePartition.Count -eq 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $layoutName `
                        -Message ("disk layout '{0}' declares no partition. A layout that creates nothing is not a layout." -f $layoutName)))
        }

        foreach ($row in $sourcePartition) {
            if (-not ($row -is [System.Collections.IDictionary])) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $layoutName `
                            -Message ("disk layout '{0}': every partition must be a mapping with a Role and a FileSystem." -f $layoutName)))
            }

            $role = ''
            if ($row.Contains('Role')) { $role = [string] $row['Role'] }

            if ($allowedRole -notcontains $role) {
                # 'Reserved' lands here on purpose: SPIKES S6's duplicate MSR
                # started as a partition somebody declared.
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $layoutName `
                            -Message ("disk layout '{0}': '{1}' is not a partition role HDT creates. The roles are {2}; the Microsoft Reserved partition is created by initialisation and must not be declared (SPIKES S6)." -f $layoutName, $role, ($allowedRole -join ', '))))
            }

            $fileSystem = ''
            if ($row.Contains('FileSystem')) { $fileSystem = [string] $row['FileSystem'] }

            if ([string]::IsNullOrWhiteSpace($fileSystem)) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $layoutName `
                            -Message ("disk layout '{0}': the {1} partition declares no file system. HDT formats every partition it creates." -f $layoutName, $role)))
            }

            $sizeByte = 0
            if ($row.Contains('SizeByte')) { $sizeByte = [long] $row['SizeByte'] }

            if ($sizeByte -lt 0) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $layoutName `
                            -Message ("disk layout '{0}': the {1} partition declares a negative size ({2} bytes)." -f $layoutName, $role, $sizeByte)))
            }

            [void] $partition.Add([pscustomobject] @{
                    Role           = $role
                    SizeByte       = $sizeByte
                    UseMaximumSize = [bool] $(if ($row.Contains('UseMaximumSize')) { $row['UseMaximumSize'] } else { $false })
                    FileSystem     = $fileSystem
                    Label          = [string] $(if ($row.Contains('Label')) { $row['Label'] } else { '' })
                    DriveLetter    = [string] $(if ($row.Contains('DriveLetter')) { $row['DriveLetter'] } else { '' })
                    GptType        = [string] $(if ($row.Contains('GptType')) { $row['GptType'] } else { '' })
                    CreateGptType  = [string] $(if ($row.Contains('CreateGptType')) { $row['CreateGptType'] } else { '' })
                    IsActive       = [bool] $(if ($row.Contains('IsActive')) { $row['IsActive'] } else { $false })
                })
        }

        if (@($partition | Where-Object { $_.Role -eq 'Windows' }).Count -ne 1) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $layoutName `
                        -Message ("disk layout '{0}' must declare exactly one Windows partition. A layout that does not say where Windows goes cannot be applied to." -f $layoutName)))
        }

        [void] $layout.Add([pscustomobject] @{
                Name              = $layoutName
                PartitionStyle    = $style
                ReservedSizeByte  = $reserved
                AlignmentSizeByte = $alignment
                Partition         = [object[]] @($partition)
            })
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return [object[]] @($layout)
    }

    $match = @($layout | Where-Object { $_.Name -eq $Name })
    if ($match.Count -eq 1) {
        return $match[0]
    }

    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name `
                -Message ("'{0}' is not a disk layout this engine knows. The layouts are {1}." -f $Name, (@($layout | ForEach-Object { $_.Name }) -join ', '))))
}
