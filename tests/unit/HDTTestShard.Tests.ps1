# tests/helpers/HDTTestShard.ps1 - the worker of a sharded ./build.ps1 -Task
# test run - exercised BY RUNNING IT.
#
# WHY IT IS RUN AND NOT PARSED. The suite had 8631 passing tests and not one of
# them started the shard script, so this defect shipped:
#
#     $engineManifest = Join-Path -Path (Split-Path -Parent $PSScriptRoot) `
#         -ChildPath 'src/Hephaestus/Hephaestus.psd1'
#
# $PSScriptRoot is tests\helpers, so ONE Split-Path gives tests\ and the
# manifest resolved to tests\src\Hephaestus\Hephaestus.psd1, which has never
# existed. Every worker died on Import-Module before Invoke-Pester, wrote no
# summary and no durations, and every sharded run of the suite failed. The idiom
# is right everywhere else in tests/ - it was copied from a file one directory
# deeper without adding the second Split-Path.
#
# A parse-level assertion cannot catch that: the line is syntactically perfect.
# Only running it catches it, so this spends one child process on doing exactly
# that, on a probe test file of its own making, and asserts the three artefacts
# the parent reads back.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:shardScript = Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestShard.ps1'

    # THE 5.1 HOST, NOT WHATEVER IS RUNNING THIS. The engine is a Windows
    # PowerShell module and build.ps1 starts its workers with (Get-Process -Id
    # $PID).Path, so the worker must work under the host the build uses.
    $script:hostPath = (Get-Process -Id $PID).Path

    $script:shardRun = {
        param([string] $Root, [string[]] $TestFile, [int] $BatchSize = -1)

        $listPath = Join-Path -Path $Root -ChildPath 'list.txt'
        Set-Content -LiteralPath $listPath -Value $TestFile -Encoding UTF8

        $summaryPath = Join-Path -Path $Root -ChildPath 'summary.clixml'
        $durationPath = Join-Path -Path $Root -ChildPath 'duration.csv'
        $resultPath = Join-Path -Path $Root -ChildPath 'result.xml'
        $errorPath = Join-Path -Path $Root -ChildPath 'err.log'
        $outputPath = Join-Path -Path $Root -ChildPath 'out.log'

        $argument = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $script:shardScript,
            '-ListPath', $listPath,
            '-SummaryPath', $summaryPath,
            '-DurationPath', $durationPath,
            '-ResultPath', $resultPath,
            '-Verbosity', 'None')

        # -1 MEANS "SAY NOTHING", so the default the real build gets is the one
        # under test. Every other value is passed through.
        if ($BatchSize -ge 0) {
            $argument += @('-BatchSize', [string] $BatchSize)
        }

        $process = Start-Process -FilePath $script:hostPath -ArgumentList $argument -PassThru -Wait -WindowStyle Hidden `
            -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath

        # NOT [string] (Get-Content -Raw): on a 0-byte log - which is what a
        # worker that succeeded leaves - Get-Content -Raw emits nothing at all
        # and the cast is applied to an empty pipeline, so the result is $null
        # rather than ''. Under Set-StrictMode -Version Latest the .Trim() below
        # then fails instead of the assertion passing.
        $standardError = ''
        if (Test-Path -LiteralPath $errorPath -PathType Leaf) {
            $standardError = @(Get-Content -LiteralPath $errorPath) -join [Environment]::NewLine
        }

        return [pscustomobject] @{
            ExitCode      = [int] $process.ExitCode
            SummaryPath   = $summaryPath
            DurationPath  = $durationPath
            ResultPath    = $resultPath
            StandardError = $standardError
        }
    }

    # A PROBE SUITE WHOSE COUNTS ARE ALL DIFFERENT. Batching is only proved by
    # the numbers ADDING UP, and files that each pass one test add up to the
    # file count whether the batches were merged or the last one simply won.
    $script:writeProbe = {
        param([string] $Root, [int] $Index, [int] $Passing, [int] $Skipped)

        $probePath = Join-Path -Path $Root -ChildPath ('HDTShardBatchProbe{0:D2}.Tests.ps1' -f $Index)
        $line = @(("Describe 'HDTShardBatchProbe{0:D2}' {{" -f $Index))
        for ($i = 1; $i -le $Passing; $i++) {
            $line += ("    It 'passes {0}' {{ 1 | Should -Be 1 }}" -f $i)
        }
        for ($i = 1; $i -le $Skipped; $i++) {
            $line += ("    It 'is skipped {0}' -Skip {{ 1 | Should -Be 2 }}" -f $i)
        }
        $line += '}'

        Set-Content -LiteralPath $probePath -Value $line -Encoding UTF8
        return $probePath
    }
}

Describe 'HDTTestShard.ps1' {

    Context 'a worker given a test file that passes' {

        BeforeAll {
            # A probe suite of this test's own making, so the assertion below is
            # about the worker and not about whatever the real suite is doing.
            $script:probeFile = Join-Path -Path $TestDrive -ChildPath 'HDTShardProbe.Tests.ps1'
            Set-Content -LiteralPath $script:probeFile -Encoding UTF8 -Value @(
                "Describe 'HDTShardProbe' {",
                "    It 'passes' { 1 | Should -Be 1 }",
                "    It 'is skipped' -Skip { 1 | Should -Be 2 }",
                '}')

            $script:run = & $script:shardRun $TestDrive @($script:probeFile)
        }

        It 'exits cleanly' {
            $script:run.ExitCode | Should -Be 0 -Because $script:run.StandardError
        }

        It 'writes nothing to standard error' {
            # The whole failure this file exists for was an Import-Module error
            # on stderr that nothing read.
            $script:run.StandardError.Trim() | Should -BeNullOrEmpty
        }

        It 'writes the summary the parent merges' {
            # LAST BY DESIGN: its absence is how build.ps1 detects a dead worker,
            # which is why a worker that dies early must never leave one behind.
            Test-Path -LiteralPath $script:run.SummaryPath -PathType Leaf | Should -BeTrue

            $summary = Import-Clixml -LiteralPath $script:run.SummaryPath
            $summary.PassedCount | Should -Be 1
            $summary.FailedCount | Should -Be 0
            $summary.SkippedCount | Should -Be 1
            $summary.FailedContainersCount | Should -Be 0
        }

        It 'writes the per-file seconds the next run packs with' {
            Test-Path -LiteralPath $script:run.DurationPath -PathType Leaf | Should -BeTrue

            $row = @(Import-Csv -LiteralPath $script:run.DurationPath)
            @($row).Count | Should -Be 1
            $row[0].Path | Should -BeLike '*HDTShardProbe.Tests.ps1'
            [double] $row[0].Seconds | Should -BeGreaterThan 0
        }

        It 'writes the NUnit result for its own shard' {
            Test-Path -LiteralPath $script:run.ResultPath -PathType Leaf | Should -BeTrue
        }
    }

    Context 'a worker that cannot load the engine' {

        It 'resolves the engine manifest to a file that exists' {
            # The regression itself, asserted directly and cheaply: evaluate the
            # script's own $engineManifest expression with $PSScriptRoot bound to
            # where the script actually lives. Copying the expression into the
            # test would be circular; reading it out of the file is not.
            $text = Get-Content -LiteralPath $script:shardScript -Raw
            $parseError = $null
            $token = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref] $token, [ref] $parseError)

            # Every assignment that feeds the manifest, in source order, so a
            # path built in two steps evaluates as it does in the script.
            $assignment = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left.Extent.Text -in @('$repositoryRoot', '$engineManifest')
                    }, $true) | Sort-Object -Property { $_.Extent.StartOffset })

            @($assignment).Count | Should -BeGreaterThan 0
            @($assignment | Where-Object { $_.Left.Extent.Text -eq '$engineManifest' }).Count | Should -Be 1

            # $PSScriptRoot as a parameter, so the expression sees the directory
            # the script lives in rather than this test file's.
            $source = @('param($PSScriptRoot)') +
            @($assignment | ForEach-Object { $_.Extent.Text }) +
            @('$engineManifest')

            $expression = [scriptblock]::Create(($source -join [Environment]::NewLine))
            $resolved = & $expression (Split-Path -Parent $script:shardScript)

            Test-Path -LiteralPath ([string] $resolved) -PathType Leaf |
                Should -BeTrue -Because ("HDTTestShard.ps1 imports '{0}', and every worker dies on Import-Module if that is not the manifest." -f $resolved)
        }
    }
    # ONE PROCESS PER BATCH, BECAUSE THE MEMORY DOES NOT COME BACK.
    #
    # A worker process retained about 10 MB per test file, linearly and with no
    # plateau: 282 MB after 10 files, 349 MB after 25, 739 MB after 50, 921 MB
    # after 75. Measured on the real suite, 68 files - 541 across 8 workers -
    # peaked at 876 MB, so eight of them cost about 7 GB at once. This host has
    # no page file, so the commit limit IS physical RAM and './build.ps1 -Task
    # ci' died with System.OutOfMemoryException while physical RAM still looked
    # free.
    #
    # A FORCED [GC]::Collect() RECLAIMED ONLY 31% of it - 921 MB went to 636 MB
    # - so collecting between batches is not enough. Only a process that exits
    # gives the whole of it back, which is why the worker now runs its list in
    # fresh grandchildren rather than calling the collector. The same 68-file
    # shard, batched five at a time, peaks at 570 MB.
    #
    # THESE ASSERT THE TWO THINGS BATCHING COULD BREAK: that the counts of every
    # batch add up in the one summary the parent reads, and that a batch which
    # dies still fails the shard instead of being quietly left out of the sum.
    Context 'a worker given more files than fit in one batch' {

        BeforeAll {
            # DIFFERENT COUNTS PER FILE, on purpose. Five files of one test each
            # total five whether the batches were added up or the last one
            # simply overwrote the others; 1+2+3+4+5 only totals 15 if they were.
            $script:batchProbe = @(
                (& $script:writeProbe $TestDrive 1 1 1),
                (& $script:writeProbe $TestDrive 2 2 0),
                (& $script:writeProbe $TestDrive 3 3 1),
                (& $script:writeProbe $TestDrive 4 4 0),
                (& $script:writeProbe $TestDrive 5 5 1))

            $script:batchRun = & $script:shardRun $TestDrive $script:batchProbe 2
        }

        It 'exits cleanly' {
            $script:batchRun.ExitCode | Should -Be 0 -Because $script:batchRun.StandardError
        }

        It 'writes nothing to standard error' {
            $script:batchRun.StandardError.Trim() | Should -BeNullOrEmpty
        }

        It 'adds every batch up into the one summary the parent reads' {
            Test-Path -LiteralPath $script:batchRun.SummaryPath -PathType Leaf | Should -BeTrue

            $summary = Import-Clixml -LiteralPath $script:batchRun.SummaryPath
            $summary.PassedCount | Should -Be 15
            $summary.SkippedCount | Should -Be 3
            $summary.FailedCount | Should -Be 0
            $summary.FailedContainersCount | Should -Be 0
        }

        It 'reports the seconds of every file, not just the last batch' {
            $row = @(Import-Csv -LiteralPath $script:batchRun.DurationPath)
            $row.Count | Should -Be 5

            # Keyed by full path, which is what Split-HDTTestBucket is handed.
            @($row | ForEach-Object { $_.Path } | Sort-Object) |
                Should -Be @($script:batchProbe | Sort-Object)
        }

        It 'writes one NUnit document per batch, all named off the shard' {
            # The parent hands one -ResultPath per shard and both CI workflows
            # collect out/testResults/*.xml as a glob, so several siblings are
            # fine - but they have to be siblings, and every batch has to leave
            # one or its tests are absent from the artefact.
            $stem = [IO.Path]::GetFileNameWithoutExtension($script:batchRun.ResultPath)
            $written = @(Get-ChildItem -Path (Split-Path -Parent $script:batchRun.ResultPath) `
                    -Filter ('{0}-batch*.xml' -f $stem) -File)

            $written.Count | Should -Be 3
            @($written | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @(
                ('{0}-batch1of3.xml' -f $stem),
                ('{0}-batch2of3.xml' -f $stem),
                ('{0}-batch3of3.xml' -f $stem))
        }

        It 'runs every file exactly once across the batches' {
            # The whole point of the exercise is to spend LESS memory on the
            # same tests. A batching bug that drops a file spends less memory
            # too, and looks identical in every number but this one.
            $total = 0
            foreach ($probe in $script:batchProbe) {
                $total += @(Select-String -LiteralPath $probe -Pattern "^\s+It " -AllMatches).Count
            }

            $summary = Import-Clixml -LiteralPath $script:batchRun.SummaryPath
            ($summary.PassedCount + $summary.FailedCount + $summary.SkippedCount) | Should -Be $total
        }
    }

    Context 'a batch whose process dies' {

        BeforeAll {
            # WHAT AN OUT-OF-MEMORY KILL LOOKS LIKE: the process is gone before
            # it writes anything. Kill() rather than a throw, because a throw is
            # caught by Pester and reported as a failed test - which is the case
            # that already worked.
            $script:killer = Join-Path -Path $TestDrive -ChildPath 'HDTShardKiller.Tests.ps1'
            Set-Content -LiteralPath $script:killer -Encoding UTF8 -Value @(
                "Describe 'HDTShardKiller' {",
                "    It 'dies the way an out-of-memory worker does' {",
                '        [System.Diagnostics.Process]::GetCurrentProcess().Kill()',
                '    }',
                '}')

            $script:deadProbe = @(
                (& $script:writeProbe $TestDrive 6 1 0),
                (& $script:writeProbe $TestDrive 7 1 0),
                $script:killer,
                (& $script:writeProbe $TestDrive 8 1 0))

            $script:deadRun = & $script:shardRun $TestDrive $script:deadProbe 2
        }

        It 'leaves no summary behind, which is how the parent detects it' {
            # Merge-HDTPesterSummary turns a missing summary into a thrown
            # failure. A batch that vanished must not be able to produce a
            # shard summary holding only the batches that survived - that is a
            # green build over a suite that partly did not run.
            Test-Path -LiteralPath $script:deadRun.SummaryPath -PathType Leaf | Should -BeFalse
        }

        It 'exits non-zero' {
            $script:deadRun.ExitCode | Should -Not -Be 0
        }

        It 'says which batch died, and what it was given' {
            $script:deadRun.StandardError | Should -Match 'batch 2 of 2'
            $script:deadRun.StandardError | Should -Match 'file'
        }
    }

    Context 'the batch size the real build gets' {

        It 'batches by default, without the parent having to ask' {
            # build.ps1 passes no -BatchSize, so a default of 0 would leave the
            # memory ceiling exactly where it was and every assertion above
            # would still pass.
            $text = Get-Content -LiteralPath $script:shardScript -Raw
            $parseError = $null
            $token = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref] $token, [ref] $parseError)

            $parameter = @($ast.ParamBlock.Parameters |
                    Where-Object { $_.Name.VariablePath.UserPath -eq 'BatchSize' })

            $parameter.Count | Should -Be 1
            $parameter[0].DefaultValue | Should -Not -BeNullOrEmpty
            [int] $parameter[0].DefaultValue.Extent.Text | Should -BeGreaterThan 0
        }

        It 'runs in this process when it is told not to batch' {
            # The grandchildren are started with -BatchSize 0, so this is what
            # stops the recursion. A non-terminating one forks until the machine
            # gives up - which is the failure mode this whole change exists to
            # avoid.
            $probe = & $script:writeProbe $TestDrive 9 2 0
            $root = Join-Path -Path $TestDrive -ChildPath 'noBatch'
            $null = New-Item -Path $root -ItemType Directory -Force

            $run = & $script:shardRun $root @($probe) 0

            $run.ExitCode | Should -Be 0 -Because $run.StandardError
            (Import-Clixml -LiteralPath $run.SummaryPath).PassedCount | Should -Be 2

            @(Get-ChildItem -Path $root -Filter '*-batch*.xml' -File).Count | Should -Be 0
        }
    }
}
