function New-HDTConsolePendingNode {
    <#
        .SYNOPSIS
            The row the console shows while it is still reading the share.

        .DESCRIPTION
            THE WINDOW OPENS BEFORE THE SHARE IS READ. Get-HDTConsoleWorkspace
            costs 820ms on the lab share - it reads and validates every task
            sequence in it - and until this row existed that second was spent
            with nothing on screen at all, because the tree had to be built
            before the window could be shown.

            SO THIS IS WHAT THE TREE HOLDS IN BETWEEN: one row, saying what is
            happening and to which share. A window that appears empty for a
            second is a window somebody clicks again, and then wonders why two
            consoles opened.

            IT CARRIES NO HeaderRoot, DELIBERATELY. The refresh timer and the
            rebuild both walk the tree looking for share roots to re-read; a
            placeholder that named one would be re-read as a share, and there is
            nothing there yet to read.

        .PARAMETER Path
            The shares about to be read, in the order they were given.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - one row, at depth 0.

        .EXAMPLE
            New-HDTConsolePendingNode -Path 'C:\HDTLab\Share'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a row in memory; it changes nothing.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [string[]] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $header = [pscustomobject] @{
        Title      = 'Hephaestus Deployment Toolkit'
        Root       = ''
        DeployRoot = ''
    }

    $field = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($Path)) {
        [void] $field.Add((New-HDTConsoleField -Label 'Share' -Value ([string] $current)))
    }

    [void] $field.Add((New-HDTConsoleField -Label '' `
                -Value 'Every task sequence on the share is read and checked before its row can say whether it is valid, which is what this is waiting for.'))

    return New-HDTConsoleNode -Depth 0 -Kind 'Root' -Status 'Ok' `
        -Text 'Deployment Shares - reading...' `
        -Field ([object[]] @($field)) `
        -Command ("Get-HDTConsoleWorkspace -Path '{0}'" -f (@($Path) -join "', '")) `
        -Header $header
}
