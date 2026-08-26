function Get-HDTConsoleDriverSaveState {
    <#
        .SYNOPSIS
            Whether the driver window has anything to save, and what it should
            say about it.

        .DESCRIPTION
            THE DIFFERENCE BETWEEN THE TICK BOX AND THE SHARE, in the two forms
            the window needs it: whether the button can be pressed, and the
            sentence beside it.

            SAVE USED TO GIVE NO ANSWER. Unticking the box and pressing Save
            wrote the document and left the window looking exactly as it had a
            moment earlier - same button, same text, nothing to say the press
            had landed. A button identical before and after is one somebody
            presses twice and then goes to the share to check by hand.

            A GREY BUTTON IS THE STRONGER SIGNAL AND THE WORDS ARE THE PLAINER
            ONE, so this returns both. Grey alone leaves somebody wondering
            whether the button was ever live; words alone leave a live button on
            a window with nothing to write.

            SAVED IS NOT A STICKY LABEL. It describes the write that just
            happened, so ticking the box again takes it away - the share no
            longer says what the window is showing, and a line still claiming
            the write would be describing a state the share is not in.

            THE COMMAND IS ALWAYS SHOWN, pressable or not. The command bar is
            what teaches the cmdlet behind the window, and hiding it until
            somebody edits something teaches it to nobody.

        .PARAMETER Enabled
            What the tick box says now.

        .PARAMETER Saved
            What the share says - the value the catalog last read back, moved on
            by each successful write.

        .PARAMETER Root
            The deployment share root, for the command line shown.

        .PARAMETER Path
            The driver, counted from inside the store.

        .PARAMETER Written
            This window has written at least once, and the last value it wrote
            is the one in -Saved. Without it there is no write to report.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Dirty, CanSave,
            Status and Command.

        .EXAMPLE
            Get-HDTConsoleDriverSaveState -Enabled $false -Saved $true -Root 'C:\HDTLab\Share' -Path 'WinPE\Dell\e1d.inf'

            The box unticked and not yet saved: CanSave is true and Status reads
            'Unsaved change'.

        .EXAMPLE
            $state = Get-HDTConsoleDriverSaveState -Enabled $false -Saved $false -Root $root -Path $path -Written
            $state.Status

            What the window shows the moment Set-HDTDriverState comes back.

        .LINK
            Set-HDTDriverState

        .LINK
            Get-HDTConsoleEditorState
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [bool] $Enabled,

        [Parameter(Mandatory = $true, Position = 1)]
        [bool] $Saved,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowEmptyString()]
        [string] $Root,

        [Parameter(Mandatory = $true, Position = 3)]
        [AllowEmptyString()]
        [string] $Path,

        [Parameter()]
        [switch] $Written
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $dirty = ($Enabled -ne $Saved)

    $status = ''
    if ($dirty) {
        $status = 'Unsaved change'
    } elseif ($Written) {
        $status = 'Saved'
    }

    return [pscustomobject] @{
        Dirty   = [bool] $dirty
        CanSave = [bool] $dirty
        Status  = [string] $status
        # LOWER CASE, BECAUSE THAT IS WHAT GETS PASTED. PowerShell renders a
        # boolean as 'True', and 'Set-HDTDriverState -Enabled $True' runs -
        # but nobody writes it that way, and the command bar is copied by hand
        # more often than it is read.
        Command = "Set-HDTDriverState -Root '{0}' -Path '{1}' -Enabled `${2}" -f
        $Root, $Path, ([string] $Enabled).ToLowerInvariant()
    }
}
