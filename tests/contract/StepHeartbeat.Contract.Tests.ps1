# ONE MECHANISM, AND EVERY STEP THAT SHELLS OUT HAS TO BE ON IT.
#
# StepProgress.Contract.Tests.ps1 next door asks a different question: does a
# step that KNOWS how far through it is say so? ApplyImage scrapes dism's
# percentage, InstallApplications counts 1 of 2, ApplyDrivers counts packages.
# That is the bar.
#
# THIS FILE IS ABOUT THE MINUTES IN BETWEEN, where there is nothing to count.
# An MSI offers no percentage; neither does a vendor's setup.exe, and neither
# does a file copy. On LT-7FJ45S2 run-20260829-190105, InstallApplications wrote
# "installing 1 of 2" at 16:13:41.358 and its next record at 16:15:38.176 -
# nearly two minutes in which the bar was correct, the step name was correct,
# and NOTHING ON THE SCREEN MOVED, because Get-HDTDeploymentProgress derives its
# elapsed clock from record timestamps and there were no records.
#
# THE FIX IS A HEARTBEAT AT THE ONE PLACE THE ENGINE WAITS, not three bespoke
# ones. IProcessService.Start now polls instead of blocking and calls back on
# every poll; New-HDTStepHeartbeat turns those callbacks into a record every
# fifteen seconds. So a step gets a living screen by handing Start a heartbeat
# and nothing else - and this file is what makes the NEXT step that shells out
# do it, instead of shipping the same silence again under a new name.
#
# THE SET IS DERIVED, NOT LISTED. Every step that asks the catalogue for the
# Process service is a step that can block on somebody else's program; naming
# them here would pass for the ones already fixed and fail nobody after them.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:HDTStepRoot = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'src/Hephaestus/Public/Steps'

# Pester 5 expands -ForEach at DISCOVERY time, so the set is built at file scope
# rather than in a BeforeAll, which would produce zero test cases.
$script:HDTProcessStepCase = @(
    Get-ChildItem -LiteralPath $script:HDTStepRoot -Filter 'Invoke-HDT*Step.ps1' -File |
        ForEach-Object {
            $text = [System.IO.File]::ReadAllText($_.FullName)

            @{
                Name = $_.Name
                Path = $_.FullName
                Text = $text

                # THE ONE SIGNATURE THAT MATTERS: a step that gets the Process
                # service is a step that can hand control to a program the
                # engine cannot see inside.
                UsesProcess = ($text -match "GetRequired\(\s*'Process'")
            }
        } |
        Where-Object { $_.UsesProcess })

# AND THE SET FOR THE MARK IS EVERY STEP, NOT ONLY THE ONES THAT SHELL OUT.
# A step does not have to hand control to somebody else's program to have a
# stretch with nothing to count: EnableBitLocker polls a volume that reports no
# completion figure, and its records need the same mark for the same reason. So
# the ban on hand-building the record is asserted over all of them, and the two
# assertions about the heartbeat MECHANISM stay over the ones that wait on a
# child process.
$script:HDTAllStepCase = @(
    Get-ChildItem -LiteralPath $script:HDTStepRoot -Filter 'Invoke-HDT*Step.ps1' -File |
        ForEach-Object {
            @{
                Name = $_.Name
                Path = $_.FullName
                Text = [System.IO.File]::ReadAllText($_.FullName)
            }
        })

Describe 'the long-child-process heartbeat contract' {

    Context 'the set is not empty' {

        # THE COUNT COMES IN THROUGH -ForEach, NOT OUT OF $script:. Pester 5 runs
        # discovery and execution in different scopes: a $script: variable filled
        # at discovery reads as $null inside an It, and @($null).Count is 1 - so
        # this guard silently passed for one file and would have passed for none.
        # -ForEach data is bound at discovery and survives.
        It 'found the steps that shell out' -ForEach @(@{ Found = @($script:HDTProcessStepCase).Count }) {
            # A regex that matched nothing would make every assertion below
            # vacuously true, which is the way a contract test dies quietly.
            $Found | Should -BeGreaterOrEqual 2 -Because (
                'CommandLine and InstallApplications both take the Process service; if neither was found ' +
                'the discovery above has stopped matching and this file is asserting nothing.')
        }
    }

    Context 'every step that waits on a child process ticks while it waits' {

        It '<Name> builds a heartbeat' -ForEach $script:HDTProcessStepCase {
            $Text | Should -Match 'New-HDTStepHeartbeat' -Because (
                "$Name hands control to a program the engine cannot see inside. Without a heartbeat the " +
                'progress card shows the same frame - and the same elapsed second - for however long that ' +
                'program takes, which on an Acrobat MSI over SMB was one hundred and seventeen seconds.')
        }

        It '<Name> hands that heartbeat to the process service' -ForEach $script:HDTProcessStepCase {
            # BUILDING ONE IS NOT USING ONE, and this is the half that would rot
            # first: a heartbeat constructed and then not passed as Start's
            # fifth argument is a heartbeat that is never ticked, and it looks
            # exactly like a working one in the source.
            $Text | Should -Match '\.Start\((?s).{0,400}?\$heartbeat' -Because (
                "$Name must pass its heartbeat to IProcessService.Start as the OnTick argument. A heartbeat " +
                'nothing invokes never fires.')
        }
    }

    Context 'no step rolls its own interval or hand-builds its own liveness record' {

        # THE COUNT, FOR THE SAME REASON THE ONE ABOVE EXISTS. A discovery that
        # stopped matching would make every assertion here vacuously true.
        It 'found the step files' -ForEach @(@{ Found = @($script:HDTAllStepCase).Count }) {
            $Found | Should -BeGreaterOrEqual 10 -Because (
                'the step catalogue is more than ten types; if discovery found fewer than that it has ' +
                'stopped matching and this file is asserting nothing.')
        }

        # ONE MECHANISM WAS THE WHOLE POINT. Three steps that each decide their
        # own cadence are three cadences to change, and the first one somebody
        # forgets is the one that ships silent.
        #
        # AND THE MARK IS PART OF THE SHAPE, WHICH IS WHERE THIS RULE FIRST
        # COLLIDED WITH ANOTHER ONE. step.progress carries measurements and
        # signs of life, `heartbeat = true` is what tells a reader which it is
        # holding (StepProgress.Contract.Tests.ps1 asserts that every record
        # says so), and Sysprep legitimately writes one such record by hand -
        # before sysprep /generalize, which then prints nothing for minutes.
        # That is not a cadence, so the ban must not forbid the record; but a
        # step spelling the mark out itself is a second author of the shape, and
        # the third one would spell it differently.
        #
        # SO THE SHAPE HAS A WRITER AND THE STEPS CALL IT. Write-HDTStepLiveness
        # owns the event name, the mark and the nudge that makes the window
        # re-read the log; New-HDTStepHeartbeat still owns the interval and the
        # rationing, and calls the same writer. A step gets to say "still alive"
        # at a moment it knows about, and gets no say in what that record looks
        # like.
        #
        # NOT AN EXEMPTION LIST. Naming Sysprep here would pass for Sysprep and
        # leave the next step free to invent its own dialect of the same record.
        It '<Name> does not spell out a liveness record of its own' -ForEach $script:HDTAllStepCase {
            $Text | Should -Not -Match 'heartbeat\s*=\s*\$true' -Because (
                "$Name must not write a heartbeat record itself. Write-HDTStepLiveness owns the shape and " +
                'the mark, and New-HDTStepHeartbeat owns the interval and the rationing; a step that needs ' +
                'to report a sign of life calls one of them.')
        }
    }
}
