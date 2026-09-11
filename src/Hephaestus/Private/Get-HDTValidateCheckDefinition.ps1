function Get-HDTValidateCheckDefinition {
    <#
        .SYNOPSIS
            Every check a Validate step can make, and what each one is called on
            screen.

        .DESCRIPTION
            THE ONE PLACE A CHECK IS DECLARED, AND IT IS DATA. The fixed list
            of checks a Validate step offers is this table, so adding one is an
            entry here rather than a new row of XAML, a new control name, a new
            handler and a new assertion that they all match. MDT compiles the
            same list of checkboxes into Workbench.

            ADDING A CHECK IS TWO EDITS: a row here, and the step reading the key
            it names. The window discovers the rest - the Validate page binds an
            ItemsControl over this list and gets the new row for free.

            THE KEY IS THE YAML KEY, exactly as the step reads it. This table is
            what makes the page and the engine agree; a label that drifted from
            its key would produce a box that writes a setting nothing reads,
            which is the failure mode the console rule exists to prevent.

            KIND IS WHAT THE WINDOW DRAWS. 'Number' is a checkbox and a value
            box, where unticking means "do not check this" rather than "check it
            against nothing". 'Switch' is a checkbox alone.
            'List' is a comma-separated line, because a variable list is short
            and typing one is faster than any grid.

            NOUN IS WHAT THE STEP TREE SAYS, and it lives here rather than in
            Get-HDTValidateStepDescription for the same reason the key does: so
            the set can be asked for instead of written down twice. That
            function walks this table and renders each DECLARED check as
            '<value> <Unit> <Noun>' where there is a unit and '<Noun> <value>'
            where there is not - '2048 MB memory', 'TPM 2.0' - and a 'Switch'
            as the Noun alone, only when it is on. So a check added here shows
            up in the tree with no second edit.

            IT IS HERE BECAUSE THE DESCRIPTION HAD DRIFTED FIVE CHECKS BEHIND.
            It hand-enumerated minRamMB, minDiskGB, requireUefi and
            requireVariable, so minTpmVersion, diskNumber, imageVersion,
            imageSizeMB and allowOtherPartition were declarable, enforced by
            the step, and invisible in the tree - and refresh.yaml declares
            three of them, so the shipped Refresh sequence described itself
            without one word about the downgrade, free-space and
            partition-match refusals that are the reason it has a Validate step
            at all. A 'List' needs no Noun: its entries are named one by one.

            SCOPE IS WHICH DEPLOYMENT TYPE THE CHECK BELONGS TO, and it is here
            for the same reason the key is: so that the set can be asked for
            rather than written down twice. 'Any' is every run. 'REFRESH' is a
            check that runs only on a wipe-and-load launched from the running
            Windows and is reported SKIPPED on a bare-metal one - MDT draws the
            same line in the same place, with `Case "REFRESH", "UPGRADE"` and a
            `Case "NEWCOMPUTER"` that says "Assuming that the drive has enough
            disk space (once cleaned)" and checks nothing (ZTIValidate.wsf:231-
            256). A NEWCOMPUTER run repartitions the disk, so the volume a
            Refresh guard measures does not survive to be measured; and it lays
            Windows onto a machine that may carry no Windows at all, so there is
            no current version to be downgraded from and no current OS partition
            to match.

            'NEWCOMPUTER' IS THE MIRROR OF THAT, AND IT IS THE TWO DISK CHECKS.
            minDiskGB and diskNumber are the floor and the override that
            Select-HDTTargetDisk chooses a deployment target with, and its first
            exclusion is absolute and not overridable: "disk N is the disk this
            machine booted from". That is exactly right for a bare-metal run,
            where the boot disk is the WinPE stick somebody plugged in, and
            exactly backwards for a Refresh, where the disk this machine booted
            from IS the one being replaced. A Refresh reuses the partition table
            Windows was already booting from, has no DiskPartition step and
            nothing to select a disk FOR - so both are reported SKIPPED with the
            reason on a REFRESH, and what governs a Refresh's target instead is
            the partition-match guard below. MDT draws the same line, gating
            every partition and format step on
            `DeploymentType equals NEWCOMPUTER` (Client.xml:131).

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] with Key, Label, Kind,
            Unit, Hint, Scope and Order.

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
            Noun  = 'memory'
            Kind  = 'Number'
            Unit  = 'MB'
            Scope = 'Any'
            Hint  = 'A 4 GB machine reports slightly under 4096 - the firmware keeps some of it - so 4096 refuses machines you meant to accept.'
        }

        [pscustomobject] @{
            Order = 2
            Key   = 'minDiskGB'
            Label = 'Ensure minimum disk size'
            Noun  = 'disk'
            Kind  = 'Number'
            Unit  = 'GB'
            Scope = 'NEWCOMPUTER'
            Hint  = 'Also what excludes a small content disk from the choice, which is what makes the target unambiguous on a two-disk machine. A Refresh chooses no disk, so this is skipped there; its free space is checked by the Refresh guard below instead.'
        }

        [pscustomobject] @{
            Order = 3
            Key   = 'requireUefi'
            Label = 'Ensure the machine booted UEFI'
            Noun  = 'UEFI firmware'
            Kind  = 'Switch'
            Unit  = ''
            Scope = 'Any'
            Hint  = 'For a sequence that only lays out GPT. A BIOS machine is refused here rather than after the image is applied.'
        }

        [pscustomobject] @{
            Order = 4
            Key   = 'minTpmVersion'
            Label = 'Ensure a TPM of at least'
            Noun  = 'TPM'
            Kind  = 'Number'
            Unit  = ''
            Scope = 'Any'
            Hint  = 'Windows 11 requires 2.0. Without this check a machine with no TPM is partitioned and imaged before Setup refuses it - on a disk that has already been wiped. A virtual machine needs a TPM added to the VM.'
        }

        [pscustomobject] @{
            Order = 5
            Key   = 'diskNumber'
            Label = 'Check this disk in particular'
            Noun  = 'target disk'
            Kind  = 'Number'
            Unit  = ''
            Scope = 'NEWCOMPUTER'
            Hint  = 'Mirror of the DiskPartition step. Left empty the engine selects one and refuses to guess when more than one qualifies. A Refresh has no DiskPartition step, so this is skipped there.'
        }

        [pscustomobject] @{
            Order = 7
            Key   = 'requireVariable'
            Label = 'Ensure these variables were gathered'
            Noun  = ''
            Kind  = 'List'
            Unit  = ''
            Scope = 'Any'
            Hint  = 'Comma separated. A sequence that needs HDTComputerName should say so here rather than fail at the step that reads it.'
        }
        # -- the three a Refresh runs, and a NEWCOMPUTER never does ----------
        #
        # MDT'S ZTIValidate GUARDS, UNDER HDT'S OWN NAMES. Each one refuses
        # before anything destructive runs, which is the only moment at which
        # refusing is worth anything: after CleanVolume has emptied the volume
        # there is no installation left to keep.

        [pscustomobject] @{
            Order = 8
            Key   = 'imageVersion'
            Label = 'Refuse a Refresh onto an older Windows'
            Noun  = 'Windows'
            Kind  = 'Number'
            Unit  = ''
            Scope = 'REFRESH'
            Hint  = 'The version this sequence applies, such as 10.0.26100. A Refresh cannot roll an installation back to an earlier build; left empty the check is skipped, as MDT skips it when it cannot determine the image build.'
        }

        [pscustomobject] @{
            Order = 9
            Key   = 'imageSizeMB'
            Label = 'Size of the image being applied'
            Noun  = 'image'
            Kind  = 'Number'
            Unit  = 'MB'
            Scope = 'REFRESH'
            Hint  = 'A Refresh needs this plus 150 MB for WinPE and its logs plus 3 GB for Setup on the volume it is replacing. Left empty only the 3222 MB floor is required.'
        }

        [pscustomobject] @{
            Order = 10
            Key   = 'allowOtherPartition'
            Label = 'Allow a Refresh onto another volume'
            Noun  = 'any volume'
            Kind  = 'Switch'
            Unit  = ''
            Scope = 'REFRESH'
            Hint  = 'A Refresh replaces the installation it started from, so by default it refuses any other volume. Tick this only when applying to a different volume is deliberate; the run warns that it was overridden.'
        }
    )
}
