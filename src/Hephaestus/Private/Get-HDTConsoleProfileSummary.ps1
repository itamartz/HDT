function Get-HDTConsoleProfileSummary {
    <#
        .SYNOPSIS
            One sentence about what a selection profile will inject.

        .DESCRIPTION
            The line under the folder list, and the only place the tab says
            anything is WRONG. A list of paths is not a warning; "1 of 2 folders
            - 1 is not on the share" is.

            IT LEADS WITH THE PROBLEM WHEN THERE IS ONE. A boot image missing one
            vendor's drivers builds cleanly, boots, and fails on a bench, so the
            count that matters is the one that is short.

            AN EMPTY PROFILE IS NOT A FAULT. Nothing is a built-in that means it,
            and a profile somebody is halfway through filling in is an ordinary
            afternoon - so both get a sentence rather than a complaint.

        .PARAMETER SelectionProfile
            One profile, as Get-HDTSelectionProfile returned it, optionally
            carrying the Resolved list Expand-HDTSelectionProfile produced.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTConsoleProfileSummary -SelectionProfile $selectionProfile[0]

        .EXAMPLE
            Get-HDTConsoleProfileSummary -SelectionProfile $empty

            'This profile includes nothing, so no drivers are injected.'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $SelectionProfile
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $folder = @(Get-HDTConsoleProfileFolder -SelectionProfile $SelectionProfile)

    if (@($folder).Count -eq 0) {
        return 'This profile includes nothing, so no drivers are injected.'
    }

    $missing = @($folder | Where-Object { -not $_.Present })

    if (@($missing).Count -eq 0) {
        if (@($folder).Count -eq 1) { return '1 folder, injected with everything under it.' }

        return ('{0} folders, each injected with everything under it.' -f @($folder).Count)
    }

    return ('{0} of {1} folders - {2} not on the share. A boot image missing one vendor''s drivers looks like a working build until a machine cannot see its disk.' -f
        (@($folder).Count - @($missing).Count), @($folder).Count,
        (& { if (@($missing).Count -eq 1) { '1 is' } else { ('{0} are' -f @($missing).Count) } }))
}
