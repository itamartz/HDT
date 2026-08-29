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
        [object] $Queue = $null,

        # WHERE THE BUILD LOG GOES, AND WHY THE SINK WRITES IT RATHER THAN THE
        # CALLER. Every build reported seventeen steps and NO BUILD KEPT THEM:
        # a command-line build recorded nothing at all, and the console wrote
        # Boot\<image>.build.log only when somebody CLICKED Open Log, exporting
        # a WPF list that was discarded when the window closed. So the build
        # whose log is worth having - the one that failed while nobody watched -
        # was the one that left nothing.
        #
        # Written here so every route to Update-HDTBootImage produces the same
        # file for the same reason, rather than the log depending on which
        # caller you happened to use.
        #
        # EMPTY MEANS NO FILE, which keeps every existing caller unchanged.
        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $LogPath = '',

        # AN IFileSystem, BECAUSE THIS WRITES A FILE AND RULE 5 IS NOT OPTIONAL.
        # Written with [System.IO.File] first, and the unit tests immediately
        # wrote a real log into the lab's live deployment share: the boot image
        # suite uses 'C:\HDTLab\Share' as its workspace root, and every OTHER
        # write in that build goes through a fake - so the single call that
        # bypassed the fake was the one that escaped onto a real share.
        [Parameter()]
        [AllowNull()]
        [object] $FileSystem = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Queue = $Queue

        # ONE FILE PER IMAGE, OVERWRITTEN BY EACH BUILD, which is what somebody
        # means by "the log" - the last build's. Get-HDTConsoleBuildLogPath
        # already settles the name for the same reason; this is the write half.
        LogPath = [string] $LogPath
        FileSystem = $FileSystem

        # WHETHER THIS SINK HAS WRITTEN YET, so the FIRST write truncates and
        # every one after it appends. Truncating at construction instead would
        # mean a -WhatIf - which builds a sink and then reports nothing -
        # destroyed the last real build's log to say nothing in its place.
        Started = $false

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

    # ONLY WHEN A LOG IS WANTED. A sink with no LogPath touches no file at all,
    # so it must not reach for an adapter it will never call.
    if (-not [string]::IsNullOrWhiteSpace($LogPath) -and $null -eq $service.FileSystem) {
        $service.FileSystem = New-HDTFileSystem
    }

    $service | Add-Member -MemberType ScriptMethod -Name Report -Value {
        param([int] $Step, [int] $Total, [string] $Title, [string] $Detail)

        if (-not [string]::IsNullOrWhiteSpace($this.LogPath)) {
            try {
                $entry = '{0}  {1}/{2}  {3}' -f (Get-Date).ToString('HH:mm:ss'), $Step, $Total, $Title

                if (-not [string]::IsNullOrWhiteSpace($Detail)) {
                    $entry = '{0}  {1}' -f $entry, $Detail
                }

                if ($this.Started) {
                    $this.FileSystem.AppendAllText($this.LogPath, ($entry + [System.Environment]::NewLine))
                } else {
                    $this.FileSystem.WriteAllText($this.LogPath, ($entry + [System.Environment]::NewLine))
                    $this.Started = $true
                }
            } catch {
                Write-Verbose ("the build log could not be written: {0}" -f $_.Exception.Message)
            }
        }

        # AND A PROGRESS BAR WHEN NOTHING ELSE IS DRAWING ONE. A queue means a
        # window is rendering these and a second renderer would fight it; no
        # queue means a bare console, where seventeen steps of silence is the
        # thing that gets a build killed half way through a mount.
        if ($null -eq $this.Queue -and $Total -gt 0) {
            $percent = [int] [math]::Round((100.0 * $Step / $Total), 0)
            if ($percent -lt 0) { $percent = 0 }
            if ($percent -gt 100) { $percent = 100 }

            Write-Progress -Activity 'Building the boot image' `
                -Status ('{0}/{1}  {2}' -f $Step, $Total, $Title) `
                -CurrentOperation $Detail -PercentComplete $percent
        }

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

        if (-not [string]::IsNullOrWhiteSpace($this.LogPath)) {
            try {
                $outcome = 'finished'
                if (-not $Succeeded) { $outcome = 'FAILED' }

                $entry = '{0}  {1}' -f (Get-Date).ToString('HH:mm:ss'), $outcome

                if (-not [string]::IsNullOrWhiteSpace($Detail)) {
                    $entry = '{0}  {1}' -f $entry, $Detail
                }

                if ($this.Started) {
                    $this.FileSystem.AppendAllText($this.LogPath, ($entry + [System.Environment]::NewLine))
                } else {
                    $this.FileSystem.WriteAllText($this.LogPath, ($entry + [System.Environment]::NewLine))
                    $this.Started = $true
                }
            } catch {
                Write-Verbose ("the build log could not be completed: {0}" -f $_.Exception.Message)
            }
        }

        if ($null -eq $this.Queue) {
            Write-Progress -Activity 'Building the boot image' -Completed
            return
        }

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
