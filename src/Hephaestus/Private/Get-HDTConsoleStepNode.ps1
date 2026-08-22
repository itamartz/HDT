function Get-HDTConsoleStepNode {
    <#
        .SYNOPSIS
            Builds the group and step rows that hang beneath one task sequence.

        .DESCRIPTION
            THE TREE USED TO STOP AT THE SEQUENCE, and the detail pane said
            "Steps: 5". A count is not something an administrator can click.
            The console is meant to have a "drag-and-drop step tree with a properties
            pane"; this builds that tree's contents, here rather than in the
            window, so every row can be asserted without a screen.

            THE ENGINE ALREADY RESOLVED THE ORDER, AND THIS DOES NOT SECOND-GUESS
            IT. Import-HDTSequenceDocument returns a FLAT, ordered step list in
            which every step carries the GroupPath it sits under, plus the groups
            separately. Walking that list in order and creating each group the
            first time it is named reproduces the nesting exactly, in the order
            Invoke-HDTTaskSequence would execute - and it means a console and a
            deployment can never disagree about what runs when. Re-parsing the
            YAML here would be a second implementation of the thing the engine
            is tested to death on.

            A GROUP IS CREATED WHEN ITS FIRST STEP NAMES IT, which is what makes
            nested groups work with no recursion and no separate tree walk: a
            GroupPath of ('Install', 'Drivers') creates 'Install' then 'Drivers'
            under it, and the next step naming the same path finds both.

            AN EMPTY GROUP HAS NO FIRST STEP, so the two lists are MERGED rather
            than one being walked. A group an administrator has named but not yet
            filled is legal - it is what the New Group button creates, and what
            emptying a group leaves behind - and it names no step and is named by
            none, so a tree built from the step list alone drew nothing at all
            and the button looked like it had done nothing. Each group says how
            many steps preceded it (AfterStep), so opening every group that is
            due before each step puts it exactly where the document puts it,
            including between two steps and after the last one.

            EVERY ROW IS SCOPED TO ITS OWN SEQUENCE OBJECT. Nothing here is keyed
            on a sequence ID, deliberately - two shares commonly hold task
            sequences with the SAME id (both of the lab's shares hold a DEMO-M4),
            and a lookup by id would hang one share's steps under the other
            share's sequence while each share still looked correct on its own.

            A STEP ROW SHOWS WHAT WOULD CHANGE A DECISION: the type, because the
            name is the administrator's prose and the type is what actually runs;
            the phase, because running in the wrong one is the commonest reason a
            step is silently skipped; and continueOnError, because it changes
            what a red deployment means. The per-type properties follow, since
            they are the difference between "Apply OS" and "apply THAT image".

            DEPTH IS COUNTED FROM THE EDITOR'S ROOT, NOT THE BROWSER'S. A
            top-level group is 0 and a step inside it is 1, because these rows
            fill the task sequence editor's own tree - the browser stops at the
            sequence (Deployment Workbench's shape) and never shows a step.

        .PARAMETER Sequence
            One task sequence row from Get-HDTConsoleWorkspace, carrying Step
            and Group.

        .PARAMETER Header
            The banner the share's rows carry.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with two properties:

              Node      every group and step row, in display order, each
                        carrying an Occurrence - which of the same-named rows it
                        is, 1-based, so a console can say WHICH row it means
              TopLevel  only the rows hanging off the sequence itself, which is
                        what the caller adds to its Children

        .EXAMPLE
            Get-HDTConsoleStepNode -Sequence $sequence -Header $header
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Sequence,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [object] $Header
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $node = New-Object -TypeName System.Collections.ArrayList

    # A sequence that would not parse has no steps to show, and its own row
    # already carries the engine's error. The SHAPE is still the shape - a
    # caller that has to check for two different return types is a caller that
    # will one day forget.
    if ($Sequence.Status -eq 'Error') {
        return [pscustomobject] @{
            Node     = [pscustomobject[]] @()
            TopLevel = [pscustomobject[]] @()
        }
    }

    $document = "(Import-HDTSequenceDocument -Path '{0}' -FileSystem (New-HDTFileSystem))" -f $Sequence.Path

    # WHICH OF THE SAME-NAMED ROWS THIS ONE IS, 1-BASED, IN DOCUMENT ORDER.
    #
    # A CONSOLE HAS A ROW AND A COMMAND LINE HAS A NAME, and until this existed
    # the console threw its row away and passed the name. A sequence with two
    # steps called 'Tattoo' - which MDT allows, and which a sequence that tattoos
    # twice legitimately is - then answered Remove with "the one to act on is
    # ambiguous. Rename one of them first", because by the time the request
    # reached Resolve-HDTStepBlock the only thing left of the selection was a
    # string.
    #
    # COUNTED THE SAME WAY THE RESOLVER COUNTS. Resolve-HDTStepBlock matches on
    # Name across BOTH groups and steps in document order, so this counts across
    # both too: two tables that disagreed about what "the second one" means would
    # be worse than the ambiguity it replaces.
    $occurrenceOf = {
        param([string] $RowName)

        return (@($node | Where-Object { [string] $_.Name -eq $RowName }).Count + 1)
    }

    # Joined GroupPath -> the group's row, so the second step in a group finds
    # the row the first one created.
    $groupNode = @{}

    # Every row that hangs directly off the sequence, in the order it appeared.
    $topLevel = New-Object -TypeName System.Collections.ArrayList

    $step = @($Sequence.Step)
    $groupList = @($Sequence.Group)

    # THE ROW FOR ONE GROUP PATH, and for every ancestor of it that does not
    # exist yet. Both halves of the merge below call it - the group list, which
    # is the only thing that knows about an empty group, and a step's own
    # GroupPath, which is the only thing that knows about a group a caller
    # handed over steps for without handing over the group. Whichever reaches a
    # path first creates it; the other finds it.
    #
    # Its output is discarded at every call site: this function returns one
    # object, and a stray Add() return value would arrive alongside it.
    $openGroup = {
        param([string[]] $Path)

        $walked = @()

        foreach ($name in @($Path)) {
            $ancestor = $walked -join "`u{001F}"
            $walked = $walked + $name
            $key = $walked -join "`u{001F}"

            if ($groupNode.ContainsKey($key)) { continue }

            $groupIndex = $groupList.Count
            $matched = @($groupList | Where-Object { (@($_.Path) -join "`u{001F}") -eq $key })

            # A GROUP'S EDITABLE NAME IS ITS OWN LEG, NOT ITS PATH. The key
            # on the line is `group:` and it holds this leg alone, so an
            # editable box showing 'Install \ Drivers' would write that
            # whole string as the name the moment anybody touched it. The
            # path is still worth showing - it is what tells one 'Drivers'
            # from another - so it gets a read-only row of its own, and only
            # where there is a path to show.
            $field = @(
                New-HDTConsoleField -Label 'Group' -Value $name -Property 'group'
            )

            if ($walked.Count -gt 1) {
                $field = $field + @(
                    New-HDTConsoleField -Label 'Path' -Value ($walked -join ' \ ')
                )
            }

            $field = $field + @(
                New-HDTConsoleField -Label 'Task Sequence' -Value $Sequence.Id
            )

            if (@($matched).Count -gt 0) {
                $groupIndex = [array]::IndexOf($groupList, $matched[0])

                $field = $field + @(
                    New-HDTConsoleField -Label 'Runs in' -Value (Get-HDTConsoleDisplayText -Text $matched[0].RunIn -Fallback 'any phase')
                    New-HDTConsoleField -Label 'Condition' -Value (Get-HDTConsoleDisplayText -Text $matched[0].Condition -Fallback '(none)')
                )
            }

            $row = New-HDTConsoleNode -Depth ($walked.Count - 1) -Kind 'StepGroup' -Status 'Ok' `
                -Text $name -Name $name -Field $field `
                -Command ('{0}.Group[{1}]' -f $document, $groupIndex) `
                -Header $Header

            $row | Add-Member -NotePropertyName 'Occurrence' `
                -NotePropertyValue (& $occurrenceOf ([string] $row.Name)) -Force

            $groupNode[$key] = $row
            [void] $node.Add($row)

            if ([string]::IsNullOrEmpty($ancestor)) {
                [void] $topLevel.Add($row)
            } else {
                [void] $groupNode[$ancestor].Children.Add($row)
            }
        }
    }

    # HOW FAR INTO THE ORDER A GROUP OPENED. A group that does not say - a caller
    # may build the projection by hand - opens where the walk has reached, which
    # is where it would have been created from a step's path anyway.
    $afterStep = {
        param([object] $Group, [int] $Reached)

        $property = $Group.PSObject.Properties['AfterStep']
        if ($null -eq $property) { return $Reached }

        return [int] $property.Value
    }

    $groupAt = 0

    for ($index = 0; $index -lt $step.Count; $index++) {
        $current = $step[$index]

        # -- every group that opens before this step, in document order

        while ($groupAt -lt $groupList.Count -and (& $afterStep $groupList[$groupAt] $index) -le $index) {
            $null = & $openGroup @($groupList[$groupAt].Path)
            $groupAt++
        }

        # -- the groups this step sits in, for a projection that listed none

        $path = @($current.GroupPath)

        $parent = $null
        if ($path.Count -gt 0) {
            $null = & $openGroup $path
            $parent = $groupNode[($path -join "`u{001F}")]
        }

        # -- the step itself

        # WHICH ROWS MAY BE TYPED INTO IS DECIDED HERE. A row that writes names
        # the key it writes; a row that does not is a report. 'Type' is
        # deliberately among the reports - a step's properties belong to its
        # type, so retyping one leaves keys the new type has never heard of, and
        # Set-HDTStepProperty refuses it for the same reason.
        # THE STEP'S OWN SETTINGS, AND NOTHING ELSE. This list used to open with
        # eight rows that repeat what the window already shows: the name is in
        # the box above the tabs, the type and the group are the row you clicked
        # in the tree, and Enabled, Runs in, Condition and Continue on error are
        # the Options tab. Ten rows of which two were the step's own is why the
        # tab read as a data dump rather than as a properties page.
        #
        # MDT'S Properties TAB IS THE PER-TYPE PAGE - "Command line", "Start in",
        # "Run as" - and this is the generic version of exactly that. A step type
        # with a page of its own does not get this tab at all.
        #
        # THE FACTS ARE NOT LOST, they are where they were already being read:
        # the tree, the Options tab, and the name box.
        $field = @()

        # WHAT THE ROW REPORTS, which is not what the tab edits. These are read
        # in the tree - what the step is, which phase it runs in, whether it may
        # fail - and every one of them is answered somewhere else in the window
        # too, which is why none of them is a box.
        $report = @(
            New-HDTConsoleField -Label 'Type' -Value $current.Type
            New-HDTConsoleField -Label 'Runs' -Value ('step {0} of {1}' -f $current.Index, $step.Count)
            New-HDTConsoleField -Label 'Group' -Value (Get-HDTConsoleDisplayText -Text ($path -join ' \ ') -Fallback '(none)')
            New-HDTConsoleField -Label 'Enabled' -Value (Get-HDTConsoleFlagText -Value (-not $current.Disabled))
            New-HDTConsoleField -Label 'Runs in' -Value (Get-HDTConsoleDisplayText -Text $current.RunIn -Fallback 'any phase')
            New-HDTConsoleField -Label 'Condition' -Value (Get-HDTConsoleDisplayText -Text $current.Condition -Fallback '(none)')
            New-HDTConsoleField -Label 'Continue on error' -Value (Get-HDTConsoleFlagText -Value $current.ContinueOnError)
        )

        # THE KEYS A DEDICATED PAGE OWNS ARE NOT LISTED HERE. MDT never shows a
        # setting on two tabs of the same dialog - its Format and Partition Disk
        # page IS that step's Properties tab - and a disk number in two places
        # is a disk number that can disagree with itself while both boxes look
        # authoritative.
        #
        # Properties remains for everything else, including the step's name:
        # most step types have no page of their own, and this is the only tab
        # they get.
        $owned = @()
        if ($current.Type -eq 'DiskPartition') {
            $owned = @('diskNumber', 'wipe', 'style', 'partition', 'layout')
        }

        if ($current.Type -eq 'Validate') {
            $owned = @(Get-HDTValidateCheckDefinition | ForEach-Object { [string] $_.Key })
        }

        # THE ORDER THE DOCUMENT DECLARES, NOT THE ALPHABET. These rows were
        # sorted, which put 'value' above 'variable' on a Set Task Sequence
        # Variable step: a page that asks what to set it to before it asks what
        # to set. MDT's dialog is Task Sequence Variable then Value, the
        # template writes them that way round, and the file is the thing being
        # edited - a page whose order disagrees with it makes somebody translate
        # between the two every time they look.
        #
        # Import-HDTSequenceDocument keeps the keys ordered for exactly this.
        #
        # The per-type properties, each writing the key it is named after - the
        # difference between "Apply OS" and "apply THAT image", and the reason
        # the tab exists.
        foreach ($name in @($current.Property.Keys)) {
            $value = $current.Property[$name]

            # A KEY A DEDICATED PAGE OWNS IS STILL REPORTED, just not offered as
            # a box here. Dropping it outright took it out of the tree row's
            # summary as well - so a Validate step stopped saying what it
            # checks, which is the one thing that row is read for.
            if ($owned -contains [string] $name) {
                $report = $report + @(New-HDTConsoleField -Label $name -Value ([string] $value))
                continue
            }

            # A PROPERTY THAT IS NOT A VALUE GETS NO TEXT BOX. [string] on a
            # list of ordered dictionaries prints
            # 'System.Collections.Specialized.OrderedDictionary', which says
            # nothing about the disk - and the row was EDITABLE, so Apply
            # properties would have written those words into the document and
            # replaced a partition table with them.
            #
            # IT IS STILL SHOWN. The key is in the file, and a Properties tab
            # that silently omitted one would be lying about what the step
            # declares. It says how many entries and stays read-only; the tab
            # that owns the shape is where it is edited.
            $isTable = $false
            if ($value -is [System.Collections.IDictionary]) { $isTable = $true }
            elseif ($value -isnot [string] -and $value -is [System.Collections.IEnumerable]) { $isTable = $true }

            if (-not $isTable) {
                $field = $field + @(
                    New-HDTConsoleField -Label (Get-HDTConsolePropertyLabel -Key $name) `
                        -Value ([string] $value) -Property $name
                )

                continue
            }

            $entry = @($value).Count
            if ($value -is [System.Collections.IDictionary]) { $entry = @($value.Keys).Count }

            $field = $field + @(
                New-HDTConsoleField -Label $name -Value ('{0} entries - a table, not a value' -f $entry)
            )
        }

        # TWO FACTS ABOUT A STEP ARE WORTH SEEING WITHOUT OPENING IT, and neither
        # is what KIND of thing it is - which is all Get-HDTConsoleIcon and
        # Get-HDTConsoleIconColor answer. So the row overrides both.
        #
        # A DISABLED STEP HAS TO LOOK DISABLED AT A GLANCE. The reason to switch
        # one off is usually to run the sequence again and watch what changes,
        # and the tree is what an administrator checks before they do. The
        # engine skips it (Invoke-HDTTaskSequence branch 2a); this is the same
        # fact, on the screen. Grey, because it is inert rather than
        # interesting - it is not going to do anything at all.
        #
        # A STEP THAT IS ALLOWED TO FAIL CHANGES WHAT A GREEN DEPLOYMENT MEANS.
        # A sequence carrying continueOnError can finish having done less than
        # it says, which is a deliberate choice somebody made and is invisible
        # in a tree that draws every step as the same grey gear. Amber, because
        # it is a tolerance worth noticing and not a fault - red is for a
        # document that cannot be read.
        #
        # DISABLED WINS WHEN BOTH ARE SET: a step that never runs cannot fail,
        # so tolerating its failure is not a fact about this deployment.
        $text = '{0}. {1}' -f $current.Index, $current.Name
        $icon = ''
        $iconColor = ''

        if ([bool] $current.ContinueOnError) {
            $text = '{0}. {1}  (continues on error)' -f $current.Index, $current.Name
            # U+21B7, NOT U+21AA. The hooked arrow has an EMOJI presentation,
            # so Windows renders it as a boxed pictograph in its own colours and
            # ignores the Foreground this row asked for - the mark came out as an
            # amber-ish tile rather than an amber arrow. A curve arrow has no
            # emoji form and takes the colour it is given, the way the disabled
            # step's U+2298 does.
            $icon = [string] ([char] 0x21B7)     # clockwise top semicircle arrow - carries on past a failure
            $iconColor = '#FFB77400'
        }

        if ([bool] $current.Disabled) {
            $text = '{0}. {1}  (disabled)' -f $current.Index, $current.Name
            $icon = [string] ([char] 0x2298)     # circled division slash - switched off
            $iconColor = '#FF767676'
        }

        $row = New-HDTConsoleNode -Depth $path.Count -Kind 'Step' -Status 'Ok' `
            -Text $text -Name $current.Name -Field $field -Report $report `
            -Command ('{0}.Step[{1}]' -f $document, $index) `
            -Header $Header -Icon $icon -IconColor $iconColor

        $row | Add-Member -NotePropertyName 'Occurrence' `
            -NotePropertyValue (& $occurrenceOf ([string] $row.Name)) -Force

        [void] $node.Add($row)

        if ($null -eq $parent) {
            [void] $topLevel.Add($row)
        } else {
            [void] $parent.Children.Add($row)
        }
    }

    # Everything the merge has not reached: the groups after the last step, and
    # every group in a document that is nothing but empty ones.
    while ($groupAt -lt $groupList.Count) {
        $null = & $openGroup @($groupList[$groupAt].Path)
        $groupAt++
    }

    # TWO READINGS OF ONE BUILD. Node is every row in display order, which is
    # what the flat list needs; TopLevel is only those hanging off the sequence
    # itself, which is what the caller adds to its Children - the rest are
    # already wired into their groups above.
    return [pscustomobject] @{
        Node     = [pscustomobject[]] @($node)
        TopLevel = [pscustomobject[]] @($topLevel)
    }
}
