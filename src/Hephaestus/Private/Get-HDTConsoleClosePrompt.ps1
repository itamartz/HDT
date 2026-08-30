function Get-HDTConsoleClosePrompt {
    <#
        .SYNOPSIS
            What to ask an administrator who is closing a window, and whether
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

            AND A WINDOW MAY HOLD MORE THAN ONE DOCUMENT, which is the second
            form. The Windows PE window edits workspace.yaml, rules.yaml and
            bootstrap-rules.yaml - three files, three Save buttons - and asked
            this the single-document way it could only ever ask about the first.
            An administrator edited a rule, pressed the Save at the bottom of
            the window, got a success footer naming workspace.yaml and closed:
            the window had nothing to say and the edit was gone.

            SO THE SET FORM NAMES EVERY UNSAVED DOCUMENT, AND THE BUTTON THAT
            WRITES IT - and Yes writes all of them. It used to write only the
            first, which is the same work loss one button along: the prompt
            named rules.yaml, the administrator pressed the button that says it
            keeps the work, and the rule went out of the window anyway.

            AND A DOCUMENT THAT WILL NOT PARSE STOPS THE LOT. Each rules tab's
            Save is dark while its document is broken, and a message box has no
            way to be dark - so Yes over a broken document could only write it
            anyway or skip it in silence, and both of those are worse than not
            closing. Refused names those documents; the window puts
            RefusedMessage on the screen, writes NOTHING and stays open. Half a
            save is the one outcome an administrator cannot reason about,
            because nothing on the screen would say which half.

        .PARAMETER DocumentPath
            The one document this window would write. The sequence editor's
            form.

        .PARAMETER Dirty
            There are edits to that document that have not been saved.

        .PARAMETER Document
            Every document the window can write, each an object carrying Path,
            Dirty and SaveWith - the label on the button that writes it - and
            optionally CanSave, which is that button's own gate. A document
            that does not carry CanSave is taken to be saveable: the sequence
            editor registers none, and a window that refused to close over a
            missing property would be a worse defect than the one this fixes.
            The Windows PE window's form; see New-HDTConsoleBootImageView, which
            hands this straight over from the set it registered.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Ask             whether to put anything on the screen at all
              Title           the dialog's caption
              Message         what it says
              Button          the button set - YesNoCancel
              Icon            Question
              Unsaved         the documents with work in them, by path
              Refused         the unsaved ones Yes cannot write, by path
              RefusedMessage  what to say instead of closing, when there are any

        .EXAMPLE
            $prompt = Get-HDTConsoleClosePrompt -DocumentPath $path -Dirty
            if ($prompt.Ask) { $prompt.Message }

        .EXAMPLE
            $prompt = Get-HDTConsoleClosePrompt -Document $window.HDTDocument
            $prompt.Unsaved
    #>
    [CmdletBinding(DefaultParameterSetName = 'Single')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Single')]
        [ValidateNotNullOrEmpty()]
        [string] $DocumentPath,

        [Parameter(ParameterSetName = 'Single')]
        [switch] $Dirty,

        # AllowEmptyCollection, BECAUSE A WINDOW WITH NOTHING REGISTERED MUST
        # NOT THROW ON ITS WAY OUT. An exception raised inside Add_Closing is
        # raised while the window is going away, where nothing can show it.
        [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
        [AllowEmptyCollection()]
        [object[]] $Document
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($PSCmdlet.ParameterSetName -eq 'Single') {
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

        $unsaved = @()
        if ($Dirty) { $unsaved = @($DocumentPath) }

        # NOTHING IS EVER REFUSED HERE. The editor's Save is not gated on a
        # document that parses, and the two fields exist on both shapes so a
        # caller does not have to know which form it asked for.
        return [pscustomobject] @{
            Ask            = [bool] $Dirty
            Title          = 'Task Sequence Editor'
            Message        = $message
            Button         = 'YesNoCancel'
            Icon           = 'Question'
            Unsaved        = [string[]] $unsaved
            Refused        = [string[]] @()
            RefusedMessage = ''
        }
    }

    # THE SET FORM. Order is the order it was registered in, which is the order
    # the tabs sit in - so the list reads the way the window looks.
    $unsaved = @()
    $named = @()
    $refused = @()
    $refusedName = @()

    foreach ($one in @($Document)) {
        if ($null -eq $one) { continue }
        if (-not [bool] $one.Dirty) { continue }

        $unsaved += [string] $one.Path

        # THE BUTTON, BESIDE THE FILE. Which button saves which file is the one
        # fact the administrator who lost a rule did not have - and it still
        # earns its place now that Yes writes them all, because it says which
        # tab the work is on.
        $named += '    {0}   -   {1}' -f [string] $one.Path, [string] $one.SaveWith

        # ASKED THROUGH PSObject, NOT READ STRAIGHT OFF. Under
        # Set-StrictMode -Version Latest a property that is not there THROWS,
        # and this is called from inside a window's Closing handler where an
        # exception has nowhere to go. Absent means saveable; see the parameter.
        if ($null -eq $one.PSObject.Properties['CanSave']) { continue }
        if ([bool] $one.CanSave) { continue }

        $refused += [string] $one.Path
        $refusedName += '    {0}   -   {1}' -f [string] $one.Path, [string] $one.SaveWith
    }

    $message = ''

    if ($unsaved.Count -gt 0) {
        $message = @(
            'This window has changes that have not been saved:'
            ''
            $named
            ''
            'Each file is written by the button named beside it, on its own tab.'
            ''
            'Yes     save all of them, and close the window.'
            'No      close the window and lose all of it.'
            'Cancel  go back to the window.'
        ) -join [System.Environment]::NewLine
    }

    # WHAT YES SAYS WHEN IT CANNOT KEEP ITS WORD. Not a question - there is
    # nothing to decide, because the window has already declined to close and
    # every edit is still in it.
    $refusedMessage = ''

    if ($refused.Count -gt 0) {
        $refusedMessage = @(
            'These files cannot be saved as they stand:'
            ''
            $refusedName
            ''
            'Each one has the problem named on its own tab, and its Save button'
            'stays dark until that is fixed.'
            ''
            'So nothing has been written and the window is still open. Fix them'
            'and press Save, or close again and answer No to lose the lot.'
        ) -join [System.Environment]::NewLine
    }

    return [pscustomobject] @{
        Ask            = [bool] ($unsaved.Count -gt 0)
        Title          = 'Windows PE'
        Message        = $message
        Button         = 'YesNoCancel'
        Icon           = 'Question'
        Unsaved        = [string[]] $unsaved
        Refused        = [string[]] $refused
        RefusedMessage = $refusedMessage
    }
}
