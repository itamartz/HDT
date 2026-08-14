# DESIGN 4.4.1's relocation, seen from the loop that owns it.
#
# THE TRIGGER IS ONE DECISION POINT, in the one place that sees every step
# finish, and it fires only when all four of these hold:
#
#   - the context's phase is WinPE;
#   - HDTOSVolume is now non-empty - a step published it;
#   - the log is still on the RAM disk;
#   - the step that just ran reported Completed.
#
# THE STEP DOES NOT DO IT ITSELF, and that is deliberate: a step does not own the
# log context, and a step that reached into it would be the wrong shape.
#
# THE STATE MIRROR RIDES ALONG. DESIGN 4.3 says the state document is "mirrored
# to the target disk's \HDT\ as soon as a formatted volume exists", and
# -MirrorStatePath was until now a literal path the caller had to know in advance
# - which the payload cannot, for the same reason it cannot know a drive letter.
# Same trigger, same information, same place.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:winPeJsonl = 'X:\HDT\Logs\HDT.jsonl'
    $script:targetJsonl = 'W:\HDT\Logs\HDT.jsonl'

    # DEMO-M3's shape without the hardware: step 2 is the one that publishes
    # HDTOSVolume, exactly as Invoke-HDTDiskPartitionStep does - and it publishes
    # the BARE LETTER, which is what the partition step really writes.
    $script:yaml = @'
schemaVersion: 1
id: RELOCATE
name: Relocation
steps:
  - name: Validate the machine
    type: NoOp
  - name: Format and Partition
    type: SetVariable
    variables:
      HDTOSVolume: W
  - name: Apply OS
    type: NoOp
  - name: Prepare Boot
    type: NoOp
'@

    # HDTOSVolume already set, so the only thing left to decide is whether the
    # step that just ran succeeded.
    $script:failingYaml = @'
schemaVersion: 1
id: RELOCATE-FAIL
name: Relocation after a failure
steps:
  - name: A step that fails
    type: CommandLine
    command: nothing-seeded-this.exe
'@

    $script:runLeg = {
        param([hashtable] $Argument)

        $harnessArgument = @{ Yaml = $script:yaml }
        $loopArgument = @{}

        if ($null -ne $Argument) {
            foreach ($key in @($Argument.Keys)) {
                if (@('Yaml', 'Phase', 'Variable', 'FileSystem') -contains $key) {
                    $harnessArgument[$key] = $Argument[$key]
                } else {
                    $loopArgument[$key] = $Argument[$key]
                }
            }
        }

        $harness = New-HDTSequenceTestHarness @harnessArgument
        $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context `
            -State $harness.State @loopArgument

        return [pscustomobject] @{ Harness = $harness; Result = $result }
    }

    $script:recordOf = {
        param([object] $FileSystem, [string] $Path)

        if (-not $FileSystem.TestPath($Path)) { return @() }

        return @(Get-HDTLogRecord -FileSystem $FileSystem -Path $Path)
    }
}

Describe 'Invoke-HDTTaskSequence, the log relocation' {

    Context 'the trigger' {

        BeforeAll {
            $script:leg = & $script:runLeg $null
            $script:old = @(& $script:recordOf $script:leg.Harness.FileSystem $script:winPeJsonl)
            $script:new = @(& $script:recordOf $script:leg.Harness.FileSystem $script:targetJsonl)
        }

        It 'runs the whole leg' {
            $script:leg.Result.Status | Should -BeExactly 'Succeeded'
        }

        It 'relocates after the step that publishes HDTOSVolume' {
            $script:leg.Harness.Log.LogPath | Should -BeExactly 'W:\HDT\Logs'
            $script:leg.Harness.FileSystem.TestPath($script:targetJsonl) | Should -BeTrue
        }

        It 'does not relocate before it' {
            # After step 1 the log is still on X:, so step 1's completion is in
            # the RAM-disk file.
            @($script:old | Where-Object { $_.event -eq 'step.complete' } |
                    ForEach-Object { [int] $_.data.index }) | Should -Be @(1, 2)
        }

        It 'writes every later record to the new path only' {
            @($script:new | Where-Object { $_.event -eq 'step.complete' } |
                    ForEach-Object { [int] $_.data.index }) | Should -Be @(1, 2, 3, 4)

            @($script:old | Where-Object { $_.event -eq 'run.end' }) | Should -BeNullOrEmpty
            @($script:new | Where-Object { $_.event -eq 'run.end' }).Count | Should -Be 1
        }

        It 'relocates exactly once across the leg' {
            @($script:new | Where-Object { [string] $_.message -like '*_HDTLogPath*' }).Count | Should -Be 1
        }

        It 'keeps seq continuous across the relocation' {
            # THIS IS THE ASSERTION THAT MATTERS. DESIGN 4.4.2 exists because
            # timestamps skew; a relocation that reset the counter would break
            # the one ordering that is trustworthy.
            $seq = @($script:new | ForEach-Object { [int] $_.seq })
            $lastBefore = [int] $script:old[-1].seq
            $firstAfter = [int] @($script:new | Where-Object { [string] $_.message -like '*_HDTLogPath*' })[0].seq

            $firstAfter | Should -Be ($lastBefore + 1) `
                -Because ("the RAM disk log ends at seq {0} and the first record on the target volume is seq {1}" -f $lastBefore, $firstAfter)

            $seq | Should -Be @(1..$seq.Count) `
                -Because ("the relocated log's seq numbers were: {0}" -f ($seq -join ', '))
        }

        It 'moves the status heartbeat with the log' {
            # DESIGN 4.4.6's status.json lives IN the log directory, and the
            # copy-back ships that directory. A heartbeat left behind on the RAM
            # disk would put a stale 'Running' in the copy the technician reads
            # while the live one died with the reboot.
            $status = ConvertFrom-Json -InputObject ($script:leg.Harness.FileSystem.ReadAllText('W:\HDT\Logs\status.json'))

            [string] $status.status | Should -BeExactly 'Succeeded'
        }

        It 'leaves an explicitly supplied -StatusPath alone' {
            $leg = & $script:runLeg @{ StatusPath = 'Y:\heartbeat.json' }

            $leg.Harness.FileSystem.TestPath('Y:\heartbeat.json') | Should -BeTrue
            $leg.Harness.FileSystem.TestPath('W:\HDT\Logs\status.json') | Should -BeFalse
        }

        It 'sets _HDTLogPath to the relocated path' {
            [string] $script:leg.Harness.Variable['_HDTLogPath'] | Should -BeExactly 'W:\HDT\Logs'
        }

        It 'carries _HDTLogPath into the state document' {
            [string] $script:leg.Result.State.variable['_HDTLogPath'] | Should -BeExactly 'W:\HDT\Logs'
        }
    }

    Context 'when it must not fire' {

        It 'does not relocate in the FullOS phase' {
            # In the full OS the target volume IS the system volume, and
            # Get-HDTLogPath ignores a -TargetVolume there rather than pointing
            # the logs at a letter that no longer means what it meant in WinPE.
            $leg = & $script:runLeg @{ Phase = 'FullOS' }

            $leg.Harness.Log.LogPath | Should -BeExactly 'X:\HDT\Logs'
            $leg.Harness.FileSystem.TestPath($script:targetJsonl) | Should -BeFalse
        }

        It 'does not relocate when HDTOSVolume is empty' {
            $yaml = @'
schemaVersion: 1
id: NO-VOLUME
name: Nothing published a volume
steps:
  - name: Validate the machine
    type: NoOp
  - name: Apply OS
    type: NoOp
'@

            $leg = & $script:runLeg @{ Yaml = $yaml }

            $leg.Result.Status | Should -BeExactly 'Succeeded'
            $leg.Harness.Log.LogPath | Should -BeExactly 'X:\HDT\Logs'
        }

        It 'does not relocate after a step that failed' {
            # HDTOSVolume is set from the start, so the ONLY thing standing
            # between this run and a relocation is that the step failed.
            $leg = & $script:runLeg @{ Yaml = $script:failingYaml; Variable = @{ HDTOSVolume = 'W' } }

            $leg.Result.Status | Should -BeExactly 'Failed'
            $leg.Harness.Log.LogPath | Should -BeExactly 'X:\HDT\Logs'
            $leg.Harness.FileSystem.TestPath($script:targetJsonl) | Should -BeFalse
        }
    }

    Context 'the copy-back' {

        It 'copies back from the relocated path at the end' {
            # <share>\Logs\<name>-<runId> holds the WHOLE run, not the half of it
            # that happened before the disk existed.
            $leg = & $script:runLeg @{ LogDestination = 'Z:\Deploy\Logs' }

            $copied = @($leg.Harness.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' -and
                        ([string] $_.Arguments[1]) -like 'Z:\Deploy\Logs\*' } |
                    ForEach-Object { [string] $_.Arguments[0] })

            $copied.Count | Should -BeGreaterThan 0
            @($copied | Where-Object { $_ -notlike 'W:\HDT\Logs\*' }) | Should -BeNullOrEmpty `
                -Because ('the copy-back read from: {0}' -f ($copied -join ', '))
        }
    }

    Context 'the state mirror' {

        It 'sets the state mirror to the target volume when the log relocates' {
            $leg = & $script:runLeg $null

            $leg.Harness.FileSystem.TestPath('W:\HDT\state.json') | Should -BeTrue
        }

        It 'writes the mirrored state at the next checkpoint' {
            $leg = & $script:runLeg $null

            $mirror = ConvertFrom-Json -InputObject ($leg.Harness.FileSystem.ReadAllText('W:\HDT\state.json'))

            [string] $mirror.status | Should -BeExactly 'Succeeded'
            @($mirror.step | Where-Object { [int] $_.index -eq 4 })[0].status | Should -BeExactly 'Completed'
        }

        It 'leaves an explicitly supplied -MirrorStatePath alone' {
            # A caller who said where it goes is not overruled, and every
            # existing resume test keeps its meaning.
            $leg = & $script:runLeg @{ MirrorStatePath = 'Y:\HDT\state.json' }

            $leg.Harness.FileSystem.TestPath('Y:\HDT\state.json') | Should -BeTrue
            $leg.Harness.FileSystem.TestPath('W:\HDT\state.json') | Should -BeFalse
        }

        It 'leaves an explicitly supplied -StatePath alone' {
            # A caller who said where the state document goes is not overruled,
            # exactly as with -MirrorStatePath and -StatusPath.
            $leg = & $script:runLeg @{ StatePath = 'Y:\somewhere\state.json' }

            $leg.Harness.FileSystem.TestPath('Y:\somewhere\state.json') | Should -BeTrue
            $leg.Harness.FileSystem.TestPath('W:\HDT\Logs\state.json') | Should -BeFalse
        }
    }

    Context 'the state document inside the log directory' {

        # THE DEFECT THE FIRST REAL M4 RUN FOUND, and the M3 E2E found it in the
        # same run - 05-03 added the relocation and SPIKES S10 stopped anybody
        # running -Task e2e afterwards, so it sat unproven for two plans.
        #
        # By default the state document lives IN the log directory. The
        # relocation MIRRORS THE WHOLE LOG TREE, so a copy of state.json arrives
        # on the target volume - and if the writes keep going to the RAM disk
        # that copy is FROZEN at the moment of the move. Copy-HDTLog then ships
        # the relocated directory to the share, so the state document a
        # technician reads reports three steps Pending on a deployment that
        # succeeded. A stale document is worse than an absent one, because it is
        # believed.
        #
        # DESIGN 4.4.6's heartbeat was moved for exactly this reason and in
        # exactly this place; the state document was not, and nothing on the RAM
        # disk survives the reboot to make keeping it there worth anything.

        It 'moves the state document with the log' {
            $leg = & $script:runLeg $null

            $leg.Harness.FileSystem.TestPath('W:\HDT\Logs\state.json') | Should -BeTrue
        }

        It 'keeps writing it after the relocation' {
            # THE ASSERTION THAT BITES. The mirrored copy exists either way; what
            # a stale one cannot say is that step 4 completed, because step 4 ran
            # after the move.
            $leg = & $script:runLeg $null

            $document = ConvertFrom-Json -InputObject ($leg.Harness.FileSystem.ReadAllText('W:\HDT\Logs\state.json'))

            [string] $document.status | Should -BeExactly 'Succeeded'
            @($document.step | ForEach-Object { [string] $_.status }) |
                Should -Be @('Completed', 'Completed', 'Completed', 'Completed')
        }

        It 'leaves the RAM disk copy behind rather than deleting it' {
            # The same bargain the log itself makes: everything written so far
            # was mirrored and the copy on X: is left in place. It dies with the
            # RAM disk, which is why it is not the one that matters.
            $leg = & $script:runLeg $null

            $leg.Harness.FileSystem.TestPath($leg.Harness.StatePath) | Should -BeTrue
        }
    }
}
