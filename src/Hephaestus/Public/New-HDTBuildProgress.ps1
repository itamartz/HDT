function New-HDTBuildProgress {
    <#
        .SYNOPSIS
            The channel Update-HDTBootImage reports its seventeen steps on.

        .DESCRIPTION
            THE BUILD WAS SILENT, AND THAT IS WHAT THIS FIXES. Two and a half
            minutes between a ShouldProcess and a result object, with nothing in
            between: on a console that is a prompt which has stopped answering,
            and in a window it is worse - the window greys out, an administrator
            reasonably concludes it has hung and kills it, and a killed build
            strands a mounted image that needs dism /cleanup-wim before anything
            can build again.

            IT IS A SERVICE, NOT Write-Progress. The build has to be able to run
            in a background runspace with a window draining its reports on the
            dispatcher, and a cmdlet writing to its own progress stream cannot be
            read from another thread. An injected sink is also what CLAUDE.md
            rule 5 asks for, and it makes the reporting assertable under Pester
            with no window and no ADK.

            THE DEFAULT RECORDS NOTHING. Update-HDTBootImage reports on every
            build whether or not anybody is watching, so the do-nothing path is
            the common one and it must cost nothing: with no -Queue, Report is a
            method that returns.

            DRAINED MEANS TAKEN. A watcher ticks a few times a second and
            appends whatever it drains; a Drain that left the reports behind
            would repaint the whole build on every tick.

            THE QUEUE IS THE CALLER'S, AND IT MUST BE SYNCHRONIZED. Two threads
            cross it - the runspace reporting and the dispatcher draining - and
            an unsynchronised Queue corrupts or throws under that. Taking it as
            a parameter rather than making one here is what lets the window hand
            the same queue to a sink it passes into another runspace.

        .PARAMETER Queue
            The synchronized queue to record into. Omitted, nothing is recorded.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Report, Complete
            and Drain.

        .EXAMPLE
            $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            $progress = New-HDTBuildProgress -Queue $queue
            Update-HDTBootImage -WorkspaceRoot 'C:\HDTLab\Share' -Progress $progress

        .EXAMPLE
            foreach ($report in $progress.Drain()) {
                '{0}/{1} {2}' -f $report.Step, $report.Total, $report.Title
            }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory service object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object] $Queue = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Queue = $Queue

        # WHETHER THE END HAS BEEN REPORTED, so the runspace that ran the command
        # can supply one when the command did not. Update-HDTBootImage reports
        # its own; Import-HDTDriver has half a dozen exits, including
        # ThrowTerminatingError and a ShouldProcess refusal, and threading a
        # report through every one of them is how the next command to use this
        # window forgets. The first import through it extracted 269 drivers,
        # listed all of them, and finished 'FAILED - the build ended without
        # saying why', which is a successful import reported as a failure.
        Completed = $false
    }

    $service | Add-Member -MemberType ScriptMethod -Name Report -Value {
        param([int] $Step, [int] $Total, [string] $Title, [string] $Detail)

        if ($null -eq $this.Queue) { return }

        $this.Queue.Enqueue([pscustomobject] @{
                Step       = $Step
                Total      = $Total
                Title      = $Title
                Detail     = $Detail
                IsComplete = $false
                Succeeded  = $false
            })
    }

    # THE END IS A REPORT LIKE ANY OTHER, so a watcher reads one stream and
    # never has to poll a second thing to find out whether the build is still
    # going. A window that simply stopped receiving would have to guess between
    # "finished", "slow" and "died".
    $service | Add-Member -MemberType ScriptMethod -Name Complete -Value {
        param([bool] $Succeeded, [string] $Detail)

        # SET BEFORE THE QUEUE CHECK, so a sink built with no queue - which is
        # every command-line caller - still records that the end was reported.
        # Otherwise the flag would mean "there was a queue" rather than "the
        # command said it had finished".
        $this.Completed = $true

        if ($null -eq $this.Queue) { return }

        $this.Queue.Enqueue([pscustomobject] @{
                Step       = 0
                Total      = 0
                Title      = 'finished'
                Detail     = $Detail
                IsComplete = $true
                Succeeded  = $Succeeded
            })
    }

    $service | Add-Member -MemberType ScriptMethod -Name Drain -Value {

        if ($null -eq $this.Queue) { return , ([object[]] @()) }

        $taken = New-Object -TypeName System.Collections.ArrayList

        # Count is read once per iteration rather than cached: the other thread
        # is still enqueueing, and draining "the count it had when we started"
        # is a race that loses reports at the end of a build.
        while ($this.Queue.Count -gt 0) {
            [void] $taken.Add($this.Queue.Dequeue())
        }

        # The unary comma is mandatory: a ScriptMethod collapses a
        # single-element array to a scalar without it.
        return , ([object[]] @($taken))
    }

    return $service
}
