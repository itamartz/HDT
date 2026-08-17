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

    $command = "Import-HDTSequenceDocument -Path '{0}' -FileSystem (New-HDTFileSystem)" -f $Sequence.Path

    # The banner the editor's own rows carry. It names the document rather than
    # the share, because the document is what this window edits and what two
    # same-id sequences differ by.
    $header = [pscustomobject] @{
        Title      = '{0} - {1}' -f $Sequence.Id, $Sequence.Name
        Root       = [string] $Sequence.Path
        DeployRoot = [string] $Sequence.Id
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

        Node         = [pscustomobject[]] @($step.Node)
        Root         = [pscustomobject[]] @($step.TopLevel)
        Command      = $command
    }
}
