function Get-HDTConsoleRemoval {
    <#
        .SYNOPSIS
            What a technician is asked before something is deleted from a share,
            and what they are told about what else stops working.

        .DESCRIPTION
            THE THREE IRREVERSIBLE PRESSES IN THIS WINDOW - removing a task
            sequence, an operating system or an application - and they each used
            to compose their own question, their own refusal and their own
            command line inside their own handler. Three chances to get a
            destructive dialog wrong, and no test on any of them. One of them
            being right was never the set being right.

            THIS IS THE LAST THING ANYBODY READS. The folder goes with the thing
            being removed, and there is no undo in this window, so the dialog is
            the only point at which the press can still be stopped.

            THE CONSEQUENCES BELONG IN THE QUESTION, NOT AFTER IT. Remove-*
            -WhatIf already knows which task sequences use what is about to go;
            asking "are you sure?" without saying so asks somebody to confirm
            something they have not been told.

            AND THE CONSEQUENCES ARE NOT THE SAME SENTENCE, which is why this is
            a decision rather than a template:

              - a sequence that INSTALLS a missing application still deploys,
                and the machine simply arrives without it;
              - a sequence that APPLIES a missing operating system FAILS;
              - an application that DEPENDS on a missing one will not install at
                all, later, on a deployment nobody connects to this press.

            Wording them alike would flatten a failure into an inconvenience.

            THE PARAMETER NAME IS NOT THE SAME EITHER. Remove-HDTTaskSequence and
            Remove-HDTOperatingSystem take -Workspace; Remove-HDTApplication
            takes -WorkspaceRoot. The echoed line is meant to be retyped, so it
            has to be the one that binds.

            AND IT SAYS SO RATHER THAN DOING NOTHING. A row that names no share
            or no id gets a sentence, because a menu item that returns quietly is
            one somebody presses twice and then reports as broken.

            IT REMOVES NOTHING. It composes the question; the caller shows it and
            runs the command.

        .PARAMETER Kind
            What is being removed.

        .PARAMETER Root
            The share it is being removed from.

        .PARAMETER Id
            The id, as the row names it.

        .PARAMETER UsedBy
            The task sequences that use it, from Remove-* -WhatIf.

        .PARAMETER RequiredBy
            The applications that depend on it. Only an application has these.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              CanRemove  whether the row names something removable
              Refusal    why not, when it does not
              Title      the dialog's title
              Warning    what else stops working, '' when nothing does
              Question   the whole sentence to put in the dialog
              Command    the Remove-HDT* line, '' when refusing

        .EXAMPLE
            Get-HDTConsoleRemoval -Kind 'TaskSequence' -Root 'C:\HDTLab\Share' -Id 'DEMO-05'

        .EXAMPLE
            $ask = Get-HDTConsoleRemoval -Kind 'Application' -Root $where -Id $which -UsedBy $answer.UsedBy
            [System.Windows.MessageBox]::Show($window, $ask.Question, $ask.Title)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('TaskSequence', 'OperatingSystem', 'Application')]
        [string] $Kind,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [string] $Root,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowEmptyString()]
        [string] $Id,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $UsedBy = @(),

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $RequiredBy = @()
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $newLine = [System.Environment]::NewLine

    # WHAT EACH KIND IS CALLED, WHAT GOES WITH IT, AND WHAT ELSE BREAKS. The
    # third column is the sentence that differs most, and it is the reason these
    # cannot share one template.
    $shape = switch ($Kind) {
        'TaskSequence' {
            @{
                Noun      = 'task sequence'
                Title     = 'Remove Task Sequence'
                Command   = 'Remove-HDTTaskSequence'
                Parameter = 'Workspace'
                Goes      = 'the sequence, its answer file and anything else kept beside them'
                UsedFormat = ''
            }
        }
        'OperatingSystem' {
            @{
                Noun      = 'operating system'
                Title     = 'Remove Operating System'
                Command   = 'Remove-HDTOperatingSystem'
                Parameter = 'Workspace'
                Goes      = 'os.yaml and whatever media was imported beside it'
                # A SEQUENCE WITHOUT ITS IMAGE FAILS OUTRIGHT.
                UsedFormat = 'These task sequences apply it and will fail without it: {0}.'
            }
        }
        default {
            @{
                Noun      = 'application'
                Title     = 'Remove Application'
                Command   = 'Remove-HDTApplication'
                Parameter = 'WorkspaceRoot'
                Goes      = 'app.yaml and the installer copied beside it'
                # A MACHINE ARRIVES WITHOUT IT; it does not fail.
                UsedFormat = 'These task sequences install it: {0}.'
            }
        }
    }

    # THE ROW HAS TO NAME BOTH. See the refusal note above.
    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($Id)) {
        $article = 'a'
        if ($Kind -eq 'OperatingSystem' -or $Kind -eq 'Application') { $article = 'an' }

        return [pscustomobject] @{
            CanRemove = $false
            Refusal   = 'that row does not name a share and {0} {1} id, so there is nothing to remove.' -f
                $article, $shape.Noun
            Title     = [string] $shape.Title
            Warning   = ''
            Question  = ''
            Command   = ''
        }
    }

    $warning = ''

    if (@($UsedBy).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string] $shape.UsedFormat)) {
        $warning = '{0}{0}{1}' -f $newLine, ([string] $shape.UsedFormat -f (@($UsedBy) -join ', '))
    }

    # ONLY AN APPLICATION HAS DEPENDENTS.
    if ($Kind -eq 'Application' -and @($RequiredBy).Count -gt 0) {
        $warning = '{0}{1}{1}These applications depend on it and will not install without it: {2}.' -f
            $warning, $newLine, (@($RequiredBy) -join ', ')
    }

    $question = ("Remove the {0} '{1}' from{2}{3}?{2}{2}Its folder goes with it - {4}. This cannot be undone from here.{5}" -f
        $shape.Noun, $Id, $newLine, $Root, $shape.Goes, $warning)

    return [pscustomobject] @{
        CanRemove = $true
        Refusal   = ''
        Title     = [string] $shape.Title
        Warning   = $warning
        Question  = $question
        Command   = "{0} -{1} '{2}' -Id '{3}'" -f $shape.Command, $shape.Parameter, $Root, $Id
    }
}
