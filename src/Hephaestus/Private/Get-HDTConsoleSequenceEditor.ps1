function Get-HDTConsoleSequenceEditor {
    <#
        .SYNOPSIS
            Builds everything the task sequence editor window shows for one
            task sequence.

        .DESCRIPTION
            THE EDITOR IS A SEPARATE WINDOW, WHICH IS DEPLOYMENT WORKBENCH'S
            SHAPE. MDT lists task sequences in the tree and edits their steps in
            a properties dialog opened from one - step tree on the left,
            properties on the right, Add/Remove/Up/Down across the top.
            This console is meant to be "deliberately close to Deployment
            Workbench so muscle memory transfers".

            IT IS ALSO WHERE WRITING BELONGS. The browser opens a live
            deployment share and promises to write nothing to it; an editing
            surface nested inside that window would make the promise
            half-true, which is worse than either answer. A window an
            administrator deliberately opened on one document is an honest
            place to offer a Save.

            EVERYTHING THAT REACHES THE SCREEN IS DECIDED HERE, the same rule
            Get-HDTConsoleTreeNode follows and for the same reason: the injected
            host adds rows to a control and formats nothing, which is what
            leaves it branch-free and honestly exempt from TDD (the rule
            1). If the host built these rows, the only thing that could ever
            check the editor's output would be a person looking at a screen.

            IT TAKES THE SEQUENCE OBJECT, NEVER AN ID. Two shares commonly hold
            task sequences with the same id - both of this lab's shares hold a
            DEMO-M4 - so an editor that resolved an id against a workspace could
            open one share's document while displaying the other's, and would
            look correct right up to the moment it wrote. The object carries its
            own Path, and that Path is what a Save will use.

            A SEQUENCE THAT WOULD NOT PARSE OPENS EMPTY RATHER THAN THROWING.
            The browser already shows the engine's message on the sequence's own
            row; an editor that threw on open would leave an administrator with
            a dialog they cannot dismiss and no explanation in it.

        .PARAMETER Sequence
            One task sequence row from Get-HDTConsoleWorkspace's TaskSequence
            collection, carrying Id, Name, Path, Step and Group.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Title         the window title, naming the task sequence
              DocumentPath  the sequence.yaml this editor would write
              Id, Name      the task sequence being edited
              StepCount     how many steps it holds
              Node          every group and step row, in display order
              Root          only the rows hanging off the tree's root
              Command       the module call that produced the contents

        .EXAMPLE
            $share = Get-HDTConsoleWorkspace -Path 'C:\HDTLab\Share'
            $editor = Get-HDTConsoleSequenceEditor -Sequence @($share.TaskSequence)[0]
            $editor.Node | Format-Table Depth, Kind, Text

            The editor window's contents, on a console, with no window.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Sequence
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $command = "Import-HDTSequenceDocument -Path '{0}'" -f $Sequence.Path

    # The banner the editor's own rows carry. It names the document rather than
    # the share, because the document is what this window edits and what two
    # same-id sequences differ by.
    $header = [pscustomobject] @{
        Title      = '{0} - {1}' -f $Sequence.Id, $Sequence.Name
        Root       = [string] $Sequence.Path
        DeployRoot = [string] $Sequence.Id
    }

    # -- the Variables tab ---------------------------------------------------
    #
    # THE BLOCK THE NEW SEQUENCE WINDOW FILLS AND NOTHING COULD CHANGE. That
    # window asks for the administrator password, the OS image and the
    # organisation, writes them into variables:, and until Set-HDTSequenceVariable
    # existed an administrator who mistyped the password re-created the
    # sequence.
    #
    # THE MAP IS WHAT MAKES A ROW READABLE. HDTOSImageIndex on its own teaches
    # nobody anything; Get-HDTVariableMap carries the sentence explaining it and
    # the name MDT used, which is the whole reason somebody arriving from
    # Workbench can find their way around.
    #
    # NOTHING IS MASKED, INCLUDING THE PASSWORD. It is stored readable in the
    # document because WinPE uses it with nobody present - a masked box over a
    # readable file is theatre, and it stops an administrator checking what they
    # typed.

    $map = @{}
    foreach ($entry in @(Get-HDTVariableMap)) { $map[[string] $entry.HDTName] = $entry }

    $variableRow = New-Object -TypeName System.Collections.ArrayList

    # PSObject.Properties, NOT a null check: under the StrictMode this module
    # sets, reading a property an object does not carry THROWS rather than
    # returning $null - and a sequence with no variables block has no property
    # at all.
    if ($null -ne $Sequence.PSObject.Properties['Variable'] -and $null -ne $Sequence.Variable) {
        foreach ($name in @($Sequence.Variable.Keys)) {
            $known = $null
            if ($map.ContainsKey([string] $name)) { $known = $map[[string] $name] }

            $hint = ''
            $mdtName = ''

            if ($null -ne $known) {
                $hint = [string] $known.Description
                $mdtName = [string] $known.MdtName
            } else {
                # A NAME THE MAP DOES NOT KNOW IS NOT AN ERROR. A sequence may
                # carry a variable of its own for a custom step to read, and a
                # row that refused to show it would hide the document.
                $hint = 'Not one of the variables HDT publishes - a step in this sequence reads it.'
            }

            [void] $variableRow.Add([pscustomobject] @{
                    Name    = [string] $name
                    Value   = [string] $Sequence.Variable[$name]
                    Hint    = $hint
                    MdtName = $mdtName
                })
        }
    }

    $step = Get-HDTConsoleStepNode -Sequence $Sequence -Header $header

    return [pscustomobject] @{
        Title        = 'Task Sequence Editor - {0}' -f $Sequence.Id
        DocumentPath = [string] $Sequence.Path
        Id           = [string] $Sequence.Id
        Name         = [string] $Sequence.Name
        Description  = [string] $Sequence.Description
        StepCount    = @($Sequence.Step).Count

        # THE TWO CALLS THE HEADER BOXES RUN. The id is not among them on
        # purpose: it is the folder name, so changing it is a move - rules that
        # name it, boot images that select it and the run state on a machine
        # mid-deployment all point at the old one.
        NameCommandFormat        = 'Set-HDTTaskSequenceProperty -Line $line -Name ''{0}'''
        DescriptionCommandFormat = 'Set-HDTTaskSequenceProperty -Line $line -Description ''{0}'''

        Variable     = [pscustomobject[]] @($variableRow)
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


        # THE TWO CALLS THE VARIABLES TAB RUNS. Set and Remove, because a
        # variable set by mistake has to be removable - and neither writes: the
        # editor's Save is still the only thing that touches the share.
        VariableCommandFormat       = 'Set-HDTSequenceVariable -Line $line -Name ''{0}'' -Value ''{1}'''
        VariableRemoveCommandFormat = 'Set-HDTSequenceVariable -Line $line -Name ''{0}'' -Remove'

        Node         = [pscustomobject[]] @($step.Node)
        Root         = [pscustomobject[]] @($step.TopLevel)
        Command      = $command
    }
}
