# HDTDeploymentMethod, PUBLISHED WHERE THE PROVIDER IS ALREADY KNOWN.
#
# bootstrap.Provider is baked into the boot image by Update-HDTBootImage and is
# read in Start-HDTDeployment.ps1 in section 7, where Resolve-HDTDeployRoot is
# already handed it. Deriving the method from THAT value, on that line, is what
# makes "the engine and a step condition gate on one answer" true rather than a
# hope: two places deciding UNC vs MEDIA is two answers that can disagree, and
# the ROADMAP settled against it.
#
# THREE READERS AT THREE DIFFERENT TIMES, WHICH IS WHY THE ORDER IS THE DESIGN:
#
#   the connect loop           needs a plain local - Resolve-HDTVariable has
#                              not run yet
#   Get-HDTLogDestination      needs it in $resolved.Variable
#   the engine bag / steps     needs it in $variable, which is what
#                              Invoke-HDTTaskSequence checkpoints into
#                              state.json and Start-HDTResume.ps1 puts back
#
# So the assertions here are about ORDER, and they are written against the
# payload's AST for the reason EarlyLogDestination.Tests.ps1 gives: running the
# entry point for real means a booted machine to power off.
#
# AND A SECOND Describe THAT RUNS THE REAL COMMANDS rather than reading them,
# because a text scan is exactly what let the last payload defect ship (see
# WelcomeRetryCredential.Tests.ps1's header).

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:payloadPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload/Start-HDTDeployment.ps1'

    $script:parseError = $null
    $script:token = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:payloadPath, [ref] $script:token, [ref] $script:parseError)

    $script:commandNamed = {
        param([string] $Name)

        $wanted = $Name

        return @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq $wanted
                }, $true) | Sort-Object { $_.Extent.StartOffset })
    }

    # THE FIRST OFFSET OF A COMMAND, the way EarlyLogDestination.Tests.ps1
    # measures order. A command that is never called answers -1 rather than
    # throwing, so a failure reads as "it is not there" and not as an index
    # error in the test.
    $script:firstOffsetOf = {
        param([string] $Name)

        $found = @(& $script:commandNamed $Name)
        if ($found.Count -eq 0) { return -1 }

        return [int] $found[0].Extent.StartOffset
    }

    # THE CONNECT LOOP, FOUND BY WHAT IT DOES rather than by where it sits -
    # the same handle WelcomeRetryCredential.Tests.ps1 lifts it by.
    $script:connectLoop = $null
    $loop = @($script:ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.WhileStatementAst]
            }, $true) | Where-Object { $_.Extent.Text -match "providerArgument\['Root'\]" })

    if ($loop.Count -eq 1) { $script:connectLoop = $loop[0] }

    # EVERY ASSIGNMENT TO AN INDEXED BAG, keyed by the text of its left side, so
    # "$result['deploymentMethod'] is written" is one lookup.
    $script:assignmentTo = {
        param([string] $Left)

        $wanted = $Left

        return @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    ([string] $node.Left.Extent.Text) -eq $wanted
                }, $true) | Sort-Object { $_.Extent.StartOffset })
    }
}

Describe 'HDTDeploymentMethod, published where the provider is already known' {

    It 'parses with no error' {
        @($script:parseError).Count | Should -Be 0 -Because (@($script:parseError | ForEach-Object { $_.Message }) -join "`n")
    }

    Context 'the order, which is the whole design' {

        It 'is derived by Get-HDTDeploymentMethod, and nowhere else in the payload' {
            @(& $script:commandNamed 'Get-HDTDeploymentMethod').Count | Should -Be 1
        }

        It 'is derived before the connect loop, which reads it' {
            $script:connectLoop | Should -Not -BeNullOrEmpty

            $derived = & $script:firstOffsetOf 'Get-HDTDeploymentMethod'
            $derived | Should -BeGreaterThan -1
            $derived | Should -BeLessThan ([int] $script:connectLoop.Extent.StartOffset)
        }

        It 'is derived before Get-HDTLogDestination, which reads it' {
            # Behaviour 3 (plan 03) reads the method out of $resolved.Variable
            # to decide where a media run's logs can go at all. It is a
            # different reader at a different time and the one derivation has to
            # come before both.
            $derived = & $script:firstOffsetOf 'Get-HDTDeploymentMethod'
            $logDestination = & $script:firstOffsetOf 'Get-HDTLogDestination'

            $logDestination | Should -BeGreaterThan -1
            $derived | Should -BeLessThan $logDestination
        }

        It 'is derived from bootstrap.Provider, the same value Resolve-HDTDeployRoot is given' {
            $call = @(& $script:commandNamed 'Get-HDTDeploymentMethod')[0]

            [string] $call.Extent.Text | Should -Match 'bootstrap\.Provider'
        }

        It 'never compares a provider name to a literal outside Get-HDTDeploymentMethod' {
            # SCOPED TO 'Local' AND 'MEDIA' ON PURPOSE. The payload legitimately
            # compares Provider -eq 'Smb' in section 8, for the CREDENTIAL - a
            # credential is an SMB concept and asking for one is not a method
            # decision. What must not exist is a SECOND place that decides UNC
            # vs MEDIA, because that is the answer that can disagree with
            # itself.
            $offender = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.BinaryExpressionAst]
                    }, $true) |
                    Where-Object {
                        ([string] $_.Left.Extent.Text) -match "^'(Local|MEDIA)'$" -or
                        ([string] $_.Right.Extent.Text) -match "^'(Local|MEDIA)'$"
                    })

            @($offender | ForEach-Object { $_.Extent.Text }) | Should -Be @()
        }
    }

    Context 'the three bags it reaches' {

        It 'is published into the resolved variables, so Get-HDTLogDestination sees it' {
            # THROUGH THE $resolveArgument HASHTABLE AND NOT AFTER THE CALL, and
            # that is the point rather than a style. Start-HDTWizardDeployment
            # re-runs the resolver with this SAME hashtable to apply the
            # technician's answers, and ITS result is the bag the engine deploys
            # with. A publication made after the first resolution would survive
            # on a share with no wizard and vanish on one with a wizard.
            $written = @(& $script:assignmentTo "`$resolveArgument['EngineVariable']")
            $written.Count | Should -Be 1

            [string] $written[0].Right.Extent.Text | Should -Match 'HDTDeploymentMethod'

            $resolve = & $script:firstOffsetOf 'Resolve-HDTVariable'
            $resolve | Should -BeGreaterThan -1
            [int] $written[0].Extent.StartOffset | Should -BeLessThan $resolve
        }

        It 'is published into the engine variable bag, so a step condition sees it' {
            # AND SO IT CROSSES THE REBOOT. $variable is what
            # Invoke-HDTTaskSequence checkpoints into state.json and what
            # Start-HDTResume.ps1 puts back before it does anything, so the
            # full-OS leg gets the method without re-deriving it from a
            # bootstrap file that may have been re-resolved.
            @(& $script:assignmentTo "`$variable['HDTDeploymentMethod']").Count | Should -Be 1
        }

        It 'reaches RESULT.json, beside the deploy root it was decided with' {
            @(& $script:assignmentTo "`$result['deploymentMethod']").Count | Should -Be 1
        }

        It 'is published with source Engine, so the provenance log says where it came from' {
            # The key is EngineVariable and nothing else, which is the ONE
            # parameter that records source Engine. Naming the private
            # Add-HDTResolvedVariable here would parse, lint, pass every AST
            # test in this repository and fail only on iron - which is what
            # tests/contract/PayloadExportedCommand.Contract.Tests.ps1 exists
            # for.
            @(& $script:commandNamed 'Add-HDTResolvedVariable').Count | Should -Be 0

            $written = @(& $script:assignmentTo "`$resolveArgument['EngineVariable']")
            $written.Count | Should -Be 1
        }
    }

    Context 'what it says out loud' {

        It 'logs the method and the provider it came from at Info, not Debug' {
            # & $say WITH NO LEVEL IS Information. An admin needs this to
            # understand every outcome below it - the retry count, the Welcome
            # screen, where the log went - so it is not Debug volume.
            $line = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
                        ([string] $node.CommandElements[0].Extent.Text) -eq '$say' -and
                        ([string] $node.Extent.Text) -match 'deployment method'
                    }, $true))

            $line.Count | Should -Be 1
            @($line[0].CommandElements).Count | Should -Be 2
            [string] $line[0].Extent.Text | Should -Match 'bootstrap\.Provider'
        }
    }
}

Describe 'the value itself' {

    It 'is MEDIA under the Local provider' {
        Get-HDTDeploymentMethod -Provider 'Local' | Should -BeExactly 'MEDIA'
    }

    It 'is UNC under the Smb provider' {
        Get-HDTDeploymentMethod -Provider 'Smb' | Should -BeExactly 'UNC'
    }

    It 'reaches the resolved bag with source Engine, through the key the payload sets' {
        # THE ROUND TRIP THROUGH THE REAL COMMANDS. The payload builds
        # @{ HDTDeploymentMethod = <method> } and hands it to Resolve-HDTVariable
        # as -EngineVariable; this is that, run rather than read.
        $method = Get-HDTDeploymentMethod -Provider 'Local'
        $resolved = Resolve-HDTVariable -EngineVariable @{ HDTDeploymentMethod = $method }

        $resolved.Variable['HDTDeploymentMethod'] | Should -BeExactly 'MEDIA'
        $resolved.Provenance['HDTDeploymentMethod'].Source | Should -BeExactly 'Engine'
    }

    It 'leaves HDTDeploymentType as NEWCOMPUTER under either' {
        # THE ROADMAP'S EXPLICIT WARNING, MADE CHECKABLE. The two are different
        # questions: DeploymentType says WHAT is being done and a machine built
        # from a disc is still a bare-metal install; DeploymentMethod says HOW
        # the content got here. Get-HDTMachineFact publishes the first as the
        # constant NEWCOMPUTER and nothing about media may change it.
        foreach ($provider in @('Local', 'Smb')) {
            $resolved = Resolve-HDTVariable `
                -EngineVariable @{ HDTDeploymentMethod = (Get-HDTDeploymentMethod -Provider $provider) } `
                -Fact @{ HDTDeploymentType = 'NEWCOMPUTER' }

            $resolved.Variable['HDTDeploymentType'] | Should -BeExactly 'NEWCOMPUTER'
        }
    }

    It 'is never assigned HDTDeploymentType by the payload, because that is a different question' {
        @(& $script:assignmentTo "`$variable['HDTDeploymentType']").Count | Should -Be 0
    }
}
