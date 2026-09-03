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
        [ValidateSet('TaskSequence', 'OperatingSystem', 'Application', 'DriverFolder', 'MonitorRun',
            'WindowsUpdate', 'Media')]
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
                IdName    = 'Id'
                UsedFormat = ''
            }
        }
        'DriverFolder' {
            @{
                Noun      = 'driver folder'
                Title     = 'Delete Driver Folder'
                Command   = 'Remove-HDTDriverFolder'
                Parameter = 'Root'
                # WHAT GOES IS THE DRIVERS, not "the folder beside it". A driver
                # folder IS its contents - an .inf with the .sys, .cat and .dll
                # that only mean anything next to it - so the sentence the other
                # kinds share would understate this one badly.
                Goes      = 'every driver under it, and the .sys and .cat files beside each one'
                IdName    = 'Path'
                UsedFormat = ''
            }
        }
        'MonitorRun' {
            @{
                Noun      = 'monitored run'
                # CLEAR, NOT REMOVE. Every other word on this menu takes
                # something off the share that a deployment needs; this one
                # takes a row off a screen. Calling it Remove would put it in
                # the same sentence as deleting an operating system.
                Title     = 'Clear Monitored Run'
                Command   = 'Remove-HDTMonitorRun'
                Parameter = 'Root'
                Goes      = 'the heartbeat file this row is drawn from, and nothing else'
                IdName    = 'RunId'
                UsedFormat = ''
            }
        }
        'WindowsUpdate' {
            @{
                Noun      = 'Windows update'
                Title     = 'Remove Windows Update'
                Command   = 'Remove-HDTWindowsUpdate'
                Parameter = 'WorkspaceRoot'
                # THE .msu IS NAMED BECAUSE IT IS WHAT IS ACTUALLY BEING LOST.
                # update.yaml is a few lines somebody can retype; the package is
                # most of a gigabyte they downloaded, and it is the half of this
                # folder that cannot be reconstructed from the console.
                Goes      = 'update.yaml and the .msu copied beside it'
                IdName    = 'Id'
                # THE SENTENCE COVERS BOTH WAYS A SEQUENCE CAN REACH THIS
                # FOLDER, because `updates` added the second one. A step that
                # names a RELEASE points at nothing by name and deploys without
                # this update; a step whose `updates` NAMES THIS ID does point
                # here, and the step refuses an id the share does not have. So
                # neither the operating system's "will fail" nor the old "will
                # deploy without it" is true of the whole list, and the line has
                # to say which sequence is which - it names them and says where
                # to look, in the space the wording next door uses.
                UsedFormat = 'These task sequences apply this update: {0}. One that names it under Updates will fail without it; one that only applies its release will deploy without it.'
            }
        }
        'OperatingSystem' {
            @{
                Noun      = 'operating system'
                Title     = 'Remove Operating System'
                Command   = 'Remove-HDTOperatingSystem'
                Parameter = 'Workspace'
                Goes      = 'os.yaml and whatever media was imported beside it'
                IdName    = 'Id'
                # A SEQUENCE WITHOUT ITS IMAGE FAILS OUTRIGHT.
                UsedFormat = 'These task sequences apply it and will fail without it: {0}.'
            }
        }
        'Media' {
            @{
                Noun      = 'media definition'
                Title     = 'Remove Media'
                Command   = 'Remove-HDTMedia'
                Parameter = 'WorkspaceRoot'
                Goes      = 'media.yaml and the ISO beside it, when the ISO is inside the folder'
                IdName    = 'Id'
                # NOTHING ON THIS SHARE DEPENDS ON A MEDIA ITEM the way a
                # sequence depends on an application or an image - it is a
                # leaf, PROJECTED FROM the share, never referenced BY
                # anything on it. The ISO-left-behind warning that Media DOES
                # have is composed by the caller, not here - see
                # New-HDTConsoleView.ps1's removeMedia.Add_Click - because it
                # is not the "these depend on it" shape this column carries
                # for every other kind.
                UsedFormat = ''
            }
        }
        default {
            @{
                Noun      = 'application'
                Title     = 'Remove Application'
                Command   = 'Remove-HDTApplication'
                Parameter = 'WorkspaceRoot'
                Goes      = 'app.yaml and the installer copied beside it'
                IdName    = 'Id'
                # A MACHINE ARRIVES WITHOUT IT; it does not fail.
                UsedFormat = 'These task sequences install it: {0}.'
            }
        }
    }

    # THE ROW HAS TO NAME BOTH. See the refusal note above.
    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($Id)) {
        $article = 'a'
        if ($Kind -eq 'OperatingSystem' -or $Kind -eq 'Application') { $article = 'an' }

        # A FOLDER IS NAMED BY ITS PATH, and 'a driver folder id' names nothing
        # anybody would recognise on the row they just right-clicked.
        $what = '{0} {1} id' -f $article, $shape.Noun
        if ($Kind -eq 'DriverFolder') { $what = 'a folder under Drivers\' }
        if ($Kind -eq 'MonitorRun') { $what = 'a run under Logs\_active' }

        return [pscustomobject] @{
            CanRemove = $false
            Refusal   = 'that row does not name a share and {0}, so there is nothing to remove.' -f $what
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

    # A DRIVER FOLDER IS ITS CONTENTS, so it does not get the "its folder goes
    # with it" sentence the other three share - the folder is the thing being
    # removed, not something that follows it out.
    $lead = 'Its folder goes with it'
    if ($Kind -eq 'DriverFolder') { $lead = 'It takes' }

    # A HEARTBEAT IS A RECORD, NOT A PART OF THE SHARE. Nothing reads it, so
    # 'this cannot be undone' would be true and useless - what somebody actually
    # wants to know before pressing this is whether they are about to interfere
    # with a machine that is still deploying. They are not.
    if ($Kind -eq 'MonitorRun') {
        return [pscustomobject] @{
            CanRemove = $true
            Refusal   = ''
            Title     = [string] $shape.Title
            Warning   = ''
            Question  = ("Clear the {0} '{1}' from{2}{3}?{2}{2}It takes {4}. The deployment itself is not affected - a run still in progress reappears here when the engine writes its next step." -f
                $shape.Noun, $Id, $newLine, $Root, $shape.Goes)
            Command   = "{0} -{1} '{2}' -{3} '{4}'" -f
                $shape.Command, $shape.Parameter, $Root, $shape.IdName, $Id
        }
    }

    $question = ("Remove the {0} '{1}' from{2}{3}?{2}{2}{6} - {4}. This cannot be undone from here.{5}" -f
        $shape.Noun, $Id, $newLine, $Root, $shape.Goes, $warning, $lead)

    return [pscustomobject] @{
        CanRemove = $true
        Refusal   = ''
        Title     = [string] $shape.Title
        Warning   = $warning
        Question  = $question
        Command   = "{0} -{1} '{2}' -{3} '{4}'" -f
            $shape.Command, $shape.Parameter, $Root, $shape.IdName, $Id
    }
}
