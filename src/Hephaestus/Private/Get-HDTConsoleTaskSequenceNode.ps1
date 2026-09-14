function Get-HDTConsoleTaskSequenceNode {
    <#
        .SYNOPSIS
            The Task Sequences category of one share, and every row under it.

        .DESCRIPTION
            The sequences a share holds, with DESIGN 12's inline validation on each
            row: Test-HDTTaskSequence has already been asked, and the answer belongs
            where somebody sees it before they boot a machine rather than after.

            THE BROWSER STOPS AT THE SEQUENCE. Its steps are
            Get-HDTConsoleSequenceEditor's, the way Workbench edits a sequence in a
            properties window opened from the tree rather than in the tree.

            ONE CATEGORY, ONE BUILDER - see Get-HDTConsoleShareNode, which composes
            this one with the rest in the order a share is built.

        .PARAMETER Workspace
            The share from Get-HDTConsoleWorkspace this category belongs to.
            The whole projection is passed rather than the one list this
            category draws: the rows carry the share root in their commands and
            some carry the share itself as Subject, so a narrower parameter
            would be three parameters that always travel together.

        .PARAMETER Header
            The banner every node in the tree carries, from
            Get-HDTConsoleHeader.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] - the category row
            first, then every row beneath it in display order. The rows are also
            wired into the Children of their parents, so the caller adds the
            whole list to the flat reading and the first row to the tree.

        .EXAMPLE
            Get-HDTConsoleTaskSequenceNode -Workspace $workspace -Header $header
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Workspace,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [object] $Header
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $node = New-Object -TypeName System.Collections.ArrayList


    $sequenceFolder = Get-HDTWorkspacePath -Root $Workspace.Root -Kind TaskSequences
    $sequenceCommand = "Get-HDTWorkspacePath -Root '{0}' -Kind TaskSequences" -f $Workspace.Root

    # NAMED, NOT JUST LABELLED. The text carries a count - 'Task Sequences (5)' -
    # and the window has to be able to tell this row from the other three
    # categories to hang New Task Sequence off it. Matching on a label would put
    # a parser in the window and break the day somebody rewords it.
    $sequenceCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' `
        -Name 'TaskSequences' `
        -Text ('Task Sequences ({0})' -f @($Workspace.TaskSequence).Count) `
        -Icon (Get-HDTConsoleIcon -Kind 'TaskSequence' -Status 'Ok') `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $sequenceFolder
        New-HDTConsoleField -Label 'Task Sequences' -Value @($Workspace.TaskSequence).Count
    ) `
        -Command $sequenceCommand -Header $Header

    [void] $node.Add($sequenceCategory)

    $sequenceRow = New-Object -TypeName System.Collections.ArrayList

    foreach ($sequence in @($Workspace.TaskSequence)) {
        # DESIGN 12'S "VALIDATION, SURFACED INLINE". Test-HDTTaskSequence answers
        # what a schema cannot - would this sequence actually work on the machine
        # you are about to deploy - and Get-HDTConsoleWorkspace has already asked
        # it. This puts the answer where somebody will see it before they boot a
        # machine rather than after.
        $lint = Get-HDTConsoleLintText -Finding $sequence.Finding

        # THE TWO THAT CAN BE TYPED INTO, and they are typed into HERE rather
        # than in a window that has to be opened first: renaming a sequence is
        # the commonest edit there is, and Workbench asks for a properties
        # dialog to do it. The id is not among them - it is the folder name, so
        # changing it is a move rather than an edit.
        #
        # NO '(none)' ON THE DESCRIPTION: the fallback is for reading, and a box
        # somebody tabs out of writes what is in it. The empty box says the same
        # thing and writes nothing.
        $field = @(
            New-HDTConsoleField -Label 'Id' -Value $sequence.Id
            New-HDTConsoleField -Label 'Name' -Value $sequence.Name -Property 'name'

            # MDT'S Version BOX, on the row MDT puts it on. The document has
            # always carried the key and the importer has always read it; it was
            # the one header a sequence had that the console could neither show
            # nor write, so changing it meant editing the YAML by hand.
            New-HDTConsoleField -Label 'Version' -Value ([string] $sequence.Version) -Property 'version'
            New-HDTConsoleField -Label 'Description' -Value ([string] $sequence.Description) -Property 'description'
            New-HDTConsoleField -Label 'Steps' -Value $sequence.StepCount
            New-HDTConsoleField -Label 'Groups' -Value $sequence.GroupCount
            New-HDTConsoleField -Label 'Validation' -Value $lint.Detail
            New-HDTConsoleField -Label 'Document' -Value $sequence.Path
        )

        $text = '{0} - {1}' -f $sequence.Id, $sequence.Name

        # THE COUNT GOES ON THE ROW. A tree of thirty sequences is scanned, not
        # read: the row has to say "this one" without being opened, and the pane
        # is for somebody who has already decided to look.
        $sequenceStatus = $sequence.Status

        if ($sequence.Status -eq 'Ok' -and -not [string]::IsNullOrEmpty($lint.Caption)) {
            $text = '{0} - {1}  ({2})' -f $sequence.Id, $sequence.Name, $lint.Caption
            $sequenceStatus = $lint.Status
        }

        if ($sequence.Status -eq 'Error') {
            $text = '{0} - (unreadable)' -f $sequence.Id
            $field = @(
                New-HDTConsoleField -Label 'Id' -Value $sequence.Id
                New-HDTConsoleField -Label 'Document' -Value $sequence.Path
                New-HDTConsoleField -Label 'Could not be read' -Value $sequence.Error
            )
        }

        # THE ID IS THE NAME, and Text is only the label. Name falls back to Text
        # when it is not given, so the tree's Remove was handed
        # 'DEMO-M4 - Deploy Windows 11 LTSC' as an id and refused it for having
        # spaces - a row that would not go, for a reason that appeared in the
        # command box rather than anywhere near the row. It is also what survives
        # somebody rewording the label.
        $row = New-HDTConsoleNode -Depth 3 -Kind 'TaskSequence' -Status $sequenceStatus `
            -Name ([string] $sequence.Id) `
            -Text $text -Field $field `
            -Command ("Import-HDTSequenceDocument -Path '{0}'" -f $sequence.Path) `
            -Header $Header -Subject $sequence

        # THE BROWSER STOPS HERE, and the steps are Get-HDTConsoleSequenceEditor's.
        # Deployment Workbench lists task sequences in the tree and edits their
        # steps in a properties window opened from one; CLAUDE.md asks for a
        # console close enough to it that muscle memory transfers. Expanding
        # every step of every sequence of every share would also be unusable at
        # the size an administrator runs - the lab's own sample share is four
        # sequences and over thirty step rows before a single operating system.
        $row | Add-Member -MemberType NoteProperty -Name 'Folder' `
            -Value ([string] $sequence.Folder) -Force

        [void] $sequenceRow.Add($row)
    }

    $sequenceGrouped = Group-HDTConsoleFolderRow -Row ([object[]] @($sequenceRow)) -Depth 3 `
        -Declared ([string[]] @($Workspace.Folder.TaskSequence)) -Category TaskSequence -Header $Header

    foreach ($current in @($sequenceGrouped.Node)) { [void] $node.Add($current) }
    foreach ($current in @($sequenceGrouped.TopLevel)) { [void] $sequenceCategory.Children.Add($current) }

    if (@($Workspace.TaskSequence).Count -eq 0) {
        $row = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' -Text '(none)' `
            -Field @(
            New-HDTConsoleField -Label 'Folder' -Value $sequenceFolder
            New-HDTConsoleField -Label '' -Value 'There is no task sequence on this share yet. A task sequence is a folder under the folder above with a sequence.yaml in it.'
        ) `
            -Command $sequenceCommand -Header $Header

        [void] $node.Add($row)
        [void] $sequenceCategory.Children.Add($row)
    }

    return [pscustomobject[]] @($node)
}
