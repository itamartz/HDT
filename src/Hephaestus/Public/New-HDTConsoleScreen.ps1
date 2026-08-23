function New-HDTConsoleScreen {
    <#
        .SYNOPSIS
            Creates the IScreen the console measures its window against.

        .DESCRIPTION
            An adapter over one Windows call and nothing else, which is what
            keeps it branch-free and honestly exempt from TDD.
            Every decision about what to do with the answer belongs to
            Get-HDTConsoleSetting, which is unit tested against
            New-HDTFakeScreen.

            IT REPORTS THE WORK AREA, NOT THE SCREEN. The work area is the
            desktop minus the taskbar, which is the space a maximised window
            actually gets. Measuring against the full screen would call a window
            that fits, when it is in fact overlapping the taskbar by its height.

            AND IT REPORTS WHERE THAT AREA STARTS, NOT ONLY HOW BIG IT IS. The
            console opens at the top-left of the usable desktop, which is a
            literal 0,0 only while the taskbar is docked at the bottom or the
            right. Docked at the top or the left it moves the origin down or
            across by its thickness, and a window pinned to 0,0 would then open
            underneath it - title bar included. The same measurement answers
            both questions, so it is taken once.

            IT USES SystemParameters RATHER THAN Windows.Forms.Screen, and the
            difference matters on a high-DPI display: WPF's Width, Height, Left
            and Top are device-independent units, and SystemParameters.WorkArea
            is a Rect in the same units carrying all four. Windows.Forms.Screen
            reports physical pixels, so on a 150% display it would report a
            desktop half again larger than the one WPF is laying the window out
            in - and the clamp would let through exactly the oversized window it
            exists to prevent, at an origin half again too far across.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            An object with one method, GetWorkArea(), returning a
            System.Management.Automation.PSCustomObject with Left, Top, Width and
            Height in device-independent units.

        .EXAMPLE
            $screen = New-HDTConsoleScreen
            $screen.GetWorkArea()

            The usable desktop - what is left after the taskbar. The console opens
            inside it, so a remembered size from a bigger monitor cannot put the
            window somewhere nobody can reach.

        .EXAMPLE
            $area = $screen.GetWorkArea()
            '{0}x{1} at {2},{3}' -f $area.Width, $area.Height, $area.Left, $area.Top

            The four numbers a window position is decided from. It is a parameter so
            a test can describe a monitor this machine does not have.
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
            Left   = [int] $area.Left
            Top    = [int] $area.Top
            Width  = [int] $area.Width
            Height = [int] $area.Height
        }
    }

    return $screen
}
