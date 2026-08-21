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
        param([string] $Root, [string[]] $TestFile)

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
}
