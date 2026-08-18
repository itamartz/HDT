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

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Status, Message, StatusText  whether the text still reads, and what to say
              Node, Root                   the tree, flat and as roots
              Selected                     the row SelectedName names, or nothing
              Option                       Get-HDTConsoleStepOption for it, or nothing
              StepCount                    how many steps the document holds
              Dirty                        echoed back, so the window has one source
              CanRemove, CanCopy, CanMoveUp, CanMoveDown, CanPaste, CanSave

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
        [object] $Document
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
    $sequence = [pscustomobject] @{
        Id     = [string] $sequence.Id
        Name   = [string] $sequence.Name
        Path   = [string] $Path
        Status = 'Ok'
        Step   = @($sequence.Step)
        Group  = @($sequence.Group)
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

    $built = Get-HDTConsoleStepNode -Sequence $sequence -Header $header

    # -- the selected row, and what it makes possible ----------------------

    $selected = $null
    $option = $null

    $canMoveUp = $false
    $canMoveDown = $false

    if (-not [string]::IsNullOrEmpty($SelectedName)) {
        $step = @($sequence.Step | Where-Object { $_.Name -eq $SelectedName })
        $group = @($sequence.Group | Where-Object { @($_.Path).Count -gt 0 -and $_.Path[-1] -eq $SelectedName })

        $subject = $null
        $sibling = @()

        if (@($step).Count -gt 0) {
            $subject = $step[0]

            # A step's neighbours are the steps sharing its GroupPath - the last
            # step of one group is not the neighbour of the first step of the
            # next, however adjacent they look on screen.
            $key = @($subject.GroupPath) -join "`u{001F}"
            $sibling = @($sequence.Step | Where-Object { (@($_.GroupPath) -join "`u{001F}") -eq $key })
        } elseif (@($group).Count -gt 0) {
            $subject = $group[0]

            # A group's are the groups at its own level under the same parent.
            #
            # NOT $path: PowerShell variable names are case-insensitive, so that
            # would assign to this function's own [string] $Path parameter,
            # which coerces the array to a single string and takes .Count with
            # it. The failure surfaces two lines later as "the property 'Count'
            # cannot be found", naming neither the parameter nor the assignment.
            $groupPath = @($subject.Path)
            $depth = $groupPath.Count
            $parent = Get-HDTGroupParent -Path $groupPath

            $sibling = @($sequence.Group | Where-Object {
                    $other = @($_.Path)

                    $other.Count -eq $depth -and (Get-HDTGroupParent -Path $other) -eq $parent
                })
        }

        if ($null -ne $subject) {
            $at = [array]::IndexOf($sibling, $subject)

            $canMoveUp = ($at -gt 0)
            $canMoveDown = ($at -ge 0 -and $at -lt (@($sibling).Count - 1))

            $option = Get-HDTConsoleStepOption -Step $subject

            # The row on screen, so the window can put the selection back where
            # it was after a splice rebuilt the tree. Matched on Name rather
            # than Text: a step legitimately called '2. Reboot' would otherwise
            # be found by the wrong row, or by none.
            $selected = @($built.Node | Where-Object { $_.Name -eq $SelectedName })[0]

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
