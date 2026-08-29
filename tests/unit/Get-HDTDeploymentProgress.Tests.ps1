# WHAT THE PROGRESS WINDOW SHOWS, WORKED OUT FROM THE LOG.
#
# DESIGN 11.1: the progress window is driven by the JSONL event stream and NOT
# by a parallel progress API. The engine already emits run.start, step.start,
# step.complete, step.fail, step.skip and phase.change with a controlled
# vocabulary (DESIGN 4.4.2), so there is exactly one source of truth for what a
# deployment is doing - the screen and the log can never disagree, and a step
# author gets progress for free without calling a UI function.
#
# THIS IS THAT DERIVATION, AND IT IS PURE. No window, no runspace, no clock, no
# file system. The window is a thin adapter over what this returns, which is
# what lets the whole of it be asserted on a developer machine with no display.
#
# THERE IS NO ELAPSED HERE, AND THAT IS THE POINT. A record says WHAT is
# happening; only a clock can say HOW LONG, and this function has none - reading
# one would make every assertion below depend on when it ran. So it reports the
# times it can read off the stream - when the run started, when the step running
# now started - and the window subtracts those from its own clock, once a
# second, for as long as the step takes. See the note above the skew context.
#
# THE RECORDS ARE THE REAL SHAPE - ts, runId, seq, level, phase, stepIndex,
# stepName, stepType, component, event, message, durationMs, data - as
# ConvertTo-HDTLogRecord writes them.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    function New-HDTProgressRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds in-memory test data; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string] $Event,

            [Parameter()]
            [int] $Second = 0,

            [Parameter()]
            [string] $Phase = 'WinPE',

            [Parameter()]
            [AllowNull()]
            [hashtable] $Data,

            [Parameter()]
            [int] $StepIndex = 0,

            [Parameter()]
            [AllowEmptyString()]
            [string] $StepName = '',

            # THE LINE A LOOPING STEP WRITES ABOUT ITSELF - "installing 1 of 2:
            # Acrobat Acrobat Reader DC". Defaulted to the event name, which is
            # what every record above this parameter was already carrying.
            [Parameter()]
            [AllowEmptyString()]
            [string] $Message
        )

        $record = [ordered] @{
            ts        = ([datetime]::new(2026, 8, 15, 9, 0, 0, [System.DateTimeKind]::Utc)).AddSeconds($Second).ToString('o')
            runId     = 'r-1'
            seq       = $Second + 1
            level     = 'Info'
            phase     = $Phase
            component = 'Engine'
            event     = $Event
            message   = $Event
        }

        if ($PSBoundParameters.ContainsKey('Message')) { $record['message'] = $Message }

        if ($StepIndex -gt 0) {
            $record['stepIndex'] = $StepIndex
            $record['stepName'] = $StepName
            $record['stepType'] = 'NoOp'
        }

        if ($null -ne $Data) { $record['data'] = $Data }

        return [pscustomobject] $record
    }

    # A run that has partitioned a disk and is applying an image: five steps,
    # two finished, the third in flight.
    $script:midRun = @(
        New-HDTProgressRecord -Event 'run.start' -Second 0 -Data @{ sequenceId = 'STD-CLIENT'; stepIndex = 0; stepCount = 5; leg = 1 }
        New-HDTProgressRecord -Event 'step.start' -Second 1 -StepIndex 1 -StepName 'Partition disk' -Data @{ index = 1; name = 'Partition disk'; type = 'DiskPartition'; attempt = 1 }
        New-HDTProgressRecord -Event 'step.complete' -Second 20 -StepIndex 1 -StepName 'Partition disk' -Data @{ index = 1; attempt = 1; exitCode = 0 }
        New-HDTProgressRecord -Event 'step.start' -Second 21 -StepIndex 2 -StepName 'Apply unattend' -Data @{ index = 2; name = 'Apply unattend'; type = 'ApplyUnattend'; attempt = 1 }
        New-HDTProgressRecord -Event 'step.complete' -Second 25 -StepIndex 2 -StepName 'Apply unattend' -Data @{ index = 2; attempt = 1; exitCode = 0 }
        New-HDTProgressRecord -Event 'step.start' -Second 26 -StepIndex 3 -StepName 'Apply image' -Data @{ index = 3; name = 'Apply image'; type = 'ApplyImage'; attempt = 1 }
    )
}

Describe 'Get-HDTDeploymentProgress' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTDeploymentProgress' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'a run in flight' {

        It 'names the task sequence' {
            [string] (Get-HDTDeploymentProgress -Record $script:midRun).SequenceId | Should -BeExactly 'STD-CLIENT'
        }

        It 'names the step that is running now' {
            [string] (Get-HDTDeploymentProgress -Record $script:midRun).StepName | Should -BeExactly 'Apply image'
        }

        It 'says step N of M' {
            $progress = Get-HDTDeploymentProgress -Record $script:midRun

            [int] $progress.StepNumber | Should -Be 3
            [int] $progress.StepCount | Should -Be 5
        }

        It 'counts a step as done when it finished, not when the next one started' {
            # THE OFF-BY-ONE A PROGRESS BAR ALWAYS HAS. Two steps have
            # completed; the third is running and has not.
            [int] (Get-HDTDeploymentProgress -Record $script:midRun).CompletedCount | Should -Be 2
        }

        It 'reports percent complete from what finished' {
            [int] (Get-HDTDeploymentProgress -Record $script:midRun).PercentComplete | Should -Be 40
        }

        It 'reports the phase' {
            [string] (Get-HDTDeploymentProgress -Record $script:midRun).Phase | Should -BeExactly 'WinPE'
        }

        It 'reports when the step that is running now started' {
            # THE FACT THE WINDOW NEEDS TO RUN A CLOCK, and the only one this
            # function can honestly supply: the step began at +26s, and how long
            # ago that was is a question only something holding a clock can
            # answer.
            [datetime] (Get-HDTDeploymentProgress -Record $script:midRun).StepStartTime |
                Should -Be ([datetime]::new(2026, 8, 15, 9, 0, 26, [System.DateTimeKind]::Utc))
        }

        It 'reports when the run started' {
            [datetime] (Get-HDTDeploymentProgress -Record $script:midRun).RunStartTime |
                Should -Be ([datetime]::new(2026, 8, 15, 9, 0, 0, [System.DateTimeKind]::Utc))
        }

        It 'reports those times in UTC, which is what ts is written in' {
            # The window subtracts them from UtcNow. A local-kind time here
            # would be out by the machine's offset - two hours of imaginary
            # deployment in this lab, and none at all in Reykjavik, which is
            # exactly the kind of defect that reproduces on one site only.
            [string] (Get-HDTDeploymentProgress -Record $script:midRun).StepStartTime.Kind |
                Should -BeExactly 'Utc'
        }

        It 'works out no elapsed of its own, because it has no clock to do it with' {
            # THE DEFECT THIS REPLACED. ElapsedSecond was the sum of the
            # stretches the records' own timestamps ran forwards through, so it
            # advanced only when something wrote a record and was frozen between
            # them by construction - measured on LT-D5M1NN3, run-20260829-223623:
            # step 7 wrote step.start and then nothing for minutes, and the
            # number on the card never moved. The field is gone rather than
            # merely unused, because a stale duration nobody notices is exactly
            # how it would come back.
            (Get-HDTDeploymentProgress -Record $script:midRun).PSObject.Properties['ElapsedSecond'] |
                Should -BeNullOrEmpty
        }

        It 'is Running' {
            [string] (Get-HDTDeploymentProgress -Record $script:midRun).Status | Should -BeExactly 'Running'
        }
    }

    Context "WinPE's clock, which is wrong, and then corrects itself" {

        # THE DEFECT THIS CONTEXT EXISTS FOR, MEASURED ON A REAL DEPLOYMENT.
        # LT-7FJ45S2, run-20260829-172208: the WinPE leg stamped its 122 records
        # 08/30 01:22:10 to 01:29:00 with clockUnsynced true, the machine
        # rebooted, and the full-OS leg stamped its 18 records 08/29 14:34:22 to
        # 14:36:36 with a corrected clock - TEN HOURS AND FIFTY-THREE MINUTES
        # EARLIER. The last record in the file was therefore older than the
        # first, the guard on the subtraction refused a negative span, and
        # ElapsedSecond kept its initialised zero.
        #
        # WHAT THE TECHNICIAN SAW was "00:00:00 elapsed" on the progress card for
        # the whole of the full-OS leg, on a deployment that had by then been
        # running two and a half hours. Not a frozen clock - a clock that never
        # started, which is a different defect and looks identical.
        #
        # WHY THE CLOCK MOVES AT ALL is DESIGN 4.4.2: WinPE boots with an
        # unsynchronised clock, the engine already knows it (every WinPE record
        # carries clockUnsynced true) and the full OS fixes it at the first
        # sync. So this is not an exotic case - it is what EVERY deployment that
        # reboots does, and elapsed has been zero on the full-OS leg of all of
        # them.
        #
        # WHAT MAKES THIS SURVIVABLE NOW IS THAT NOTHING SUBTRACTS ACROSS THE
        # JUMP. The window runs the clock, against StepStartTime, and it
        # subtracts it from the SAME clock that stamped it - the machine's own,
        # this side of the reboot - so WinPE's skew cancels out of the
        # difference even while the absolute time is nonsense. The resumed leg
        # is a new process with a new window starting from the resumed step's
        # own step.start, so there is no stretch left for a wrong clock to be
        # measured across. That is why the segment machinery could go, and it
        # went because summing record timestamps froze the clock between
        # records (see the run-in-flight context above).
        #
        # THE JUMP ITSELF IS STILL REAL and these assertions still exist:
        # nothing below may report a WinPE time as the start of a full-OS step.

        BeforeAll {
            # The shape above, in miniature: a WinPE leg an hour ahead, then a
            # full-OS leg at the true time.
            $script:skewed = @(
                New-HDTProgressRecord -Event 'run.start' -Second 3600 -Data @{ sequenceId = 'client'; stepCount = 4 }
                New-HDTProgressRecord -Event 'step.start' -Second 3610 -StepIndex 1 -StepName 'Format'
                New-HDTProgressRecord -Event 'step.complete' -Second 3700 -StepIndex 1 -StepName 'Format'
                New-HDTProgressRecord -Event 'reboot.resume' -Second 30 -Phase 'FullOS'
                New-HDTProgressRecord -Event 'step.start' -Second 40 -Phase 'FullOS' -StepIndex 2 -StepName 'Install Applications'
                New-HDTProgressRecord -Event 'step.progress' -Second 130 -Phase 'FullOS' -StepIndex 2 -Data @{ percent = 50 }
            )
        }

        It 'times the resumed step by the clock the resumed leg is stamping' {
            # THE HEADLINE. The full-OS step began at +40s on the corrected
            # clock, and that is what the window subtracts from its own UtcNow -
            # the same clock, so the skew is on both sides and cancels.
            [datetime] (Get-HDTDeploymentProgress -Record $script:skewed).StepStartTime |
                Should -Be ([datetime]::new(2026, 8, 15, 9, 0, 40, [System.DateTimeKind]::Utc))
        }

        It 'never carries the clock of the WinPE leg into the full-OS one' {
            # An hour ahead is what the WinPE leg was stamped with. A window
            # subtracting THAT from the corrected clock would open reading an
            # hour of deployment that had not happened, in the field somebody
            # uses to decide whether to intervene.
            [datetime] (Get-HDTDeploymentProgress -Record $script:skewed).StepStartTime |
                Should -Not -Be ([datetime]::new(2026, 8, 15, 10, 0, 10, [System.DateTimeKind]::Utc))
        }

        It 'follows the last run.start, so a resume dates the run from the resume' {
            $resumed = @($script:skewed) + @(
                New-HDTProgressRecord -Event 'run.start' -Second 200 -Phase 'FullOS' -Data @{ sequenceId = 'client'; stepCount = 4 })

            [datetime] (Get-HDTDeploymentProgress -Record $resumed).RunStartTime |
                Should -Be ([datetime]::new(2026, 8, 15, 9, 3, 20, [System.DateTimeKind]::Utc))
        }

        It 'has no step running at the instant a run starts' {
            # The leg before the reboot left its step.start in this same file.
            # Carrying it across would open the resumed window on a clock that
            # had already been running for the whole of WinPE.
            $resumed = @($script:skewed) + @(
                New-HDTProgressRecord -Event 'run.start' -Second 200 -Phase 'FullOS' -Data @{ sequenceId = 'client'; stepCount = 4 })

            (Get-HDTDeploymentProgress -Record $resumed).StepStartTime | Should -BeNullOrEmpty
        }
    }

    Context 'the phase changing under it' {

        It 'follows phase.change rather than the record it is written on' {
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'phase.change' -Second 200 -Phase 'WinPE' -Data @{ from = 'WinPE'; to = 'FullOS' })

            [string] (Get-HDTDeploymentProgress -Record $record).Phase | Should -BeExactly 'FullOS'
        }

        It 'keeps counting across the reboot, because the step numbers do' {
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'phase.change' -Second 200 -Data @{ from = 'WinPE'; to = 'FullOS' }
                New-HDTProgressRecord -Event 'step.complete' -Second 201 -StepIndex 3 -Data @{ index = 3; attempt = 1; exitCode = 0 }
                New-HDTProgressRecord -Event 'step.start' -Second 202 -Phase 'FullOS' -StepIndex 4 -StepName 'Install applications' -Data @{ index = 4; name = 'Install applications'; type = 'InstallApplications'; attempt = 1 })

            $progress = Get-HDTDeploymentProgress -Record $record

            [int] $progress.StepNumber | Should -Be 4
            [int] $progress.CompletedCount | Should -Be 3
            [string] $progress.Phase | Should -BeExactly 'FullOS'
        }
    }

    Context 'a step that did not complete' {

        It 'counts a skipped step as done, because the bar is about progress and not about work' {
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'step.skip' -Second 30 -StepIndex 3 -Data @{ index = 3; reason = 'condition' })

            [int] (Get-HDTDeploymentProgress -Record $record).CompletedCount | Should -Be 3
        }

        It 'goes to Failed on step.fail and names the step that did it' {
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'step.fail' -Second 40 -StepIndex 3 -StepName 'Apply image' -Data @{ index = 3; attempt = 1 })

            $progress = Get-HDTDeploymentProgress -Record $record

            [string] $progress.Status | Should -BeExactly 'Failed'
            [string] $progress.StepName | Should -BeExactly 'Apply image'
        }

        It 'does not count a failed step as completed' {
            # A BAR THAT ADVANCES ON FAILURE IS A BAR THAT LIES at the one
            # moment a technician is reading it closely.
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'step.fail' -Second 40 -StepIndex 3 -Data @{ index = 3; attempt = 1 })

            [int] (Get-HDTDeploymentProgress -Record $record).CompletedCount | Should -Be 2
        }

        It 'stays Failed even if something is logged after it' {
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'step.fail' -Second 40 -StepIndex 3 -Data @{ index = 3 }
                New-HDTProgressRecord -Event 'message' -Second 41)

            [string] (Get-HDTDeploymentProgress -Record $record).Status | Should -BeExactly 'Failed'
        }
    }

    Context 'a run that ended' {

        It 'is Succeeded when every step finished' {
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'step.complete' -Second 60 -StepIndex 3 -Data @{ index = 3 }
                New-HDTProgressRecord -Event 'step.start' -Second 61 -StepIndex 4 -StepName 'Configure boot' -Data @{ index = 4; name = 'Configure boot' }
                New-HDTProgressRecord -Event 'step.complete' -Second 70 -StepIndex 4 -Data @{ index = 4 }
                New-HDTProgressRecord -Event 'step.start' -Second 71 -StepIndex 5 -StepName 'Restart' -Data @{ index = 5; name = 'Restart' }
                New-HDTProgressRecord -Event 'step.complete' -Second 75 -StepIndex 5 -Data @{ index = 5 }
                New-HDTProgressRecord -Event 'run.end' -Second 76 -Data @{ status = 'Succeeded' })

            $progress = Get-HDTDeploymentProgress -Record $record

            [string] $progress.Status | Should -BeExactly 'Succeeded'
            [int] $progress.PercentComplete | Should -Be 100
        }

        It 'takes the status run.end reported rather than counting for itself' {
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'run.end' -Second 80 -Data @{ status = 'Failed' })

            [string] (Get-HDTDeploymentProgress -Record $record).Status | Should -BeExactly 'Failed'
        }
    }

    Context 'a stream it cannot make sense of' {

        It 'survives no records at all' {
            $progress = Get-HDTDeploymentProgress -Record @()

            [int] $progress.StepCount | Should -Be 0
            [int] $progress.PercentComplete | Should -Be 0
            [string] $progress.Status | Should -BeExactly 'Unknown'
        }

        It 'reports no percentage when nothing said how many steps there are' {
            # A DIVISION BY ZERO IN A PROGRESS BAR takes down the window that
            # was showing a technician what went wrong.
            $record = @(New-HDTProgressRecord -Event 'step.start' -Second 1 -StepIndex 1 -StepName 'Partition disk' -Data @{ index = 1 })

            [int] (Get-HDTDeploymentProgress -Record $record).PercentComplete | Should -Be 0
        }

        It 'ignores a record with no event rather than throwing' {
            $record = @([pscustomobject] @{ ts = '2026-08-15T09:00:00.0000000Z'; message = 'no event here' }) + @($script:midRun)

            { Get-HDTDeploymentProgress -Record $record } | Should -Not -Throw
        }

        It 'never reports more than 100 percent' {
            # A resumed run can log more completions than run.start counted.
            $record = @($script:midRun) + @(1..9 | ForEach-Object {
                    New-HDTProgressRecord -Event 'step.complete' -Second (100 + $_) -StepIndex $_ -Data @{ index = $_ }
                })

            [int] (Get-HDTDeploymentProgress -Record $record).PercentComplete | Should -BeLessOrEqual 100
        }
    }
}

Describe 'how far through the step itself' {

    # THE SEQUENCE BAR AND THE STEP BAR ARE DIFFERENT FACTS. PercentComplete is
    # how many steps are done; StepPercent is how far through the one that is
    # running - and for the nine minutes an 18 GB apply takes, it is the only
    # number on the screen that moves.
    #
    # IT BELONGS TO THE STEP THAT REPORTED IT AND TO NO OTHER. A step that
    # starts inherits nothing from the one before it, or the bar would open at
    # 100% and count down.

    It 'reads the percentage off the latest step.progress' {
        $record = @($script:midRun) + @(
            New-HDTProgressRecord -Event 'step.progress' -Second 30 -StepIndex 3 -Data @{ index = 3; percent = 20 }
            New-HDTProgressRecord -Event 'step.progress' -Second 60 -StepIndex 3 -Data @{ index = 3; percent = 65 }
        )

        [int] (Get-HDTDeploymentProgress -Record $record).StepPercent | Should -Be 65
    }

    It 'is zero before anything has reported' {
        [int] (Get-HDTDeploymentProgress -Record $script:midRun).StepPercent | Should -Be 0
    }

    It 'is cleared when the next step starts' {
        $record = @($script:midRun) + @(
            New-HDTProgressRecord -Event 'step.progress' -Second 30 -StepIndex 3 -Data @{ index = 3; percent = 65 }
            New-HDTProgressRecord -Event 'step.complete' -Second 90 -StepIndex 3 -Data @{ index = 3; attempt = 1; exitCode = 0 }
            New-HDTProgressRecord -Event 'step.start' -Second 91 -StepIndex 4 -StepName 'Install drivers' -Data @{ index = 4; name = 'Install drivers'; type = 'InjectDriver'; attempt = 1 }
        )

        [int] (Get-HDTDeploymentProgress -Record $record).StepPercent | Should -Be 0
    }

    It 'is cleared when the step that reported it finishes' {
        $record = @($script:midRun) + @(
            New-HDTProgressRecord -Event 'step.progress' -Second 30 -StepIndex 3 -Data @{ index = 3; percent = 65 }
            New-HDTProgressRecord -Event 'step.complete' -Second 90 -StepIndex 3 -Data @{ index = 3; attempt = 1; exitCode = 0 }
        )

        [int] (Get-HDTDeploymentProgress -Record $record).StepPercent | Should -Be 0
    }

    It 'keeps the last percentage a failed step reached' {
        # An apply that died at 60% died somewhere different from one that never
        # started, and this is the number that says so.
        $record = @($script:midRun) + @(
            New-HDTProgressRecord -Event 'step.progress' -Second 30 -StepIndex 3 -Data @{ index = 3; percent = 60 }
            New-HDTProgressRecord -Event 'step.fail' -Second 40 -StepIndex 3 -StepName 'Apply image' -Data @{ index = 3; attempt = 1 }
        )

        $progress = Get-HDTDeploymentProgress -Record $record

        [int] $progress.StepPercent | Should -Be 60
        [string] $progress.Status | Should -BeExactly 'Failed'
    }

    It 'ignores a step.progress with no percentage rather than throwing' {
        $record = @($script:midRun) + @(New-HDTProgressRecord -Event 'step.progress' -Second 30 -StepIndex 3 -Data @{ index = 3 })

        { Get-HDTDeploymentProgress -Record $record } | Should -Not -Throw
        [int] (Get-HDTDeploymentProgress -Record $record).StepPercent | Should -Be 0
    }
}

Describe 'which one of the many it is on' {

    # "INSTALL APPLICATIONS" IS ONE STEP AND ELEVEN INSTALLERS. A technician
    # watching a machine sit on that name for twenty minutes cannot tell Acrobat
    # from the one that hung, and the step name is the same string either way.
    #
    # THE STEPS ALREADY WRITE IT. Measured on LT-D5M1NN3, run-20260829-223623
    # and on the VM run PC-5784-6600-26-run-20260829-220902: step.progress
    # records reading "installing 1 of 2: Acrobat Acrobat Reader DC 2600121771",
    # "staging Latitude 5420: 64%", "Acrobat ... - still running after 45s". The
    # window had nothing to render them with, because this function exposed no
    # such field - so the log knew and the screen did not.
    #
    # THE MESSAGE, NOT SOMETHING REBUILT FROM data. It is written for a person,
    # it is the same string in the log and on the screen, and it is the one
    # field every step type fills the same way - data carries application,
    # package or imagePath depending on who wrote it.

    It 'shows what the step said it was doing' {
        $record = @($script:midRun) + @(
            New-HDTProgressRecord -Event 'step.progress' -Second 30 -StepIndex 3 `
                -Message 'installing 1 of 2: Acrobat Acrobat Reader DC 2600121771' `
                -Data @{ index = 3; application = 'Acrobat Reader DC'; done = 1; total = 2; percent = 0 })

        [string] (Get-HDTDeploymentProgress -Record $record).Activity |
            Should -BeExactly 'installing 1 of 2: Acrobat Acrobat Reader DC 2600121771'
    }

    It 'follows the latest one, because the next application is the news' {
        $record = @($script:midRun) + @(
            New-HDTProgressRecord -Event 'step.progress' -Second 30 -StepIndex 3 `
                -Message 'installing 1 of 2: Acrobat Acrobat Reader DC 2600121771' -Data @{ index = 3; percent = 0 }
            New-HDTProgressRecord -Event 'step.progress' -Second 90 -StepIndex 3 `
                -Message 'installing 2 of 2: TightVNC Software Tightvnc 2.8.88' -Data @{ index = 3; percent = 50 })

        [string] (Get-HDTDeploymentProgress -Record $record).Activity |
            Should -BeExactly 'installing 2 of 2: TightVNC Software Tightvnc 2.8.88'
    }

    It 'says nothing before the step has said anything' {
        # Blank is honest for the second or two after step.start. The previous
        # step's last line would be a screen stating something that stopped
        # being true one record ago.
        [string] (Get-HDTDeploymentProgress -Record $script:midRun).Activity | Should -BeExactly ''
    }

    It 'is cleared when the next step starts' {
        $record = @($script:midRun) + @(
            New-HDTProgressRecord -Event 'step.progress' -Second 30 -StepIndex 3 `
                -Message 'installing 2 of 2: TightVNC Software Tightvnc 2.8.88' -Data @{ index = 3; percent = 50 }
            New-HDTProgressRecord -Event 'step.complete' -Second 90 -StepIndex 3 -Data @{ index = 3; attempt = 1; exitCode = 0 }
            New-HDTProgressRecord -Event 'step.start' -Second 91 -StepIndex 4 -StepName 'Apply Windows Settings' `
                -Data @{ index = 4; name = 'Apply Windows Settings'; type = 'ApplyUnattend'; attempt = 1 })

        [string] (Get-HDTDeploymentProgress -Record $record).Activity | Should -BeExactly ''
    }

    It 'is cleared when the step that said it finishes' {
        # THE SAME TRAP THE STEP BAR WAS ALREADY CAUGHT BY: a finished step is
        # not a step that is 60% done, and it is not still installing TightVNC.
        $record = @($script:midRun) + @(
            New-HDTProgressRecord -Event 'step.progress' -Second 30 -StepIndex 3 `
                -Message 'installing 2 of 2: TightVNC Software Tightvnc 2.8.88' -Data @{ index = 3; percent = 50 }
            New-HDTProgressRecord -Event 'step.complete' -Second 90 -StepIndex 3 -Data @{ index = 3; attempt = 1; exitCode = 0 })

        [string] (Get-HDTDeploymentProgress -Record $record).Activity | Should -BeExactly ''
    }

    It 'is cleared when the step that said it is skipped' {
        $record = @($script:midRun) + @(
            New-HDTProgressRecord -Event 'step.progress' -Second 30 -StepIndex 3 `
                -Message 'installing 2 of 2: TightVNC Software Tightvnc 2.8.88' -Data @{ index = 3; percent = 50 }
            New-HDTProgressRecord -Event 'step.skip' -Second 90 -StepIndex 3 -Data @{ index = 3 })

        [string] (Get-HDTDeploymentProgress -Record $record).Activity | Should -BeExactly ''
    }

    It 'shows a heartbeat without letting it touch the bar' {
        # A HEARTBEAT IS A step.progress WITH NO percent, and both halves of that
        # matter: its message is the most useful thing on the screen when a step
        # has gone quiet, and resetting the bar to zero underneath it would
        # undo the only number that had been moving.
        $record = @($script:midRun) + @(
            New-HDTProgressRecord -Event 'step.progress' -Second 30 -StepIndex 3 `
                -Message 'applying install.wim (index 1) to W:\: 45%' -Data @{ index = 3; percent = 45 }
            New-HDTProgressRecord -Event 'step.progress' -Second 75 -StepIndex 3 `
                -Message 'Acrobat Acrobat Reader DC 2600121771 - still running after 45s' `
                -Data @{ index = 3; heartbeat = $true })

        $progress = Get-HDTDeploymentProgress -Record $record

        [string] $progress.Activity | Should -BeExactly 'Acrobat Acrobat Reader DC 2600121771 - still running after 45s'
        [int] $progress.StepPercent | Should -Be 45
    }

    It 'ignores a step.progress with no message rather than blanking the line' {
        $record = @($script:midRun) + @(
            New-HDTProgressRecord -Event 'step.progress' -Second 30 -StepIndex 3 `
                -Message 'installing 1 of 2: Acrobat Acrobat Reader DC 2600121771' -Data @{ index = 3; percent = 0 }
            New-HDTProgressRecord -Event 'step.progress' -Second 60 -StepIndex 3 -Message '' -Data @{ index = 3; percent = 20 })

        [string] (Get-HDTDeploymentProgress -Record $record).Activity |
            Should -BeExactly 'installing 1 of 2: Acrobat Acrobat Reader DC 2600121771'
    }
}

Describe 'a clock the records cannot start' {

    It 'has no step start time before the first step' {
        # THE WINDOW SHOWS 00:00:00 HERE, and it must be able to tell "no step
        # yet" from "a step that started at midnight". $null says so; a zero
        # datetime would be the year 1 AD rendered as a fortnight of elapsed.
        $record = @(New-HDTProgressRecord -Event 'run.start' -Second 0 -Data @{ sequenceId = 'STD-CLIENT'; stepCount = 5 })

        (Get-HDTDeploymentProgress -Record $record).StepStartTime | Should -BeNullOrEmpty
    }

    It 'has no times at all when there are no records' {
        $progress = Get-HDTDeploymentProgress -Record @()

        $progress.StepStartTime | Should -BeNullOrEmpty
        $progress.RunStartTime | Should -BeNullOrEmpty
    }

    It 'survives a timestamp it cannot parse' {
        # A JSONL on a RAM disk that a deployment was cut off in the middle of
        # writing is the normal way this arrives, and a window that goes blank
        # over half a line is the second failure of the night.
        $record = @([pscustomobject] @{ ts = 'not a time'; event = 'step.start'
                data                       = [pscustomobject] @{ index = 1; name = 'Partition disk'; type = 'DiskPartition' }
            })

        { Get-HDTDeploymentProgress -Record $record } | Should -Not -Throw
        (Get-HDTDeploymentProgress -Record $record).StepStartTime | Should -BeNullOrEmpty
    }

    It 'keeps the step running while the engine moves between steps' {
        # BETWEEN step.complete AND THE NEXT step.start THE CLOCK DOES NOT
        # RESET. The deployment is still doing something in that gap, and a
        # clock that flicked to zero four times a second between every pair of
        # steps would read as a screen resetting rather than as a machine
        # working.
        $record = @($script:midRun) + @(
            New-HDTProgressRecord -Event 'step.complete' -Second 90 -StepIndex 3 -Data @{ index = 3; attempt = 1; exitCode = 0 })

        [datetime] (Get-HDTDeploymentProgress -Record $record).StepStartTime |
            Should -Be ([datetime]::new(2026, 8, 15, 9, 0, 26, [System.DateTimeKind]::Utc))
    }
}


}
