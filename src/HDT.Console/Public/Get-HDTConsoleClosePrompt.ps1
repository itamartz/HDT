function Get-HDTConsoleClosePrompt {
    <#
        .SYNOPSIS
            What to ask an administrator who is closing the editor, and whether
            to ask at all.

        .DESCRIPTION
            THE X IS A WAY OUT AND MUST STAY ONE. The editor used to shut on the
            spot and throw every splice away without a word - the title said
            "unsaved changes" and pressing X agreed with it silently. Nothing
            reached the share, because Save is the only thing that writes, but
            the work was gone.

            SO IT ASKS, AND CLOSING IS STILL ONE OF THE ANSWERS. An editor that
            REFUSED to close until the document was saved would be worse than
            one that discarded it: an administrator who has made a mess of a
            sequence needs to leave without writing it, and that is exactly when
            they are least able to fix it first. Three answers - save and close,
            close without saving, stay.

            IT ONLY ASKS WHEN THERE IS SOMETHING TO LOSE. A window closed
            without an edit in it is closed, immediately. A dialog on every exit
            is a dialog nobody reads, and one that has trained somebody to press
            the same button every time is worse than no dialog at all.

            IT NAMES THE DOCUMENT. Both of this lab's shares hold a DEMO-M4, so
            two editors can be open on windows that differ only in which file
            they would write - and "Save your changes?" over one of them is a
            question with no answer.

            IT SPELLS OUT WHAT THE BUTTONS DO. Yes and No do not say which one
            writes, and the difference between them here is a file on a
            deployment share.

            THE WORDING IS DECIDED HERE, not in the adapter, so what an
            administrator is asked can be read in a test rather than by
            provoking a dialog on a screen.

        .PARAMETER DocumentPath
            The sequence.yaml this editor would write.

        .PARAMETER Dirty
            There are edits that have not been saved.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Ask      whether to put anything on the screen at all
              Title    the dialog's caption
              Message  what it says
              Button   the button set - YesNoCancel
              Icon     Question

        .EXAMPLE
            $prompt = Get-HDTConsoleClosePrompt -DocumentPath $path -Dirty
            if ($prompt.Ask) { $prompt.Message }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $DocumentPath,

        [Parameter()]
        [switch] $Dirty
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $message = ''

    if ($Dirty) {
        $message = @(
            ("This task sequence has changes that have not been saved:" )
            ''
            $DocumentPath
            ''
            'Yes     save them, and close the editor.'
            'No      close the editor and lose them.'
            'Cancel  go back to the editor.'
        ) -join [System.Environment]::NewLine
    }

    return [pscustomobject] @{
        Ask     = [bool] $Dirty
        Title   = 'Task Sequence Editor'
        Message = $message
        Button  = 'YesNoCancel'
        Icon    = 'Question'
    }
}
