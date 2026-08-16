function Resolve-HDTConsoleWindowSize {
    <#
        .SYNOPSIS
            Fits a remembered window size to the desktop that has to show it.

        .DESCRIPTION
            THE WHOLE POINT IS THAT AN ADMINISTRATOR CANNOT BE LOCKED OUT BY A
            PREFERENCE. Get-HDTConsoleSetting already raises a size below the
            window's minimum; this lowers one above the screen's work area, and
            it is the same argument from the other end.

            A WINDOW BIGGER THAN THE DESKTOP IS WORSE THAN ONE TOO SMALL. The
            markup says WindowStartupLocation="CenterScreen", so a window taller
            than the desktop is centred with its title bar above the top edge,
            and a title bar off the top cannot be dragged back with a mouse. The
            window is open, in the task list, focusable, and invisible - which
            reads to the person who launched it as "it did not start".

            EACH DIMENSION IS CLAMPED ON ITS OWN. A narrow desktop is not a
            reason to forget a remembered height, and a short one is not a reason
            to forget a width.

            THE MINIMUM WINS WHERE THEY CONFLICT. On a desktop smaller than the
            window's declared minimum no size satisfies both, and WPF enforces
            MinWidth/MinHeight regardless - so answering anything lower would be
            a number that lies about the window it produces.

            A SCREEN THAT CANNOT BE MEASURED CHANGES NOTHING, deliberately. A
            display query throws in a session with no desktop, and answers zero
            in some remote ones. Neither may be the reason a window fails to
            open, so both leave the size exactly as it arrived.

        .PARAMETER Size
            The size so far - the object Get-HDTConsoleSetting built, with Path,
            Width and Height. It is returned, modified in place.

        .PARAMETER Screen
            An IScreen.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - the same object, with
            Width and Height fitted to the screen.

        .EXAMPLE
            Resolve-HDTConsoleWindowSize -Size $size -Screen (New-HDTConsoleScreen)
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

    # ONE try FOR THE WHOLE MEASUREMENT, for the reason Get-HDTConsoleSetting
    # uses one for the whole read: every way a display can fail to answer ends in
    # the same outcome, so telling them apart would be a distinction with no
    # consequence.
    try {
        $area = $Screen.GetWorkArea()

        $areaWidth = [int] $area.Width
        $areaHeight = [int] $area.Height

        # Zero is "the display did not say", not "a desktop of no size".
        if ($areaWidth -gt 0) {
            $Size.Width = [Math]::Max([Math]::Min([int] $Size.Width, $areaWidth), $script:HDTConsoleMinimumWidth)
        }

        if ($areaHeight -gt 0) {
            $Size.Height = [Math]::Max([Math]::Min([int] $Size.Height, $areaHeight), $script:HDTConsoleMinimumHeight)
        }
    } catch {
        Write-Verbose ('The desktop could not be measured, so the remembered size is used unchanged: {0}' -f
            [string] $_.Exception.Message)
    }

    return $Size
}
