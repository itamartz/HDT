# src/Hephaestus/Payload/Start-HDTDeployment.ps1 - THE QUESTION IT NEVER ASKED.
#
# This file minted a NEW run at step 1 on every WinPE boot. That is right for
# every boot but one: the boot a reference build does after sysprep, when it
# comes back into WinPE to capture itself. On THAT boot the old behaviour would
# have run the sequence's own DiskPartition step against the volume it had just
# generalized - and the machine would have looked like it was deploying
# normally the whole time.
#
# TESTED BY PARSING AND INSPECTING IT, like every other payload here. Running it
# for real means a booted machine to power off, which is tests/e2e.
#
# THE THREE THINGS THAT MUST BE TRUE, AND THEY ARE ALL ABOUT ORDER:
#
#   1. the question is asked BEFORE a run is minted   - or the answer is useless
#   2. Ambiguous THROWS                               - or it guesses, and a
#                                                       guess here formats a disk
#   3. Resume passes -Resumed to the loop             - or discovery finds the
#                                                       run and the guard that
#                                                       protects it never arms

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    $script:payloadPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload/Start-HDTDeployment.ps1'

    $script:parseError = $null
    $script:token = $null
    $script:ast = $null
    $script:text = ''

    if (Test-Path -LiteralPath $script:payloadPath -PathType Leaf) {
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:payloadPath, [ref] $script:token, [ref] $script:parseError)
        $script:text = Get-Content -LiteralPath $script:payloadPath -Raw
    }

    $script:commandNamed = {
        param([string] $Name)

        if ($null -eq $script:ast) { return @() }

        $wanted = $Name

        return @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq $wanted
                }, $true))
    }

    $script:argumentOf = {
        param([object] $Command)

        return @($Command.CommandElements | ForEach-Object { [string] $_.Extent.Text })
    }
}

Describe 'Start-HDTDeployment.ps1 and a run already in progress' {

    It 'parses' {
        $script:parseError | Should -BeNullOrEmpty
    }

    Context 'asking the question' {

        It 'asks Get-HDTResumeCandidate' {
            @(& $script:commandNamed 'Get-HDTResumeCandidate').Count | Should -BeGreaterOrEqual 1
        }

        # THE ORDER IS THE ASSERTION. A discovery that ran after New-HDTRunState
        # would have already minted the run it exists to prevent.
        It 'asks it before it mints a run' {
            $discover = @(& $script:commandNamed 'Get-HDTResumeCandidate')
            $mint = @(& $script:commandNamed 'New-HDTRunState')

            $discover.Count | Should -BeGreaterOrEqual 1
            $mint.Count | Should -BeGreaterOrEqual 1
            $discover[0].Extent.StartOffset | Should -BeLessThan $mint[0].Extent.StartOffset
        }

        # AND BEFORE THE WIZARD. A resumed leg has a technician's answers
        # already, carried in the state document's variable bag. Opening the
        # wizard again on the capture boot would stop a reference build dead
        # waiting for somebody who went home hours ago.
        It 'asks it before the wizard opens' {
            $discover = @(& $script:commandNamed 'Get-HDTResumeCandidate')
            $wizard = @(& $script:commandNamed 'Import-HDTWizardDocument')

            $discover.Count | Should -BeGreaterOrEqual 1
            $wizard.Count | Should -BeGreaterOrEqual 1
            $discover[0].Extent.StartOffset | Should -BeLessThan $wizard[0].Extent.StartOffset
        }

        # IT MUST BE ABLE TO SEE THE DISK. Get-HDTResumeCandidate scans lettered
        # volumes through IDiskService, so a call that did not pass one would
        # answer None on every machine - which is the old behaviour with a new
        # name on it.
        It 'hands it the disk service' {
            $discover = @(& $script:commandNamed 'Get-HDTResumeCandidate')[0]

            & $script:argumentOf $discover | Should -Contain '-Disk'
        }

        It 'hands it a clock, so staleness is measured rather than guessed' {
            $discover = @(& $script:commandNamed 'Get-HDTResumeCandidate')[0]

            & $script:argumentOf $discover | Should -Contain '-Clock'
        }
    }

    Context 'refusing what it cannot read' {

        # THE FAIL-SAFE, AND THE ONE ASSERTION WORTH THE WHOLE FILE.
        #
        # Ambiguous means "there may be a run in progress and I cannot tell".
        # The only safe act is to stop. Carrying on would mint a run and reach
        # a partition step, so a warning here would be a warning printed onto a
        # screen nobody is watching while the disk is being formatted.
        It 'throws on Ambiguous rather than deploying' {
            $script:text | Should -Match "(?s)Ambiguous.{0,400}throw"
        }

        # THE REFUSAL HAS TO SAY WHAT TO DELETE. Get-HDTResumeCandidate builds
        # that sentence - it is the one that knows which file it found - so the
        # payload must surface the Reason rather than a message of its own.
        It 'reports the reason the discovery gave' {
            $script:text | Should -Match 'Ambiguous'
            $script:text | Should -Match '\$resume\.Reason'
        }
    }

    Context 'resuming' {

        It 'passes -Resumed to the loop' {
            $run = @(& $script:commandNamed 'Invoke-HDTTaskSequence')

            $run.Count | Should -BeGreaterOrEqual 1
            (@($run | ForEach-Object { & $script:argumentOf $_ }) -join ' ') | Should -Match '\-Resumed'
        }

        # THE RESUMED LEG KEEPS WRITING TO THE DOCUMENT IT RESUMED FROM. A leg
        # that read W:\HDT\state.json and then checkpointed to X:\HDT\Logs\state.json
        # would leave the durable copy frozen at the moment of the resume, and
        # the share would collect the frozen one - which is the stale-state
        # failure 05-03 already cost a lab run.
        It 'checkpoints back to the document it found' {
            $script:text | Should -Match '\$resume\.Path'
        }

        # THE RUN ID IS THE ONE ALREADY ON DISK. Minting a fresh one would split
        # a single deployment into two runs in the log, and the seq counter that
        # exists to order them across a reboot would restart.
        It 'keeps the run id from the state document' {
            $script:text | Should -Match '\$resume\.State\.runId'
        }
    }

    Context 'the ordinary path' {

        # THE REGRESSION GUARD. A machine with no run in progress must still
        # deploy exactly as it did, which means None reaches none of the above.
        It 'still mints a run' {
            @(& $script:commandNamed 'New-HDTRunState').Count | Should -BeGreaterOrEqual 1
        }

        It 'still calls the loop exactly once' {
            @(& $script:commandNamed 'Invoke-HDTTaskSequence').Count | Should -Be 1
        }
    }
}
