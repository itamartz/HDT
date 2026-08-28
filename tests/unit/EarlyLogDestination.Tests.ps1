# WHERE THE LOG GOES, DECIDED BEFORE ANYTHING CAN THROW.
#
# THE RUN THIS FILE EXISTS FOR. A real deployment in this lab died in WinPE
# before a single step ran, and the failure screen said:
#
#   HDTConfigurationError: no task sequence was named.
#   Log: (no log destination was resolved)
#
# The reason was true and useless: the copy-back destination was resolved four
# hundred lines below the thing that threw, so the tail's copy-back - which is
# guarded on that destination - shipped nothing, and the entire record of why
# went away with the RAM disk five seconds later.
#
# b08bb91 MOVED THE OTHER HALF AND LEFT THIS ONE. HDTSLShareDynamicLogging (the
# live mirror) was pulled up to sit immediately after Resolve-HDTVariable, so a
# run that dies mid-wizard leaves its lines on the share as they happen.
# HDTSLShare - the COPY AT THE END - stayed where it was, which is after the
# wizard and after the progress window, so the one guard that decides whether a
# dead run's log is ever seen was still being set too late.
#
# SO THE ASSERTIONS HERE ARE ABOUT ORDER, and they are written against the
# payload's AST because running the entry point for real means a booted machine
# to power off - which is what tests/e2e is (see StartHDTDeploymentPayload).

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

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

    # THE FIRST OFFSET OF A COMMAND, which is what every ordering assertion in
    # this file compares. A command that is never called answers -1 rather than
    # throwing, so the failure reads as "it is not there" and not as an index
    # error in the test.
    $script:firstOffsetOf = {
        param([string] $Name)

        $found = @(& $script:commandNamed $Name)
        if ($found.Count -eq 0) { return -1 }

        return [int] $found[0].Extent.StartOffset
    }

    # THE try/catch THAT GUARDS THE LIVE MIRROR, found by what its body does
    # rather than by where it sits, so moving the block does not break the test
    # that says the block is guarded.
    #
    # THE INNERMOST ONE, WHICH IS WHY THIS SORTS. The payload's whole run sits
    # inside one enormous try, and that outer block's body matches SetDynamicPath
    # too - so taking the first match found the wrong guard and measured a
    # distance of thirty-four thousand characters.
    $script:mirrorTry = @($script:ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.TryStatementAst]
            }, $true) |
            Where-Object { [string] $_.Body.Extent.Text -match 'SetDynamicPath' } |
            Sort-Object { $_.Extent.Text.Length })

    # The last copy-back in the file - the tail's, the one a run that died
    # before the loop reaches.
    $script:tailCopy = $null
    $copy = @(& $script:commandNamed 'Copy-HDTLog')
    if ($copy.Count -gt 0) { $script:tailCopy = $copy[-1] }
}

Describe 'Start-HDTDeployment.ps1 and the log destination a run that dies early still has' {

    It 'parses with no error' {
        @($script:parseError).Count | Should -Be 0 -Because (@($script:parseError | ForEach-Object { $_.Message }) -join "`n")
    }

    It 'resolves the copy-back destination after the rules have resolved' {
        # HDTSLShare is a resolved variable like any other (Get-HDTLogDestination
        # reads it and nothing else), so this is the earliest the answer exists.
        $resolve = & $script:firstOffsetOf 'Resolve-HDTVariable'
        $destination = & $script:firstOffsetOf 'Get-HDTLogDestination'

        $resolve | Should -BeGreaterThan -1
        $destination | Should -BeGreaterThan $resolve
    }

    It 'resolves it before the wizard is asked which pages to show' {
        # THE REGRESSION TEST FOR THE FIELD FAILURE. The run that died said
        # 'no log destination was resolved' because the wizard threw first.
        $destination = & $script:firstOffsetOf 'Get-HDTLogDestination'
        $wizard = & $script:firstOffsetOf 'Get-HDTWizardPage'

        $wizard | Should -BeGreaterThan -1
        $destination | Should -BeGreaterThan -1
        $destination | Should -BeLessThan $wizard -Because 'a run that dies in the wizard is the run whose log somebody wants'
    }

    It 'resolves it before the progress window goes up' {
        $destination = & $script:firstOffsetOf 'Get-HDTLogDestination'
        $progress = & $script:firstOffsetOf 'Start-HDTProgressDisplay'

        $progress | Should -BeGreaterThan -1
        $destination | Should -BeLessThan $progress
    }

    It 'resolves it beside the live mirror rather than in a second place of its own' {
        # HDTSLShareDynamicLogging and HDTSLShare are the two halves of one
        # question - where does this run's log end up - and two answers computed
        # four hundred lines apart is how the second one got left behind.
        $destination = & $script:firstOffsetOf 'Get-HDTLogDestination'

        $script:mirrorTry.Count | Should -BeGreaterOrEqual 1
        $mirror = [int] $script:mirrorTry[0].Extent.StartOffset

        [Math]::Abs($destination - $mirror) | Should -BeLessThan 4000
    }

    It 'resolves it exactly once, so nothing later replaces it with an empty one' {
        @(& $script:commandNamed 'Get-HDTLogDestination').Count | Should -Be 1
    }

    It 'fills the result document where it resolves it' {
        # Everything downstream reads $result['logDestination'] - the failure
        # screen's Log line, the tail's copy-back guard, RESULT.json. Filling it
        # sooner is the whole fix; changing what reads it is not.
        $assignment = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    [string] $node.Left.Extent.Text -eq "`$result['logDestination']"
                }, $true))

        $assignment.Count | Should -Be 1

        $destination = & $script:firstOffsetOf 'Get-HDTLogDestination'
        $wizard = & $script:firstOffsetOf 'Get-HDTWizardPage'

        [int] $assignment[0].Extent.StartOffset | Should -BeGreaterThan $destination
        [int] $assignment[0].Extent.StartOffset | Should -BeLessThan $wizard
    }
}

Describe 'Start-HDTDeployment.ps1 and a live mirror that could not be prepared' {

    # NEVER FATAL, AND NEVER SILENT EITHER. A share that cannot be written to is
    # a reason to stop mirroring, not a reason to stop deploying - but a
    # technician standing at the bench has to be able to tell that the logs are
    # not reaching the share, and the log is the one place that cannot tell them.

    It 'is guarded, so a share that has gone does not end the deployment' {
        $script:mirrorTry.Count | Should -BeGreaterOrEqual 1
        @($script:mirrorTry[0].CatchClauses).Count | Should -BeGreaterOrEqual 1
    }

    It 'does not rethrow out of the guard' {
        $body = [string] $script:mirrorTry[0].CatchClauses[0].Body.Extent.Text

        $body | Should -Not -Match '(?m)^\s*throw'
    }

    It 'says so on the boot panel and not only in the log that just failed' {
        # $say writes the sentence to the transcript, to Write-Information, to
        # the boot status overlay - which is open here - and to the engine's own
        # stream. Write-HDTLog alone would put the news about a share that
        # cannot be reached into the copy of the log on that share.
        $body = [string] $script:mirrorTry[0].CatchClauses[0].Body.Extent.Text

        $body | Should -Match '\$say'
    }
}

Describe 'Start-HDTDeployment.ps1 and a copy-back that failed' {

    # Copy-HDTLog IS DOCUMENTED NEVER TO THROW, and for five milestones that
    # meant it returned nothing at all and wrote a Warning through Write-HDTLog
    # - into the log it had just failed to send. The failure existed and no
    # surface carried it. It answers a result now, and the tail reports it.

    It 'keeps the answer instead of piping it to Out-Null' {
        $script:tailCopy | Should -Not -BeNullOrEmpty

        # $x = Copy-HDTLog @arg -> CommandAst inside a PipelineAst inside an
        # AssignmentStatementAst.
        $pipeline = $script:tailCopy.Parent

        $pipeline | Should -BeOfType ([System.Management.Automation.Language.PipelineAst])
        $pipeline.Parent | Should -BeOfType ([System.Management.Automation.Language.AssignmentStatementAst])
    }

    It 'reads whether it succeeded' {
        $script:text = Get-Content -LiteralPath $script:payloadPath -Raw

        $script:text | Should -Match '\.Succeeded'
    }

    It 'reports the outcome through the same voice as everything else' {
        # $say, so the sentence reaches the transcript that becomes LAUNCHER.log
        # rather than only Write-Information on a console nobody is reading.
        $statement = $script:tailCopy.Parent.Parent.Parent

        [string] $statement.Extent.Text | Should -Match '\$say'
    }

    It 'copies back before RESULT.json is serialised, so the evidence file can say what happened' {
        # RESULT.json is the file 05-05's zero-keystroke proof reads and the
        # file somebody opens after a failed run. A copy-back that ran after it
        # was written could not put its own outcome in it.
        $convert = @(& $script:commandNamed 'ConvertTo-Json')

        $convert.Count | Should -BeGreaterOrEqual 1
        [int] $script:tailCopy.Extent.StartOffset |
            Should -BeLessThan ([int] $convert[0].Extent.StartOffset)
    }

    It 'still runs outside the try, where a run that died before the loop reaches it' {
        $largestTry = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.TryStatementAst]
                    }, $true) | Sort-Object { $_.Extent.Text.Length } -Descending)[0]

        [int] $script:tailCopy.Extent.StartOffset |
            Should -BeGreaterThan ([int] $largestTry.Extent.EndOffset)
    }

    It 'says something when there was no destination to copy to at all' {
        $script:text = Get-Content -LiteralPath $script:payloadPath -Raw

        $script:text | Should -Match 'no log destination'
    }
}

Describe 'Every caller of Copy-HDTLog' {

    # RULE 8, AGAINST THE SET AND NOT AGAINST THE ONE THAT WAS CHANGED.
    # Copy-HDTLog used to answer a bare path string and nothing at all when the
    # copy failed. It answers a result object now, and a caller left reading it
    # as a string would log "the log was copied to
    # System.Management.Automation.PSCustomObject" - true of the type and
    # useless to the person reading it.

    BeforeAll {
        $script:sourceRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus'

        $script:callSite = @(Get-ChildItem -LiteralPath $script:sourceRoot -Filter '*.ps1' -Recurse -File |
                Where-Object { $_.Name -ne 'Hephaestus.bundle.ps1' -and $_.Name -ne 'Copy-HDTLog.ps1' } |
                ForEach-Object {
                    $file = $_
                    $fileError = $null
                    $fileToken = $null
                    $fileAst = [System.Management.Automation.Language.Parser]::ParseFile(
                        $file.FullName, [ref] $fileToken, [ref] $fileError)

                    $fileAst.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.CommandAst] -and
                            $node.GetCommandName() -eq 'Copy-HDTLog'
                        }, $true) | ForEach-Object {
                        [pscustomobject] @{
                            File    = $file.FullName
                            Command = $_
                            Text    = [string] $fileAst.Extent.Text
                        }
                    }
                })
    }

    It 'is found by this test at all' {
        # The positive control. A scan that matched nothing would pass every
        # assertion below while proving none of them.
        $script:callSite.Count | Should -BeGreaterOrEqual 2
    }

    It 'keeps the result rather than discarding it' {
        $discarded = @($script:callSite | Where-Object {
                [string] $_.Command.Parent.Extent.Text -match '\|\s*Out-Null'
            })

        $discarded.Count | Should -Be 0 -Because (@($discarded | ForEach-Object { $_.File }) -join "`n")
    }

    It 'reads the result as an object and not as a path' {
        $wrong = @($script:callSite | ForEach-Object {
                $assignment = $_.Command.Parent.Parent

                if ($assignment -isnot [System.Management.Automation.Language.AssignmentStatementAst]) {
                    return $_.File
                }

                $name = ([string] $assignment.Left.Extent.Text).TrimStart('$')

                if ($_.Text -notmatch [regex]::Escape('$' + $name) + '\.(Path|Succeeded|Message)') {
                    return $_.File
                }
            })

        @($wrong).Count | Should -Be 0 -Because (@($wrong) -join "`n")
    }
}
