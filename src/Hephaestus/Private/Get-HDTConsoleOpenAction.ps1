function Get-HDTConsoleOpenAction {
    <#
        .SYNOPSIS
            What a double-click on a tree row opens, if anything.

        .DESCRIPTION
            TWO KINDS OF ROW OPEN, AND THE ROW SAYS WHICH IT IS. A task sequence
            opens the editor; the boot image opens the Windows PE window, which
            is Deployment Workbench's deployment share Properties. The routing is
            on the Kind the node already carries: Get-HDTConsoleTreeNode made
            that decision once, and a handler working it out again from the row's
            shape would be a second opinion free to drift from the first.

            CanOpen IS NOT AN INVITATION TO OPEN THE EDITOR. It says the row
            carries a subject - and an operating system now carries one, so the
            details pane can write its document. That is not the same as having a
            second window to show. An OS's properties ARE the details pane, and
            opening a sequence editor on an os.yaml would put a step tree on
            screen for a document that has no steps.

            A ROW BUILT SOMEWHERE OTHER THAN Get-HDTConsoleTreeNode may carry no
            CanOpen at all - a monitor row builds its own - and reading a
            property that is not there is a terminating error under StrictMode,
            on the dispatcher, which takes the window down for a double-click on
            a row that was never openable.

            IT OPENS NOTHING ITSELF. It answers which window the caller should
            show, and hands back the subject to show it for.

        .PARAMETER Row
            The selected tree row, or $null.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Open     'SequenceEditor', 'BootImage' or 'None'
              Subject  what to open it for, $null when nothing opens

        .EXAMPLE
            Get-HDTConsoleOpenAction -Row $tree.SelectedItem

        .EXAMPLE
            $open = Get-HDTConsoleOpenAction -Row $selected
            if ($open.Open -eq 'BootImage') { & $openBootImage ([string] $open.Subject) }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Row
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $nothing = [pscustomobject] @{ Open = 'None'; Subject = $null }

    if ($null -eq $Row) { return $nothing }

    # ASKED FOR, NOT ASSUMED. See the StrictMode note above.
    if (@($Row.PSObject.Properties.Match('CanOpen')).Count -eq 0) { return $nothing }
    if (-not [bool] $Row.CanOpen) { return $nothing }

    $kind = [string] $Row.Kind

    if ($kind -eq 'BootImage') {
        return [pscustomobject] @{ Open = 'BootImage'; Subject = $Row.Subject }
    }

    # AND ONLY A TASK SEQUENCE OPENS THE EDITOR. See the CanOpen note above.
    if ($kind -ne 'TaskSequence') { return $nothing }

    return [pscustomobject] @{ Open = 'SequenceEditor'; Subject = $Row.Subject }
}
