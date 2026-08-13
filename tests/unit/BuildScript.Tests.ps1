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
