function Move-HDTBootImageStartCommand {
    <#
        .SYNOPSIS
            Moves a start command one place up or down the list.

        .DESCRIPTION
            ORDER IS SEMANTICS IN THIS LIST. startnet.cmd runs these lines in
            the order they are written and cmd.exe runs them synchronously, so
            a tool that has to be up before the next line runs has to be ABOVE
            it. Until this existed the whole vocabulary was Add - which appends
            or takes -First - and reordering meant remove and re-add: three
            presses to move one row, and the row's place lost entirely if the
            second half failed.

            IT MOVES ONE PLACE, NOT TO A POSITION. That is what an up arrow
            beside a list means, and it composes: pressing it three times moves
            a row three places. A -Position parameter would need the caller to
            know the current index, which is the thing the list is already
            showing them.

            AT THE END IT DOES NOTHING, AND THAT IS NOT AN ERROR. The button is
            pressed by somebody holding it to walk a row up several places, and
            refusing at the top would put a message on screen for a press that
            simply had nowhere to go. A command the document does not run IS an
            error, because that is a caller working from a stale list.

            THE WHOLE ENTRY MOVES, comment and all. Get-HDTWorkspaceItem reports
            the first and last line each entry owns, so a note an administrator
            wrote under a command travels with the command rather than being
            left behind pointing at whatever moved into its place.

        .PARAMETER Line
            The workspace.yaml lines to edit. Returned spliced, with every line
            this command was not asked to change byte-identical.

        .PARAMETER Command
            The start command to move, exactly as the document holds it.

        .PARAMETER Direction
            Up or Down, one place.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the workspace.yaml lines, spliced.

        .EXAMPLE
            $line = Move-HDTBootImageStartCommand -Line $line -Command 'X:\Tools\run.cmd' -Direction Up

        .EXAMPLE
            $line = Move-HDTBootImageStartCommand -Line $line -Command 'wpeutil disablefirewall' -Direction Up
            $line = Move-HDTBootImageStartCommand -Line $line -Command 'wpeutil disablefirewall' -Direction Up

            Two places up. Pressing an arrow twice is what this composes to.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Command,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateSet('Up', 'Down')]
        [string] $Direction
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $workspace = ConvertFrom-HDTWorkspaceLine -Line $Line
    $declared = @($workspace.BootImage.StartCommand)

    $at = [array]::IndexOf([string[]] @($declared), [string] $Command)

    if ($at -lt 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Command -Category ObjectNotFound `
                    -Message ("this boot image does not run '{0}', so there is nothing to move. It runs: {1}" -f
                        $Command, (@($declared) -join ' | '))))
    }

    $other = $at - 1
    if ($Direction -eq 'Down') { $other = $at + 1 }

    # Already where it was asked to go. See the header: a press with nowhere to
    # go is a press, not a mistake.
    if ($other -lt 0 -or $other -ge @($declared).Count) { return [string[]] @($Line) }

    if (-not $PSCmdlet.ShouldProcess($Command, ('Run this one place {0} the list' -f $Direction.ToLowerInvariant()))) {
        return [string[]] @($Line)
    }

    $block = Get-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'startCommand')
    $entry = @(Get-HDTWorkspaceItem -Line $Line -Block $block)

    # In document order, whichever way the move was asked for: the splice below
    # walks the file forwards and has to meet the earlier one first.
    $first = $entry[$at]
    $second = $entry[$other]

    if ($first.Index -gt $second.Index) {
        $first = $entry[$other]
        $second = $entry[$at]
    }

    $result = New-Object -TypeName System.Collections.ArrayList
    $index = 0

    while ($index -lt @($Line).Count) {

        if ($index -ne $first.Index) {
            [void] $result.Add([string] $Line[$index])
            $index++
            continue
        }

        # The later entry, then whatever sits between the two, then the earlier
        # one. Anything between them - a blank line, a comment about neither -
        # is still between them afterwards.
        for ($take = $second.Index; $take -le $second.End; $take++) {
            [void] $result.Add([string] $Line[$take])
        }

        for ($take = $first.End + 1; $take -lt $second.Index; $take++) {
            [void] $result.Add([string] $Line[$take])
        }

        for ($take = $first.Index; $take -le $first.End; $take++) {
            [void] $result.Add([string] $Line[$take])
        }

        $index = $second.End + 1
    }

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line ([string[]] @($result)))
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] @($result)
}
