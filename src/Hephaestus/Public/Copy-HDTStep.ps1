function Copy-HDTStep {
    <#
        .SYNOPSIS
            Returns the lines one step or group occupies, ready to be pasted
            elsewhere.

        .DESCRIPTION
            The Copy button, and the cmdlet an administrator can type instead.

            IT IS THE HALF OF A CROSS-GROUP MOVE THAT CAN BE SEEN. Move refuses
            to take a step out of its group, because "before the group" and
            "into the group above" are both plausible readings of Up on a first
            step. Copy, Paste and Remove do the same job with each half visible
            and separately undoable.

            THE COMMENT COMES WITH IT, for the same reason it travels with a
            move: the comment explains this step, and a copy that left it behind
            would paste a step stripped of the one thing recording why it is
            configured the way it is.

            IT CHANGES NOTHING. The document goes in and comes back untouched;
            what is returned is a copy of some of its lines.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The step or group to copy.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the block's lines, comment first.

        .EXAMPLE
            $block = Copy-HDTStep -Line $line -Name 'Apply OS'
            Add-HDTStep -Line $line -Block $block -After 'Prepare Boot'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Reads lines out of an in-memory document; it changes nothing.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        # WHICH OF THE SAME-NAMED STEPS, 1-BASED, IN DOCUMENT ORDER. Omitted, an
        # ambiguous name is refused rather than guessed at. The console passes
        # it because it has a selected row; a person typing a name has not said
        # which one they mean, and is told so.
        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $Occurrence = 0
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $block = Resolve-HDTStepBlock -Line $Line -Name $Name -Occurrence $Occurrence

    return [string[]] @($Line[$block.Start..$block.End])
}
