function Get-HDTConsoleStepNode {
    <#
        .SYNOPSIS
            Builds the group and step rows that hang beneath one task sequence.

        .DESCRIPTION
            THE TREE USED TO STOP AT THE SEQUENCE, and the detail pane said
            "Steps: 5". A count is not something an administrator can click.
            DESIGN 12 calls for a "drag-and-drop step tree with a properties
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

              Node      every group and step row, in display order
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

    # Joined GroupPath -> the group's row, so the second step in a group finds
    # the row the first one created.
    $groupNode = @{}

    # Every row that hangs directly off the sequence, in the order it appeared.
    $topLevel = New-Object -TypeName System.Collections.ArrayList

    $step = @($Sequence.Step)

    for ($index = 0; $index -lt $step.Count; $index++) {
        $current = $step[$index]

        $path = @($current.GroupPath)

        # -- the groups this step sits in, created the first time they are named

        $parent = $null
        $walked = @()

        foreach ($name in $path) {
            $walked = $walked + $name
            $key = $walked -join "`u{001F}"

            if (-not $groupNode.ContainsKey($key)) {
                $groupIndex = @($Sequence.Group).Count
                $matched = @($Sequence.Group | Where-Object { (@($_.Path) -join "`u{001F}") -eq $key })

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
                    $groupIndex = [array]::IndexOf(@($Sequence.Group), $matched[0])

                    $field = $field + @(
                        New-HDTConsoleField -Label 'Runs in' -Value (Get-HDTConsoleDisplayText -Text $matched[0].RunIn -Fallback 'any phase')
                        New-HDTConsoleField -Label 'Condition' -Value (Get-HDTConsoleDisplayText -Text $matched[0].Condition -Fallback '(none)')
                    )
                }

                $row = New-HDTConsoleNode -Depth ($walked.Count - 1) -Kind 'StepGroup' -Status 'Ok' `
                    -Text $name -Name $name -Field $field `
                    -Command ('{0}.Group[{1}]' -f $document, $groupIndex) `
                    -Header $Header

                $groupNode[$key] = $row
                [void] $node.Add($row)

                if ($null -eq $parent) {
                    [void] $topLevel.Add($row)
                } else {
                    [void] $parent.Children.Add($row)
                }
            }

            $parent = $groupNode[$key]
        }

        # -- the step itself

        # WHICH ROWS MAY BE TYPED INTO IS DECIDED HERE. A row that writes names
        # the key it writes; a row that does not is a report. 'Type' is
        # deliberately among the reports - a step's properties belong to its
        # type, so retyping one leaves keys the new type has never heard of, and
        # Set-HDTConsoleStepProperty refuses it for the same reason.
        $field = @(
            New-HDTConsoleField -Label 'Name' -Value $current.Name -Property 'name'
            New-HDTConsoleField -Label 'Type' -Value $current.Type
            New-HDTConsoleField -Label 'Runs' -Value ('step {0} of {1}' -f $current.Index, $step.Count)
            New-HDTConsoleField -Label 'Group' -Value (Get-HDTConsoleDisplayText -Text ($path -join ' \ ') -Fallback '(none)')
            New-HDTConsoleField -Label 'Enabled' -Value (Get-HDTConsoleFlagText -Value (-not $current.Disabled))
            New-HDTConsoleField -Label 'Runs in' -Value (Get-HDTConsoleDisplayText -Text $current.RunIn -Fallback 'any phase')
            New-HDTConsoleField -Label 'Condition' -Value (Get-HDTConsoleDisplayText -Text $current.Condition -Fallback '(none)')
            New-HDTConsoleField -Label 'Continue on error' -Value (Get-HDTConsoleFlagText -Value $current.ContinueOnError)
        )

        # The per-type properties, each writing the key it is named after - the
        # difference between "Apply OS" and "apply THAT image", and the reason
        # the tab exists.
        foreach ($name in @($current.Property.Keys | Sort-Object)) {
            $field = $field + @(
                New-HDTConsoleField -Label $name -Value ([string] $current.Property[$name]) -Property $name
            )
        }

        # A DISABLED STEP HAS TO LOOK DISABLED AT A GLANCE. The reason to switch
        # one off is usually to run the sequence again and watch what changes,
        # and the tree is what an administrator checks before they do. The
        # engine skips it (Invoke-HDTTaskSequence branch 2a); this is the same
        # fact, on the screen.
        $text = '{0}. {1}' -f $current.Index, $current.Name
        $icon = ''

        if ([bool] $current.Disabled) {
            $text = '{0}. {1}  (disabled)' -f $current.Index, $current.Name
            $icon = [string] ([char] 0x2298)     # circled division slash - switched off
        }

        $row = New-HDTConsoleNode -Depth $path.Count -Kind 'Step' -Status 'Ok' `
            -Text $text -Name $current.Name -Field $field `
            -Command ('{0}.Step[{1}]' -f $document, $index) `
            -Header $Header -Icon $icon

        [void] $node.Add($row)

        if ($null -eq $parent) {
            [void] $topLevel.Add($row)
        } else {
            [void] $parent.Children.Add($row)
        }
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
