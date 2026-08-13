# DESIGN 4.3's state document, in memory. New-HDTRunState builds it; only
# Save-HDTRunState writes it, which is why this function has no -FileSystem
# parameter at all.
#
# Every timestamp in the document is a formatted STRING, never a [datetime]:
# ConvertTo-Json renders a raw [datetime] as "\/Date(...)\/" under Windows
# PowerShell 5.1, and 5.1 is the engine that writes this file in WinPE.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTRunState' {

    BeforeEach {
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc))
        $script:step = @(
            @{ Index = 1; Name = 'Validate'; Type = 'Validate'; Group = @('Preinstall'); Resumable = $false }
            @{ Index = 2; Name = 'Restart'; Type = 'Restart'; Group = @('Preinstall'); Resumable = $true }
            @{ Index = 3; Name = 'Apply OS'; Type = 'ApplyImage'; Group = @('Install', 'Imaging'); Resumable = $false }
        )
        $script:state = New-HDTRunState -SequenceId 'STD-CLIENT' -RunId '8f3c1a90' -Phase WinPE `
            -Clock $script:clock -Step $script:step `
            -Variable ([ordered] @{ HDTComputerName = 'PC-0001'; HDTDriverGroup = 'Latitude 7450' })
    }

    It 'declares schemaVersion 1' {
        $script:state.schemaVersion | Should -Be 1
    }

    It 'records the sequence id and run id' {
        $script:state.sequenceId | Should -BeExactly 'STD-CLIENT'
        $script:state.runId | Should -BeExactly '8f3c1a90'
    }

    It 'records the phase' {
        $script:state.phase | Should -BeExactly 'WinPE'
    }

    It 'starts at step index one' {
        # stepIndex is the 1-based index of the NEXT step to run.
        $script:state.stepIndex | Should -Be 1
    }

    It 'starts at leg one' {
        $script:state.leg | Should -Be 1
    }

    It 'starts with status Running' {
        $script:state.status | Should -BeExactly 'Running'
    }

    It 'starts with seq zero' {
        $script:state.seq | Should -Be 0
    }

    It 'stamps startedUtc from the injected clock' {
        $script:state.startedUtc | Should -BeExactly '2026-08-13T00:11:02.4810000Z'
    }

    It 'stamps updatedUtc from the injected clock' {
        $script:state.updatedUtc | Should -BeExactly '2026-08-13T00:11:02.4810000Z'
    }

    It 'formats both timestamps as strings' {
        $script:state.startedUtc | Should -BeOfType ([string])
        $script:state.updatedUtc | Should -BeOfType ([string])
    }

    It 'reads the time only through the injected clock' {
        $script:clock.GetOperationName() | Should -Be @('GetUtcNow')
    }

    It 'copies the variables it was given' {
        $script:state.variable['HDTComputerName'] | Should -BeExactly 'PC-0001'
        $script:state.variable['HDTDriverGroup'] | Should -BeExactly 'Latitude 7450'
    }

    It 'stores variables case-insensitively' {
        $script:state.variable['hdtcomputername'] | Should -BeExactly 'PC-0001'
    }

    It 'keeps the variables in the order they were given' {
        @($script:state.variable.Keys) | Should -Be @('HDTComputerName', 'HDTDriverGroup')
    }

    It 'starts with an empty variable set when none is given' {
        $bare = New-HDTRunState -SequenceId 'STD-CLIENT' -RunId 'r1' -Phase WinPE -Clock $script:clock

        @($bare.variable.Keys).Count | Should -Be 0
    }

    It 'marks every step Pending' {
        @($script:state.step | ForEach-Object { $_.status }) | Should -Be @('Pending', 'Pending', 'Pending')
    }

    It 'copies the index, name, type and group of every step' {
        @($script:state.step | ForEach-Object { $_.index }) | Should -Be @(1, 2, 3)
        @($script:state.step | ForEach-Object { $_.name }) | Should -Be @('Validate', 'Restart', 'Apply OS')
        @($script:state.step | ForEach-Object { $_.type }) | Should -Be @('Validate', 'Restart', 'ApplyImage')
        @($script:state.step[2].group) | Should -Be @('Install', 'Imaging')
    }

    It 'takes the group path off a REAL flattened step' {
        # The dictionaries above say Group because a test wrote them.
        # Import-HDTSequenceDocument says GroupPath, and it is the only thing
        # that ever builds a step list in production - so a document built from
        # one has to carry the group path too, or the state's group array (and
        # every report column rendered from it) is empty on every real run.
        $yaml = @'
schemaVersion: 1
id: GROUPED
name: A grouped sequence
steps:
  - group: Install
    steps:
      - group: Imaging
        steps:
          - name: Apply OS
            type: NoOp
'@
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\sequence.yaml' = $yaml }
        $sequence = Import-HDTSequenceDocument -Path 'C:\ws\sequence.yaml' -FileSystem $fs

        $state = New-HDTRunState -SequenceId $sequence.Id -RunId 'r1' -Phase WinPE `
            -Clock $script:clock -Step $sequence.Step -Variable ([ordered] @{})

        @($state.step[0].group) | Should -Be @('Install', 'Imaging')
    }

    It 'carries the resumable flag of every step' {
        @($script:state.step | ForEach-Object { $_.resumable }) | Should -Be @($false, $true, $false)
    }

    It 'starts with attempt zero on every step' {
        @($script:state.step | ForEach-Object { $_.attempt }) | Should -Be @(0, 0, 0)
    }

    It 'starts every step with no result recorded' {
        $script:state.step[0].startedUtc | Should -BeNullOrEmpty
        $script:state.step[0].endedUtc | Should -BeNullOrEmpty
        $script:state.step[0].durationMs | Should -BeNullOrEmpty
        $script:state.step[0].exitCode | Should -BeNullOrEmpty
        $script:state.step[0].message | Should -BeNullOrEmpty
    }

    It 'accepts an empty step list' {
        $bare = New-HDTRunState -SequenceId 'STD-CLIENT' -RunId 'r1' -Phase WinPE -Clock $script:clock

        @($bare.step).Count | Should -Be 0
    }

    It 'accepts steps supplied as objects rather than dictionaries' {
        # 03-02's flattener emits objects; a state document must not care.
        $fromObject = New-HDTRunState -SequenceId 'STD-CLIENT' -RunId 'r1' -Phase WinPE -Clock $script:clock `
            -Step @([pscustomobject] @{ Index = 1; Name = 'Validate'; Type = 'Validate'; Group = @('Preinstall'); Resumable = $true })

        $fromObject.step[0].name | Should -BeExactly 'Validate'
        $fromObject.step[0].resumable | Should -BeTrue
    }

    It 'starts with autologon not armed' {
        $script:state.autoLogon.armed | Should -BeFalse
    }

    It 'starts with a null deployment password' {
        $script:state.deploymentPassword | Should -BeNullOrEmpty
    }

    It 'defaults pauseOnError to false' {
        $script:state.pauseOnError | Should -BeFalse
    }

    It 'honours -PauseOnError' {
        $paused = New-HDTRunState -SequenceId 'STD-CLIENT' -RunId 'r1' -Phase WinPE -Clock $script:clock -PauseOnError

        $paused.pauseOnError | Should -BeTrue
    }

    It 'reads no file' {
        # A state document is built in memory; only Save-HDTRunState writes.
        (Get-Command -Name New-HDTRunState).Parameters.ContainsKey('FileSystem') | Should -BeFalse
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name New-HDTRunState -ErrorAction Stop

        $help.Name | Should -BeExactly 'New-HDTRunState'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
