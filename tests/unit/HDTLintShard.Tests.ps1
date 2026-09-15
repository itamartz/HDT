# tests/helpers/HDTLintShard.ps1 - the worker of a sharded ./build.ps1 -Task
# lint run - exercised BY RUNNING IT, for the reason HDTTestShard.Tests.ps1
# gives at length: nothing in the suite had ever started either shard script,
# and the one defect that fact allowed through - a Split-Path one level short -
# killed every worker of every sharded run while 8631 tests stayed green.
#
# WHAT THIS PINS. Two things, and they pull in opposite directions:
#
#   IT MUST STILL REPORT WHAT IT FINDS. A lint worker that returns an empty
#   diagnostic set is indistinguishable from a clean repository, so a change
#   that quietly stopped it analysing would read as a green build. The bait
#   fixture in tests/fixtures/analyzer is deliberately dirty and is what
#   Invoke-HDTSelfCheck check 4 uses for the same reason.
#
#   IT MUST NOT KEEP EVERY FILE IT ANALYSED. `./build.ps1 -Task ci` died with
#   System.OutOfMemoryException on a host with no page file, where the commit
#   limit IS physical RAM. Each Invoke-ScriptAnalyzer builds an AST, runs every
#   rule over it and drops the lot, and without a collection in between a worker
#   climbed to ~250 MB and stayed there; with one it sits flat at ~178 MB. Eight
#   workers, so 8 x 72 MB of headroom handed back to the test shards running
#   beside them.
#
# WHY A COLLECTION IS RIGHT HERE AND WRONG IN THE TEST SHARD. Lint plateaus -
# the analyser really is done with the file - and the test worker did not: a
# forced [GC]::Collect() at 75 test files took 921 MB to 636 MB and no further,
# only 31% of it. That is why HDTTestShard.ps1 batches into fresh processes and
# this one does not need to.

# AT DISCOVERY, NOT IN BeforeAll. Pester evaluates every -Skip: while it is
# discovering the file, which is before any BeforeAll has run - so a flag set in
# one is $null when the skip is decided, `-not $null` is $true, and all five
# analyzer assertions skip on a machine that has the analyzer installed. They
# did, silently, and the file reported "Passed: 1, Skipped: 5" as green. The
# file body itself runs at discovery, so this is the one place the value exists
# in time; being in the script scope, the run-time blocks below see it too.
$script:analyzerAvailable = $null -ne (Get-Module -ListAvailable -Name PSScriptAnalyzer)

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:shardScript = Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTLintShard.ps1'
    $script:settingsPath = Join-Path -Path $script:repoRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'
    $script:baitFixture = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/analyzer/AnalyzerBait.ps1'

    # THE HOST THE BUILD USES, resolved off $PID exactly as Invoke-HDTShardedLint
    # resolves it: a 5.1 leg that shelled out to pwsh would prove nothing about
    # 5.1, which is the whole point of running both legs.
    $script:hostPath = (Get-Process -Id $PID).Path

    $script:lintRun = {
        param([string] $Root, [string[]] $SourceFile)

        $listPath = Join-Path -Path $Root -ChildPath 'list.txt'
        Set-Content -LiteralPath $listPath -Value $SourceFile -Encoding UTF8

        $diagnosticPath = Join-Path -Path $Root -ChildPath 'diagnostic.clixml'
        $errorPath = Join-Path -Path $Root -ChildPath 'err.log'
        $outputPath = Join-Path -Path $Root -ChildPath 'out.log'

        $argument = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $script:shardScript,
            '-ListPath', $listPath,
            '-DiagnosticPath', $diagnosticPath,
            '-SettingsPath', $script:settingsPath)

        $process = Start-Process -FilePath $script:hostPath -ArgumentList $argument -PassThru -Wait -WindowStyle Hidden `
            -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath

        # NOT [string] (Get-Content -Raw): on the 0-byte log a clean worker
        # leaves, -Raw emits nothing and the cast produces $null rather than '',
        # which Set-StrictMode -Version Latest then fails on at .Trim().
        $standardError = ''
        if (Test-Path -LiteralPath $errorPath -PathType Leaf) {
            $standardError = @(Get-Content -LiteralPath $errorPath) -join [Environment]::NewLine
        }

        return [pscustomobject] @{
            ExitCode       = [int] $process.ExitCode
            DiagnosticPath = $diagnosticPath
            StandardError  = $standardError
        }
    }
}

Describe 'HDTLintShard.ps1' {

    Context 'a worker given a file the analyzer objects to' {

        BeforeAll {
            # ASKED AGAIN HERE. Discovery and run are separate scopes in
            # Pester 5, so the $script:analyzerAvailable the -Skip: above reads
            # is not the one this block would see - it is $null here, the run
            # never happens, and four assertions then fail on a null path
            # instead of being skipped. Cheap enough to ask twice.
            $script:baitRun = $null
            if ($null -ne (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
                $script:baitRun = & $script:lintRun $TestDrive @($script:baitFixture)
            }
        }

        It 'exits cleanly' -Skip:(-not $script:analyzerAvailable) {
            $script:baitRun.ExitCode | Should -Be 0 -Because $script:baitRun.StandardError
        }

        It 'writes the diagnostic file the parent reads' -Skip:(-not $script:analyzerAvailable) {
            # WRITTEN LAST AND ALWAYS: its absence is how Invoke-HDTShardedLint
            # tells a dead worker from a clean one, and a lint that passed by
            # not looking is worse than one that failed.
            Test-Path -LiteralPath $script:baitRun.DiagnosticPath -PathType Leaf | Should -BeTrue
        }

        It 'still reports what it finds' -Skip:(-not $script:analyzerAvailable) {
            $diagnostic = @((Import-Clixml -LiteralPath $script:baitRun.DiagnosticPath).Diagnostic)

            $diagnostic.Count | Should -BeGreaterThan 0
            @($diagnostic | Where-Object { $_.RuleName -eq 'PSUseCompatibleSyntax' }).Count |
                Should -BeGreaterThan 0 -Because 'the 5.1 target in PSScriptAnalyzerSettings.psd1 has to be in force'
        }

        It 'flattens each record to the five fields the parent formats' -Skip:(-not $script:analyzerAvailable) {
            # A live DiagnosticRecord does not survive Export-Clixml intact.
            $first = @((Import-Clixml -LiteralPath $script:baitRun.DiagnosticPath).Diagnostic)[0]

            foreach ($property in @('Severity', 'RuleName', 'ScriptPath', 'Line', 'Message')) {
                $first.PSObject.Properties.Name | Should -Contain $property
            }
        }
    }

    Context 'a worker given a file the analyzer is happy with' {

        It 'reports a clean shard as an empty set, not as nothing at all' -Skip:(-not $script:analyzerAvailable) {
            $root = Join-Path -Path $TestDrive -ChildPath 'clean'
            $null = New-Item -Path $root -ItemType Directory -Force

            $clean = Join-Path -Path $root -ChildPath 'Get-HDTCleanProbe.ps1'
            Set-Content -LiteralPath $clean -Encoding UTF8 -Value @(
                'function Get-HDTCleanProbe {',
                '    [CmdletBinding()]',
                '    [OutputType([string])]',
                '    param()',
                '',
                "    return 'probe'",
                '}')

            $run = & $script:lintRun $root @($clean)

            $run.ExitCode | Should -Be 0 -Because $run.StandardError
            Test-Path -LiteralPath $run.DiagnosticPath -PathType Leaf | Should -BeTrue

            # Export-Clixml of a bare @() comes back as a single $null, which
            # reads as one diagnostic with no Severity - hence the wrapper.
            @((Import-Clixml -LiteralPath $run.DiagnosticPath).Diagnostic).Count | Should -Be 0
        }
    }

    Context 'what it holds on to while it works' {

        It 'releases each file''s analysis before it starts the next' {
            # ASSERTED ON THE SOURCE because the alternative is a memory
            # threshold, and a byte count measured on a shared lab host is a
            # flake generator rather than a test. What matters is that the
            # collection happens per file and inside the loop - once at the end
            # would give the peak back after the peak had already been paid.
            $text = Get-Content -LiteralPath $script:shardScript -Raw

            $parseError = $null
            $token = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref] $token, [ref] $parseError)

            @($parseError).Count | Should -Be 0

            # The ForEach-Object body that calls the analyzer, and nothing else.
            $analyzerBlock = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
                        $node.Extent.Text -match 'Invoke-ScriptAnalyzer'
                    }, $true) | Sort-Object -Property { $_.Extent.Text.Length })

            @($analyzerBlock).Count | Should -BeGreaterThan 0

            $innermost = $analyzerBlock[0].Extent.Text
            $innermost | Should -Match '\[GC\]::Collect\(\)'
            $innermost | Should -Match '\[GC\]::WaitForPendingFinalizers\(\)'
        }
    }
}
