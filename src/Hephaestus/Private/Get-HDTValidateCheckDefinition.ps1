function Get-HDTValidateCheckDefinition {
    <#
        .SYNOPSIS
            Every check a Validate step can make, and what each one is called on
            screen.

        .DESCRIPTION
            THE ONE PLACE A CHECK IS DECLARED. MDT's Validate dialog is a fixed
            list of checkboxes compiled into Workbench; this is the same list as
            DATA, so adding one is an entry here rather than a new row of XAML,
            a new control name, a new handler and a new assertion that they all
            match.

            ADDING A CHECK IS TWO EDITS: a row here, and the step reading the key
            it names. The window discovers the rest - the Validate page binds an
            ItemsControl over this list and gets the new row for free.

            THE KEY IS THE YAML KEY, exactly as the step reads it. This table is
            what makes the page and the engine agree; a label that drifted from
            its key would produce a box that writes a setting nothing reads,
            which is the failure mode the console rule exists to prevent.

            KIND IS WHAT THE WINDOW DRAWS. 'Number' is a checkbox and a value
            box - MDT's shape, where unticking means "do not check this" rather
            than "check it against nothing". 'Switch' is a checkbox alone.
            'List' is a comma-separated line, because a variable list is short
            and typing one is faster than any grid.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] with Key, Label, Kind,
            Unit, Hint and Order.

        .EXAMPLE
            Get-HDTValidateCheckDefinition | Format-Table Key, Label, Kind
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [pscustomobject[]] @(
        [pscustomobject] @{
            Order = 1
            Key   = 'minRamMB'
            Label = 'Ensure minimum memory'
            Kind  = 'Number'
            Unit  = 'MB'
            Hint  = 'A 4 GB machine reports slightly under 4096 - the firmware keeps some of it - so 4096 refuses machines you meant to accept.'
        }

        [pscustomobject] @{
            Order = 2
            Key   = 'minDiskGB'
            Label = 'Ensure minimum disk size'
            Kind  = 'Number'
            Unit  = 'GB'
            Hint  = 'Also what excludes a small content disk from the choice, which is what makes the target unambiguous on a two-disk machine.'
        }

        [pscustomobject] @{
            Order = 3
            Key   = 'requireUefi'
            Label = 'Ensure the machine booted UEFI'
            Kind  = 'Switch'
            Unit  = ''
            Hint  = 'For a sequence that only lays out GPT. A BIOS machine is refused here rather than after the image is applied.'
        }

        [pscustomobject] @{
            Order = 4
            Key   = 'minTpmVersion'
            Label = 'Ensure a TPM of at least'
            Kind  = 'Number'
            Unit  = ''
            Hint  = 'Windows 11 requires 2.0. Without this check a machine with no TPM is partitioned and imaged before Setup refuses it - on a disk that has already been wiped. A virtual machine needs a TPM added to the VM.'
        }

        [pscustomobject] @{
            Order = 5
            Key   = 'diskNumber'
            Label = 'Check this disk in particular'
            Kind  = 'Number'
            Unit  = ''
            Hint  = 'Mirror of the DiskPartition step. Left empty the engine selects one and refuses to guess when more than one qualifies.'
        }

        [pscustomobject] @{
            Order = 6
            Key   = 'wipe'
            Label = 'The disk may already hold data'
            Kind  = 'Switch'
            Unit  = ''
            Hint  = 'Mirror of the DiskPartition step. Without it a disk carrying any formatted volume is refused - so a pre-flight that omits it fails on a machine the deployment would have handled.'
        }

        [pscustomobject] @{
            Order = 7
            Key   = 'requireVariable'
            Label = 'Ensure these variables were gathered'
            Kind  = 'List'
            Unit  = ''
            Hint  = 'Comma separated. A sequence that needs HDTComputerName should say so here rather than fail at the step that reads it.'
        }
    )
}
