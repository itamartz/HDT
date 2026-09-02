# THE END-OF-RUN COPY-BACK, WHEN THE DEPLOY ROOT IS A DISC.
#
# A deployment from media has two logs and only one of them can be written. The
# WinPE leg copies its log to the OS volume's HDT\Logs before it restarts - that
# needs no network, it is the copy an administrator actually reads, and media
# depends on it MORE than a share deployment does. The other copy goes to
# <deployRoot>\Logs at the end of the run, and under media that is read-only
# content.
#
# A MACHINE THAT HAPPENS TO HAVE A NIC IS STILL DEPLOYING FROM A DISC, so
# "we can reach a share" is not a reason to write to one nobody named. The gate
# is inside Get-HDTLogDestination, which both legs already call, because gating
# at the two call sites is two changes that can drift.
#
# AND THE SKIP IS SAID OUT LOUD. Without a line for it the log ends with "no log
# destination was resolved" - true, reads like a failure to resolve one, and
# sends the reader looking for a share that is working perfectly well.
#
# WRITTEN AGAINST THE AST, because both payloads are scripts and running them
# for real means a booted machine to power off - which is what tests/e2e is.
# The share-deployment assertions at the bottom are real calls to the real
# command, because those need no machine at all.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:parseOf = {
        param([string] $RelativePath)

        $path = Join-Path -Path $script:repoRoot -ChildPath $RelativePath

        $fileError = $null
        $fileToken = $null
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $path, [ref] $fileToken, [ref] $fileError)

        return [pscustomobject] @{
            Path  = $path
            Ast   = $fileAst
            Error = @($fileError)
            Text  = [string] $fileAst.Extent.Text
        }
    }

    $script:winpe = & $script:parseOf 'src/Hephaestus/Payload/Start-HDTDeployment.ps1'
    $script:fullOs = & $script:parseOf 'src/Hephaestus/Payload/Start-HDTResume.ps1'
    $script:loop = & $script:parseOf 'src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1'

    $script:commandIn = {
        param($Parsed, [string] $Name)

        $wanted = $Name

        return @($Parsed.Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq $wanted
                }, $true) | Sort-Object { $_.Extent.StartOffset })
    }

    # THE if CHAIN THAT REPORTS THE COPY-BACK DESTINATION, found by what its
    # clauses read rather than by where it sits, so moving the block does not
    # break the test that says the block reports the skip.
    #
    # THE INNERMOST ONE. The payload's whole run sits inside one enormous try,
    # and an outer if could contain this text too - so this sorts by extent
    # length and takes the shortest match.
    $script:logTargetIf = @($script:winpe.Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst]
            }, $true) |
            Where-Object { [string] $_.Extent.Text -match '\$logTarget\.' } |
            Sort-Object { $_.Extent.Text.Length })

    # The tail's copy-back - the LAST Copy-HDTLog in the WinPE payload, the one
    # a run that died before the loop still reaches.
    $script:tailCopy = @(& $script:commandIn $script:winpe 'Copy-HDTLog')[-1]

    $script:tailIf = @($script:winpe.Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst]
            }, $true) |
            Where-Object {
                [int] $_.Extent.StartOffset -lt [int] $script:tailCopy.Extent.StartOffset -and
                [int] $_.Extent.EndOffset -gt [int] $script:tailCopy.Extent.EndOffset
            } |
            Sort-Object { $_.Extent.Text.Length })[0]

    # THE COPY THAT MUST KEEP HAPPENING, in Invoke-HDTTaskSequence's restart
    # path: the WinPE log written to the OS volume before the machine reboots.
    # Found by its guard, which reads HDTOSVolume.
    $script:volumeCopyIf = @($script:loop.Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst]
            }, $true) |
            Where-Object {
                [string] $_.Clauses[0].Item1.Extent.Text -match 'HDTOSVolume' -and
                [string] $_.Extent.Text -match 'Copy-HDTLog'
            } |
            Sort-Object { $_.Extent.Text.Length })[0]

    # The argument a named parameter was given at a call site, as text.
    $script:argumentOf = {
        param($Command, [string] $Parameter)

        $element = @($Command.CommandElements)

        for ($i = 0; $i -lt $element.Count; $i++) {
            if ($element[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and
                [string] $element[$i].ParameterName -eq $Parameter) {

                if ($null -ne $element[$i].Argument) { return [string] $element[$i].Argument.Extent.Text }
                if ($i + 1 -lt $element.Count) { return [string] $element[$i + 1].Extent.Text }
            }
        }

        return ''
    }

    $script:bag = {
        param([System.Collections.IDictionary] $Value)

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Value) {
            foreach ($key in @($Value.Keys)) { $live[[string] $key] = $Value[$key] }
        }

        return $live
    }
}

Describe 'the end-of-run copy-back, under media' {

    Context 'both payloads still parse' {

        It 'parses Start-HDTDeployment.ps1 with no error' {
            $script:winpe.Error.Count | Should -Be 0 -Because (@($script:winpe.Error | ForEach-Object { $_.Message }) -join "`n")
        }

        It 'parses Start-HDTResume.ps1 with no error' {
            $script:fullOs.Error.Count | Should -Be 0 -Because (@($script:fullOs.Error | ForEach-Object { $_.Message }) -join "`n")
        }
    }

    Context 'the WinPE leg' {

        It 'reports the copy-back destination from one if chain, so there is one place to read' {
            # The positive control. A scan that matched nothing would pass every
            # assertion below while proving none of them.
            $script:logTargetIf.Count | Should -BeGreaterOrEqual 1
        }

        It 'says the copy-back was skipped, naming the destination and the method' {
            $media = @($script:logTargetIf[0].Clauses |
                    Where-Object { [string] $_.Item1.Extent.Text -match "Source" -and [string] $_.Item1.Extent.Text -match "'Media'" })

            $media.Count | Should -Be 1

            $body = [string] $media[0].Item2.Extent.Text

            $body | Should -Match '\$say'
            $body | Should -Match '\$logTarget\.Skipped'
            $body | Should -Match 'MEDIA'
        }

        It 'says it at Info, because an admin needs it to understand the outcome' {
            # $say takes a severity as its second argument and defaults to Info.
            # This is not a problem - it is the designed outcome - and the
            # logging rule puts something an admin needs in order to understand
            # a run at Info, where they will see it without re-running anything.
            $media = @($script:logTargetIf[0].Clauses |
                    Where-Object { [string] $_.Item1.Extent.Text -match "'Media'" })

            $media.Count | Should -Be 1

            [string] $media[0].Item2.Extent.Text | Should -Not -Match "'(Warning|Error|Debug)'"
        }

        It 'checks the method before it checks for an empty path, or the skip is never reached' {
            # UNDER MEDIA THE PATH IS EMPTY BY DESIGN, so an empty-path clause
            # placed first would swallow the media case and print the symptom
            # instead of the reason.
            $clause = @($script:logTargetIf[0].Clauses)

            [string] $clause[0].Item1.Extent.Text | Should -Match "'Media'"
        }

        It 'does not warn "no log destination was resolved" - that is a different fact' {
            $media = @($script:logTargetIf[0].Clauses |
                    Where-Object { [string] $_.Item1.Extent.Text -match "'Media'" })[0]

            [string] $media.Item2.Extent.Text | Should -Not -Match 'no log destination'
        }

        It 'still records logDestination and logDestinationSource in RESULT.json' {
            # A reader of that file learns the same thing the log says.
            $assignment = @($script:winpe.Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        [string] $node.Left.Extent.Text -in @("`$result['logDestination']", "`$result['logDestinationSource']")
                    }, $true))

            $assignment.Count | Should -Be 2

            foreach ($one in $assignment) {
                [string] $one.Right.Extent.Text | Should -Match '\$logTarget\.'
            }
        }

        It 'guards the end-of-run Copy-HDTLog on a non-empty destination, so MEDIA ships nothing' {
            $script:tailIf | Should -Not -BeNullOrEmpty

            [string] $script:tailIf.Clauses[0].Item1.Extent.Text |
                Should -Match 'IsNullOrWhiteSpace'
            [string] $script:tailIf.Clauses[0].Item1.Extent.Text |
                Should -Match "logDestination"
        }

        It 'says why at the tail as well, rather than repeating the resolution warning' {
            # THE TAIL IS WHERE A READER LOOKS FOR THE COPY-BACK OUTCOME, and
            # its else branch said "no log destination was resolved" - which
            # under media is the symptom, not the reason, and is exactly the
            # sentence that sends somebody hunting a healthy share.
            $branch = @($script:tailIf.Clauses | ForEach-Object { [string] $_.Item1.Extent.Text })

            ($branch -join "`n") | Should -Match "'Media'"
        }
    }

    Context 'the two other things that read the same answer, and both go quiet' {

        It 'passes an empty LogDestination to Invoke-HDTTaskSequence under MEDIA, so nothing is mirrored to the disc while the run is going' {
            # The live mirror stops under media by the same rule: no writing to
            # read-only content. Nothing re-resolves the destination here, so
            # an empty answer reaches the loop unaltered.
            $call = @(& $script:commandIn $script:winpe 'Invoke-HDTTaskSequence')

            $call.Count | Should -Be 1

            $argument = & $script:argumentOf $call[0] 'LogDestination'
            $argument | Should -BeExactly '$logDestination'

            $assignment = @($script:winpe.Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        [string] $node.Left.Extent.Text -eq '$logDestination'
                    }, $true))

            $assignment.Count | Should -Be 1
            [string] $assignment[0].Right.Extent.Text | Should -BeExactly "[string] `$result['logDestination']"
        }

        It 'still passes the deploy-root path under UNC' {
            # THE SAME LINE, and that is the point: one unconditional read of
            # one answer. UNC fills it, MEDIA empties it, and no branch here
            # can disagree with Get-HDTLogDestination.
            $assignment = @($script:winpe.Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        [string] $node.Left.Extent.Text -eq '$logDestination'
                    }, $true))

            [string] $assignment[0].Right.Extent.Text | Should -Not -Match 'Media'
        }

        It 'gives the failure screen a log path a technician can actually open' {
            # THE REGRESSION THIS PHASE WOULD OTHERWISE INTRODUCE. The Log row
            # read $result['logDestination'], which is empty under media - so a
            # media deployment that failed showed a technician a blank row, when
            # the whole point is that the machine still has its own log.
            $call = @(& $script:commandIn $script:winpe 'Get-HDTDeploymentFailure')

            $call.Count | Should -BeGreaterOrEqual 1

            $argument = & $script:argumentOf $call[0] 'LogPath'
            $argument | Should -Not -Match "^\(?\[string\]\s*\`$result\['logDestination'\]\)?$"

            # AND THE LOCAL PATH IS WHAT IT FALLS BACK TO. $result['logPath'] is
            # the machine's own log directory and is always set - the document
            # declares it, section 6 fills it before a single step runs.
            $name = ([string] $argument).Trim('(', ')', ' ')

            $fallback = @($script:winpe.Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        [string] $node.Left.Extent.Text -eq $name
                    }, $true))

            $fallback.Count | Should -BeGreaterOrEqual 2 -Because 'the destination first, then the local path when it is empty'

            @($fallback | ForEach-Object { [string] $_.Right.Extent.Text }) |
                Should -Contain "[string] `$result['logPath']"
        }
    }

    Context 'the full-OS leg' {

        It 'reads the method out of the restored state document, not from a second source' {
            # $variable is restored from state.variable, which the WinPE leg
            # checkpointed with HDTDeploymentMethod in it, and that bag is what
            # Get-HDTLogDestination is handed. Re-deriving the method here would
            # be a second answer that can disagree with the first.
            $call = @(& $script:commandIn $script:fullOs 'Get-HDTLogDestination')

            $call.Count | Should -Be 1
            (& $script:argumentOf $call[0] 'Variable') | Should -BeExactly '$variable'

            @(& $script:commandIn $script:fullOs 'Get-HDTDeploymentMethod').Count |
                Should -Be 0 -Because 'the method crosses the reboot in state.json rather than being derived twice'
        }

        It 'restores that bag case-insensitively, as the WinPE leg wrote it' {
            $script:fullOs.Text | Should -Match 'OrderedDictionary\]::new\(\[System\.StringComparer\]::OrdinalIgnoreCase\)'
        }

        It 'leaves $logDestination empty under MEDIA, so the copy loop ships nothing' {
            # It keeps the ANSWER now rather than only the .Path, because the
            # skip has to be said and Source is what says it.
            $call = @(& $script:commandIn $script:fullOs 'Get-HDTLogDestination')[0]

            $statement = $call.Parent.Parent

            $statement | Should -BeOfType ([System.Management.Automation.Language.AssignmentStatementAst])
            [string] $statement.Right.Extent.Text | Should -Not -Match '\)\.Path\s*$'
        }

        It 'says the skip in its own log, naming the destination and the method' {
            $script:fullOs.Text | Should -Match "(?s)Source.{0,40}'Media'"
            $script:fullOs.Text | Should -Match 'MEDIA'
            $script:fullOs.Text | Should -Match '\.Skipped'
        }

        It 'still copies to the deploy root under UNC' {
            # The loop is told where only when there is somewhere, and that
            # guard is unchanged: UNC fills it exactly as it did.
            $script:fullOs.Text | Should -Match "IsNullOrWhiteSpace\(\`$logDestination\)\)\s*\{\s*\r?\n\s*\`$loopArgument\['LogDestination'\]"
        }

        It 'gives its failure screen a log path a technician can actually open too' {
            # THE SAME DEFECT IN THE SAME SHAPE. Fix it in both places or the
            # full-OS leg of a media deployment shows the blank row instead.
            $call = @(& $script:commandIn $script:fullOs 'Get-HDTDeploymentFailure')

            $call.Count | Should -BeGreaterOrEqual 1
            (& $script:argumentOf $call[0] 'LogPath') | Should -Not -BeExactly '$logDestination'
        }
    }

    Context 'the copy that must keep happening' {

        # THE WORST POSSIBLE OUTCOME OF A PHASE ABOUT MEDIA would be breaking
        # the one log a media deployment can leave behind. It needs no network,
        # it is the copy an administrator reads on the machine itself, and media
        # depends on it more than a share deployment does.

        It 'still writes the WinPE log to the OS volume before the restart, under MEDIA' {
            $script:volumeCopyIf | Should -Not -BeNullOrEmpty

            [string] $script:volumeCopyIf.Extent.Text | Should -Match 'Copy-HDTLog'
        }

        It 'writes it under UNC too, unchanged' {
            # ONE STATEMENT, NO METHOD IN IT, so there is no direction for it to
            # differ in. This is the same assertion said from the other end.
            [string] $script:volumeCopyIf.Clauses[0].Item1.Extent.Text |
                Should -Match 'HDTOSVolume'
        }

        It 'is reached by no code path this phase added a method check to' {
            $text = [string] $script:volumeCopyIf.Extent.Text

            $text | Should -Not -Match 'HDTDeploymentMethod'
            $text | Should -Not -Match '\$deploymentMethod'
            $text | Should -Not -Match "'Media'"
        }

        It 'is guarded on the leg and the volume and nothing else' {
            [string] $script:volumeCopyIf.Clauses[0].Item1.Extent.Text |
                Should -Match "Phase.{0,20}'WinPE'"
        }
    }

    Context 'the share deployment, which must not have changed' {

        # REAL CALLS TO THE REAL COMMAND. These need no booted machine, so
        # there is no reason to assert them against an AST.

        It 'still copies the run to the deploy root Logs folder under UNC' {
            $answer = Get-HDTLogDestination -WorkspaceRoot '\\srv\HDTShare$' `
                -Variable (& $script:bag ([ordered] @{ HDTDeploymentMethod = 'UNC' }))

            [string] $answer.Path | Should -BeExactly '\\srv\HDTShare$\Logs'
            [string] $answer.Source | Should -BeExactly 'DeployRoot'
        }

        It 'still prefers HDTSLShare under either method' -ForEach @(
            @{ Method = 'UNC' }
            @{ Method = 'MEDIA' }
        ) {
            $answer = Get-HDTLogDestination -WorkspaceRoot 'D:\Deploy' `
                -Variable (& $script:bag ([ordered] @{
                            HDTDeploymentMethod = $Method
                            HDTSLShare          = '\\logs-01\HDTLogs'
                        }))

            [string] $answer.Path | Should -BeExactly '\\logs-01\HDTLogs'
            [string] $answer.Source | Should -BeExactly 'HDTSLShare'
        }
    }
}
