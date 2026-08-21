# build.ps1 - the task runner, asserted BY PARSING IT rather than by running it.
#
# Running it here would be running a build inside a build. What matters is the
# shape of the dispatcher, and there is a real trap in it that a ValidateSet
# assertion alone walks straight past:
#
#   $canonicalOrder = @('clean','build','lint','test','selfcheck')
#   $ordered = @($canonicalOrder | Where-Object { $requested -contains $_ })
#
# A task accepted by the ValidateSet but absent from $canonicalOrder produces an
# EMPTY $ordered. The foreach then runs nothing, the script prints
# "BUILD SUCCEEDED ()" and exits 0. './build.ps1 -Task integration' would report
# success without having run a single integration test - and the verification
# step of the plan that added it would believe the report.
#
# So this file asserts three separate things, and the second is the one that
# matters: the names are accepted, the names are DISPATCHED, and an empty
# dispatch is a FAILURE.
#
# It also pins Invoke-HDTTest's Run.Path to tests/unit and tests/contract. The
# first person to add tests/integration to that list turns a two-second suite
# into a twenty-minute one that needs an elevated session and 25 GB of disk.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:buildPath = Join-Path -Path $script:repoRoot -ChildPath 'build.ps1'
    $script:buildText = Get-Content -LiteralPath $script:buildPath -Raw

    $script:parseError = $null
    $script:token = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:buildPath, [ref] $script:token, [ref] $script:parseError)

    # The -Task parameter's ValidateSet, read off the AST rather than matched
    # out of the text: a regex over the file would also match the -Verbosity set.
    $script:taskValue = @()
    $taskParameter = @($script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'Task' })

    if ($taskParameter.Count -eq 1) {
        $attribute = @($taskParameter[0].Attributes |
                Where-Object { $_.TypeName.FullName -like '*ValidateSet*' })

        if ($attribute.Count -eq 1) {
            $script:taskValue = @($attribute[0].PositionalArguments | ForEach-Object { $_.Value })
        }
    }

    # Every function the build script defines, by name and body.
    $script:functionAst = @($script:ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true))

    $script:functionBody = {
        param([string] $Name)

        $wanted = $Name
        $match = @($script:functionAst | Where-Object { $_.Name -eq $wanted })
        if ($match.Count -eq 0) {
            return ''
        }

        return [string] $match[0].Extent.Text
    }

    # The canonical order array literal, and the switch that dispatches it.
    $script:canonicalAssignment = @($script:ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$canonicalOrder'
            }, $true))

    $script:switchAst = @($script:ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.SwitchStatementAst]
            }, $true))

    $script:dispatchedName = @()
    foreach ($switch in $script:switchAst) {
        foreach ($clause in $switch.Clauses) {
            # A switch clause is a Tuple<ExpressionAst, StatementBlockAst>; Item1
            # is the label. There is no .Item on it.
            $script:dispatchedName += ([string] $clause.Item1.Extent.Text).Trim("'", '"')
        }
    }
}

Describe 'build.ps1' {

    It 'parses with no error' {
        @($script:parseError).Count | Should -Be 0 -Because (@($script:parseError | ForEach-Object { $_.Message }) -join "`n")
    }

    It 'passes the PowerShell 5.1 syntax scanner' {
        $violation = @(Get-HDTScriptCompatibilityViolation -Path $script:buildPath)

        $violation.Count | Should -Be 0 -Because (@($violation | ForEach-Object { $_.Reason }) -join "`n")
    }

    Context 'the tasks it accepts' {

        It 'accepts an integration task' {
            $script:taskValue | Should -Contain 'integration'
        }

        It 'accepts an e2e task' {
            $script:taskValue | Should -Contain 'e2e'
        }

        It 'still accepts the five canonical tasks and ci' {
            foreach ($name in @('clean', 'build', 'lint', 'test', 'selfcheck', 'ci')) {
                $script:taskValue | Should -Contain $name
            }
        }
    }

    Context 'what ci expands to' {

        It 'keeps ci as the five canonical tasks' {
            # DESIGN 12.2.5 puts integration on pushes to main and E2E nightly.
            # Neither belongs in the suite a developer runs before a commit, and
            # neither can run on a CI worker with no Hyper-V and no staged media.
            $script:canonicalAssignment.Count | Should -Be 1

            $literal = [string] $script:canonicalAssignment[0].Right.Extent.Text

            foreach ($name in @('clean', 'build', 'lint', 'test', 'selfcheck')) {
                $literal | Should -BeLike ("*'{0}'*" -f $name)
            }
        }

        It 'does not put integration or e2e in the canonical order' {
            $literal = [string] $script:canonicalAssignment[0].Right.Extent.Text

            $literal | Should -Not -BeLike '*integration*'
            $literal | Should -Not -BeLike '*e2e*'
        }
    }

    Context 'the dispatch' {

        It 'dispatches the integration task' {
            # Accepted by the ValidateSet is NOT the same as run. See the header.
            $script:dispatchedName | Should -Contain 'integration'
        }

        It 'dispatches the e2e task' {
            $script:dispatchedName | Should -Contain 'e2e'
        }

        It 'still dispatches the five canonical tasks' {
            foreach ($name in @('clean', 'build', 'lint', 'test', 'selfcheck')) {
                $script:dispatchedName | Should -Contain $name
            }
        }

        It 'fails when the requested task resolves to nothing' {
            # A build that ran no task is not a build that succeeded. Without
            # this guard the trap in the header is silent.
            $script:buildText | Should -Match '(?s)\$ordered\.Count\s+-eq\s+0.*throw'
        }
    }

    Context 'what each task runs' {

        It 'runs only tests/unit and tests/contract in the test task' {
            $body = & $script:functionBody 'Invoke-HDTTest'

            $body | Should -BeLike '*tests/unit*'
            $body | Should -BeLike '*tests/contract*'
            $body | Should -Not -BeLike '*tests/integration*'
            $body | Should -Not -BeLike '*tests/e2e*'
        }

        It 'runs tests/integration in the integration task' {
            $body = & $script:functionBody 'Invoke-HDTIntegrationTest'

            $body | Should -BeLike '*tests/integration*'
            $body | Should -Not -BeLike '*tests/unit*'
        }

        It 'runs tests/e2e in the e2e task' {
            $body = & $script:functionBody 'Invoke-HDTEndToEndTest'

            $body | Should -BeLike '*tests/e2e*'
            $body | Should -Not -BeLike '*tests/unit*'
        }
    }

    Context 'the reports' {

        # WHAT THE README SHOWS HAS TO COME FROM THE BUILD. A workflow that
        # computed its own numbers would be a second implementation of the test
        # run, and the one that rots is always the one nobody runs locally.

        It 'offers a Coverage switch' {
            $script:buildText | Should -Match '\[switch\]\s*\$Coverage'
        }

        It 'leaves coverage off unless it is asked for' {
            # It profiles every command the suite executes. A developer running
            # one file should not pay for a number nobody is going to read.
            $script:buildText | Should -Not -Match '\[switch\]\s*\$Coverage\s*=\s*\$true'

            $body = & $script:functionBody 'Invoke-HDTTest'
            $body | Should -Match '(?s)if\s*\(\$Coverage\)'
        }

        It 'measures the engine, not the tests that exercise it' {
            $body = & $script:functionBody 'Invoke-HDTTest'

            $body | Should -BeLike '*src/Hephaestus*'
            $body | Should -Not -BeLike '*CoveragePath*tests/unit*'
        }

        It 'writes the badges in one place' {
            @($script:functionAst | Where-Object { $_.Name -eq 'Write-HDTBuildBadge' }).Count |
                Should -Be 1
        }

        It 'writes them before it judges the run' {
            # A badge that only exists when the build is green is a badge that
            # always reads green. A red run writes its badges and they say so.
            $body = & $script:functionBody 'Invoke-HDTTest'

            $badgeAt = $body.IndexOf('Write-HDTBuildBadge')
            $judgeAt = $body.IndexOf('Assert-HDTPesterResult')

            $badgeAt | Should -BeGreaterThan 0
            $badgeAt | Should -BeLessThan $judgeAt
        }

        It 'counts a file that could not be discovered as a failure' {
            # Same trap as Assert-HDTPesterResult: no test failing is not the
            # same as every test passing, and the badge must not disagree with
            # the build about which it was.
            $body = & $script:functionBody 'Write-HDTBuildBadge'

            $body | Should -BeLike '*FailedContainersCount*'
        }
    }

    Context 'how it judges a Pester result' {

        # FOUND BY 05-06, THE HARD WAY, AND IT IS THE HEADER'S TRAP IN A NEW
        # COSTUME. A discovery-time failure - reading a variable in a `-Skip:`
        # that was never set, SPIKES S9.15's trap for the fourth time - makes
        # Pester DROP the tests it could not discover and report:
        #
        #     Result: Failed   FailedCount: 0   FailedContainersCount: 1
        #
        # FailedCount is zero because no test failed. No test failed because
        # three quarters of the file was never discovered. A build that judges a
        # run by FailedCount alone prints BUILD SUCCEEDED over a file whose
        # assertions never ran - which is exactly what it did, over
        # tests/integration/WinPeContent.Integration.Tests.ps1, before this test
        # was written.
        #
        # An empty dispatch is a failure (above); so is an empty discovery.

        It 'judges a run in one place' {
            # One shared judgement rather than the same condition copied into
            # three functions, for the same reason Test-HDTElevation is shared:
            # that is how one of the three ends up subtly different.
            @($script:functionAst | Where-Object { $_.Name -eq 'Assert-HDTPesterResult' }).Count |
                Should -Be 1
        }

        It 'judges it by more than FailedCount' {
            $body = & $script:functionBody 'Assert-HDTPesterResult'

            $body | Should -BeLike '*FailedCount*'
            $body | Should -BeLike '*FailedContainersCount*' -Because 'a container that failed to discover reports FailedCount 0, and a build that only reads FailedCount calls that success'
        }

        It 'says which file could not be discovered' {
            # A build that fails with "1 container failed" and no name sends the
            # operator to read three suites. The error Pester attaches to the
            # container is the only thing that says where.
            $body = & $script:functionBody 'Assert-HDTPesterResult'

            $body | Should -BeLike '*Containers*'
            $body | Should -BeLike '*ErrorRecord*'
        }

        It 'has all three suites judge their run through it' {
            foreach ($name in @('Invoke-HDTTest', 'Invoke-HDTIntegrationTest', 'Invoke-HDTEndToEndTest')) {
                $body = & $script:functionBody $name

                $body | Should -BeLike '*Assert-HDTPesterResult*' -Because "$name must not judge its own run"
            }
        }

        It 'leaves no suite judging itself by FailedCount alone' {
            # The assertion that keeps the previous one from being satisfied by
            # a call that sits BESIDE the old condition rather than replacing it.
            #
            # Scoped to the three runner functions. Invoke-HDTSelfCheck reads
            # FailedCount too and is right to: it is asserting that a
            # DELIBERATELY failing test was detected, which is a different
            # question from whether a suite ran.
            foreach ($name in @('Invoke-HDTTest', 'Invoke-HDTIntegrationTest', 'Invoke-HDTEndToEndTest')) {
                $body = & $script:functionBody $name

                $body | Should -Not -BeLike '*FailedCount -gt 0*' -Because "$name must not keep its own judgement beside the shared one"
            }
        }
    }

    Context 'the preconditions each new task names' {

        It 'asks the identity, not the environment' {
            # One shared check rather than the WindowsPrincipal incantation
            # copied into two functions, which is how one of them ends up
            # subtly different from the other.
            $body = & $script:functionBody 'Test-HDTElevation'

            $body | Should -BeLike '*WindowsBuiltInRole*'
            $body | Should -BeLike '*WindowsIdentity*'
        }

        It 'requires elevation for the integration task' {
            $body = & $script:functionBody 'Invoke-HDTIntegrationTest'

            $body | Should -BeLike '*Test-HDTElevation*'
            $body | Should -BeLike '*elevated*'
        }

        It 'warns rather than refusing when the staged media is absent' {
            # THE MEDIA IS A PRECONDITION OF SOME INTEGRATION FILES, NOT OF THE
            # TASK. 05-02 added tests/integration/SmbContentProvider.Integration.Tests.ps1,
            # which needs a folder and a share and no Windows image at all; a
            # hard throw here meant the whole task refused to start on a machine
            # with no staged media, and every file in it - including the ones
            # that skip themselves correctly - went unrun. Each slow file
            # recomputes its own skip condition (SPIKES S9.15), so the task
            # names what is missing and lets them.
            $body = & $script:functionBody 'Invoke-HDTIntegrationTest'

            $body | Should -BeLike '*install.wim*'
            $body | Should -Match '(?s)install\.wim[^}]*Write-Warning'
        }

        It 'still refuses the integration task without elevation' {
            $body = & $script:functionBody 'Invoke-HDTIntegrationTest'

            $body | Should -Match '(?s)Test-HDTElevation[^}]*throw'
        }

        It 'requires elevation for the e2e task' {
            $body = & $script:functionBody 'Invoke-HDTEndToEndTest'

            $body | Should -BeLike '*Test-HDTElevation*'
            $body | Should -BeLike '*elevated*'
        }

        It 'requires the Hyper-V module for the e2e task' {
            $body = & $script:functionBody 'Invoke-HDTEndToEndTest'

            $body | Should -BeLike '*Hyper-V*'
        }

        It 'names the boot image and the staged media for the e2e task' {
            # A test that fails obscurely inside Hyper-V because the ISO is not
            # there wastes an hour. Name the missing precondition in a sentence.
            $body = & $script:functionBody 'Invoke-HDTEndToEndTest'

            $body | Should -BeLike '*HDTPE_x64_uefi.iso*'
            $body | Should -BeLike '*install.wim*'
        }

        It 'accepts either the ADK or a prebuilt ISO for the e2e task' {
            # THIS PRECONDITION WAS FALSE UNTIL 05-04. It required SPIKES S1/S3's
            # HAND-BUILT ISO and said in its own error message that "building one
            # from code is M4's Update-HDTBootImage" - which now exists, and which
            # the e2e suite calls to build its own boot vehicle. A task that
            # refuses to start unless a hand-built artifact from a spike is
            # present would make the code that replaced it unrunnable.
            $body = & $script:functionBody 'Invoke-HDTEndToEndTest'

            $body | Should -BeLike '*Get-HDTAdkPath*'
            $body | Should -Not -BeLike '*Building one from code is M4*'
        }

        It 'names both routes when neither the ADK nor an ISO is present' {
            $body = & $script:functionBody 'Invoke-HDTEndToEndTest'

            # One sentence naming BOTH: install the ADK, or put a prebuilt ISO
            # where the suite can find it. An error that named only one would
            # send an operator down the wrong road half the time.
            $body | Should -Match '(?s)HDTPE_x64_uefi\.iso[^}]*throw'
            $body | Should -BeLike '*Update-HDTBootImage*'
            $body | Should -BeLike '*Windows ADK*'
        }

        It 'names the ADK as an integration precondition' {
            # tests/integration/BootImage.Integration.Tests.ps1 needs it and skips
            # itself without it, exactly as the media-dependent files do. The task
            # says what is missing and lets each file decide.
            $body = & $script:functionBody 'Invoke-HDTIntegrationTest'

            $body | Should -BeLike '*ADK*'
            $body | Should -Match '(?s)ADK[^}]*Write-Warning'
        }
    }

    Context 'what gets staged' {

        # THE PACKAGE SHIPS THE BUNDLE AND NOT THE SOURCES IT REPLACES. Both is
        # the same code twice - 2.6 MB of it - and leaves the loader deciding
        # between two copies on a timestamp comparison, on a machine where
        # neither copy will ever be edited.
        #
        # Update-HDTBootImage already staged it this way into WinPE. This is the
        # same decision for the Gallery.
        It 'drops the sources the bundle replaces' {
            $body = & $script:functionBody 'Invoke-HDTBuild'

            $body | Should -Match "'Private'"
            $body | Should -Match "'Public'"
            $body | Should -Match 'Remove-Item'
        }

        # AND IT REFUSES RATHER THAN SHIPPING A MODULE THAT CANNOT LOAD. Removing
        # the sources is only safe because the bundle is there; a stage with
        # neither is a package that imports nothing, and the Gallery keeps it for
        # ever.
        It 'refuses to trim a stage that has no bundle in it' {
            $body = & $script:functionBody 'Invoke-HDTBuild'

            $body | Should -Match 'Hephaestus\.bundle\.ps1'
            $body | Should -Match '(?s)bundle[^}]*throw'
        }
    }

    Context 'naming' {

        It 'names every build function Verb-HDTNoun' {
            # The naming contract already covers this file; this asserts the two
            # new functions specifically, so a rename cannot quietly land.
            $name = @($script:functionAst | ForEach-Object { $_.Name })

            $name | Should -Contain 'Invoke-HDTIntegrationTest'
            $name | Should -Contain 'Invoke-HDTEndToEndTest'

            @(Get-HDTFunctionNameViolation -Name $name).Count | Should -Be 0
        }
    }
}
