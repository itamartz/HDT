# WinPE-side resume discovery (DESIGN 4.5.3).
#
# THE ONE THAT STOPS A CAPTURE LEG REPARTITIONING THE DISK IT JUST SEALED.
#
# Invoke-HDTTaskSequence has always survived the WinPE -> FullOS reboot. The
# other direction had nothing at all: Start-HDTDeployment.ps1 minted a NEW run
# at step 1 on every WinPE boot, so a machine that rebooted into WinPE
# mid-sequence - which is exactly what a Sysprep-and-Capture reference build
# does - would have run its DiskPartition step against the volume it had just
# generalized.
#
# THE ANSWER IS A SCAN, NOT A BOOT FLAG. bcdedit /bootsequence is a TRANSPORT:
# it decides which image the firmware loads and is consumed before one line of
# HDT runs, so the booted WinPE cannot ask whether it arrived that way. MDT
# knows this, which is why MDT ALSO keeps C:\MININT and looks for it. A machine
# that reached WinPE by PXE, by an ISO left in the drive or by a technician
# pressing F12 must reach the same answer, and a transport-keyed check answers
# correctly for one of those and formats the disk for the other three.
#
# AND IT IS A THREE-WAY, WHICH IS THE WHOLE SAFETY PROPERTY.
# Invoke-HDTBootReconciliation is a two-way - Resume or Teardown - and that is
# right in the full OS, where the worst case of guessing wrong is a machine
# that does not autologon. In WinPE "Teardown" means "mint a new run", which
# means FORMAT. So anything this cannot read, cannot parse, or finds twice is
# Ambiguous, and Ambiguous refuses rather than guessing.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:now = [datetime]::new(2026, 8, 30, 12, 0, 0, [System.DateTimeKind]::Utc)

    # A state document exactly as Save-HDTRunState writes it. The fields this
    # command reads are set explicitly; the rest are here because
    # Assert-HDTRunStateDocument requires them.
    $script:stateJson = {
        param(
            [string] $Status = 'Running',
            [datetime] $UpdatedUtc = $script:now,
            [int] $StepIndex = 9,
            [string] $Phase = 'FullOS',
            [string] $RunId = 'run-20260830-090000'
        )

        $document = [ordered] @{
            schemaVersion = 1
            runId         = $RunId
            sequenceId    = 'REFERENCE'
            status        = $Status
            phase         = $Phase
            leg           = 2
            seq           = 412
            logLevel      = 'Info'
            startedUtc    = '2026-08-30T09:00:00.0000000Z'
            updatedUtc    = $UpdatedUtc.ToUniversalTime().ToString('o')
            stepIndex     = $StepIndex
            pauseOnError  = $false
            variable      = @{ HDTOSVolume = 'W' }
            step          = @()
            autoLogon     = [ordered] @{
                armed       = $false
                userName    = $null
                domainName  = $null
                countSet    = 0
                secretName  = $null
                runOnceName = $null
            }
        }

        return (ConvertTo-Json -InputObject $document -Depth 8)
    }

    # A disk service reporting the volumes a WinPE leg would see after the OS
    # has been laid down: the RAM disk, the ESP and the Windows volume.
    $script:diskWith = {
        param([string[]] $Letter)

        New-HDTFakeDiskService -Volume @(
            @($Letter | ForEach-Object {
                    [pscustomobject] @{
                        DriveLetter        = $_
                        FileSystem         = 'NTFS'
                        FileSystemLabel    = ''
                        SizeBytes          = 100GB
                        SizeRemainingBytes = 60GB
                    }
                })
        )
    }

    $script:call = {
        param([object] $Disk, [object] $FileSystem, [int] $MaxAgeHour = 12)

        $argument = @{
            Disk       = $Disk
            FileSystem = $FileSystem
            Clock      = (New-HDTFakeClock -UtcNow $script:now)
        }
        if ($PSBoundParameters.ContainsKey('MaxAgeHour')) { $argument['MaxAgeHour'] = $MaxAgeHour }

        return (Get-HDTResumeCandidate @argument)
    }
}

Describe 'Get-HDTResumeCandidate' {

    Context 'when no volume carries a state document' {

        # THE ORDINARY PATH, AND IT MUST NOT BREAK. Every deployment that has
        # ever worked arrives here: a machine with a raw disk, or one whose
        # previous run was cleaned up. It gets None, and None is what lets
        # Start-HDTDeployment go on to mint a run and partition.
        It 'answers None' {
            $disk = & $script:diskWith @('X', 'W')
            $fileSystem = New-HDTFakeFileSystem

            $decision = & $script:call $disk $fileSystem

            $decision.Action | Should -Be 'None'
        }

        It 'says so in the reason' {
            $decision = & $script:call (& $script:diskWith @('X', 'W')) (New-HDTFakeFileSystem)

            $decision.Reason | Should -Match 'no run'
        }

        It 'returns no state' {
            $decision = & $script:call (& $script:diskWith @('X', 'W')) (New-HDTFakeFileSystem)

            $decision.State | Should -BeNullOrEmpty
        }
    }

    Context 'when exactly one volume carries a live run' {

        BeforeEach {
            $script:liveDisk = & $script:diskWith @('X', 'S', 'W')
            $script:liveFileSystem = New-HDTFakeFileSystem -File @{
                'W:\HDT\state.json' = (& $script:stateJson)
            }
        }

        It 'answers Resume' {
            $decision = & $script:call $script:liveDisk $script:liveFileSystem

            $decision.Action | Should -Be 'Resume'
        }

        It 'returns the state it read' {
            $decision = & $script:call $script:liveDisk $script:liveFileSystem

            $decision.State.runId | Should -Be 'run-20260830-090000'
            $decision.State.stepIndex | Should -Be 9
        }

        # THE PATH IS PART OF THE ANSWER, because the resumed leg has to keep
        # WRITING to the document it resumed from. A leg that read W:\HDT\state.json
        # and then checkpointed to X:\HDT\Logs\state.json would leave the durable
        # copy frozen at the moment of the resume - which is the stale-state
        # failure 05-03 already cost a lab run.
        It 'names the document it found' {
            $decision = & $script:call $script:liveDisk $script:liveFileSystem

            $decision.Path | Should -Be 'W:\HDT\state.json'
        }
    }

    Context 'when the run on disk has already finished' {

        # A DEPLOYED MACHINE BEING REDEPLOYED. Its last run left a state
        # document behind saying Succeeded, and the operator has booted the
        # media again on purpose. That is a new deployment, and refusing it
        # would make every second deployment of a machine impossible.
        It 'answers None for Succeeded' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                'W:\HDT\state.json' = (& $script:stateJson -Status 'Succeeded')
            }

            (& $script:call (& $script:diskWith @('X', 'W')) $fileSystem).Action | Should -Be 'None'
        }

        It 'answers None for Failed' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                'W:\HDT\state.json' = (& $script:stateJson -Status 'Failed')
            }

            (& $script:call (& $script:diskWith @('X', 'W')) $fileSystem).Action | Should -Be 'None'
        }
    }

    Context 'when the state document cannot be trusted' {

        # THE HALF-WRITTEN FILE. Save-HDTRunState is the only writer; a machine
        # that lost power mid-write leaves truncated JSON. ConvertFrom-Json
        # throws, and THAT MUST NOT BECOME "no run in progress" - which is the
        # reading that formats the disk. Import-HDTRunState's own message
        # already argues it: "A run with no state document starts from the
        # beginning; one that cannot be read does not."
        It 'answers Ambiguous for truncated JSON' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                'W:\HDT\state.json' = '{ "schemaVersion": 1, "runId": "run-2026'
            }

            (& $script:call (& $script:diskWith @('X', 'W')) $fileSystem).Action | Should -Be 'Ambiguous'
        }

        It 'answers Ambiguous for JSON that is not a state document' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                'W:\HDT\state.json' = '{ "hello": "world" }'
            }

            (& $script:call (& $script:diskWith @('X', 'W')) $fileSystem).Action | Should -Be 'Ambiguous'
        }

        It 'names the file in the reason, so a technician knows what to delete' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                'W:\HDT\state.json' = '{ "schemaVersion": 1, "runId": "run-2026'
            }

            (& $script:call (& $script:diskWith @('X', 'W')) $fileSystem).Reason |
                Should -Match ([regex]::Escape('W:\HDT\state.json'))
        }

        It 'returns no state, so nothing downstream can act on a half-read one' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                'W:\HDT\state.json' = '{ "hello": "world" }'
            }

            (& $script:call (& $script:diskWith @('X', 'W')) $fileSystem).State | Should -BeNullOrEmpty
        }
    }

    Context 'when two volumes each carry a live run' {

        # A MACHINE WITH TWO WINDOWS INSTALLATIONS, or one whose previous
        # deployment left a document on a second disk. There is no way to tell
        # which run this boot belongs to, and picking one has a fifty per cent
        # chance of resuming somebody else's deployment onto this disk.
        BeforeEach {
            $script:twoFileSystem = New-HDTFakeFileSystem -File @{
                'W:\HDT\state.json' = (& $script:stateJson -RunId 'run-20260830-090000')
                'D:\HDT\state.json' = (& $script:stateJson -RunId 'run-20260830-100000')
            }
        }

        It 'answers Ambiguous' {
            (& $script:call (& $script:diskWith @('X', 'W', 'D')) $script:twoFileSystem).Action |
                Should -Be 'Ambiguous'
        }

        It 'names both, so the operator can see what it found' {
            $reason = (& $script:call (& $script:diskWith @('X', 'W', 'D')) $script:twoFileSystem).Reason

            $reason | Should -Match ([regex]::Escape('W:\HDT\state.json'))
            $reason | Should -Match ([regex]::Escape('D:\HDT\state.json'))
        }
    }

    Context 'when the run on disk is stale' {

        # THE ONE PLACE THIS DELIBERATELY DIVERGES FROM
        # Invoke-HDTBootReconciliation, and it is worth stating plainly.
        #
        # In the full OS a stale run is torn down: the worst case of being
        # wrong is a machine that does not log itself on. In WinPE the same
        # reading means "start a new deployment", which means FORMAT - and an
        # abandoned run and a live one are indistinguishable to a clock that
        # has skewed, which SPIKES records WinPE's doing.
        #
        # So a stale document in WinPE is a question for a person, and the
        # person answers it by deleting the one file the message names.
        It 'answers Ambiguous rather than starting a new deployment' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                'W:\HDT\state.json' = (& $script:stateJson -UpdatedUtc $script:now.AddHours(-40))
            }

            (& $script:call (& $script:diskWith @('X', 'W')) $fileSystem).Action | Should -Be 'Ambiguous'
        }

        It 'resumes one that is inside the window' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                'W:\HDT\state.json' = (& $script:stateJson -UpdatedUtc $script:now.AddHours(-2))
            }

            (& $script:call (& $script:diskWith @('X', 'W')) $fileSystem).Action | Should -Be 'Resume'
        }

        It 'honours -MaxAgeHour' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                'W:\HDT\state.json' = (& $script:stateJson -UpdatedUtc $script:now.AddHours(-40))
            }

            (& $script:call (& $script:diskWith @('X', 'W')) $fileSystem -MaxAgeHour 72).Action |
                Should -Be 'Resume'
        }
    }

    Context 'the RAM disk' {

        # X: IS NEW EVERY BOOT, so it cannot carry a run across one. A state
        # document there belongs to THIS boot's own WinPE leg - the engine
        # writes X:\HDT\Logs\state.json before a volume exists to mirror to -
        # and reading it as evidence of a run in progress would make every
        # ordinary deployment resume itself.
        It 'is not scanned' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                'X:\HDT\state.json' = (& $script:stateJson)
            }

            (& $script:call (& $script:diskWith @('X', 'W')) $fileSystem).Action | Should -Be 'None'
        }
    }

    Context 'the scan itself' {

        It 'asks the disk service for its volumes rather than touching the filesystem directly' {
            $journal = New-Object -TypeName System.Collections.ArrayList
            $disk = New-HDTFakeDiskService -Journal $journal -Volume @(
                [pscustomobject] @{
                    DriveLetter        = 'W'
                    FileSystem         = 'NTFS'
                    FileSystemLabel    = ''
                    SizeBytes          = 100GB
                    SizeRemainingBytes = 60GB
                })

            & $script:call $disk (New-HDTFakeFileSystem) | Out-Null

            @($journal | ForEach-Object { $_.Operation }) | Should -Contain 'GetVolume'
        }

        # A DISK SERVICE THAT CANNOT LIST IS NOT EVIDENCE OF AN EMPTY MACHINE.
        # Answering None here would format a disk because Get-Volume failed.
        It 'answers Ambiguous when the volumes cannot be listed' {
            $disk = New-HDTFakeDiskService -Volume @() -Failure @{ GetVolume = 'the disk subsystem did not answer' }

            (& $script:call $disk (New-HDTFakeFileSystem)).Action | Should -Be 'Ambiguous'
        }
    }
}
