function New-HDTConsoleScreen {
    <#
        .SYNOPSIS
            Creates the IScreen the console measures its window against.

        .DESCRIPTION
            An adapter over one Windows call and nothing else, which is what
            keeps it branch-free and honestly exempt from TDD (CLAUDE.md rule 1).
            Every decision about what to do with the answer belongs to
            Get-HDTConsoleSetting, which is unit tested against
            New-HDTFakeScreen.

            IT REPORTS THE WORK AREA, NOT THE SCREEN. The work area is the
            desktop minus the taskbar, which is the space a maximised window
            actually gets. Measuring against the full screen would call a window
            that fits, when it is in fact overlapping the taskbar by its height.

            IT USES SystemParameters RATHER THAN Windows.Forms.Screen, and the
            difference matters on a high-DPI display: WPF's Width and Height are
            device-independent units, and SystemParameters.WorkArea is in the
            same units. Windows.Forms.Screen reports physical pixels, so on a
            150% display it would report a desktop half again larger than the one
            WPF is laying the window out in - and the clamp would let through
            exactly the oversized window it exists to prevent.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            An object with one method, GetWorkArea(), returning a
            System.Management.Automation.PSCustomObject with Width and Height in
            device-independent units.

        .EXAMPLE
            (New-HDTConsoleScreen).GetWorkArea()

            The desktop the console has to fit inside.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an adapter object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Add-Type -AssemblyName PresentationFramework

    $screen = [pscustomobject] @{ }

    Add-Member -InputObject $screen -MemberType ScriptMethod -Name 'GetWorkArea' -Value {
        $area = [System.Windows.SystemParameters]::WorkArea

        return [pscustomobject] @{
            Width  = [int] $area.Width
            Height = [int] $area.Height
        }
    }

    return $screen
}
