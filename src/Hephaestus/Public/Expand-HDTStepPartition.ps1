function Expand-HDTStepPartition {
    <#
        .SYNOPSIS
            Writes a DiskPartition step's named layout out as the step's own
            partition table, so it can be edited row by row.

        .DESCRIPTION
            'layout: uefi-standard' MEANS "THE STANDARD LAYOUT, WHATEVER IT
            BECOMES". The step carries no rows of its own, which is why the
            console's five partition buttons were dark on every sequence the
            standard client template produces - and that is every sequence
            anybody makes. MDT's Format and Partition Disk grid is editable the
            moment it opens. This is the command that makes HDT's editable too.

            IT IS ONE DELIBERATE CONVERSION, NOT A SIDE EFFECT OF CLICKING EDIT.
            The console names it in the footer and says what it did, because
            after this the step no longer tracks the built-in: it carries a
            frozen copy of what the built-in was on the day the button was
            pressed. Somebody who wants the tracking back deletes the table and
            writes the layout key again.

            DESIGN 9.1'S RULE SURVIVES IT. A step may name a layout or write its
            own partitions and not both, so the layout key is REMOVED in the same
            splice that writes the rows - never left sitting beside them, which
            is a document with two answers about one disk.

            THE NAMES ARE THE ROLES, AND THAT IS LOAD-BEARING.
            Invoke-HDTDiskPartitionStep publishes HDTSystemVolume, HDTOSVolume
            and HDTRecoveryVolume by ROLE, and ConvertTo-HDTDiskLayout takes an
            authored row's role from its name - so the rows come out called
            System, Windows and Recovery. A conversion that renamed Windows to
            anything friendlier would leave ApplyImage with nowhere to apply to,
            and nothing would say so until a machine was being built.

            ONE THING DOES CHANGE, AND IT IS NOT A BUG. In uefi-standard the
            alignment slack lands on Recovery (UseMaximumSize); in an authored
            table it lands on whichever row says 'remainder', which is Windows.
            The disks differ by the partition alignment plus the unused 16 MB MSR
            allowance - a few megabytes on the Windows volume rather than the
            recovery one. Recovery ends up exactly the 1 GB it asked for.

            IT SPLICES. Comments die at parse time, so this edits the lines it
            was given and leaves every one it does not own exactly as it found
            it.

        .PARAMETER Line
            The document's lines, as read.

        .PARAMETER Name
            The step to expand.

        .PARAMETER Occurrence
            Which step of that name, when a sequence holds more than one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document's lines, spliced.

        .EXAMPLE
            $path = 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $line = [string[]] @([System.IO.File]::ReadAllLines($path))
            $line = Expand-HDTStepPartition -Line $line -Name 'Format and Partition Disk (UEFI)'
            Save-HDTSequenceDocument -Path $path -Line $line

            Turns the built-in into rows, after which Add-HDTStepPartition and
            Set-HDTStepPartition work on the step.

        .EXAMPLE
            $path = 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $line = [string[]] @([System.IO.File]::ReadAllLines($path))
            $line = Expand-HDTStepPartition -Line $line -Name 'Format and Partition Disk (UEFI)'
            $line = Add-HDTStepPartition -Line $line -Name 'Format and Partition Disk (UEFI)' `
                -Partition 'Data' -Type Primary -Size 'remainder'

            The reason to expand at all: a data volume beside Windows, which is
            the commonest thing anybody does with MDT's Format and Partition
            Disk and which a named layout cannot express. Note that Windows must
            stop claiming the remainder first - two rows cannot both have it.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter()]
        [int] $Occurrence = 0
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $target = Resolve-HDTStepBlock -Line $Line -Name $Name -Occurrence $Occurrence

    # THE SCALAR A KEY LINE CARRIES, unquoted. The document has not been parsed
    # here and must not be - a parse would drop the comments this command exists
    # to preserve.
    $read = {
        param([int] $Index)

        if ($Index -lt 0) { return '' }

        $text = [string] $Line[$Index]
        if ($text -notmatch '^\s*[A-Za-z0-9_]+:\s*(.*?)\s*$') { return '' }

        $value = [string] $Matches[1]

        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            return $value.Substring(1, $value.Length - 2)
        }

        if ($value.Length -ge 2 -and $value.StartsWith("'") -and $value.EndsWith("'")) {
            return $value.Substring(1, $value.Length - 2)
        }

        return $value
    }

    $typeKey = Get-HDTStepKey -Line $Line -Block $target -Key 'type'
    $stepType = [string] (& $read ([int] $typeKey.Index))

    if ($stepType -ne 'DiskPartition') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name -Category InvalidOperation `
                    -Message ("step '{0}' is a {1} step, and only a DiskPartition step lays a disk out. There is nothing here to expand." -f
                        $Name, $(if ([string]::IsNullOrWhiteSpace($stepType)) { 'typeless' } else { $stepType }))))
    }

    $partitionKey = Get-HDTStepKey -Line $Line -Block $target -Key 'partition'

    if ([int] $partitionKey.Index -ge 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name -Category InvalidOperation `
                    -Message ("step '{0}' already writes its own partition table, so there is no layout to expand. Its rows are edited with Add-HDTStepPartition and Set-HDTStepPartition." -f $Name)))
    }

    $layoutKey = Get-HDTStepKey -Line $Line -Block $target -Key 'layout'

    if ([int] $layoutKey.Index -lt 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name -Category InvalidOperation `
                    -Message ("step '{0}' names no layout and writes no table, so it says nothing about how the disk should be laid out. Give it a layout, or add a partition row." -f $Name)))
    }

    $layoutName = [string] (& $read ([int] $layoutKey.Index))

    # A LAYOUT NAME IS OFTEN A VARIABLE, AND THAT IS AN MDT SHAPE RATHER THAN A
    # MISTAKE - DEMO-M4 carries layout: "%HDTDiskLayout%". This edits the
    # DOCUMENT, where the token has not been expanded and never will be, so
    # there is no table to write: nobody yet knows which one.
    if ($layoutName -like '*%*') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name -Category InvalidOperation `
                    -Message ("step '{0}' picks its layout at run time with '{1}', so there is no single table to write here. Replace the variable with a layout name first, or add the rows by hand." -f
                        $Name, $layoutName)))
    }

    # UNKNOWN NAMES REFUSE HERE, NAMING THE NAME. Get-HDTDiskLayout already says
    # which layouts exist, and repeating half of that message would be a second
    # place to keep the list.
    $resolved = Get-HDTDiskLayout -Name $layoutName

    if (-not $PSCmdlet.ShouldProcess($Name, ("Write layout '{0}' out as this step's own partition table" -f $layoutName))) {
        return [string[]] @($Line)
    }

    # THE ROWS SIT WHERE THE LAYOUT KEY SAT, so the step's keys stay in the
    # column they were authored in.
    $pad = ' ' * [int] $layoutKey.Indent
    $rowPad = ' ' * ([int] $layoutKey.Indent + 2)
    $inner = ' ' * ([int] $layoutKey.Indent + 4)

    $written = New-Object -TypeName System.Collections.ArrayList
    [void] $written.Add(('{0}partition:' -f $pad))

    foreach ($current in @($resolved.Partition)) {
        if ($null -eq $current) { continue }

        [void] $written.Add(('{0}- name: {1}' -f $rowPad, (Get-HDTConsoleScalarText -Value ([string] $current.Role))))
        [void] $written.Add(('{0}type: {1}' -f $inner, (Get-HDTPartitionTypeText -Partition $current)))
        [void] $written.Add(('{0}size: {1}' -f $inner, (Get-HDTConsoleScalarText -Value (Get-HDTPartitionSizeText -Partition $current))))

        # THE BUILT-IN'S OWN CHOICE, WRITTEN DOWN. Left out, the authored path
        # would fall back to its own default - FAT32 for an ESP and NTFS
        # otherwise - which happens to agree today and is not the same as saying
        # what this layout decided.
        if (-not [string]::IsNullOrWhiteSpace([string] $current.FileSystem)) {
            [void] $written.Add(('{0}filesystem: {1}' -f $inner, [string] $current.FileSystem))
        }
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($i -eq [int] $layoutKey.Index) {
            foreach ($one in $written) { [void] $result.Add($one) }
            continue
        }

        [void] $result.Add($Line[$i])
    }

    return [string[]] @($result)
}
