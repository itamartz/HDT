# src/Hephaestus/Payload/Start-HDTResume.ps1 - the RunOnce payload.
#
# Not a module file: the loader only dot-sources Private\ and Public\, so this is
# staged to C:\HDT\ and launched by the RunOnce entry Set-HDTAutoLogon writes.
#
# IT IS TESTED BY PARSING AND INSPECTING IT rather than by running it. Running it
# for real means importing a module from C:\HDT\Modules, building real service
# adapters, and rebooting a machine - which belongs to phase 04's integration
# layer, where there is a machine to reboot. What CAN be proven from a desk is
# the thing most likely to be got wrong: that the boot reconcile runs BEFORE
# anything else (DESIGN 4.5.2), that the payload passes the reconciled state to
# the loop rather than starting a new run, and that it parses under both engines.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:payloadPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload/Start-HDTResume.ps1'

    $script:parseError = $null
    $script:token = $null
    $script:ast = $null

    if (Test-Path -LiteralPath $script:payloadPath -PathType Leaf) {
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:payloadPath, [ref] $script:token, [ref] $script:parseError)
        $script:text = Get-Content -LiteralPath $script:payloadPath -Raw

        # The comment-free token stream, so an assertion that a name appears
        # NOWHERE is about the code and not about the prose explaining why the
        # name is absent from the code.
        $script:codeOnly = (@($script:token |
                    Where-Object { $_.Kind -ne 'Comment' } |
                    ForEach-Object { [string] $_.Text }) -join ' ')
    }

    $script:commandNamed = {
        param([string] $Name)

        if ($null -eq $script:ast) {
            return @()
        }

        # Copied into a local before the nested predicate closes over it:
        # PSScriptAnalyzer cannot see a parameter used only inside a nested
        # scriptblock and reports it unused.
        $wanted = $Name

        return @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq $wanted
                }, $true))
    }

    # WHAT THE LOOP IS GIVEN, however it is given. The call splats, because two
    # of its arguments are conditional - a leg with no share to copy logs to
    # must not pass -LogDestination at all, and the loop tells the two apart
    # with $PSBoundParameters. So an assertion that reads only the call site
    # would report every argument missing.
    $script:loopReceives = {
        param([string] $Name)

        $loop = @(& $script:commandNamed 'Invoke-HDTTaskSequence')[0]
        if ($null -eq $loop) { return $false }

        $element = @($loop.CommandElements | ForEach-Object { [string] $_.Extent.Text })

        if ($element -contains ('-{0}' -f $Name)) { return $true }

        # Splatted: find the hashtable literals assigned to the splatted
        # variable, and every key added to it afterwards.
        $splat = @($element | Where-Object { $_ -like '@*' })
        if (@($splat).Count -eq 0) { return $false }

        $variable = ([string] $splat[0]).TrimStart('@')

        $assigned = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst]
                }, $true) | Where-Object { $_.Left.Extent.Text -like ('*{0}*' -f $variable) })

        foreach ($one in $assigned) {
            if ($one.Extent.Text -match ('(?m)^\s*\[?''?{0}''?\]?\s*=' -f [regex]::Escape($Name))) { return $true }
            if ($one.Left.Extent.Text -like ("*['{0}']*" -f $Name)) { return $true }
        }

        return $false
    }

}

Describe 'Start-HDTResume.ps1' {

    It 'exists at src/Hephaestus/Payload/Start-HDTResume.ps1' {
        Test-Path -LiteralPath $script:payloadPath -PathType Leaf | Should -BeTrue
    }

    It 'parses with no error' {
        @($script:parseError).Count | Should -Be 0 -Because (@($script:parseError | ForEach-Object { $_.Message }) -join "`n")
    }

    It 'passes the PowerShell 5.1 syntax scanner' {
        $violation = @(Get-HDTScriptCompatibilityViolation -Path $script:payloadPath)

        $violation.Count | Should -Be 0 -Because (@($violation | ForEach-Object { $_.Reason }) -join "`n")
    }

    It 'defines no unprefixed function' {
        $name = @(Get-HDTSourceFunction -Path $script:payloadPath | ForEach-Object { $_.Name })
        $violation = @(Get-HDTFunctionNameViolation -Name $name)

        $violation.Count | Should -Be 0
    }

    It 'is not dot-sourced by the module loader' {
        # Payload\ is deliberately outside Private\ and Public\: this script runs
        # as a script, not as an exported command.
        $loader = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psm1') -Raw

        $loader | Should -Not -BeLike '*Payload*'
    }

    Context 'the parameters' {

        It 'takes a -ModulePath parameter' {
            $parameter = @($script:ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })

            $parameter | Should -Contain 'ModulePath'
        }

        It 'defaults the module path to C:\HDT\Modules\Hephaestus' {
            $modulePath = @($script:ast.ParamBlock.Parameters |
                    Where-Object { $_.Name.VariablePath.UserPath -eq 'ModulePath' })[0]

            $modulePath.DefaultValue.Extent.Text | Should -BeLike '*C:\HDT\Modules\Hephaestus*'
        }

        It 'takes a -StatePath parameter defaulting to C:\HDT\state.json' {
            $statePath = @($script:ast.ParamBlock.Parameters |
                    Where-Object { $_.Name.VariablePath.UserPath -eq 'StatePath' })

            $statePath.Count | Should -Be 1
            $statePath[0].DefaultValue.Extent.Text | Should -BeLike '*C:\HDT\state.json*'
        }

        It 'puts the staged module root on PSModulePath before it imports anything' {
            # WITHOUT THIS THE LEG DIES ON THE FIRST DOCUMENT IT READS.
            # ConvertFrom-HDTYaml imports powershell-yaml lazily by NAME, so a
            # copy staged at C:\HDT\Modules\powershell-yaml is invisible unless
            # C:\HDT\Modules is a module path - and the engine cannot read a
            # sequence, a rule or an image catalog without it. The WinPE entry
            # point has always done this; this one never did, and nothing
            # noticed because no full-OS leg had ever run.
            $script:text | Should -BeLike '*PSModulePath*'

            $assignment = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left.Extent.Text -like '*PSModulePath*'
                    }, $true))

            $assignment.Count | Should -BeGreaterOrEqual 1

            $import = @(& $script:commandNamed 'Import-Module')[0]
            $assignment[0].Extent.StartOffset | Should -BeLessThan $import.Extent.StartOffset
        }

        It 'sets StrictMode and ErrorActionPreference' {
            @(& $script:commandNamed 'Set-StrictMode').Count | Should -Be 1
            $script:text | Should -BeLike "*ErrorActionPreference = 'Stop'*"
        }
    }

    Context 'the order of operations' {

        It 'calls Invoke-HDTBootReconciliation' {
            @(& $script:commandNamed 'Invoke-HDTBootReconciliation').Count | Should -Be 1
        }

        It 'calls Invoke-HDTTaskSequence' {
            @(& $script:commandNamed 'Invoke-HDTTaskSequence').Count | Should -Be 1
        }

        It 'calls the reconcile before the loop' {
            # DESIGN 4.5.2: "before doing anything else".
            $reconcile = @(& $script:commandNamed 'Invoke-HDTBootReconciliation')[0]
            $loop = @(& $script:commandNamed 'Invoke-HDTTaskSequence')[0]

            $reconcile.Extent.StartOffset | Should -BeLessThan $loop.Extent.StartOffset
        }

        It 'imports the module before the reconcile' {
            $import = @(& $script:commandNamed 'Import-Module')[0]
            $reconcile = @(& $script:commandNamed 'Invoke-HDTBootReconciliation')[0]

            $import.Extent.StartOffset | Should -BeLessThan $reconcile.Extent.StartOffset
        }

        It 'returns without running the sequence when the reconcile said Teardown' {
            # The guard has to name Teardown and has to come between the two.
            $reconcile = @(& $script:commandNamed 'Invoke-HDTBootReconciliation')[0]
            $loop = @(& $script:commandNamed 'Invoke-HDTTaskSequence')[0]

            $guard = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.IfStatementAst]
                    }, $true) | Where-Object {
                    $_.Extent.StartOffset -gt $reconcile.Extent.StartOffset -and
                    $_.Extent.StartOffset -lt $loop.Extent.StartOffset -and
                    $_.Extent.Text -like '*Teardown*'
                })

            $guard.Count | Should -BeGreaterOrEqual 1
            @($guard | Where-Object { $_.Extent.Text -like '*exit 0*' -or $_.Extent.Text -like '*return*' }).Count |
                Should -BeGreaterOrEqual 1
        }
    }

    Context 'what it hands the loop' {

        It 'passes -State to Invoke-HDTTaskSequence' {
            & $script:loopReceives 'State' | Should -BeTrue
        }

        It 'rebuilds the log context from the state seq' {
            $script:text | Should -BeLike '*-Seq*'
            $script:text | Should -BeLike '*New-HDTLogContext*'
        }

        It 'seeds the BOOT log context with a seq too' {
            # DESIGN 4.4.2: seq is monotonic and survives reboots. The boot log
            # writes the reconcile's own reboot.resume record BEFORE the run log
            # exists, so a boot context left at zero restarts the numbering at 1
            # in the middle of the stream - which is precisely the ambiguity the
            # counter exists to prevent. Every New-HDTLogContext call in this
            # file therefore passes -Seq.
            $context = @(& $script:commandNamed 'New-HDTLogContext')

            $context.Count | Should -Be 2

            foreach ($call in $context) {
                @($call.CommandElements | ForEach-Object { $_.Extent.Text }) |
                    Should -Contain '-Seq' -Because 'a log context that restarts seq breaks the ordering of a multi-leg deployment'
            }
        }

        It 'continues the run log from the boot log rather than from the state' {
            # The boot log has already consumed a number by the time the run log
            # is built, so seeding the run log from $state.seq would reissue it.
            $script:text | Should -BeLike '*$bootLog.Seq*'
        }

        It 're-imports the sequence rather than assuming one' {
            @(& $script:commandNamed 'Import-HDTSequenceDocument').Count | Should -Be 1
        }

        It 'builds the real service adapters' {
            foreach ($name in @('New-HDTFileSystem', 'New-HDTClock', 'New-HDTRegistryService', 'New-HDTLsaService', 'New-HDTPowerService')) {
                @(& $script:commandNamed $name).Count | Should -BeGreaterOrEqual 1 -Because "the payload has to build $name"
            }
        }

        It 'tells the power service it is in the full OS' {
            # THE OTHER HALF OF 05-06. This payload runs from RunOnce on a
            # deployed Windows install, where shutdown.exe exists and wpeutil
            # does not - the exact mirror of the WinPE entry point. Neither
            # detects anything, because both already know, and -Environment is
            # mandatory so neither can forget.
            $power = @(& $script:commandNamed 'New-HDTPowerService')

            $power.Count | Should -Be 1

            $element = @($power[0].CommandElements | ForEach-Object { [string] $_.Extent.Text })
            $element | Should -Contain '-Environment'
            $element | Should -Contain 'FullOS'
        }

        It 'names wpeutil nowhere in its code' {
            # It is not on a deployed machine, and reaching for it here would
            # fail on every resume leg. Asserted over the comment-free stream,
            # because the payload's own comment explains that absence and an
            # assertion on the raw text would be about the explanation.
            $script:codeOnly | Should -Not -BeLike '*wpeutil*'
        }

        It 'names no fake' {
            $script:text | Should -Not -BeLike '*New-HDTFake*'
        }
    }

    Context 'reaching the deployment share' {

        # THE FULL-OS LEG IS THE ONE THAT INSTALLS SOFTWARE, and the software is
        # on the share. Until this existed the payload defaulted -WorkspaceRoot
        # to C:\HDT and built no content provider at all, so the first thing
        # InstallApplications did was look for Applications\ on the local disk
        # and find nothing there - a step that cannot work in the phase it is
        # documented to run in.
        #
        # THE ANSWER IS THE ONE THE WinPE PAYLOAD ALREADY GAVE. bootstrap.json
        # carries the deploy root and the account that opens it; it is staged
        # beside this file by Copy-HDTResumeAgent for exactly this reason, and
        # read here with the same command.

        It 'reads the bootstrap document' {
            @(& $script:commandNamed 'Get-HDTBootstrapConfiguration').Count | Should -BeGreaterOrEqual 1
        }

        It 'takes a -BootstrapPath parameter defaulting beside itself' {
            $parameter = @($script:ast.ParamBlock.Parameters |
                    Where-Object { $_.Name.VariablePath.UserPath -eq 'BootstrapPath' })

            $parameter.Count | Should -Be 1
            [string] $parameter[0].DefaultValue.Value | Should -BeExactly 'C:\HDT\bootstrap.json'
        }

        It 'builds a content provider and connects it' {
            @(& $script:commandNamed 'New-HDTContentProvider').Count | Should -BeGreaterOrEqual 1
            $script:text | Should -BeLike '*.Connect()*'
        }

        It 'hands the provider to the service catalog' {
            # InstallApplications reaches for $Context.Service.Content to find an
            # application's source folder. A catalog without one makes every
            # application in the plan unresolvable.
            $catalog = @(& $script:commandNamed 'New-HDTServiceCatalog')

            $catalog.Count | Should -Be 1

            @($catalog[0].CommandElements | ForEach-Object { [string] $_.Extent.Text }) |
                Should -Contain '-Content'
        }

        It 'ships this leg s logs back to the share' {
            # THE TECHNICIAN READS THE SHARE, NOT THE MACHINE. Invoke-HDTTaskSequence
            # copies the log tree only when it is told where; the WinPE entry point
            # tells it and this one did not, so everything the full-OS leg did -
            # which applications installed, which were skipped, what a failure
            # said - stayed on a machine that had already been handed over.
            #
            # THROUGH Get-HDTLogDestination, so HDTSLShare works here too. MDT
            # sends deployment logs to a log server through exactly that
            # variable, and a second answer to "where do logs go" is a second
            # place for them to be missing from.
            @(& $script:commandNamed 'Get-HDTLogDestination').Count | Should -BeGreaterOrEqual 1

            & $script:loopReceives 'LogDestination' | Should -BeTrue
        }

        It 'runs the sequence from the share rather than from C:\HDT' {
            # The sequence, the applications and the rules all live on the share,
            # and the step resolves its catalog from the context's workspace root.
            # A resume rooted at C:\HDT would re-import a sequence that is not
            # there and fail before it reached the first step.
            $context = @(& $script:commandNamed 'New-HDTExecutionContext')

            $context.Count | Should -Be 1

            $element = @($context[0].CommandElements | ForEach-Object { [string] $_.Extent.Text })
            $element | Should -Contain '-WorkspaceRoot'

            # Not the parameter, which is the fallback for a share it cannot reach.
            $at = [array]::IndexOf($element, '-WorkspaceRoot')
            $element[$at + 1] | Should -Not -BeExactly '$WorkspaceRoot'
        }
    }
}

# MDT ENDS State Restore ON A SCREEN, AND SO DOES THIS. A ZTI machine that
# finished and one that failed looked identical to the person standing at it -
# the leg ran to `exit 0` or `exit 1` and drew nothing.
#
# THE GATE IS THE VARIABLE AND NOTHING ELSE. The WinPE failure screen is also
# suppressed whenever no progress window was opened, which is exactly why an
# unattended machine saw nothing this morning. Repeating that here would ship
# the same silence under a new name.
Describe 'Start-HDTResume.ps1 and the deployment summary' {

    It 'shows the summary when the leg ends' {
        $script:text | Should -BeLike '*Show-HDTDeploymentFailure*'
    }

    It 'builds it from the run log, the way the WinPE leg does' {
        $script:text | Should -BeLike '*Get-HDTDeploymentFailure*'
        $script:text | Should -BeLike '*Get-HDTRunLogRecord*'
    }

    It 'shows it for a run that succeeded as well as one that failed' {
        # One screen, two states - so nothing here may gate on IsFailure.
        $script:text | Should -Not -BeLike '*if ($summary.IsFailure)*'
    }

    It 'takes HDTSkipFinalSummary as the only reason not to' {
        # MDT's SkipFinalSummary, with MDT's meaning and HDT's prefix.
        $script:text | Should -BeLike '*HDTSkipFinalSummary*'
    }

    It 'never lets the screen become the failure' {
        # This machine has just been deployed. A window that cannot be drawn
        # must not change what the leg reports.
        $script:text | Should -Match '(?s)Show-HDTDeploymentFailure.*?catch'
    }
}

Describe 'Start-HDTResume.ps1 and the finish action' {

    # MDT's FinishAction. This leg used to end on exit 0 and leave the machine
    # sitting at a desktop, logged in as the local Administrator, until somebody
    # walked over to it.

    It 'asks Get-HDTFinishAction what the value means' {
        # NOT A switch IN THE PAYLOAD. The payload is not unit tested by
        # execution - these assertions read its text - so every branch about
        # what REBOOT means belongs in the function that IS, and this asserts
        # the payload delegates rather than deciding.
        @(& $script:commandNamed 'Get-HDTFinishAction') | Should -Not -BeNullOrEmpty
    }

    It 'reads HDTFinishAction from the resolved variables' {
        $script:text | Should -BeLike '*HDTFinishAction*'
    }

    It 'tells it this is the full OS' {
        # The leg knows which world it is in; the function does not detect one.
        # LOGOFF means something here and nothing in WinPE, and that difference
        # is only correct if the environment is passed truthfully.
        $script:text | Should -Match '(?s)Get-HDTFinishAction.*?FullOS'
    }

    It 'acts through the power service rather than calling shutdown.exe' {
        # Rule 5. The payload holds an IPowerService already, for the Restart
        # step; a payload that shelled out directly would be the one code path
        # in the engine that no fake can stand in front of.
        $script:codeOnly | Should -Not -BeLike '*shutdown.exe*'
        $script:text | Should -Match '(?s)Get-HDTFinishAction.*?\$power\.'
    }

    It 'ends the machine after the summary screen, not before' {
        # A machine that powers off while its Finished screen is being drawn has
        # shown the technician nothing. The order is the whole point.
        $script:text | Should -Match '(?s)Show-HDTDeploymentFailure.*?Get-HDTFinishAction'
    }

    It 'never lets the finish action change what the leg reports' {
        # A deployment that succeeded and then failed to reboot still succeeded,
        # and a machine left powered on is a smaller problem than a green run
        # recorded as a failure.
        $script:text | Should -Match '(?s)Get-HDTFinishAction.*?catch'
    }
}
