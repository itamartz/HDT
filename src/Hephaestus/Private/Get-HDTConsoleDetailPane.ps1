function Get-HDTConsoleDetailPane {
    <#
        .SYNOPSIS
            Which detail pane a row shows: the field list, or the driver grid.

        .DESCRIPTION
            A DECISION, SO IT LIVES IN A COMMAND. New-HDTConsoleHost and
            New-HDTConsoleView stay branch-free because they are exempt from TDD
            as thin wrappers over WPF, and the price of that exemption is that
            every choice they make is made somewhere Pester can reach.

            A DRIVER FOLDER SHOWS A LIST BECAUSE IT HAS ONE. Every other row on
            this tree is a handful of fields - a share's name and deploy root, a
            sequence's step count - and a folder in the driver store is forty
            drivers, or two hundred. Workbench splits the same way and for the
            same reason.

            THE DRIVERS CATEGORY GETS THE GRID TOO, and shows the whole store.
            An administrator who clicks 'Drivers' and gets two fields about a
            folder path has been told nothing they came for.

        .PARAMETER Kind
            The row's Kind.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with ShowGrid.

        .EXAMPLE
            Get-HDTConsoleDetailPane -Kind 'DriverFolder'

        .EXAMPLE
            (Get-HDTConsoleDetailPane -Kind 'Share').ShowGrid

            $false - a share is fields.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Kind
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [pscustomobject] @{
        ShowGrid = (@('DriverFolder') -contains $Kind)
    }
}
