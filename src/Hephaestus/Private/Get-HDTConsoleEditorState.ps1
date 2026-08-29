function Get-HDTConsoleEditorState {
    <#
        .SYNOPSIS
            Everything the task sequence editor shows about a document it is
            part-way through editing: the tree, the selected row's options, and
            which actions are available.

        .DESCRIPTION
            THIS IS WHAT LETS THE WINDOW STAY BRANCH-FREE. Wiring the toolbar
            means deciding things - which buttons are live for the selected row,
            what the tree looks like after a splice, whether the edited text
            still parses - and this toolkit puts decisions in commands
            rather than in an adapter nothing tests. With this in place every
            handler in New-HDTConsoleHost is one call and one assignment.

            THE EDITED LINES ARE RE-READ THROUGH THE ENGINE, NOT TRACKED AS A
            MODEL. After each splice the text is handed to
            Import-HDTSequenceDocument through an in-memory IFileSystem, so what
            the tree draws is what the DEPLOYMENT would run - not a parallel
            model of it that could drift. It also means a splice that produced
            something unreadable is caught here, with the file on the share
            still intact, which is the same check
            Save-HDTSequenceDocument makes one press later.

            A BROKEN DOCUMENT REPORTS RATHER THAN THROWS. An editor that threw
            mid-edit would leave an administrator with a dialog they cannot
            dismiss and a window they cannot get their work out of. The status
            says what happened and every action goes dark, which is the same
            answer Get-HDTConsoleStepNode gives a sequence that will not parse.

            UP IS NOT ALWAYS AVAILABLE, AND THAT IS DELIBERATE.
            Move-HDTStep refuses to move the first step in a group past
            the group's own boundary, because "before the group" and "the last
            step of the group above" are both plausible and the console must not
            guess. A toolbar that
            offered Up there would turn an ordinary-looking press into an error
            box, so the button is dark instead - the refusal is the same, made
            one moment earlier and without the dialog.

            SIBLINGS ARE COUNTED IN THE DOCUMENT, NOT IN THE TREE. A group's
            neighbours are the other groups at its level; a step's are the steps
            sharing its GroupPath. Counting rows on screen would make the last
            step of one group look like the neighbour of the first step of the
            next, which is exactly the move that is refused.

            PASTE AND SAVE ARE ABOUT THE WINDOW, NOT THE DOCUMENT. Whether
            anything has been copied, and whether anything has been changed, are
            facts the window holds; they come in as switches so that this
            command still has no state of its own and can be called as often as
            the tree is rebuilt.

        .PARAMETER Line
            The document as it currently stands, already split into lines.

        .PARAMETER Path
            The sequence.yaml these lines came from. Used so any error the
            engine raises names the file the administrator is editing.

        .PARAMETER SelectedName
            The step or group the administrator has selected, if any.

        .PARAMETER HasClipboard
            Something has been copied, so Paste means something.

        .PARAMETER Dirty
            There are edits that have not been saved.

        .PARAMETER NoTree
            The caller binds neither Node nor Root, so the rows are not built.
            Both come back empty and everything else is unchanged.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Status, Message, StatusText  whether the text still reads, and what to say
              Node, Root                   the tree, flat and as roots - both
                                           empty under -NoTree
              Selected                     the row SelectedName and
                                           SelectedOccurrence name, or nothing
              Option                       Get-HDTConsoleStepOption for it, or nothing
              StepCount                    how many steps the document holds
              Dirty                        echoed back, so the window has one source
              CanRemove, CanCopy, CanMoveUp, CanMoveDown, CanPaste, CanSave
              MoveUpTarget, MoveDownTarget
                                           where Up and Down would put the
                                           selected row - Target,
                                           TargetOccurrence and Position - or
                                           nothing, which is what a dark button
                                           means

        .EXAMPLE
            $state = Get-HDTConsoleEditorState -Line $line -Path $path -SelectedName 'Apply OS'
            $state.CanMoveUp

        .EXAMPLE
            $line = Move-HDTStep -Line $line -Name 'Apply OS' -Direction Down
            $state = Get-HDTConsoleEditorState -Line $line -Path $path -SelectedName 'Apply OS' -Dirty

            The whole editing loop: splice, then re-read.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Position = 2)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $SelectedName,

        # WHICH OF THE SAME-NAMED ROWS WAS SELECTED, 1-BASED. The tree is rebuilt
        # from scratch after every splice, so the object that was selected no
        # longer exists and the selection has to be described rather than held -
        # and a name alone cannot describe it when two steps share one.
        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $SelectedOccurrence = 0,

        [Parameter()]
        [switch] $HasClipboard,

        [Parameter()]
        [switch] $Dirty
,

        # WHAT THE HOST ALREADY PARSED. The editor rebuilds its whole right
        # pane after every edit and four view models each turned the same lines
        # back into a document to do it - about 70ms apiece, on the UI thread,
        # while somebody waited for a checkbox to tick.
        #
        # THE HOST GUARANTEES THEY AGREE: it parses $book.Line once and hands
        # the result to all four in the same refresh. Omitted, this parses the
        # lines exactly as it always did, which is what a script or a test
        # wants.
        [Parameter()]
        [AllowNull()]
        [object] $Document,

        # THE CALLER SAYING IT WILL BIND NEITHER Node NOR Root, so the rows are
        # not built at all - the same bargain Get-HDTDriver -NoHardwareId makes
        # with the grid it fills.
        #
        # IT IS THE SELECTION PATH THIS EXISTS FOR, and the header above already
        # said so: reflect must never touch the tree, because assigning
        # ItemsSource from inside a selection change pulls the rows out from
        # under the handler still choosing one. It said it and then called
        # Get-HDTConsoleStepNode anyway - 164ms of a 365ms click on a 17-row
        # sequence, building rows that were discarded on the next line, and
        # linearly worse on a real client sequence.
        #
        # NOTHING ELSE CHANGES. Every button, every option, the Variables tab
        # and the status line are worked out from the DOCUMENT rather than from
        # the rows, which is what makes this a saving rather than a trade.
        # Selected goes with the tree, because it IS a row: it is the object the
        # window marks IsSelected, and there is nothing to mark.
        [Parameter()]
        [switch] $NoTree
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $status = 'Ok'
    $message = ''
    $sequence = $null

    try {
        # HANDED IN? THEN NOTHING IS RE-READ. See the -Document help above. The
        # try still wraps it: a document the host parsed is already known good,
        # and one it did not is the case this catch exists for.
        if ($null -ne $Document) {
            $sequence = $Document
        } else {
            $reader = New-HDTFileSystemFromText -Path $Path -Text ($Line -join [System.Environment]::NewLine)
            $sequence = Import-HDTSequenceDocument -Path $Path -FileSystem $reader
        }
    } catch {
        $status = 'Error'
        $message = [string] $_.Exception.Message
    }

    if ($status -eq 'Error') {
        return [pscustomobject] @{
            Status      = 'Error'
            Message     = $message
            StatusText  = ('This document cannot be read: {0}' -f $message)
            Node        = [pscustomobject[]] @()
            Root        = [pscustomobject[]] @()
            Selected    = $null
            Option      = $null
            StepCount   = 0
            Dirty       = [bool] $Dirty
            CanRemove   = $false
            CanCopy     = $false
            CanMoveUp   = $false
            CanMoveDown = $false
            CanPaste    = $false
            CanSave     = $false
        }
    }

    # -- the tree ----------------------------------------------------------
    #
    # Get-HDTConsoleStepNode reads a workspace's task sequence row rather than a
    # document, so the document is presented as one. Nothing is invented: every
    # field below is either the document's own or the path it was read from.
    #
    # AND THE VARIABLE BLOCK COMES WITH IT, which it did not - so the Variables
    # tab was empty on every sequence that had one. This projection is built
    # BEFORE the block below reads $sequence.Variable, and dropping the key here
    # meant the read a few lines down found nothing, every time, silently: an
    # empty grid looks exactly like a sequence that declares no variables.
    $carried = $null
    if ($null -ne $sequence.PSObject.Properties['Variable']) { $carried = $sequence.Variable }

    $sequence = [pscustomobject] @{
        Id       = [string] $sequence.Id
        Name     = [string] $sequence.Name
        Path     = [string] $Path
        Status   = 'Ok'
        Step     = @($sequence.Step)
        Group    = @($sequence.Group)
        Variable = $carried
    }

    # -- the Variables tab ---------------------------------------------------
    #
    # THE BLOCK THE NEW SEQUENCE WINDOW FILLS. Read on every refresh rather than
    # once at open, because the tab edits it: a row showing what the document
    # said before the last Set would be a row that lies after the first edit.
    #
    # THE MAP MAKES THE ROW READABLE. HDTOSImageIndex on its own teaches nobody;
    # Get-HDTVariableMap carries the sentence and the name MDT used, which is
    # what somebody arriving from Workbench is looking for.
    $map = @{}
    foreach ($entry in @(Get-HDTVariableMap)) { $map[[string] $entry.HDTName] = $entry }

    $variableRow = New-Object -TypeName System.Collections.ArrayList

    if ($null -ne $sequence.PSObject.Properties['Variable'] -and $null -ne $sequence.Variable) {
        foreach ($name in @($sequence.Variable.Keys)) {
            $hint = 'Not one of the variables HDT publishes - a step in this sequence reads it.'
            $mdtName = ''

            if ($map.ContainsKey([string] $name)) {
                $hint = [string] $map[[string] $name].Description
                $mdtName = [string] $map[[string] $name].MdtName
            }

            [void] $variableRow.Add([pscustomobject] @{
                    Name    = [string] $name
                    Value   = [string] $sequence.Variable[$name]
                    Hint    = $hint
                    MdtName = $mdtName
                })
        }
    }

    $header = [pscustomobject] @{
        Title      = '{0} - {1}' -f $sequence.Id, $sequence.Name
        Root       = [string] $Path
        DeployRoot = [string] $sequence.Id
    }

    # THE SAME SHAPE EITHER WAY, so a caller that turns -NoTree on does not have
    # to start checking for a different set of properties - which is the bargain
    # Get-HDTConsoleStepNode itself makes with a sequence that will not parse.
    $built = [pscustomobject] @{
        Node     = [pscustomobject[]] @()
        TopLevel = [pscustomobject[]] @()
    }

    if (-not $NoTree) { $built = Get-HDTConsoleStepNode -Sequence $sequence -Header $header }

    # -- the selected row, and what it makes possible ----------------------

    $selected = $null
    $option = $null

    $canMoveUp = $false
    $canMoveDown = $false

    # WHERE UP AND DOWN WOULD PUT IT, worked out by the command that owns that
    # question. They used to mean "swap with a sibling", so a step at the edge of
    # a group had a dark button and nowhere to go; they now walk the list a
    # technician can SEE, crossing group boundaries wherever it does.
    #
    # A DARK BUTTON NOW MEANS THE END OF THE DOCUMENT and nothing else. It used
    # to mean the edge of a group, which is why a step could be stuck in one.
    $moveUpTarget = $null
    $moveDownTarget = $null

    if (-not [string]::IsNullOrEmpty($SelectedName)) {

        # A DOCUMENT THAT WILL NOT PARSE MUST NOT THROW OUT OF AN EDITOR. The
        # status line already says the text is broken; a second failure here
        # would replace that sentence with a stack.
        try {
            $moveUpTarget = Get-HDTStepNeighbourTarget -Line $Line -Name $SelectedName `
                -Occurrence $SelectedOccurrence -Direction Up
        } catch {
            $moveUpTarget = $null
        }

        try {
            $moveDownTarget = Get-HDTStepNeighbourTarget -Line $Line -Name $SelectedName `
                -Occurrence $SelectedOccurrence -Direction Down
        } catch {
            $moveDownTarget = $null
        }
    }

    if (-not [string]::IsNullOrEmpty($SelectedName)) {
        $step = @($sequence.Step | Where-Object { $_.Name -eq $SelectedName })
        $group = @($sequence.Group | Where-Object { @($_.Path).Count -gt 0 -and $_.Path[-1] -eq $SelectedName })

        $subject = $null

        # THE SIBLING ARITHMETIC IS GONE. It existed to answer CanMoveUp and
        # CanMoveDown from the row's index among its own siblings, which is what
        # made a step at the edge of a group unmovable - the toolbar was
        # describing a group's contents rather than the list on screen.
        # Get-HDTStepNeighbourTarget answers that now, above.

        # AND THE SUBJECT FOLLOWS THE SELECTED ROW, NOT THE FIRST OF ITS NAME.
        # $step[0] meant that on a sequence with two steps called 'Tattoo' the
        # Options tab, the condition box, the Runs-in text and the two
        # checkboxes all described the FIRST one however carefully the second
        # was clicked - quietly, and only on duplicates.
        #
        # THE ORDINAL IS CLAMPED RATHER THAN TRUSTED. It is counted across
        # groups AND steps, the way Resolve-HDTStepBlock counts, so a document
        # holding a group and a step of the same name can hand this a number
        # past the end of the step list. Landing on the last of them is wrong
        # in a way somebody can see; an index error is a window that will not
        # open.
        $pick = {
            param([object[]] $Candidate)

            if (@($Candidate).Count -eq 0) { return $null }

            $index = 0
            if ($SelectedOccurrence -gt 0) { $index = $SelectedOccurrence - 1 }
            if ($index -gt (@($Candidate).Count - 1)) { $index = @($Candidate).Count - 1 }

            return $Candidate[$index]
        }

        if (@($step).Count -gt 0) {
            $subject = & $pick $step
        } elseif (@($group).Count -gt 0) {
            $subject = & $pick $group
        }

        $canMoveUp = ($null -ne $moveUpTarget)
        $canMoveDown = ($null -ne $moveDownTarget)

        if ($null -ne $subject) {

            # THE SIBLING ARITHMETIC THAT USED TO LIVE HERE IS GONE. It set
            # CanMoveUp from the row's index among its own siblings, which is
            # what made a step at the edge of a group unmovable: the buttons
            # were describing a group's contents rather than the list on screen.
            # Get-HDTStepNeighbourTarget answers that now, above, and a dark
            # button means the end of the DOCUMENT.
            $option = Get-HDTConsoleStepOption -Step $subject

            # The row on screen, so the window can put the selection back where
            # it was after a splice rebuilt the tree. Matched on Name rather
            # than Text: a step legitimately called '2. Reboot' would otherwise
            # be found by the wrong row, or by none.
            # THE OCCURRENCE PICKS THE ROW WHEN THE NAME CANNOT. Without it the
            # first row of that name is highlighted after every splice, so a
            # technician editing the second Tattoo watched the selection jump to
            # the first one each time they touched it.
            $candidate = @($built.Node | Where-Object { $_.Name -eq $SelectedName })

            $selected = $null
            if (@($candidate).Count -gt 0) {
                $selected = $candidate[0]

                if ($SelectedOccurrence -gt 0 -and $SelectedOccurrence -le @($candidate).Count) {
                    $selected = $candidate[$SelectedOccurrence - 1]
                }
            }

            # AND IT IS MARKED, so the tree comes back with it highlighted. The
            # window binds TreeViewItem.IsSelected to this and does nothing
            # else; a host that walked ItemContainerGenerator to find the row
            # again would be a decision in an adapter, and one only a person
            # looking at a screen could check.
            if ($null -ne $selected) { $selected.IsSelected = $true }
        }
    }

    $found = ($null -ne $option)

    $count = @($sequence.Step).Count

    $statusText = '{0} steps' -f $count
    if ($Dirty) { $statusText = '{0} steps - unsaved changes' -f $count }

    return [pscustomobject] @{
        Status      = 'Ok'
        Message     = ''
        StatusText  = $statusText
        Node        = [pscustomobject[]] @($built.Node)
        Root        = [pscustomobject[]] @($built.TopLevel)
        Selected    = $selected
        Option      = $option
        StepCount   = $count
        Dirty       = [bool] $Dirty
        MoveUpTarget   = $moveUpTarget
        MoveDownTarget = $moveDownTarget
        CanRemove   = $found
        CanCopy     = $found
        CanMoveUp   = $canMoveUp
        CanMoveDown = $canMoveDown
        CanPaste    = ([bool] $HasClipboard -and $found)
        CanSave     = [bool] $Dirty

        Variable    = [pscustomobject[]] @($variableRow)
        # WHAT THE BOX OFFERS TO TYPE AGAINST. A name typed from memory is a
        # name typed wrong - HDTOSImageIndex, HDTJoinWorkgroup, HDTAdminPassword
        # are close enough to guess and far enough to get wrong - and a misspelt
        # one sets something nothing reads, silently, until a deployment comes
        # out with the wrong answer.
        #
        # WRITABLE ONLY. The engine-owned _HDT* names are refused by the command
        # and by rules.yaml alike, so offering them would be offering a mistake.
        VariableChoice = [string[]] @(Get-HDTVariableMap |
                Where-Object { $_.Writable } | ForEach-Object { [string] $_.HDTName })

        VariableCommandFormat       = 'Set-HDTSequenceVariable -Line $line -Name ''{0}'' -Value ''{1}'''
        VariableRemoveCommandFormat = 'Set-HDTSequenceVariable -Line $line -Name ''{0}'' -Remove'
    }
}
