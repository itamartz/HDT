function Get-HDTConsoleBootImageSaveCommand {
    <#
        .SYNOPSIS
            The command lines the boot image pane echoes after Save - every
            invocation the press made, in the order it made them.

        .DESCRIPTION
            EVERY COMMAND SAVE RAN, NOT JUST THE LAST ONE. One press is seven
            invocations, and echoing only the write hides the six that decided
            what was written - which is exactly the surface DESIGN 12 says the
            box at the bottom of the window exists to teach. The console may not
            do anything the cmdlets cannot, and that promise is only checkable if
            the window shows the whole sequence.

            FOURTEEN BRANCHES, TAKEN OUT OF AN Add_Click. This is the second time
            one press makes the "empty means clear it" decision, and it is made
            against different data than the first: the write half reads the
            BOXES, and this reads the REFRESHED VIEW - so what the box shows is
            what the file now says rather than what somebody typed at it. The two
            can legitimately disagree, because saving normalises. Echoing the
            typed value would print a command that was never run.

            THE ORDER IS THE ORDER THEY RAN IN, because the box exists to be
            retyped: Set-HDTWorkspaceProperty first, the five documents in the
            order the pane applies them, and Save-HDTWorkspaceDocument last.
            Reading it top to bottom has to reproduce the press.

            WHITESPACE IS EMPTY HERE TOO. A box holding a space is one somebody
            cleared badly, and "-Path ' '" is a command that writes a key of
            spaces - the one thing the echo must never teach.

            IT FORMATS ONLY. The clear line and the apply format both come off
            the view, so this command never spells a cmdlet name itself: the view
            and the echo cannot drift into naming different commands.

        .PARAMETER View
            The refreshed boot image view, as Get-HDTConsoleBootImage builds it.
            Each optional setting carries its value, the line that clears it and
            the format that applies it.

        .PARAMETER Path
            The document the save was written to.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - seven command lines, in the order they ran.

        .EXAMPLE
            Get-HDTConsoleBootImageSaveCommand -View $book.View -Path 'C:\ws\workspace.yaml'

        .EXAMPLE
            $commandText.Text = (@(Get-HDTConsoleBootImageSaveCommand -View $book.View -Path $Path) -join
                [System.Environment]::NewLine)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $View,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # The property write the pane made before any document was touched.
    [string] $View.General.Command

    # THE FIVE DOCUMENTS, each as the three facts the echo needs: what it is set
    # to, the line that clears it, and the format that applies it. Two of them
    # hang off General and three carry their own object, which is the only reason
    # this is a table rather than a loop over property names.
    $document = @(
        @{
            Value  = [string] $View.General.Unattend
            Clear  = [string] $View.General.UnattendClearCommand
            Format = [string] $View.General.UnattendCommandFormat
        }
        @{
            Value  = [string] $View.General.Background
            Clear  = [string] $View.General.BackgroundClearCommand
            Format = [string] $View.General.BackgroundCommandFormat
        }
        @{
            Value  = [string] $View.TimeZone.Id
            Clear  = [string] $View.TimeZone.ClearCommand
            Format = [string] $View.TimeZone.ApplyCommandFormat
        }
        @{
            Value  = [string] $View.ClientCertificate.Path
            Clear  = [string] $View.ClientCertificate.ClearCommand
            Format = [string] $View.ClientCertificate.ApplyCommandFormat
        }
        @{
            Value  = [string] $View.Driver.Group
            Clear  = [string] $View.Driver.ClearCommand
            Format = [string] $View.Driver.ApplyCommandFormat
        }
    )

    foreach ($one in $document) {
        if ([string]::IsNullOrWhiteSpace($one.Value)) {
            [string] $one.Clear
            continue
        }

        $one.Format -f $one.Value
    }

    # The write, named for the document it went to.
    "Save-HDTWorkspaceDocument -Line `$line -Path '{0}'" -f $Path
}
