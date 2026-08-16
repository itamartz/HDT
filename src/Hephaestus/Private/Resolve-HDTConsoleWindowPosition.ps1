function Resolve-HDTConsoleWindowPosition {
    <#
        .SYNOPSIS
            Places a console window at the top-left of the usable desktop.

        .DESCRIPTION
            EVERY WINDOW THIS TOOLKIT'S CONSOLE OPENS STARTS IN THE SAME CORNER.
            The console and the task sequence editor both open at the size of the
            work area, so a centred window of that size lands in the same place by
            arithmetic rather than by intent - and the moment one of them is
            smaller than the desktop, or a second monitor changes what "centre"
            means, they stop agreeing. Saying where they go is one rule; letting
            two different WindowStartupLocation values happen to coincide is not.

            IT IS THE WORK AREA'S ORIGIN, NOT A LITERAL 0,0. A taskbar docked at
            the bottom or the right leaves the origin at 0,0 and the two answers
            are identical; docked at the top or the left it moves the origin by
            the taskbar's thickness, and a window placed at 0,0 opens underneath
            it with its title bar covered. That is the same reasoning the size
            clamp already uses, taken from the same measurement.

            ZERO IS A REAL ORIGIN, WHICH IS WHY THERE IS NO GUARD ON IT.
            Resolve-HDTConsoleWindowSize reads a zero width as "the display did
            not say", because no desktop is nought units wide. A zero LEFT is what
            an ordinary desktop reports, so treating it as an absent answer would
            reject the commonest case there is.

            A SCREEN THAT CANNOT BE MEASURED LEAVES THE CORNER ALONE. A display
            query throws in a session with no desktop. That may never be the
            reason a window fails to open, and 0,0 - which is what the caller
            arrived with - is where the work area starts on every desktop that
            does not say otherwise.

            THE SIZE IS NOT TOUCHED. Resolve-HDTConsoleWindowSize already decided
            how big the window is, including the floor and the ceiling that fight
            over it. Two commands reading one measurement is cheaper than one
            command holding two rules.

        .PARAMETER Size
            The window geometry so far - the object Get-HDTConsoleSetting or
            Resolve-HDTConsoleEditorSize built, carrying Width, Height, Left and
            Top. It is returned, modified in place.

        .PARAMETER Screen
            An IScreen, or $null to leave the position as it arrived.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - the same object, with
            Left and Top set to the work area's origin.

        .EXAMPLE
            Resolve-HDTConsoleWindowPosition -Size $size -Screen (New-HDTConsoleScreen)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Size,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [object] $Screen
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Screen) {
        return $Size
    }

    # ONE try FOR THE WHOLE MEASUREMENT, as Resolve-HDTConsoleWindowSize uses one:
    # every way a display can fail to answer ends in the same outcome, so telling
    # them apart would be a distinction with no consequence.
    try {
        $area = $Screen.GetWorkArea()

        $Size.Left = [int] $area.Left
        $Size.Top = [int] $area.Top
    } catch {
        Write-Verbose ('The desktop could not be measured, so the window opens at the corner: {0}' -f
            [string] $_.Exception.Message)
    }

    return $Size
}
