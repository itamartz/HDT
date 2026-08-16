function Resolve-HDTConsoleEditorSize {
    <#
        .SYNOPSIS
            Decides how big the task sequence editor opens.

        .DESCRIPTION
            IT OPENS AT THE SIZE OF THE WINDOW IT WAS OPENED FROM. The editor is
            reached by double-clicking a task sequence in the browser, and an
            administrator who has dragged that browser out to fill a monitor has
            said what size they want a window on this machine to be. A second
            window that then comes up at a number somebody typed into the markup
            reads as a different application.

            IT IS THE OWNER'S CURRENT SIZE, NOT ITS REMEMBERED ONE. A maximised
            console reports the maximised size, and that is the right answer -
            what was asked for is the size on the screen, not the size the window
            would return to.

            NO OWNER IS A REAL CASE, NOT A GUARD. Show-HDTSequenceEditor is a
            command an administrator can run against a share with no console open
            anywhere, and there is nothing to copy then. Zero in either dimension
            means the caller had nothing to say about it, and each dimension falls
            back on its own - half an answer must not throw away the other half.

            THE FLOOR IS THE EDITOR'S OWN MINIMUM, WHICH IS LOWER THAN THE
            CONSOLE'S. WPF enforces MinWidth and MinHeight whatever it is handed,
            so answering anything below them would be a number that lies about the
            window it produces.

            THE CEILING IS THE DESKTOP, AND IT IS THE CONSOLE'S FITTER THAT
            APPLIES IT. Resolve-HDTConsoleWindowSize already knows why a window
            larger than the work area is worse than one too small, and a second
            copy of that argument is a second thing to keep true. It clamps up to
            the CONSOLE's minimum, which is larger than the editor's, so it can
            only ever raise this answer - never lower it below the markup.

        .PARAMETER OwnerWidth
            The current width of the window the editor was opened from. Zero when
            nothing opened it.

        .PARAMETER OwnerHeight
            The current height of the window the editor was opened from. Zero when
            nothing opened it.

        .PARAMETER Screen
            An IScreen, or $null to leave the answer unfitted.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Width and Height.

        .EXAMPLE
            Resolve-HDTConsoleEditorSize -OwnerWidth 1600 -OwnerHeight 1000 -Screen (New-HDTConsoleScreen)

            The editor, as big as the console it came from.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [int] $OwnerWidth = 0,

        [Parameter()]
        [int] $OwnerHeight = 0,

        [Parameter()]
        [AllowNull()]
        [object] $Screen
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $width = [int] $script:HDTConsoleEditorDefaultWidth
    $height = [int] $script:HDTConsoleEditorDefaultHeight

    # Zero is "the caller had no owner to measure", not "open at nothing" - the
    # same reading Get-HDTConsoleSetting gives a preference file that says zero.
    if ($OwnerWidth -gt 0) { $width = $OwnerWidth }
    if ($OwnerHeight -gt 0) { $height = $OwnerHeight }

    $result = [pscustomobject] @{
        Width  = [Math]::Max($width, [int] $script:HDTConsoleEditorMinimumWidth)
        Height = [Math]::Max($height, [int] $script:HDTConsoleEditorMinimumHeight)
    }

    return (Resolve-HDTConsoleWindowSize -Size $result -Screen $Screen)
}
