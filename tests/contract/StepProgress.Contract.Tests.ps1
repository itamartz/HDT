# The long-step progress contract (DESIGN 11.1).
#
# A STEP THAT CAN RUN FOR MINUTES MUST SAY SOMETHING BETWEEN ITS START AND ITS
# FINISH. Not because a bar is pretty - because of what the alternative looks
# like on a machine somebody is standing in front of.
#
# THREE STEPS SHIPPED SILENT, AND EACH ONE WAS FOUND THE SAME WAY: a technician
# watching a deployment that was working perfectly and could not tell.
#
#   ApplyDrivers        82 drivers, 670 seconds on a Latitude 5490. Eleven
#                       minutes of the same frame.
#   ApplyUnattend       over three minutes on LT-7FJ45S2 run-20260829-172208,
#                       running offlineServicing over 133 .inf packages.
#   InstallApplications an Acrobat MSI with a 687 MB patch, over SMB, on the
#                       same run. Four log lines for the whole step, all of them
#                       boundaries.
#
# AND IT IS WORSE THAN A STILL BAR, because the progress card's elapsed clock is
# derived from the FIRST AND LAST RECORD IN THE LOG (Get-HDTDeploymentProgress).
# A step that writes nothing does not merely fail to move its own bar - it stops
# the clock for the whole deployment. Silence is not a cosmetic defect here.
#
# SO THE RULE IS ENFORCED AGAINST THE SET, NOT AGAINST THE THREE THAT WERE
# FIXED. Every step type in the registry must be classified: either it reports,
# or it is named below with the reason it cannot. A step type that is neither
# fails this file, which is what makes the NEXT slow step somebody adds a
# decision rather than an oversight - the three above were all oversights, and
# every one of them passed its own tests.
#
# Pester 5 expands -ForEach at DISCOVERY time, so the registry is built at file
# scope rather than in a BeforeAll, which would produce zero test cases.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') `
    -Force -ErrorAction Stop

# THE STEPS THAT MUST REPORT, and what each of them has to report WITH. A step
# is on this list because it can occupy a deployment for minutes; the second
# column is the fact it already had in hand, which is why none of these needed a
# new service, a new channel or an output capture to fix.
$script:HDTReportingStep = [ordered] @{
    'ApplyImage'          = "dism.exe prints a percentage meter on stdout while it writes the image."
    'ApplyDrivers'        = "it stages drivers one at a time and knows how many there are."
    # NOT "the same meter", WHICH IS WHAT THIS LINE USED TO SAY AND WAS WRONG.
    # dism.exe prints NO percentage for /Apply-Unattend - a banner, then silence,
    # then one sentence. LT-D5M1NN3 run-20260829-223623 proved it from a boot
    # image built AFTER the meter was wired here: twenty step.progress records
    # out of ApplyImage in that run, none at all out of this step, across 153
    # seconds of real offlineServicing over 260 .inf packages. So the adapter
    # runs dism as a POLLED process and the step hands it a heartbeat, which is
    # MDT's shape - RunCommandLog polls, scrapes AND beats event 41003 for
    # exactly the case where the tool says nothing.
    'ApplyUnattend'       = "dism.exe prints no meter for /Apply-Unattend, so the adapter polls the process and the step beats a heartbeat with the elapsed time."
    'InstallApplications' = "it resolves the whole ordered plan before it starts, so it knows it is on 1 of 2."
    'EnableBitLocker'     = "it polls the volume every fifteen seconds and can say the disk is still encrypting."
}

# THE STEPS THAT DO NOT, EACH WITH THE REASON IT CANNOT RATHER THAN A BLANK
# EXEMPTION. Two shapes only: a step that finishes in seconds has nothing to
# report, and a step that hands control to somebody else's program cannot know
# how far through it is. Anything that is neither of those does not belong here.
$script:HDTQuietStep = [ordered] @{
    'CommandLine'        = "it runs an operator's own command line, and the engine cannot know how far through somebody else's program it is. A number invented from elapsed time would be a bar that lied."
    'PowerShell'         = "the same: an operator's script, whose progress is theirs to report and not the engine's to guess."
    'InstallRoles'       = "one Install-WindowsFeature call for the whole set, and that cmdlet reports on PowerShell's progress STREAM, which is a console bar and not data - the same reason New-HDTImageService shells dism.exe rather than calling Expand-WindowsImage. Reporting would mean a new output channel on IFeatureService."
    'ConfigureBoot'      = "bcdboot and bcdedit, and both return in seconds."
    'DiskPartition'      = "partitioning and a quick format, seconds on any disk this deploys to."
    'Gather'             = "reads CIM and the rules, in seconds."
    'InstallCertificate' = "writes a certificate to a store; effectively instant."
    'NoOp'               = "does nothing, at length."
    'Restart'            = "it arms a reboot and returns; the machine is gone before there is anything to report."
    'SetVariable'        = "assigns a variable; effectively instant."
    'Tattoo'             = "writes a handful of registry values; effectively instant."
    'Validate'           = "reads the machine's facts and checks them, in seconds."
}

$script:HDTStepProgressCase = @(Get-HDTStepType |
        Where-Object { $_.Source -eq 'Hephaestus' } |
        ForEach-Object {
            @{
                Type        = [string] $_.Type
                InvokeName  = [string] $_.InvokeCommand.Name
                MustReport  = $script:HDTReportingStep.Contains([string] $_.Type)
                IsClassified = ($script:HDTReportingStep.Contains([string] $_.Type) -or
                    $script:HDTQuietStep.Contains([string] $_.Type))
            }
        })

$script:HDTMustReportCase = @($script:HDTStepProgressCase | Where-Object { $_.MustReport })

# THE STALE-NAME CHECK, ALSO EXPANDED AT DISCOVERY. It used to read the lists
# above from inside an It body, where the file's script scope is not visible:
# Pester's run phase does not share a scope with discovery, so under
# Set-StrictMode -Version Latest the read threw and the assertion NEVER RAN
# ONCE. Its siblings passed because -ForEach is evaluated while discovering,
# which is the same phase the lists are built in - so this check is fed the
# same way, one case per classified name.
$script:HDTKnownStepType = @($script:HDTStepProgressCase | ForEach-Object { $_.Type })

$script:HDTClassifiedNameCase = @(
    @($script:HDTReportingStep.Keys) + @($script:HDTQuietStep.Keys) |
        ForEach-Object {
            @{
                ClassifiedType = [string] $_
                IsKnown        = $script:HDTKnownStepType -contains [string] $_
            }
        })

Describe 'the long-step progress contract' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:stepFileRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Steps'
    }

    Context 'every step type is classified' {

        # THE TEST THAT CATCHES THE NEXT ONE. A step type added without a
        # decision about whether it can run for minutes fails here, by name,
        # before anybody deploys with it.
        It 'classifies <Type> as either reporting or quiet, with a reason' -ForEach $script:HDTStepProgressCase {
            $IsClassified | Should -BeTrue -Because (
                "every step type must be listed in this file as one that reports progress or one that cannot, " +
                "with the reason. '$Type' is in neither list, so nobody has decided whether it can occupy a " +
                'deployment for minutes in silence.')
        }

        # A name left behind after a step type was renamed or removed would
        # exempt nothing and look like it exempted something.
        It 'classifies <ClassifiedType>, which the registry still has' -ForEach $script:HDTClassifiedNameCase {
            $IsKnown | Should -BeTrue -Because (
                "'$ClassifiedType' is classified in this file as reporting or quiet, but it is not a step type " +
                'this module exports. A name left behind by a rename or a removal exempts nothing and looks ' +
                'like it exempted something.')
        }
    }

    Context 'a step that can run for minutes reports while it runs' {

        # PARSED RATHER THAN EXECUTED, and deliberately: running these for real
        # would need an image, a disk and an encrypting volume. What is asserted
        # is that the two lines exist in the step's own file - the record, and
        # the nudge that makes the window read it. Each step's UNIT tests then
        # prove the records come out in the right order and at the right stride
        # against the fakes; this file's job is to prove nobody FORGOT.
        It '<Type> writes a step.progress record' -ForEach $script:HDTMustReportCase {
            $path = Join-Path -Path $script:stepFileRoot -ChildPath ('{0}.ps1' -f $InvokeName)
            $text = [System.IO.File]::ReadAllText($path)

            $text | Should -Match "step\.progress" -Because (
                "$Type can occupy a deployment for minutes. Without a record between its start and its finish " +
                'the progress card shows the same frame throughout AND its elapsed clock stops, because elapsed ' +
                'is derived from the first and last record in the log.')
        }

        It '<Type> asks the display to re-read the log' -ForEach $script:HDTMustReportCase {
            $path = Join-Path -Path $script:stepFileRoot -ChildPath ('{0}.ps1' -f $InvokeName)
            $text = [System.IO.File]::ReadAllText($path)

            # THE RECORD ALONE IS NOT ENOUGH, and this is the half that was
            # missing for ApplyDrivers: the line was written to the JSONL and
            # nothing told the window to look, so the step reported into a file
            # nobody was reading.
            $text | Should -Match "Update-HDTProgressDisplay" -Because (
                "$Type writes a step.progress, but a record nothing reads back is a record that draws nothing.")
        }

        It '<Type> reports through the log rather than through a channel of its own' -ForEach $script:HDTMustReportCase {
            $path = Join-Path -Path $script:stepFileRoot -ChildPath ('{0}.ps1' -f $InvokeName)
            $text = [System.IO.File]::ReadAllText($path)

            # DESIGN 11.1: "there is exactly one source of truth for what the
            # deployment is doing, so the screen and the log can never
            # disagree". A step calling the progress host directly would be a
            # second truth, and the first thing it would do is drift on a
            # resume.
            $text | Should -Not -Match "Service\.Progress" -Because (
                "$Type must report by writing a record and asking the display to re-read it, never by pushing " +
                'to the progress host itself (DESIGN 11.1).')
        }
    }
}
