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
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
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

Describe 'New-HDTBuildProgress writes a build log' {

    # A BUILD THAT LEFT NO RECORD, WHICH IS EVERY BUILD.
    #
    # The default sink records nothing, so a command-line build was five minutes
    # of silence that wrote no log - and the console only ever wrote
    # Boot\<image>.build.log when somebody CLICKED Open Log, exporting the lines
    # out of a WPF list that was thrown away when the window closed. So a build
    # that failed while nobody was watching left nothing behind at all, which is
    # exactly the build whose log is worth having.
    #
    # THE SINK WRITES IT, NOT THE CALLER, so every route through
    # Update-HDTBootImage gets the same file for the same reason - the console's
    # Open Log button and a bare command line are not two answers to "where is
    # the log".
    #
    # AND IT MAY NEVER FAIL A BUILD. A share that has gone read-only is a reason
    # to lose the log, not a reason to lose a boot image somebody waited five
    # minutes for.

    BeforeEach {
        $script:logPath = Join-Path -Path $TestDrive -ChildPath 'HDTPE_wiz_x64.build.log'
    }

    It 'writes a line for every step it is told about' {
        $sink = New-HDTBuildProgress -LogPath $script:logPath

        $sink.Report(1, 17, 'Reading the workspace document', 'C:\HDTLab\Share')
        $sink.Report(5, 17, 'Copying the source WinPE image', 'scratch\boot.wim')

        $line = @(Get-Content -LiteralPath $script:logPath)

        @($line | Where-Object { $_ -like '*Reading the workspace document*' }).Count | Should -Be 1
        @($line | Where-Object { $_ -like '*Copying the source WinPE image*' }).Count | Should -Be 1
    }

    It 'numbers each step, so a log that stops says where it stopped' {
        $sink = New-HDTBuildProgress -LogPath $script:logPath

        $sink.Report(5, 17, 'Copying the source WinPE image', '')

        (Get-Content -LiteralPath $script:logPath -Raw) | Should -BeLike '*5/17*'
    }

    It 'records the detail, because "which folder" is the first question of a failed build' {
        $sink = New-HDTBuildProgress -LogPath $script:logPath

        $sink.Report(4, 17, 'Checking the scratch path', 'C:\HDTLab\scratch\bootimage')

        (Get-Content -LiteralPath $script:logPath -Raw) | Should -BeLike '*C:\HDTLab\scratch\bootimage*'
    }

    It 'says how it ended, and whether that was a success' {
        $sink = New-HDTBuildProgress -LogPath $script:logPath

        $sink.Report(1, 17, 'Reading the workspace document', '')
        $sink.Complete($true, 'C:\HDTLab\Share\Boot\HDTPE_wiz_x64.wim')

        $text = Get-Content -LiteralPath $script:logPath -Raw

        $text | Should -BeLike '*finished*'
        $text | Should -BeLike '*HDTPE_wiz_x64.wim*'
    }

    It 'marks a failed build as failed rather than merely stopping' {
        $sink = New-HDTBuildProgress -LogPath $script:logPath

        $sink.Complete($false, 'the image could not be mounted')

        (Get-Content -LiteralPath $script:logPath -Raw) | Should -BeLike '*FAILED*'
    }

    It 'starts each build a fresh file, because "the log" means the last build''s' {
        $sink = New-HDTBuildProgress -LogPath $script:logPath
        $sink.Report(1, 17, 'the first build', '')

        $second = New-HDTBuildProgress -LogPath $script:logPath
        $second.Report(1, 17, 'the second build', '')

        $text = Get-Content -LiteralPath $script:logPath -Raw

        $text | Should -BeLike '*the second build*'
        $text | Should -Not -BeLike '*the first build*'
    }

    It 'writes nothing at all when no log path is named' {
        # ITS OWN PATH, because TestDrive lives for the whole block and the
        # tests above have already written the shared one - asserting on that
        # file would prove the previous test ran, not that this sink stayed
        # silent.
        $untouched = Join-Path -Path $TestDrive -ChildPath 'never-written.build.log'

        $sink = New-HDTBuildProgress

        $sink.Report(1, 17, 'Reading the workspace document', '')
        $sink.Complete($true, '')

        Test-Path -LiteralPath $untouched | Should -BeFalse
    }

    It 'never lets the log cost the build' {
        # A directory where the file should be: every write throws, and not one
        # of them may reach the caller.
        $blocked = Join-Path -Path $TestDrive -ChildPath 'blocked.build.log'
        [void] (New-Item -Path $blocked -ItemType Directory -Force)

        { $sink = New-HDTBuildProgress -LogPath $blocked
          $sink.Report(1, 17, 'Reading the workspace document', '')
          $sink.Complete($true, 'done') } | Should -Not -Throw
    }

    It 'still feeds a queue when it has one, so the window is unaffected' {
        $queue = New-Object -TypeName 'System.Collections.Queue'
        $sink = New-HDTBuildProgress -Queue $queue -LogPath $script:logPath

        $sink.Report(3, 17, 'Planning the optional components', '')

        @($sink.Drain()).Count | Should -Be 1
        (Get-Content -LiteralPath $script:logPath -Raw) | Should -BeLike '*Planning the optional components*'
    }

    It 'leaves the previous log alone until it actually has something to say' {
        # A SINK THAT NEVER REPORTS MUST NOT DESTROY THE LAST BUILD'S LOG.
        # Update-HDTBootImage builds its sink before it takes ShouldProcess, so
        # a -WhatIf constructs one and then reports nothing - and truncating at
        # construction would mean a dry run wiped the record of the real build
        # before it, replacing it with an empty file.
        $path = Join-Path -Path $TestDrive -ChildPath 'kept.build.log'
        Set-Content -LiteralPath $path -Value 'the previous build' -Encoding UTF8

        $null = New-HDTBuildProgress -LogPath $path

        (Get-Content -LiteralPath $path -Raw) | Should -BeLike '*the previous build*'
    }

    It 'writes through the injected file system and never straight to disk' {
        # THIS ESCAPED ONTO A LIVE SHARE. Written with [System.IO.File] first,
        # and the boot image suite - whose workspace root is the real string
        # 'C:\HDTLab\Share' - promptly wrote a build log into the lab's actual
        # deployment share on every test run. Every other write in that build
        # goes through a fake; the one that bypassed it was the one that got out.
        $fs = New-HDTFakeFileSystem
        $path = 'Z:\Deploy\Boot\HDTPE_wiz_x64.build.log'

        $sink = New-HDTBuildProgress -LogPath $path -FileSystem $fs
        $sink.Report(1, 17, 'Reading the workspace document', 'Z:\Deploy')
        $sink.Complete($true, 'Z:\Deploy\Boot\HDTPE_wiz_x64.wim')

        @($fs.GetOperationName()) | Should -Contain 'WriteAllText'
        @($fs.GetOperationName()) | Should -Contain 'AppendAllText'
        $fs.ReadAllText($path) | Should -BeLike '*Reading the workspace document*'
    }

    It 'reaches for no file system at all when it has no log to write' {
        # A sink with no LogPath touches nothing, so it must not construct an
        # adapter it will never call - every existing caller pays nothing.
        $sink = New-HDTBuildProgress

        $sink.FileSystem | Should -BeNullOrEmpty
    }
}
