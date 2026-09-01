function Get-HDTUpdateApplyOrder {
    <#
        .SYNOPSIS
            Puts imported updates into the order they must be applied in.

        .DESCRIPTION
            THE SERVICING STACK GOES FIRST, AND THIS IS THE ONE PLACE THAT
            DECIDES IT. An update installs through the servicing stack; a package
            that needs a newer stack than the image has fails, and the failure
            reads as a corrupt package rather than as an ordering mistake. So a
            servicing stack update sorts ahead of everything else.

            AND IT IS READ, NOT GUESSED. kind comes from the package's own
            CompDB Feature/@Type - ServicingStackUpdate or CumulativeUpdate - so
            this is a fact about the package rather than a pattern matched
            against a file name. That is the honest answer to "can you detect an
            SSU reliably": for a package carrying readable metadata, yes,
            exactly; for one that does not, its kind is 'Other' and it sorts with
            the cumulative updates, which is stated rather than hidden.

            IN PRACTICE THE QUESTION MOSTLY DISSOLVES, and it is worth saying
            why rather than leaving the ordering looking more load-bearing than
            it is. Both packages this was built against BUNDLE their servicing
            stack update inside the same .msu - KB5094126 carries KB5094135 as
            SSU-26100.8648-x64.cab, KB5094125 carries KB5094137 - and DISM
            applies the bundled stack itself before the cumulative payload.
            Verified on 2026-09-01: a mounted Windows 11 LTSC image went from
            10.0.26100.1742 to 10.0.26100.8655 from the combined package alone.
            The ordering here is for the case of a standalone servicing stack
            update, which is still a shape Microsoft ships.

            THEN BY THE BUILD EACH UPDATE PRODUCES, ASCENDING, which is the
            correct order for cumulative updates and is what puts a checkpoint
            update ahead of the update that requires it: 26100.1742 before
            26100.8655. An update with no readable target build sorts last
            rather than first, because an unknown prerequisite is safer applied
            after the known ones than before them.

            THEN BY KB, so two updates that tie are still in a stable order and
            a log from one run can be compared with a log from the next.

        .PARAMETER Update
            The updates to order, as Get-HDTWindowsUpdate builds them.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[], in apply order.

        .EXAMPLE
            Get-HDTUpdateApplyOrder -Update $update | Format-Table Kb, Kind, TargetVersion

            A standalone servicing stack update first, then the cumulative
            updates oldest build first.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]] $Update
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $row = @($Update | Where-Object { $null -ne $_ })

    if ($row.Count -eq 0) { return [pscustomobject[]] @() }

    # THREE KEYS, COMPUTED ONCE. Sort-Object with script blocks would recompute
    # them per comparison; more to the point, computing them here is what lets
    # each one carry the comment saying why it is a key at all.
    $keyed = foreach ($current in $row) {

        # 0 sorts before 1: the servicing stack first.
        $stackFirst = 1
        if ([string] $current.Kind -eq 'ServicingStackUpdate') { $stackFirst = 0 }

        # AN UNKNOWN BUILD SORTS LAST, NOT FIRST. [int]::MaxValue rather than 0,
        # because an update whose prerequisites could not be read is safer after
        # the ones that could be.
        $build = [int]::MaxValue
        $revision = [int]::MaxValue
        if ([int] $current.Build -gt 0) {
            $build = [int] $current.Build
            $revision = [int] $current.Revision
        }

        [pscustomobject] @{
            StackFirst = $stackFirst
            Build      = $build
            Revision   = $revision
            Kb         = [string] $current.Kb
            Item       = $current
        }
    }

    return [pscustomobject[]] @(@($keyed |
                Sort-Object -Property StackFirst, Build, Revision, Kb |
                ForEach-Object { $_.Item }))
}
