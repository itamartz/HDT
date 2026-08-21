# ROADMAP M0 asks for the harness to prove itself: a deliberately failing test
# must fail, a passing one must pass, and analyzer violations must be detected.
# A suite nobody has watched go red is not a suite.
#
# The failure fixtures live in tests/selfcheck/, which build.ps1 -Task test never
# puts in Run.Path. They are executed here in a CHILD PROCESS so their failure is
# observed without becoming this suite's failure, and so the real exit-code path
# CI depends on is the thing under test.

# -Skip: is evaluated during discovery, so the analyzer probe has to run at
# discovery time - a BeforeAll would be too late. Pester 5 discards
# discovery-phase variables, hence the repeated setup in BeforeAll.
$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
$script:HDTAnalyzerMissing = -not (Test-HDTModuleAvailable -Name PSScriptAnalyzer)

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:buildScript = Join-Path -Path $script:repoRoot -ChildPath 'build.ps1'
    $script:selfCheckRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/selfcheck'
    $script:failureFixture = Join-Path -Path $script:selfCheckRoot -ChildPath 'DeliberateFailure.Tests.ps1'
    $script:passFixture = Join-Path -Path $script:selfCheckRoot -ChildPath 'DeliberatePass.Tests.ps1'
    $script:analyzerBait = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/analyzer/AnalyzerBait.ps1'
    $script:analyzerSettings = Join-Path -Path $script:repoRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'

    # The child process must be the same PowerShell edition this test is running
    # under, otherwise the 5.1 leg silently proves nothing about 5.1.
    $script:hostPath = (Get-Process -Id $PID).Path

    # Runs one fixture in a child process with Run.Exit enabled and returns the
    # process exit code. This is Pester's own exit path, not a re-implementation
    # of it.
    $script:invokeFixtureExitCode = {
        param($HostPath, $FixturePath)

        $command = "Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Force; " +
        "`$c = New-PesterConfiguration; " +
        "`$c.Run.Path = '$FixturePath'; " +
        "`$c.Run.Exit = `$true; " +
        "`$c.Output.Verbosity = 'None'; " +
        "Invoke-Pester -Configuration `$c"

        & $HostPath -NoProfile -Command $command 2>&1 | Out-Null
        return $LASTEXITCODE
    }

    # Runs one fixture in a child process without Run.Exit and returns the
    # passed/failed counts through a marker line.
    $script:invokeFixtureCount = {
        param($HostPath, $FixturePath)

        $command = "Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Force; " +
        "`$c = New-PesterConfiguration; " +
        "`$c.Run.Path = '$FixturePath'; " +
        "`$c.Run.PassThru = `$true; " +
        "`$c.Output.Verbosity = 'None'; " +
        "`$r = Invoke-Pester -Configuration `$c; " +
        "'HDTCOUNT passed={0} failed={1}' -f `$r.PassedCount, `$r.FailedCount"

        $output = & $HostPath -NoProfile -Command $command 2>&1
        return @($output | Where-Object { $_ -is [string] -and $_ -like 'HDTCOUNT*' })[0]
    }

    $script:failureExitCode = $null
    $script:failureCounts = $null
    $script:passExitCode = $null

    if (Test-Path -Path $script:failureFixture -PathType Leaf) {
        $script:failureExitCode = & $script:invokeFixtureExitCode $script:hostPath $script:failureFixture
        $script:failureCounts = & $script:invokeFixtureCount $script:hostPath $script:failureFixture
    }

    if (Test-Path -Path $script:passFixture -PathType Leaf) {
        $script:passExitCode = & $script:invokeFixtureExitCode $script:hostPath $script:passFixture
    }

    $script:buildAst = $null
    if (Test-Path -Path $script:buildScript -PathType Leaf) {
        $tokens = $null
        $parseErrors = $null
        $script:buildAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:buildScript, [ref] $tokens, [ref] $parseErrors)
    }

    $script:analyzerAvailable = Test-HDTModuleAvailable -Name PSScriptAnalyzer
}

Describe 'Harness self-proof (ROADMAP M0)' {

    Context 'The self-check fixtures exist' {

        It 'ships a deliberately failing test fixture' {
            Test-Path -Path $script:failureFixture -PathType Leaf | Should -BeTrue
        }

        It 'ships a deliberately passing test fixture' {
            Test-Path -Path $script:passFixture -PathType Leaf | Should -BeTrue
        }

        It 'ships an analyzer bait fixture' {
            Test-Path -Path $script:analyzerBait -PathType Leaf | Should -BeTrue
        }
    }

    Context 'A failing test fails' {

        It 'exits non-zero when the deliberate failure fixture runs' {
            $script:failureExitCode | Should -Not -BeNullOrEmpty -Because 'the fixture must exist and have been run'
            $script:failureExitCode | Should -Not -Be 0
        }

        It 'exits with the failed test count, which is one' {
            # Pester with Run.Exit uses the failed count as the exit code. One
            # failing It therefore means exit code 1, not merely "non-zero".
            $script:failureExitCode | Should -Be 1
        }

        It 'reports exactly one failed and zero passed tests for the failure fixture' {
            $script:failureCounts | Should -Be 'HDTCOUNT passed=0 failed=1'
        }
    }

    Context 'A passing test passes' {

        It 'exits zero when the deliberate pass fixture runs' {
            $script:passExitCode | Should -Not -BeNullOrEmpty -Because 'the fixture must exist and have been run'
            $script:passExitCode | Should -Be 0
        }
    }

    Context 'Analyzer violations are detected' {

        It 'produces at least one analyzer diagnostic for the bait fixture' -Skip:$script:HDTAnalyzerMissing {
            Test-Path -Path $script:analyzerBait -PathType Leaf | Should -BeTrue
            $diagnostic = @(Invoke-ScriptAnalyzer -Path $script:analyzerBait -Settings $script:analyzerSettings)
            $diagnostic.Count | Should -BeGreaterThan 0
        }

        It 'produces a PSUseCompatibleSyntax error for the bait fixture' -Skip:$script:HDTAnalyzerMissing {
            # Proves the 5.1 target version in PSScriptAnalyzerSettings.psd1 is
            # actually in force, not just declared.
            Test-Path -Path $script:analyzerBait -PathType Leaf | Should -BeTrue
            $diagnostic = @(Invoke-ScriptAnalyzer -Path $script:analyzerBait -Settings $script:analyzerSettings)
            @($diagnostic | Where-Object { $_.RuleName -eq 'PSUseCompatibleSyntax' }).Count | Should -BeGreaterThan 0
        }

        It 'covers the self-check fixtures with the analyzer and finds them clean' {
            # tests/selfcheck is outside Run.Path but NOT outside the source set:
            # the naming, compatibility and analyzer rules still apply to it.
            $sourceFile = @(Get-HDTSourceFile -RepositoryRoot $script:repoRoot)
            $sourceFile | Should -Contain $script:failureFixture
            $sourceFile | Should -Contain $script:passFixture
        }

        # THE CLEAN-SOURCES SWEEP IS NOT HERE. It used to be: an It that looped
        # Invoke-ScriptAnalyzer over all 730 files of Get-HDTSourceFile and
        # asserted no diagnostics. That is ./build.ps1 -Task lint, character for
        # character - same source set, same settings file, same failure - and
        # 'ci' runs lint anyway, before this suite, so the sweep only ever ran
        # second on an already-proven tree.
        #
        # IT COST 78 SECONDS AND IT SET THE FLOOR ON THE WHOLE SUITE. That one
        # It made this the slowest file in tests/ at 121s, which is a quarter of
        # a 500s run, and it capped test sharding: no number of parallel workers
        # can finish sooner than the longest single file.
        #
        # WHAT M0 ACTUALLY ASKS FOR IS STILL PROVEN, by the two bait-fixture Its
        # above - a deliberately dirty file produces diagnostics, including
        # PSUseCompatibleSyntax. That is the claim "analyzer violations are
        # detected". Whether the repository happens to be clean today is lint's
        # question, and lint fails the build on it.
        It 'excludes the analyzer bait from the source set, so it never turns the suite red' {
            # The bait contains ?? and cannot be parsed by 5.1 at all.
            @(Get-HDTSourceFile -RepositoryRoot $script:repoRoot) | Should -Not -Contain $script:analyzerBait
        }
    }

    Context 'build.ps1 wires the self-check in' {

        It 'exposes a selfcheck task' {
            $script:buildAst | Should -Not -BeNullOrEmpty

            $parameter = $script:buildAst.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'Task' }
            $parameter | Should -Not -BeNullOrEmpty

            $validateSet = @($parameter.Attributes |
                    Where-Object { $_.TypeName.FullName -match 'ValidateSet' })
            $validateSet.Count | Should -BeGreaterThan 0

            $allowed = @($validateSet[0].PositionalArguments | ForEach-Object { $_.Value })
            $allowed | Should -Contain 'selfcheck'
        }

        It 'includes selfcheck in the ci task chain' {
            $assignment = @($script:buildAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $node.Left.VariablePath.UserPath -eq 'canonicalOrder'
                    }, $true))

            $assignment.Count | Should -BeGreaterThan 0

            $element = @($assignment[0].Right.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
                    }, $true) | ForEach-Object { $_.Value })

            $element | Should -Contain 'selfcheck'
        }

        It 'excludes tests/selfcheck from the normal test run' {
            $testFunction = @($script:buildAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -eq 'Invoke-HDTTest'
                    }, $true))

            $testFunction.Count | Should -Be 1

            $literal = @($testFunction[0].FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
                    }, $true) | ForEach-Object { $_.Value })

            $literal | Should -Contain 'tests/unit'
            $literal | Should -Contain 'tests/contract'
            @($literal | Where-Object { $_ -like '*selfcheck*' }).Count | Should -Be 0
        }

        It 'defines Invoke-HDTSelfCheck' {
            $selfCheckFunction = @($script:buildAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -eq 'Invoke-HDTSelfCheck'
                    }, $true))

            $selfCheckFunction.Count | Should -Be 1
        }

        It 'exits zero when build.ps1 -Task selfcheck runs' {
            & $script:hostPath -NoProfile -File $script:buildScript -Task selfcheck 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
    }
}
