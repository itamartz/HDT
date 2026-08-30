# <share>\Logs\_active\<RunId>.json AT THE END OF EVERY KIND OF RUN.
#
# The marker is written every step so a console watching the share can see a
# machine working - MDT's SLShareDynamicLogging. It is also THE ONE ARTIFACT
# THAT SURVIVES A PRUNED LOG TREE, which has happened twice on this lab's share:
# both times the marker was all that was left of a deployment.
#
# So it has to agree with status.json when the run stops, whatever stopped it. A
# marker frozen at 'Running' does not just lose a fact - it makes a run that
# FAILED indistinguishable from one still in flight, which is the one distinction
# anybody reads it for.
#
# THE SET, NOT THE ONE CASE. Every way a run can end gets a row here:
#
#   Succeeded       the loop ran out of steps
#   Failed          a step failed and did not declare continueOnError
#   Failed          the engine itself threw - the reboot ceremony, a checkpoint
#   RebootPending   the run is NOT over; the marker must say so, because the
#                   machine is coming back and a console must not draw it as gone
#
# WHAT IS NOT COVERED, AND SAID RATHER THAN PRETENDED: a hard power loss, or a
# process killed outright. No code runs, so no marker is written, and the file
# keeps whatever the last completed step put there. That staleness is honest -
# it is a machine that stopped without warning, and the `updated` timestamp is
# what says so. Staleness because a code path forgot to write is not, and that
# is what this file is about.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:shareLogRoot = 'X:\Share\Logs'
    $script:activePath = '{0}\_active\run-0001.json' -f $script:shareLogRoot
    $script:statusPath = 'X:\HDT\Logs\status.json'

    # Runs one sequence to its end with a share to mirror to, and hands back both
    # documents so they can be compared with each other rather than with a
    # literal - "the marker agrees with status.json" is the actual requirement.
    $script:runToEnd = {
        param([string] $Yaml, [hashtable] $Variable, [object] $Lsa)

        $argument = @{ Yaml = $Yaml; Phase = 'FullOS' }
        if ($null -ne $Variable) { $argument['Variable'] = $Variable }
        if ($null -ne $Lsa) { $argument['Lsa'] = $Lsa }

        $harness = New-HDTSequenceTestHarness @argument

        $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context `
            -State $harness.State -LogDestination $script:shareLogRoot

        $marker = $null
        if ($harness.FileSystem.TestPath($script:activePath)) {
            $marker = $harness.FileSystem.ReadAllText($script:activePath) | ConvertFrom-Json
        }

        $status = $null
        if ($harness.FileSystem.TestPath($script:statusPath)) {
            $status = $harness.FileSystem.ReadAllText($script:statusPath) | ConvertFrom-Json
        }

        return [pscustomobject] @{
            Harness = $harness
            Result  = $result
            Marker  = $marker
            Status  = $status
        }
    }

    $script:succeedYaml = @'
schemaVersion: 1
id: MARKER-OK
name: A run that finishes
steps:
  - name: First
    type: NoOp
  - name: Second
    type: NoOp
'@

    $script:failYaml = @'
schemaVersion: 1
id: MARKER-FAIL
name: A run with a step that fails
steps:
  - name: First
    type: NoOp
  - name: The one that fails
    type: NoOp
    fail: true
  - name: Never reached
    type: NoOp
'@

    $script:rebootYaml = @'
schemaVersion: 1
id: MARKER-REBOOT
name: A run that stops for a reboot
steps:
  - name: First
    type: NoOp
  - name: Restart
    type: Restart
  - name: After the reboot
    type: NoOp
'@
}

Describe 'the _active marker at the end of a run' {

    Context 'a run that succeeded' {

        BeforeAll { $script:run = & $script:runToEnd $script:succeedYaml $null $null }

        It 'ends Succeeded' {
            $script:run.Result.Status | Should -BeExactly 'Succeeded'
        }

        It 'leaves a marker' {
            $script:run.Marker | Should -Not -BeNullOrEmpty
        }

        It 'agrees with status.json about the outcome' {
            $script:run.Marker.status | Should -BeExactly $script:run.Status.status
            $script:run.Marker.status | Should -BeExactly 'Succeeded'
        }

        It 'agrees with status.json about the step it reached' {
            $script:run.Marker.stepIndex | Should -Be $script:run.Status.stepIndex
            $script:run.Marker.stepName | Should -BeExactly $script:run.Status.stepName
        }

        It 'agrees with status.json about when it was updated' {
            # The two are one document written to two paths. A marker with an
            # older timestamp is a marker that stopped being written.
            $script:run.Marker.updated | Should -BeExactly $script:run.Status.updated
        }
    }

    Context 'a run whose step failed' {

        BeforeAll { $script:run = & $script:runToEnd $script:failYaml $null $null }

        It 'ends Failed' {
            $script:run.Result.Status | Should -BeExactly 'Failed'
        }

        It 'says Failed on the marker, not Running' {
            # THE ONE THAT MATTERS. A marker left at Running makes a dead run
            # look like a live one.
            $script:run.Marker | Should -Not -BeNullOrEmpty
            $script:run.Marker.status | Should -BeExactly 'Failed'
            $script:run.Marker.status | Should -BeExactly $script:run.Status.status
        }

        It 'names the step it died on rather than the last one attempted' {
            $script:run.Marker.stepName | Should -BeExactly 'The one that fails'
            $script:run.Marker.stepIndex | Should -Be $script:run.Status.stepIndex
        }

        It 'agrees with status.json about when it was updated' {
            $script:run.Marker.updated | Should -BeExactly $script:run.Status.updated
        }
    }

    Context 'a run the engine itself failed' {

        BeforeAll {
            # The reboot ceremony throwing, which is how run-20260830-204613
            # ended: no step reported a failure, the engine did.
            $brokenLsa = [pscustomobject] @{ Inner = New-HDTFakeLsaService; ServiceName = 'LsaService' }
            $brokenLsa | Add-Member -MemberType ScriptProperty -Name Operations -Value { $this.Inner.Operations }
            $brokenLsa | Add-Member -MemberType ScriptProperty -Name Journal `
                -Value { $this.Inner.Journal } -SecondValue { $this.Inner.Journal = $args[0] }
            $brokenLsa | Add-Member -MemberType ScriptMethod -Name GetSecret -Value {
                param([string] $Name) return $this.Inner.GetSecret($Name)
            }
            $brokenLsa | Add-Member -MemberType ScriptMethod -Name RemoveSecret -Value {
                param([string] $Name) $this.Inner.RemoveSecret($Name)
            }
            $brokenLsa | Add-Member -MemberType ScriptMethod -Name SetSecret -Value {
                param([string] $Name, [string] $Value)
                throw [System.ArgumentException]::new('the LSA refused')
            }

            $script:run = & $script:runToEnd $script:rebootYaml @{ HDTAdminPassword = 'Set-By-The-Rules-1' } $brokenLsa
        }

        It 'ends Failed' {
            $script:run.Result.Status | Should -BeExactly 'Failed'
        }

        It 'says Failed on the marker' {
            $script:run.Marker | Should -Not -BeNullOrEmpty
            $script:run.Marker.status | Should -BeExactly 'Failed'
        }

        It 'agrees with status.json' {
            $script:run.Marker.status | Should -BeExactly $script:run.Status.status
            $script:run.Marker.updated | Should -BeExactly $script:run.Status.updated
        }
    }

    Context 'a run that stopped for a reboot' {

        BeforeAll {
            $script:run = & $script:runToEnd $script:rebootYaml @{ HDTAdminPassword = 'Set-By-The-Rules-1' } $null
        }

        It 'ends RebootPending' {
            $script:run.Result.Status | Should -BeExactly 'RebootPending'
        }

        It 'keeps a marker, because the machine is coming back' {
            # NOT swept and NOT a verdict. A console that lost this row would
            # draw a restarting machine as gone for the minutes it takes to
            # return.
            $script:run.Marker | Should -Not -BeNullOrEmpty
            $script:run.Marker.status | Should -BeExactly 'RebootPending'
        }

        It 'agrees with status.json' {
            $script:run.Marker.status | Should -BeExactly $script:run.Status.status
        }
    }

    Context 'the transition is logged' {

        BeforeAll {
            $script:run = & $script:runToEnd $script:failYaml $null $null
            $script:statusRecord = @(Get-HDTLogRecord -FileSystem $script:run.Harness.FileSystem `
                    -Path $script:run.Harness.Log.JsonlPath | Where-Object { $_.component -eq 'Status' })
        }

        It 'writes a record for the terminal status' {
            # A marker that disagrees with status.json is otherwise a question
            # with nothing in the log to answer it.
            @($script:statusRecord | Where-Object { $_.data.status -eq 'Failed' }).Count |
                Should -BeGreaterThan 0
        }

        It 'says at Info, not Debug, because an admin needs it to read the outcome' {
            $terminal = @($script:statusRecord | Where-Object { $_.data.status -eq 'Failed' })[-1]

            $terminal.level | Should -BeExactly 'Info'
        }

        It 'says where both copies went and whether the mirror landed' {
            $terminal = @($script:statusRecord | Where-Object { $_.data.status -eq 'Failed' })[-1]

            $terminal.data.path | Should -Not -BeNullOrEmpty
            $terminal.data.activePath | Should -BeExactly $script:activePath
            $terminal.data.mirrored | Should -BeTrue
        }
    }
}
