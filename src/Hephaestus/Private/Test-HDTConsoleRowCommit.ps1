function Test-HDTConsoleRowCommit {
    <#
        .SYNOPSIS
            Whether an edit on the console's details pane should be written to
            the document at all.

        .DESCRIPTION
            TWO HANDLERS ASK THIS, about two different gestures. A text box
            commits when focus leaves it; a combo box commits the moment the pick
            is made, because the list closes on the click and there is no
            "moving focus off it" a technician has any reason to cause. Both then
            have to answer the same question, and both used to answer it with
            their own run of guards inside their own handler.

            ASKED FOR, NOT ASSUMED. Not every row in this pane comes from
            New-HDTConsoleField - a monitor row and a share that would not open
            build their own - so Editable may not be on the row at all. Under
            Set-StrictMode, reading a property that is not there is a terminating
            error ON THE DISPATCHER, which takes the whole window down for a
            click on a box that was never editable in the first place. So the
            property is tested for before its value is read, and the same goes
            for Original.

            UNCHANGED IS NOT AN EDIT. Leaving a box without typing in it raises
            LostFocus exactly as an edit does, and rebuilding the pane raises
            SelectionChanged before the binding has settled. Writing on either
            would put the document through a read-set-save for nothing, mark the
            window dirty, and light up Save for walking through a sequence and
            reading it.

            AN EMPTY PICK IS NOT A PICK, BUT AN EMPTY BOX IS AN EDIT. Those are
            opposite answers to the same empty string, and the gesture is what
            separates them: a combo box reporting nothing selected is a binding
            that has not settled, while a text box somebody emptied is how a
            value gets cleared. -Picked is what tells them apart.

        .PARAMETER Row
            The row behind the control. May be $null, and may be a row that
            carries neither Editable nor Original.

        .PARAMETER Typed
            What the control holds now.

        .PARAMETER Picked
            The edit came from a combo box selection rather than a text box, so
            an empty value means the binding has not settled rather than a value
            somebody cleared.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean - whether to write the edit.

        .EXAMPLE
            Test-HDTConsoleRowCommit -Row $box.DataContext -Typed $box.Text

        .EXAMPLE
            if (Test-HDTConsoleRowCommit -Row $combo.DataContext -Typed $picked -Picked) {
                & $writeRow $row $picked $revert
            }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Row,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Typed,

        [Parameter()]
        [switch] $Picked
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Row) { return $false }

    # ASKED FOR, NOT ASSUMED. See the StrictMode note above.
    if (@($Row.PSObject.Properties.Match('Editable')).Count -eq 0) { return $false }
    if (-not [bool] $Row.Editable) { return $false }

    if (@($Row.PSObject.Properties.Match('Original')).Count -eq 0) { return $false }

    # AN EMPTY PICK IS NOT A PICK. A text box emptied on purpose is an edit.
    if ($Picked -and [string]::IsNullOrEmpty($Typed)) { return $false }

    # UNCHANGED IS NOT AN EDIT.
    if ($Typed -ceq [string] $Row.Original) { return $false }

    return $true
}
