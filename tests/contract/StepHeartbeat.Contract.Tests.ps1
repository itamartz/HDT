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

        It '<Name> does not roll its own interval or its own record' -ForEach $script:HDTProcessStepCase {
            # ONE MECHANISM WAS THE WHOLE POINT. Three steps that each decide
            # their own cadence are three cadences to change, and the first one
            # somebody forgets is the one that ships silent.
            $Text | Should -Not -Match 'heartbeat\s*=\s*\$true' -Because (
                "$Name must not write a heartbeat record itself; New-HDTStepHeartbeat owns the shape, the " +
                'interval and the rationing.')
        }
    }
}
