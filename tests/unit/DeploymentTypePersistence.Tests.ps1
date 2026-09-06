# HDTDeploymentType IS DERIVED ONCE AND THEN CARRIED, AND THE DEFECT IS THAT IT
# WAS DERIVED EVERY LEG.
#
# f663780 made the value fall out of the phase: WinPE gives NEWCOMPUTER, the full
# OS gives REFRESH. That is the right derivation and it is MDT's
# (LiteTouch.wsf:373-387). What it is NOT is a question to ask twice.
#
# A REFRESH STARTS IN THE FULL OS AND THEN GOES TO WinPE. SystemDrive is C: on
# the leg the operator launched, so the run is a REFRESH; it stages a WinPE,
# reboots, and comes back with SystemDrive at X: - so re-deriving on the leg that
# comes back calls the same run a NEWCOMPUTER. The run forgets what it is
# mid-flight, and it forgets it at precisely the moment the resume guard is
# asking, because REFRESH is the one value that unlocks ApplyImage there
# (DESIGN 3.2).
#
# MDT'S ANSWER, AND HDT TAKES IT: DERIVE ONLY WHEN IT IS NOT ALREADY KNOWN.
# LiteTouch.wsf:373-387 reads
#   ElseIf oEnvironment.Item("DeploymentType") = "" then
#       oEnvironment.Item("DeploymentType") = "REFRESH"
# - the derivation is the ELSE branch of "nobody has said yet". The value lives
# in the run's persisted environment and survives the reboot in it.
#
# SO: THE PHASE IS RE-DERIVED EVERY LEG, THE TYPE IS NOT. The phase is a fact
# about the leg - it decides where this leg's log goes and which steps it may
# run - and it is read fresh every time, correctly. The type is a fact about the
# RUN, it is decided on the run's first leg, and every leg after that reads it
# off the checkpoint.
#
# AND THE PROVENANCE HAS TO SAY WHICH OF THE TWO HAPPENED. An administrator
# reading the log of the WinPE leg of a Refresh sees REFRESH beside a machine
# whose SystemDrive is X:, and the only thing that makes that readable rather
# than alarming is a provenance line saying the value was carried from the
# checkpoint rather than derived here (CLAUDE.md's logging rule).
#
# WALKED AS A SET, NOT NAMED. The phases come off the ValidateSet and the types
# come out of the derivation, so a third leg added to either fails this the day
# it lands rather than the day somebody debugs it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:cimFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim'

    # EVERY LEG THERE IS, READ OFF THE PARAMETER RATHER THAN LISTED HERE.
    $script:phase = @(InModuleScope Hephaestus {
            $parameter = (Get-Command -Name Get-HDTDeploymentType).Parameters['Phase']
            $set = @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })

            return [string[]] @($set[0].ValidValues)
        })

    $script:derive = {
        param([string] $Phase)

        return [string] (InModuleScope Hephaestus -Parameters @{ Phase = $Phase } {
                param($Phase)

                return (Get-HDTDeploymentType -Phase $Phase)
            })
    }

    $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 9, 5, 9, 0, 0, [System.DateTimeKind]::Utc))

    $script:gather = {
        param([string] $Phase, [string] $DeploymentType, [hashtable] $Provenance)

        $argument = @{
            CimProvider         = (New-HDTFakeCimProvider -FixturePath $script:cimFixturePath)
            RegistryService     = (New-HDTFakeRegistryService -Value @{})
            EnvironmentProvider = (New-HDTFakeEnvironmentProvider -Variable @{ PROCESSOR_ARCHITECTURE = 'AMD64' })
            Phase               = $Phase
        }

        if (-not [string]::IsNullOrEmpty($DeploymentType)) { $argument['DeploymentType'] = $DeploymentType }
        if ($null -ne $Provenance) { $argument['Provenance'] = $Provenance }

        return (Get-HDTMachineFact @argument)
    }
}

Describe 'HDTDeploymentType is derived once and carried' {

    Context 'the derivation itself' {

        # ONE PLACE, TWO CALLERS. Get-HDTMachineFact publishes the fact and
        # New-HDTRunState stamps it onto the checkpoint; if each carried its own
        # copy of the mapping, the document and the variable could disagree
        # about the same run, and the guard reads one of them.
        It 'answers a deployment type for every leg there is' {
            $script:phase.Count | Should -BeGreaterThan 0

            foreach ($leg in $script:phase) {
                (& $script:derive $leg) | Should -Not -BeNullOrEmpty
            }
        }

        It 'calls a WinPE start a NEWCOMPUTER' {
            (& $script:derive 'WinPE') | Should -BeExactly 'NEWCOMPUTER'
        }

        It 'calls a full-OS start a REFRESH' {
            (& $script:derive 'FullOS') | Should -BeExactly 'REFRESH'
        }
    }

    Context 'the checkpoint carries it' {

        # THE FIELD IS THE FIX. Without somewhere on the state document for the
        # value to live, "derive only when it is not already known" has nothing
        # to read: state.json is the only thing that crosses the reboot.
        It 'stamps the deployment type onto every state document it mints' {
            foreach ($leg in $script:phase) {
                $state = New-HDTRunState -SequenceId 'REFRESH-01' -RunId 'run-0001' -Phase $leg `
                    -Clock $script:clock -Variable ([ordered] @{}) -Step @()

                $state.PSObject.Properties['deploymentType'] | Should -Not -BeNullOrEmpty
                [string] $state.deploymentType | Should -BeExactly (& $script:derive $leg)
            }
        }

        # A DOCUMENT THE VALIDATOR REFUSES IS A RUN THAT CANNOT RESUME AT ALL.
        # state.schema.json sets additionalProperties false and
        # Assert-HDTRunStateDocument enumerates what it knows, so a new field is
        # a change to the validator or it is a broken document (CLAUDE.md 8).
        It 'writes a document the validator still accepts' {
            $state = New-HDTRunState -SequenceId 'REFRESH-01' -RunId 'run-0001' -Phase FullOS `
                -Clock $script:clock -Variable ([ordered] @{}) -Step @()

            $json = $state | ConvertTo-Json -Depth 8
            $parsed = $json | ConvertFrom-Json

            { InModuleScope Hephaestus -Parameters @{ Document = $parsed } {
                    param($Document)

                    Assert-HDTRunStateDocument -Document $Document -Path 'C:\HDT\state.json'
                } } | Should -Not -Throw
        }
    }

    Context 'a leg that already knows what the run is' {

        # THE WHOLE DEFECT, IN ONE ASSERTION. The leg is WinPE - it would derive
        # NEWCOMPUTER on its own evidence - and the run it is continuing is a
        # REFRESH. The carried value wins, because the run started before this
        # leg did.
        It 'takes the carried value over its own leg' {
            $fact = & $script:gather 'WinPE' 'REFRESH' $null

            [string] $fact['HDTDeploymentType'] | Should -BeExactly 'REFRESH'
        }

        It 'still derives when nothing was carried' {
            foreach ($leg in $script:phase) {
                $fact = & $script:gather $leg '' $null

                [string] $fact['HDTDeploymentType'] | Should -BeExactly (& $script:derive $leg)
            }
        }

        # AND IT DOES NOT PRETEND IT DERIVED IT. Provenance is the one place
        # that says WHERE a value came from; a carried value recorded as
        # 'engine/Phase' would name this leg's phase as the evidence for a value
        # this leg did not decide - which is the sentence an administrator
        # reading X: beside REFRESH needs, told backwards.
        It 'records the checkpoint as the source, not this leg' {
            $bag = @{}
            $null = & $script:gather 'WinPE' 'REFRESH' $bag

            $bag['HDTDeploymentType'].Source | Should -BeExactly 'state'
            $bag['HDTDeploymentType'].Property | Should -BeExactly 'deploymentType'
        }

        It 'says the run decided it on an earlier leg, and which leg this is' {
            $bag = @{}
            $null = & $script:gather 'WinPE' 'REFRESH' $bag

            [string] $bag['HDTDeploymentType'].Reason | Should -Match 'WinPE'
        }

        It 'still records the derivation as the engine when nothing was carried' {
            $bag = @{}
            $null = & $script:gather 'WinPE' '' $bag

            $bag['HDTDeploymentType'].Source | Should -BeExactly 'engine'
            $bag['HDTDeploymentType'].Property | Should -BeExactly 'Phase'
        }
    }

    Context 'the Gather step, which re-gathers mid-sequence' {

        # THE SECOND SURFACE, AND THE ONE THAT WOULD HAVE UNDONE THE FIRST.
        #
        # The payload gathers once before the sequence begins. The Gather STEP
        # gathers again, wherever a sequence puts it - DESIGN 3.2.1 has the facts
        # "refreshed after OS apply", because the machine a sequence finishes on
        # is not the machine it started on. It writes its answers straight into
        # the live variable bag.
        #
        # SO A FIX THAT STOPPED ONLY THE PAYLOAD RE-DERIVING WOULD LAST UNTIL THE
        # FIRST Gather STEP OF THE RESUMED LEG, which would quietly overwrite
        # REFRESH with NEWCOMPUTER and hand the guard the wrong answer - and the
        # log would show a value that had been correct a moment earlier
        # (CLAUDE.md 8: a thing is not added until every surface that must know
        # about it does).
        #
        # THE RUN IS ON THE CONTEXT ALREADY. New-HDTExecutionContext carries the
        # state document, so the step reads what the run says it is rather than
        # deriving from the leg it happens to be on.

        BeforeAll {
            $script:runGather = {
                param([string] $Phase, [string] $DeploymentType)

                $fileSystem = New-HDTFakeFileSystem
                $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $script:clock `
                    -Cim (New-HDTFakeCimProvider -FixturePath $script:cimFixturePath) `
                    -Registry (New-HDTFakeRegistryService) -Environment (New-HDTFakeEnvironmentProvider)

                $log = New-HDTLogContext -RunId 'run-gather' -Phase $Phase -LogPath 'X:\HDT\Logs' `
                    -FileSystem $fileSystem -Clock $script:clock -Level Debug

                $state = New-HDTRunState -SequenceId 'REFRESH-01' -RunId 'run-gather' -Phase $Phase `
                    -Clock $script:clock -Variable ([ordered] @{}) -Step @()

                if (-not [string]::IsNullOrEmpty($DeploymentType)) {
                    $state.deploymentType = $DeploymentType
                }

                $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

                $context = New-HDTExecutionContext -RunId 'run-gather' -Phase $Phase -WorkspaceRoot 'Z:\Deploy' `
                    -Variable $variable -Service $catalog -Log $log -State $state

                $step = [pscustomobject] @{
                    Name            = 'Gather'
                    Type            = 'Gather'
                    Index           = 1
                    GroupPath       = @('Initialization')
                    RunIn           = $Phase
                    Condition       = ''
                    Disabled        = $false
                    ContinueOnError = $false
                    Property        = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                }

                $result = InModuleScope Hephaestus -Parameters @{ Step = $step; Context = $context } {
                    param($Step, $Context)

                    return (Invoke-HDTGatherStep -Step $Step -Context $Context)
                }

                return [pscustomobject] @{ Result = $result; Context = $context }
            }
        }

        It 'does not rename a Refresh when it re-gathers on a WinPE leg' {
            $run = & $script:runGather 'WinPE' 'REFRESH'

            [string] $run.Result.Status | Should -BeExactly 'Completed'
            [string] $run.Context.Variable['HDTDeploymentType'] | Should -BeExactly 'REFRESH'
        }

        It 'still derives from the leg when the run has not said' {
            foreach ($leg in $script:phase) {
                $run = & $script:runGather $leg ''

                [string] $run.Context.Variable['HDTDeploymentType'] | Should -BeExactly (& $script:derive $leg)
            }
        }
    }
}
