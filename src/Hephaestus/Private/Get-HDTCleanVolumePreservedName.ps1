function Get-HDTCleanVolumePreservedName {
    <#
        .SYNOPSIS
            The names CleanVolume leaves standing when it empties a volume, and
            the reason each one is on the list.

        .DESCRIPTION
            DESIGN 3.2. A Refresh empties the OS volume by DELETING what is on
            it, and the exclusion list is not tidiness - it is the reason the
            step deletes rather than formats. A format would take the task
            sequence's state, its logs and the staged WinPE with it, which is
            everything the leg that comes back is made of.

            MDT'S LIST IS LTIApply.wsf:1275-1277 - minint, recycler, system
            volume information, deploy, drivers, _smstasksequence, smstslog,
            sysprep - and HDT'S IS SHORTER BECAUSE MDT'S IS MOSTLY MDT'S OWN
            LAYOUT. Six of those eight name MININT, _SMSTaskSequence and the
            rest of the MDT state tree, and HDT takes no MDT dependency
            (CLAUDE.md 4), so carrying those names across would be carrying the
            layout that produced them. What is left is the two Windows owns and
            the one HDT does.

            HDT\ IS THE ENTRY THAT MUST NEVER LEAVE THIS LIST. state.json is
            mirrored to <volume>\HDT\state.json by Invoke-HDTTaskSequence and
            read back by Start-HDTResume, the staged boot WIM is under
            <volume>\HDT\Boot (Get-HDTLocalWinPePlan), and the run's logs are
            beside them. Delete it and the run dies mid-flight, in the one place
            it cannot record why - and the log that would have said so went with
            it.

            AND IT IS WHY THE STEP NEEDS NO LOG GUARD OF ITS OWN. The log for a
            leg standing on this volume is at <volume>\HDT\Logs, which is inside
            the preserved directory, so the clean cannot delete the log it is
            writing to. A separate protected-path check for the log - the shape
            Invoke-HDTDiskPartitionStep needs, because a format takes the whole
            volume - would here refuse the very volume the step exists to empty.

            THE REASON IS DATA, NOT A COMMENT, because the step logs it. An
            administrator reading the log a week later has to be able to see
            what survived AND why, and a bare list of survivors makes every one
            of them look like something that failed to delete.

            IT IS A LIST RATHER THAN A LITERAL IN THE STEP so a test can walk
            the SET. "HDT\ survives" passes for HDT\ and fails nobody after it;
            a test that enumerates this covers the name added next.

        .OUTPUTS
            System.Management.Automation.PSCustomObject, one per name:

              Name    the leaf name, directly under the volume root
              Reason  why it is preserved, in the words the log carries

        .EXAMPLE
            Get-HDTCleanVolumePreservedName | Format-Table Name, Reason

            The whole set, which is what CleanVolume compares each folder
            against before it deletes one.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return @(
        [pscustomobject] @{
            Name   = 'HDT'
            Reason = "it is this run's own state directory - state.json, the staged boot image under Boot\ and the logs. Deleting it ends the run in the one place it cannot record why."
        }

        # MDT preserves 'system volume information' at LTIApply.wsf:1276 for the
        # same reason: it is NTFS's own metadata store, the volume shadow copies
        # and the change journal live in it, and a delete does not succeed - it
        # fails, which under HDT's rules would fail the whole step on a
        # directory that was never ours.
        [pscustomobject] @{
            Name   = 'System Volume Information'
            Reason = 'NTFS owns it - the change journal and the shadow copies are in it - and a delete of it fails rather than succeeding.'
        }

        # MDT's 'recycler' under the name every Windows since Vista uses. Same
        # shape as the entry above: the OS owns it, it is recreated on demand,
        # and attempting it buys a failure on a directory nobody asked to keep.
        [pscustomobject] @{
            Name   = '$Recycle.Bin'
            Reason = "Windows owns it and recreates it on demand; it is MDT's recycler entry under the name Windows has used since Vista."
        }
    )
}
