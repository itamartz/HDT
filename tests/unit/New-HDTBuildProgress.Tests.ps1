# The channel a long build reports itself on.
#
# Update-HDTBootImage is seventeen steps and two and a half minutes, and it was
# SILENT for all of them: it took a ShouldProcess and returned a result object,
# with nothing in between. On a console that is a prompt that has stopped
# answering; in a window it is worse, because the window greys out and an
# administrator reasonably concludes it has hung and kills it - which strands a
# mounted image that then needs dism /cleanup-wim before anything can build
# again.
#
# IT IS A SERVICE, NOT A Write-Progress CALL. The build has to be able to run in
# a background runspace with a window draining its reports on the dispatcher,
# and a cmdlet writing to its own progress stream cannot be read from another
# thread. An injected sink is also what CLAUDE.md rule 5 asks for, and what
# makes the reporting assertable under Pester with no window at all.
#
# THE DEFAULT SINK RECORDS NOTHING. Every existing caller - the tests, the
# console, a script - keeps working unchanged and pays nothing.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTBuildProgress' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'New-HDTBuildProgress' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'exposes the two methods the contract needs' {
        $sink = New-HDTBuildProgress

        $method = @($sink | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

        $method | Should -Contain 'Report'
        $method | Should -Contain 'Complete'
    }

    It 'records nothing when nobody asked for a queue' {
        # THE DEFAULT IS A NULL OBJECT. Update-HDTBootImage reports on every
        # build whether or not anybody is watching, so the do-nothing path is
        # the hot one.
        $sink = New-HDTBuildProgress
        $sink.Report(1, 17, 'read workspace.yaml', 'C:\ws\workspace.yaml')

        @($sink.Drain()).Count | Should -Be 0
    }

    It 'hands a queued report back through Drain, once' {
        $sink = New-HDTBuildProgress -Queue ([System.Collections.Queue]::Synchronized([System.Collections.Queue]::new()))

        $sink.Report(1, 17, 'read workspace.yaml', 'C:\ws\workspace.yaml')
        $sink.Report(2, 17, 'resolve the ADK', '')

        $drained = @($sink.Drain())

        @($drained).Count | Should -Be 2
        $drained[0].Step | Should -Be 1
        $drained[0].Total | Should -Be 17
        $drained[0].Title | Should -BeExactly 'read workspace.yaml'
        $drained[0].Detail | Should -BeExactly 'C:\ws\workspace.yaml'

        # DRAINED MEANS TAKEN. A window ticks four times a second and appends
        # what it drains; a Drain that left the reports behind would repaint the
        # whole build every tick.
        @($sink.Drain()).Count | Should -Be 0
    }

    It 'marks the end, so a watcher knows to stop rather than time out' {
        $sink = New-HDTBuildProgress -Queue ([System.Collections.Queue]::Synchronized([System.Collections.Queue]::new()))

        $sink.Complete($true, '')

        $last = @($sink.Drain())[-1]

        $last.IsComplete | Should -BeTrue
        $last.Succeeded | Should -BeTrue
    }

    It 'carries the failure with the end, because a window that just closes says nothing' {
        $sink = New-HDTBuildProgress -Queue ([System.Collections.Queue]::Synchronized([System.Collections.Queue]::new()))

        $sink.Complete($false, 'the ADK is incomplete')

        $last = @($sink.Drain())[-1]

        $last.Succeeded | Should -BeFalse
        $last.Detail | Should -BeExactly 'the ADK is incomplete'
    }

    It 'survives being reported to from another thread' {
        # THE WHOLE POINT. The build runs in a background runspace and the
        # window drains on the dispatcher, so the queue is crossed by two
        # threads and an unsynchronised one corrupts or throws.
        $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
        $sink = New-HDTBuildProgress -Queue $queue

        $runspace = [powershell]::Create()
        [void] $runspace.AddScript({
                param($Sink)
                for ($i = 1; $i -le 50; $i++) { $Sink.Report($i, 50, "step $i", '') }
            }).AddArgument($sink)

        $handle = $runspace.BeginInvoke()
        [void] $runspace.EndInvoke($handle)
        $runspace.Dispose()

        @($sink.Drain()).Count | Should -Be 50
    }
}
