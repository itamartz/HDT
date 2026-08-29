# DESIGN 4.4.2: two formats, one write. Every log call emits a JSONL record AND a
# CMTrace line from a single Write-HDTLog invocation, both UTF-8, both through the
# injected IFileSystem - DESIGN 4.4.1's "nothing writes a log anywhere else".
#
# Nothing in this file touches a real disk or a real clock. The seq assertions are
# the ones that matter most: seq is monotonic within a leg, continuable across
# one, and a message dropped by verbosity must not consume a number, or the
# ordering of a multi-leg deployment stops being evidence.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:jsonlPath = 'X:\HDT\Logs\HDT.jsonl'
    $script:masterPath = 'X:\HDT\Logs\HDT.log'

    # The twenty-two names of DESIGN 4.4.2's controlled vocabulary: the eleven
    # the design lists, plus reboot.teardown (DESIGN 4.5.3's failsafe, emitted by
    # 03-03), message (what a custom step's bare Write-HDTLog produces, DESIGN
    # 4.4.4) and step.progress (a step long enough to report on itself - an
    # apply, which prints a percentage for nine minutes), plus the five driver.*
    # events ApplyDrivers writes its DECISION to rather than just its outcome,
    # plus the three console.* ones - the console wrote no log at all until
    # 2026-08-27, so a reported crash could only be answered by reading source.
    # Every addition is written back into DESIGN 4.4.2.
    $script:eventVocabulary = @(
        'console.action'
        'console.error'
        'console.session'
        'driver.enumerate'
        'driver.fallback'
        'driver.group'
        'driver.match'
        'driver.staged'
        'message'
        'native.exec'
        'phase.change'
        'reboot.arm'
        'reboot.resume'
        'reboot.teardown'
        'run.end'
        'run.start'
        'step.complete'
        'step.fail'
        'step.progress'
        'step.skip'
        'step.start'
        'var.resolve'
    )
}

Describe 'Write-HDTLog' {

    BeforeEach {
        $script:journal = [System.Collections.ArrayList]::new()
        $script:fs = New-HDTFakeFileSystem -Journal $script:journal
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc)) -Journal $script:journal
        $script:context = New-HDTLogContext -RunId '8f3c1a90-0000-4000-8000-000000000001' -Phase WinPE `
            -LogPath 'X:\HDT\Logs' -FileSystem $script:fs -Clock $script:clock -ThreadId 4820
    }

    Context 'the JSONL record' {

        It 'appends one line to HDT.jsonl' {
            Write-HDTLog -Context $script:context -Message 'Applied index 1'

            $text = $script:fs.ReadAllText($script:jsonlPath)
            @($text -split "`n" | Where-Object { $_ }).Count | Should -Be 1
        }

        It 'writes valid JSON on that line' {
            Write-HDTLog -Context $script:context -Message 'Applied index 1'

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.message | Should -BeExactly 'Applied index 1'
        }

        It 'writes exactly one JSON object per call' {
            Write-HDTLog -Context $script:context -Message 'one'
            Write-HDTLog -Context $script:context -Message 'two'
            Write-HDTLog -Context $script:context -Message 'three'

            $line = @($script:fs.ReadAllText($script:jsonlPath) -split "`n" | Where-Object { $_ })

            $line.Count | Should -Be 3
            @($line | ForEach-Object { (ConvertFrom-Json -InputObject $_).message }) |
                Should -Be @('one', 'two', 'three')
        }

        It 'writes the ts as an ISO 8601 string' {
            # Asserted on the FILE TEXT, not on ConvertFrom-Json's output:
            # ConvertFrom-Json turns the string back into a [datetime] and would
            # hide the \/Date(...)\/ failure this assertion exists to catch.
            Write-HDTLog -Context $script:context -Message 'x'

            $script:fs.ReadAllText($script:jsonlPath) | Should -Match '"ts":"2026-08-13T00:11:02\.4810000Z"'
        }

        It 'never writes a \/Date( timestamp' {
            Write-HDTLog -Context $script:context -Message 'x'

            $script:fs.ReadAllText($script:jsonlPath) | Should -Not -BeLike '*/Date(*'
        }

        It 'writes the run id from the context' {
            Write-HDTLog -Context $script:context -Message 'x'

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.runId | Should -BeExactly '8f3c1a90-0000-4000-8000-000000000001'
        }

        It 'numbers records with a monotonic seq' {
            Write-HDTLog -Context $script:context -Message 'one'
            Write-HDTLog -Context $script:context -Message 'two'
            Write-HDTLog -Context $script:context -Message 'three'

            $line = @($script:fs.ReadAllText($script:jsonlPath) -split "`n" | Where-Object { $_ })
            @($line | ForEach-Object { (ConvertFrom-Json -InputObject $_).seq }) | Should -Be @(1, 2, 3)
        }

        It 'continues numbering from a seeded seq' {
            # The reboot-survival property: seq is restored from state.json on
            # resume, so the ordering of a multi-leg deployment is unambiguous even
            # when the clock skews during specialize.
            $resumed = New-HDTLogContext -RunId 'r1' -Phase FullOS -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fs -Clock $script:clock -Seq 416

            Write-HDTLog -Context $resumed -Message 'after the reboot'

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.seq | Should -Be 417
        }

        It 'writes the level it was given' {
            Write-HDTLog -Context $script:context -Message 'x' -Severity Warning

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.level | Should -BeExactly 'Warning'
        }

        It 'defaults the level to Info' {
            Write-HDTLog -Context $script:context -Message 'x'

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.level | Should -BeExactly 'Info'
        }

        It 'writes the phase from the context' {
            Write-HDTLog -Context $script:context -Message 'x'

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.phase | Should -BeExactly 'WinPE'
        }

        It 'writes the step index, name and type from the context' {
            # DESIGN 4.4.4: a custom step's output is attributable without the
            # author doing anything.
            $script:context.SetStep(3, 'Apply OS', 'ApplyImage', $null)
            Write-HDTLog -Context $script:context -Message 'x'

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.stepIndex | Should -Be 3
            $record.stepName | Should -BeExactly 'Apply OS'
            $record.stepType | Should -BeExactly 'ApplyImage'
        }

        It 'omits stepName when no step is set' {
            Write-HDTLog -Context $script:context -Message 'x'

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            @($record.PSObject.Properties.Name) | Should -Not -Contain 'stepName'
            @($record.PSObject.Properties.Name) | Should -Not -Contain 'stepType'
            @($record.PSObject.Properties.Name) | Should -Not -Contain 'stepIndex'
        }

        It 'writes the event it was given' {
            Write-HDTLog -Context $script:context -Message 'x' -Event 'step.complete'

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.event | Should -BeExactly 'step.complete'
        }

        It 'defaults the event to message' {
            # DESIGN 4.4.4's Write-HDTLog "Checking vendor BIOS level" - a custom
            # step supplies no event and must still produce a well-formed record.
            Write-HDTLog -Context $script:context -Message 'Checking vendor BIOS level'

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.event | Should -BeExactly 'message'
        }

        It 'rejects an event outside the vocabulary' {
            $record = $null
            try { Write-HDTLog -Context $script:context -Message 'x' -Event 'foo.bar' } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'ParameterArgumentValidationError*'
        }

        It 'accepts the event <_>' -ForEach @(
            'message', 'native.exec', 'phase.change', 'reboot.arm', 'reboot.resume',
            'reboot.teardown', 'run.end', 'run.start', 'step.complete', 'step.fail',
            'step.progress', 'step.skip', 'step.start', 'var.resolve'
        ) {
            Write-HDTLog -Context $script:context -Message 'x' -Event $_

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.event | Should -BeExactly $_
        }

        It 'validates exactly twenty-two events and no more' {
            # This is what ties the engine to DESIGN 4.4.2's controlled vocabulary
            # rather than to a comment. It goes red when somebody adds a twentieth
            # event without touching the design.
            $attribute = @((Get-Command -Name Write-HDTLog).Parameters['Event'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })

            $attribute.Count | Should -Be 1
            @($attribute[0].ValidValues).Count | Should -Be 22
            @($attribute[0].ValidValues | Sort-Object) | Should -Be $script:eventVocabulary
        }

        It 'writes durationMs when given' {
            Write-HDTLog -Context $script:context -Message 'x' -Event 'step.complete' -DurationMs 95120

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.durationMs | Should -Be 95120
        }

        It 'omits durationMs when not given' {
            Write-HDTLog -Context $script:context -Message 'x'

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            @($record.PSObject.Properties.Name) | Should -Not -Contain 'durationMs'
        }

        It 'writes the data payload' {
            Write-HDTLog -Context $script:context -Message 'x' -Event 'step.complete' `
                -Data ([ordered] @{ index = 1; target = 'W:\'; wim = 'X:\install.wim' })

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.data.index | Should -Be 1
            $record.data.target | Should -BeExactly 'W:\'
            $record.data.wim | Should -BeExactly 'X:\install.wim'
        }

        It 'writes a nested data payload' {
            Write-HDTLog -Context $script:context -Message 'x' `
                -Data ([ordered] @{ disk = [ordered] @{ number = 0; partition = [ordered] @{ letter = 'W' } } })

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.data.disk.partition.letter | Should -BeExactly 'W'
        }

        It 'omits data when not given' {
            Write-HDTLog -Context $script:context -Message 'x'

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            @($record.PSObject.Properties.Name) | Should -Not -Contain 'data'
        }

        It 'writes the component it was given' {
            Write-HDTLog -Context $script:context -Message 'x' -Component 'ImageService'

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.component | Should -BeExactly 'ImageService'
        }

        It 'falls back to the context component' {
            Write-HDTLog -Context $script:context -Message 'x'

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            $record.component | Should -BeExactly 'Engine'
        }

        It 'writes the keys in the DESIGN 4.4.2 order' {
            $script:context.SetStep(3, 'Apply OS', 'ApplyImage', $null)
            Write-HDTLog -Context $script:context -Message 'x' -Event 'step.complete' `
                -Component 'ImageService' -DurationMs 95120 -Data ([ordered] @{ index = 1 })

            $record = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))
            @($record.PSObject.Properties.Name) | Should -Be @(
                'ts', 'runId', 'seq', 'level', 'phase', 'clockUnsynced', 'stepIndex', 'stepName', 'stepType',
                'component', 'event', 'message', 'durationMs', 'data')
        }
    }

    Context 'the CMTrace line' {

        It 'appends one line to HDT.log' {
            Write-HDTLog -Context $script:context -Message 'Applied index 1'

            @($script:fs.ReadAllText($script:masterPath) -split "`n" | Where-Object { $_ }).Count | Should -Be 1
        }

        It 'writes both files from one call' {
            Write-HDTLog -Context $script:context -Message 'Applied index 1'

            $script:fs.GetOperationName() | Should -Be @('AppendAllText', 'AppendAllText')
            @($script:fs.Operations | ForEach-Object { $_.Arguments[0] }) |
                Should -Be @($script:jsonlPath, $script:masterPath)
        }

        It 'writes the message into the CMTrace line' {
            Write-HDTLog -Context $script:context -Message 'Applied index 1 to W:\ in 95s'

            # StartsWith, not -BeLike: '[' opens a character class in a wildcard
            # pattern, and this format is made of square brackets.
            $script:fs.ReadAllText($script:masterPath).StartsWith('<![LOG[Applied index 1 to W:\ in 95s (clock unsynced)]LOG]!>') |
                Should -BeTrue
        }

        It 'maps the severity <Severity> to the CMTrace type <Type>' -ForEach @(
            @{ Severity = 'Info'; Type = '1' }
            @{ Severity = 'Warning'; Type = '2' }
            @{ Severity = 'Error'; Type = '3' }
        ) {
            Write-HDTLog -Context $script:context -Message 'x' -Severity $Severity

            $script:fs.ReadAllText($script:masterPath) | Should -BeLike ('*type="{0}"*' -f $Type)
        }

        It 'uses the context thread id' {
            Write-HDTLog -Context $script:context -Message 'x'

            $script:fs.ReadAllText($script:masterPath) | Should -BeLike '*thread="4820"*'
        }

        It 'defaults the file to Engine when no step is running' {
            Write-HDTLog -Context $script:context -Message 'x'

            # TrimEnd: the writer leaves the line terminator on the file.
            $script:fs.ReadAllText($script:masterPath).TrimEnd("`r`n") | Should -BeLike '*file="Engine">'
        }

        It 'defaults the file to the step type when a step is running' {
            $script:context.SetStep(3, 'Apply OS', 'ApplyImage', $null)
            Write-HDTLog -Context $script:context -Message 'x'

            $script:fs.ReadAllText($script:masterPath).TrimEnd("`r`n") | Should -BeLike '*file="ApplyImage">'
        }

        It 'writes the source it was given as the file' {
            Write-HDTLog -Context $script:context -Message 'x' -Source 'Update-VendorBios.ps1'

            $script:fs.ReadAllText($script:masterPath).TrimEnd("`r`n") | Should -BeLike '*file="Update-VendorBios.ps1">'
        }
    }

    Context 'per-step logs' {

        It 'also appends the CMTrace line to the step log when one is set' {
            $script:context.SetStep(3, 'Apply OS', 'ApplyImage', 'X:\HDT\Logs\Steps\003-ApplyImage.log')
            Write-HDTLog -Context $script:context -Message 'Applied index 1'

            $script:fs.GetOperationName() | Should -Be @('AppendAllText', 'AppendAllText', 'AppendAllText')
            $script:fs.ReadAllText('X:\HDT\Logs\Steps\003-ApplyImage.log').StartsWith('<![LOG[Applied index 1 (clock unsynced)]LOG]!>') |
                Should -BeTrue
        }

        It 'writes the same line to the step log and the master log' {
            $script:context.SetStep(3, 'Apply OS', 'ApplyImage', 'X:\HDT\Logs\Steps\003-ApplyImage.log')
            Write-HDTLog -Context $script:context -Message 'Applied index 1'

            $script:fs.ReadAllText('X:\HDT\Logs\Steps\003-ApplyImage.log') |
                Should -BeExactly ($script:fs.ReadAllText($script:masterPath))
        }

        It 'does not write a step log when none is set' {
            $script:context.SetStep(3, 'Apply OS', 'ApplyImage', $null)
            Write-HDTLog -Context $script:context -Message 'x'

            $script:fs.GetOperationName() | Should -Be @('AppendAllText', 'AppendAllText')
        }

        It 'numbers the step log file in execution order' {
            # DESIGN 4.4: "step files are numbered in execution order, so the
            # directory listing itself tells you where it stopped". The caller
            # supplies the name; the context stores it verbatim.
            $script:context.SetStep(3, 'Apply OS', 'ApplyImage', 'X:\HDT\Logs\Steps\003-ApplyImage.log')
            Write-HDTLog -Context $script:context -Message 'x'

            $script:context.StepLogPath | Should -BeExactly 'X:\HDT\Logs\Steps\003-ApplyImage.log'
            $script:fs.Operations[2].Arguments[0] | Should -BeExactly 'X:\HDT\Logs\Steps\003-ApplyImage.log'
        }
    }

    Context 'line endings' {

        # CMTRACE IS CRLF, AND THE FIELDS WERE NEVER THE PART THAT BROKE.
        #
        # CMTrace's parser is line oriented and breaks entries on CRLF. Handed a
        # file of bare line feeds it never separates one entry from the next, the
        # <![LOG[...]LOG]!> match fails, and it falls back to dumping raw text
        # with the Component, Date/Time and Thread columns EMPTY. Every attribute
        # is present in the bytes and the reader never reaches them.
        #
        # WHICH IS EXACTLY HOW IT SHIPPED. The assertions above split on "`n",
        # which matches LF and CRLF alike, so they proved the component was
        # written and could not see that the file was unreadable. On the lab
        # share all sixteen HDT.log files carried CR=0 - a technician opening any
        # of them saw a blank Component column and correctly reported it missing.
        #
        # THE JSONL STAYS LF, and this is not a detail to sweep up with a blanket
        # replace: JSON Lines defines its separator as \n, so the two formats
        # genuinely differ and "fix the newlines" would break the reader that
        # works to repair the one that does not.

        It 'ends every CMTrace destination with CRLF' {
            # AGAINST THE SET, not against the master log alone. There are four
            # CMTrace destinations - local master, local step, and the two
            # SLShareDynamicLogging mirrors - and fixing only the one somebody
            # noticed would leave a technician watching the share live, which is
            # the case the mirror exists for, still reading blank columns.
            $fs = New-HDTFakeFileSystem
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc))
            $context = New-HDTLogContext -RunId 'run-20260813-001102' -Phase WinPE `
                -LogPath 'X:\HDT\Logs' -FileSystem $fs -Clock $clock -ThreadId 4820 `
                -DynamicPath '\192.0.2.108\HDTShare\Logs\LT-7FJ45S2'
            $context.SetStep(3, 'Apply OS', 'ApplyImage', 'X:\HDT\Logs\Steps\003-ApplyImage.log')

            Write-HDTLog -Context $context -Message 'Applied index 1'

            $cmtrace = @(
                [string] $context.MasterLogPath
                [string] $context.StepLogPath
                [string] $context.DynamicMasterLogPath
                [string] $context.DynamicStepLogPath
            )

            $cmtrace.Count | Should -Be 4

            foreach ($path in $cmtrace) {
                $path | Should -Not -BeNullOrEmpty
                $fs.ReadAllText($path).EndsWith("`r`n") |
                    Should -BeTrue -Because ('{0} is read by CMTrace' -f $path)
            }
        }

        It 'keeps every JSONL destination on a bare line feed' {
            $fs = New-HDTFakeFileSystem
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc))
            $context = New-HDTLogContext -RunId 'run-20260813-001102' -Phase WinPE `
                -LogPath 'X:\HDT\Logs' -FileSystem $fs -Clock $clock -ThreadId 4820 `
                -DynamicPath '\192.0.2.108\HDTShare\Logs\LT-7FJ45S2'

            Write-HDTLog -Context $context -Message 'Applied index 1'

            foreach ($path in @([string] $context.JsonlPath, [string] $context.DynamicJsonlPath)) {
                $path | Should -Not -BeNullOrEmpty
                $text = $fs.ReadAllText($path)
                $text.EndsWith("`n") | Should -BeTrue -Because ('{0} is JSON Lines' -f $path)
                $text.Contains("`r") | Should -BeFalse -Because ('{0} is JSON Lines, whose separator is a line feed' -f $path)
            }
        }

        It 'writes one CMTrace entry per call, counted the way CMTrace counts them' {
            # SPLIT ON CRLF, so this fails for a file of bare line feeds instead
            # of passing the way the "`n" splits above do.
            $fs = New-HDTFakeFileSystem
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc))
            $context = New-HDTLogContext -RunId 'run-20260813-001102' -Phase WinPE `
                -LogPath 'X:\HDT\Logs' -FileSystem $fs -Clock $clock -ThreadId 4820

            Write-HDTLog -Context $context -Message 'first'
            Write-HDTLog -Context $context -Message 'second'

            $entry = @($fs.ReadAllText([string] $context.MasterLogPath) -split "`r`n" | Where-Object { $_ })

            $entry.Count | Should -Be 2
            $entry[0].StartsWith('<![LOG[first (clock unsynced)]LOG]!>') | Should -BeTrue
            $entry[1].StartsWith('<![LOG[second (clock unsynced)]LOG]!>') | Should -BeTrue
        }
    }

    Context 'verbosity' {

        It 'drops a Debug message when the level is Info' {
            Write-HDTLog -Context $script:context -Message 'x' -Severity Debug

            @($script:fs.Operations).Count | Should -Be 0
        }

        It 'writes a Debug message when the level is Debug' {
            $verbose = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fs -Clock $script:clock -Level Debug

            Write-HDTLog -Context $verbose -Message 'x' -Severity Debug

            @($script:fs.Operations).Count | Should -Be 2
        }

        It 'drops Info and Debug when the level is Warning' {
            $quiet = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fs -Clock $script:clock -Level Warning

            Write-HDTLog -Context $quiet -Message 'info' -Severity Info
            Write-HDTLog -Context $quiet -Message 'debug' -Severity Debug
            Write-HDTLog -Context $quiet -Message 'warning' -Severity Warning

            $line = @($script:fs.ReadAllText($script:jsonlPath) -split "`n" | Where-Object { $_ })
            $line.Count | Should -Be 1
            (ConvertFrom-Json -InputObject $line[0]).message | Should -BeExactly 'warning'
        }

        It 'always writes an Error' {
            $quiet = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fs -Clock $script:clock -Level Error

            Write-HDTLog -Context $quiet -Message 'boom' -Severity Error

            (ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))).message |
                Should -BeExactly 'boom'
        }

        It 'does not consume a seq number for a dropped message' {
            # Verbosity is free, not a hole in the numbering.
            Write-HDTLog -Context $script:context -Message 'dropped' -Severity Debug
            Write-HDTLog -Context $script:context -Message 'kept'

            $script:context.Seq | Should -Be 1
            (ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:jsonlPath))).seq | Should -Be 1
        }

        It 'touches the filesystem not at all for a dropped message' {
            Write-HDTLog -Context $script:context -Message 'dropped' -Severity Debug

            @($script:fs.Operations).Count | Should -Be 0
            @($script:journal).Count | Should -Be 0
        }

        It 'does not read the clock for a dropped message' {
            Write-HDTLog -Context $script:context -Message 'dropped' -Severity Debug

            @($script:clock.Operations).Count | Should -Be 0
        }
    }

    Context 'it never touches anything real' {

        It 'writes only through the injected filesystem' {
            Write-HDTLog -Context $script:context -Message 'x'

            @($script:journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('Clock.GetUtcNow', 'FileSystem.AppendAllText', 'FileSystem.AppendAllText')
        }

        It 'reads the time only through the injected clock' {
            Write-HDTLog -Context $script:context -Message 'x'

            $script:clock.GetOperationName() | Should -Be @('GetUtcNow')
        }

        It 'reads the clock exactly once per call' {
            # Both formats carry the same instant, so one call is one reading.
            Write-HDTLog -Context $script:context -Message 'x'

            @($script:clock.Operations).Count | Should -Be 1
        }

        It 'writes nothing to the real disk' {
            $real = New-HDTLogContext -RunId 'r1' -Phase FullOS -LogPath 'C:\HDTLab\does-not-exist\Logs' `
                -FileSystem $script:fs -Clock $script:clock

            Write-HDTLog -Context $real -Message 'x'

            Test-Path -LiteralPath 'C:\HDTLab\does-not-exist' | Should -BeFalse
        }

        It 'names no forbidden writer' {
            # DESIGN 4.4.1: nothing writes a log anywhere else. Set-Content and
            # Add-Content also carry the 5.1 BOM trap; Get-Date bypasses IClock.
            $path = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Write-HDTLog.ps1'
            $text = Get-Content -LiteralPath $path -Raw

            foreach ($forbidden in @('Set-Content', 'Add-Content', 'Out-File', 'Tee-Object', 'Get-Date', 'Write-Host')) {
                $text | Should -Not -BeLike ('*{0}*' -f $forbidden) -Because "$forbidden must never appear in the log writer"
            }
        }
    }

    # -- LINE TERMINATORS -----------------------------------------------------
    #
    # THE SUITE ABOVE COULD NOT SEE THIS. Every assertion in this file splits on
    # "`n", which matches LF and CRLF identically, so it proved the component,
    # thread and file fields were written while the artifact they were written
    # into was unreadable. Measured on the lab share: HDT.log, 25,587 bytes, CR
    # 0, LF 133, CRLF 0.
    #
    # CMTRACE BREAKS ENTRIES ON CRLF. It is a line-oriented Win32 parser; handed
    # LF-only text it never splits the entries, the per-entry
    # <![LOG[...]LOG]!> match fails, and it falls back to dumping raw text with
    # Component, Date/Time and Thread blank. The attributes were correct in the
    # bytes the whole time - the reader simply never reached them. DESIGN 11
    # already states the same rule for the other Windows-format file the build
    # writes: startnet.cmd is "written ASCII with CRLF and no BOM".
    #
    # JSON LINES IS DEFINED AS LF and must not change with it.
    Context 'line terminators' {

        BeforeEach {
            # EVERY PATH THE COMMAND CAN APPEND TO, from one call: the local
            # jsonl, master and step logs, and the three mirrored under the
            # share. The tests below are driven off the SET of appends this
            # produces, so a seventh path added later cannot default to the
            # wrong ending without failing here.
            $script:everyPath = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fs -Clock $script:clock -ThreadId 4820 `
                -DynamicPath '\192.0.2.108\HDTShare\Logs\LT-7FJ45S2'
            $script:everyPath.SetStep(3, 'Apply OS', 'ApplyImage', 'X:\HDT\Logs\Steps\003-ApplyImage.log')

            Write-HDTLog -Context $script:everyPath -Message 'Applied index 1'

            $script:appended = @($script:fs.Operations |
                    Where-Object { $_.Operation -eq 'AppendAllText' } |
                    ForEach-Object {
                        [pscustomobject] @{
                            Path    = [string] $_.Arguments[0]
                            Content = [string] $_.Arguments[1]
                        }
                    })
        }

        It 'appends to every local and mirrored path from one call' {
            # If this number moves, the two classifications below have a new
            # member to account for and the assertions that follow will say so.
            $script:appended.Count | Should -Be 6
        }

        It 'writes only CMTrace entries or JSON Lines records, nothing else' {
            # The classification the rest of this Context rests on, asserted
            # rather than assumed: shape decides the terminator, not a list of
            # property names somebody has to remember to extend.
            foreach ($write in $script:appended) {
                $shape = 'neither'
                if ($write.Content.StartsWith('<![LOG[')) { $shape = 'cmtrace' }
                if ($write.Content.StartsWith('{')) { $shape = 'jsonl' }

                $shape | Should -Not -BeExactly 'neither' -Because ('{0} is neither format' -f $write.Path)
            }
        }

        It 'terminates every CMTrace entry with a carriage return and line feed' {
            $cmtrace = @($script:appended | Where-Object { $_.Content.StartsWith('<![LOG[') })

            $cmtrace.Count | Should -Be 4
            foreach ($write in $cmtrace) {
                $write.Content.EndsWith("`r`n") | Should -BeTrue -Because ('CMTrace cannot split {0} on a bare LF' -f $write.Path)
            }
        }

        It 'leaves no bare line feed anywhere in a CMTrace entry' {
            # EndsWith alone would pass on "...`n`r`n". Counting proves every LF
            # in the text is the second half of a CRLF.
            $cmtrace = @($script:appended | Where-Object { $_.Content.StartsWith('<![LOG[') })

            foreach ($write in $cmtrace) {
                $lf = @([regex]::Matches($write.Content, "`n")).Count
                $crlf = @([regex]::Matches($write.Content, "`r`n")).Count

                $lf | Should -Be $crlf -Because ('{0} carries an LF that is not part of a CRLF' -f $write.Path)
                $crlf | Should -Be 1
            }
        }

        It 'terminates every JSON Lines record with a bare line feed' {
            $jsonl = @($script:appended | Where-Object { $_.Content.StartsWith('{') })

            $jsonl.Count | Should -Be 2
            foreach ($write in $jsonl) {
                $write.Content.EndsWith("`n") | Should -BeTrue
                $write.Content.EndsWith("`r`n") | Should -BeFalse -Because ('JSON Lines is defined as LF; {0} must not gain a CR' -f $write.Path)
                @([regex]::Matches($write.Content, "`r")).Count | Should -Be 0
            }
        }

        It 'ends the CMTrace files on disk with a carriage return and line feed' {
            # The artifact, not the string: three calls, and the file the
            # technician opens must carry three CRLF-terminated entries.
            Write-HDTLog -Context $script:everyPath -Message 'two'
            Write-HDTLog -Context $script:everyPath -Message 'three'

            foreach ($path in @($script:masterPath, 'X:\HDT\Logs\Steps\003-ApplyImage.log',
                    '\192.0.2.108\HDTShare\Logs\LT-7FJ45S2\HDT.log',
                    '\192.0.2.108\HDTShare\Logs\LT-7FJ45S2\Steps\003-ApplyImage.log')) {
                $text = $script:fs.ReadAllText($path)

                @([regex]::Matches($text, "`r`n")).Count | Should -Be 3 -Because ('{0} needs one CRLF per entry' -f $path)
                @([regex]::Matches($text, "`n")).Count | Should -Be 3 -Because ('{0} must carry no bare LF' -f $path)
            }
        }

        It 'ends the JSON Lines files on disk with a bare line feed' {
            Write-HDTLog -Context $script:everyPath -Message 'two'
            Write-HDTLog -Context $script:everyPath -Message 'three'

            foreach ($path in @($script:jsonlPath, '\192.0.2.108\HDTShare\Logs\LT-7FJ45S2\HDT.jsonl')) {
                $text = $script:fs.ReadAllText($path)

                @([regex]::Matches($text, "`n")).Count | Should -Be 3
                @([regex]::Matches($text, "`r")).Count | Should -Be 0 -Because ('{0} is JSON Lines, which is LF' -f $path)
            }
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name Write-HDTLog -ErrorAction Stop

            $help.Name | Should -BeExactly 'Write-HDTLog'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }

    Context 'clockUnsynced' {

        # DESIGN 4.4.2, WRITTEN DOWN AND NEVER BUILT.
        #
        # WinPE boots with an unsynchronised clock, so a WinPE-phase timestamp is
        # present, correctly formatted and WRONG - and because ts is written as
        # UTC a reader cannot tell it is unreliable. The CMTrace date field
        # inherits the same skew, so a leg can appear on the wrong day entirely.
        #
        # MEASURED ON A REAL LATITUDE: the WinPE leg stamped 20:53Z while the
        # machine's own wall clock read 12:53 local and real UTC was 09:53. Its
        # runId - built from local time - was run-20260829-125325 and correct.
        # WinPE's session time zone is not the deployment's, so GetUtcNow() was
        # eight hours out, and the FullOS leg's status.json two minutes later was
        # right to the second. Nothing in the log said which half to trust.
        #
        # THE ENGINE DOES NOT TRY TO FIX THE CLOCK. Setting time needs a source
        # that may not exist on an isolated deployment VLAN. Ordering comes from
        # seq; the timestamp is a hint, and now an explicitly labelled one.

        It 'marks a WinPE record as having an untrustworthy clock' {
            Write-HDTLog -Context $script:context -Message 'Applied index 1'

            $line = @($script:fs.ReadAllText($script:jsonlPath) -split "`n" | Where-Object { $_ })
            $record = ConvertFrom-Json -InputObject $line[0]

            [bool] $record.clockUnsynced | Should -BeTrue
        }

        It 'clears it once the full OS is running' {
            $fs = New-HDTFakeFileSystem
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc))
            $context = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
                -FileSystem $fs -Clock $clock -ThreadId 4820

            Write-HDTLog -Context $context -Message 'Applied index 1'

            $line = @($fs.ReadAllText([string] $context.JsonlPath) -split "`n" | Where-Object { $_ })
            $record = ConvertFrom-Json -InputObject $line[0]

            [bool] $record.clockUnsynced | Should -BeFalse
        }

        It 'says so on the CMTrace line a technician actually reads' {
            Write-HDTLog -Context $script:context -Message 'Applied index 1'

            $text = $script:fs.ReadAllText($script:masterPath)

            $text.Contains('Applied index 1 (clock unsynced)') |
                Should -BeTrue -Because 'the CMTrace reader shows the message, not the jsonl field'
        }

        It 'leaves the full OS line alone' {
            $fs = New-HDTFakeFileSystem
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc))
            $context = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
                -FileSystem $fs -Clock $clock -ThreadId 4820

            Write-HDTLog -Context $context -Message 'Applied index 1'

            $fs.ReadAllText([string] $context.MasterLogPath).Contains('clock unsynced') | Should -BeFalse
        }

        It 'keeps the jsonl message clean, so the suffix is the reader''s and not the record''s' {
            Write-HDTLog -Context $script:context -Message 'Applied index 1'

            $line = @($script:fs.ReadAllText($script:jsonlPath) -split "`n" | Where-Object { $_ })
            $record = ConvertFrom-Json -InputObject $line[0]

            [string] $record.message | Should -BeExactly 'Applied index 1'
        }
    }
}
