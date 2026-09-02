function Invoke-HDTApplyUpdatesStep {
    <#
        .SYNOPSIS
            Applies imported Windows updates to the applied OS volume, offline,
            before the machine first boots.

        .DESCRIPTION
            MDT'S Packages NODE, IN HDT'S SHAPE. The updates an administrator
            imported into WindowsUpdates\ are injected into the volume the image
            was just laid onto, so the machine boots patched rather than spending
            its first hour on Windows Update. This is NOT the deferred
            WindowsUpdate step in DESIGN 10.1: that one is online, full-OS and
            talks to WSUS. This one is offline servicing in WinPE and shares
            nothing with it but a subject.

            THE PACKAGE IS HANDED TO DISM AS IT WAS DOWNLOADED, and that was
            measured rather than assumed. A modern .msu is a WIM container
            holding an express package - a .wim beside a .psf carrying the deltas
            - and pointing /Add-Package at that inner .wim fails 0x80070057.
            Handing dism the .msu works, on both packages, against both a client
            and a server image. So nothing is unpacked here, at import or at
            apply, which is also why the store is the size of the downloads.

            THE EXIT CODE IS NOT THE VERDICT. dism exited 0xC0000409 after a
            Windows 11 apply that had plainly worked - the image went from
            10.0.26100.1742 to 10.0.26100.8655 and its package count went from 85
            to 159 - and exited 0 after the equivalent Server apply. So this step
            asks the IMAGE what it has afterwards, through GetPackage, and
            believes that. It is also the only check immune to dism's prose being
            localised, since nothing in the adapter pins a language.

            EVERY PACKAGE GETS ITS OWN LOG RECORD, never one summary for the
            pass. Twenty updates in a sequence is twenty questions somebody will
            ask afterwards - which one was already in the image, which one wanted
            a prerequisite, which one actually failed - and update.apply carries
            the KB, the release, dism's code and the outcome for each. The
            updates that were NOT in the pass get one too, at Info, saying which
            release filed them or that somebody disabled them: "why did this
            machine not get KB5094125" is the question a broad import guarantees,
            and a log that mentions only the chosen one cannot answer it.

            AND THE METER IS STREAMED, WHICH IS THE DIFFERENCE BETWEEN A BAR AND
            A PHOTOGRAPH OF ONE. dism prints a percentage while it services -
            measured on this machine on 2026-09-02: one WinPE-NetFx.cab printed
            124 lines of which 58 were the bar - and the adapter now hands every
            line to a callback instead of collecting it into an array nobody
            read. The step that discarded it wrote TWO step.progress records for
            a 515-second step on HDT-UPD-01 run-20260902-004953, which on the
            machine itself is a bar that never moves and cannot be told from a
            hang.

            EACH PACKAGE'S METER IS A SLICE OF THE STEP, NOT THE WHOLE OF IT.
            Three cumulative updates each reporting their own 0-100% would send
            the bar back to zero twice, and a bar that restarts reads as a
            deployment that restarted - a worse lie than the motionless bar it
            replaces. So data.percent is the step's number, package 2 of 4 at
            50% being 37%, while the MESSAGE keeps the package's own percentage,
            because that is what dism printed and what a technician with
            dism.log open is matching against.

            NOT APPLICABLE IS NOT A FAILURE, and this is where the step parts
            company with a naive reading of DISM's exit codes. 0x800F081E means
            the package does not apply to this image, which is the ORDINARY
            result of importing a broad set and letting a sequence pick from it.
            MDT swallows every error here - ZTIPatches logs a non-zero DISM
            return and still returns Success - and this step keeps the half of
            that which is right (apply everything, never stop at the first
            problem) and rejects the half which is not (report success
            regardless). A package that failed for any other reason fails the
            step, AFTER every other package has been tried.

        .PARAMETER Step
            The step, carrying release and target.

        .PARAMETER Context
            The execution context: services, variables and the log.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            A New-HDTStepResult. Data carries release, target, considered,
            applied, alreadyPresent, notApplicable and failed.

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\PNP-TEST\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'ApplyUpdates' })[0]
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs'
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'C:\HDTLab\Share' `
                -Variable ([ordered] @{ HDTOSVolume = 'W' }) -Service (New-HDTServiceCatalog) -Log $log

            Invoke-HDTApplyUpdatesStep -Step $step -Context $context

            Applies every update filed under the step's release to the volume
            HDTOSVolume names, writing one log record per package.

        .EXAMPLE
            $result = Invoke-HDTApplyUpdatesStep -Step $step -Context $context
            $result.Data['applied']
            $result.Data['notApplicable']

            How many landed and how many did not apply to this image. A package
            that is not applicable is not a failure - importing a broad set and
            letting a sequence pick from it is the ordinary workflow.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $fail = {
        param([string] $Message, [string] $ErrorId)

        $data = [ordered] @{}
        if (-not [string]::IsNullOrWhiteSpace($ErrorId)) { $data['errorId'] = $ErrorId }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component 'ApplyUpdates' -Data $data

        return (New-HDTStepResult -Status Failed -Message $Message -Data $data)
    }

    try {
        $release = Get-HDTStepProperty -Step $Step -Name 'release' -Default '' -Context $Context -Expand -As String
        $target = Get-HDTStepProperty -Step $Step -Name 'target' -Default 'primary' -Context $Context -Expand -As String

        # What the author wrote, unexpanded, so a refusal can name the variable
        # that was meant to fill an empty target - ApplyDrivers' rule, and for
        # the same reason: the expanded value alone cannot say which rule built it.
        $targetWritten = Get-HDTStepProperty -Step $Step -Name 'target' -Default 'primary' -As String
    } catch {
        return (& $fail ([string] $_.Exception.Message) 'HDTConfigurationError')
    }

    try {
        $fileSystem = $Context.Service.GetRequired('FileSystem', 'ApplyUpdates')
        $image = $Context.Service.GetRequired('Image', 'ApplyUpdates')
    } catch {
        return (& $fail ([string] $_.Exception.Message) '')
    }

    # -- where -------------------------------------------------------------

    $letter = $target

    if ($target -eq 'primary') { $letter = [string] $Context.Variable['HDTOSVolume'] }

    if ($null -eq $letter) { $letter = '' }
    $letter = $letter.Trim().TrimEnd('\').TrimEnd(':')

    if ($letter.Length -eq 0) {
        $said = "step '{0}' services the primary volume and HDTOSVolume is not set. The partition step publishes it; HDT will not guess a volume to inject updates into." -f $Step.Name

        if ($targetWritten -match '^\s*%([^%]+)%\s*$') {
            $said = "step '{0}' services %{1}%, which is not set. The partition step publishes it; HDT will not guess a volume to inject updates into." -f
                $Step.Name, [string] $Matches[1]
        }

        return (& $fail $said 'HDTConfigurationError')
    }

    $osRoot = '{0}:\' -f $letter

    # -- what --------------------------------------------------------------

    $workspaceRoot = [string] $Context.WorkspaceRoot

    try {
        # ALREADY IN APPLY ORDER. Get-HDTWindowsUpdate sorts through
        # Get-HDTUpdateApplyOrder - servicing stack first, then by the build each
        # update produces - so the step does not re-decide an ordering that is
        # decided in one place.
        $update = @(Get-HDTWindowsUpdate -WorkspaceRoot $workspaceRoot -FileSystem $fileSystem)
    } catch {
        return (& $fail ("step '{0}' could not read the workspace's Windows updates: {1}" -f
                $Step.Name, [string] $_.Exception.Message) 'HDTConfigurationError')
    }

    $imported = $update.Count

    # EVERY UPDATE THE STORE HAD, AND WHY EACH ONE IS OR IS NOT IN THIS PASS.
    # The step used to say "considering 1 update(s)" and nothing whatever about
    # the other nineteen, which makes "why did this machine not get KB5094125"
    # unanswerable from the log - the exact question a broad import guarantees
    # somebody will ask. CLAUDE.md: write too much, never too little.
    #
    # 'message' AND NOT update.apply, and the distinction is the one the
    # vocabulary already draws. update.apply means "this is what happened when
    # this update was APPLIED", and every reader of that stream reads an
    # outcome; an update that was never handed to dism has no outcome and would
    # be a blank row in each of them. data.selected is the discriminator a
    # reader filters on instead.
    #
    # AN EMPTY release IS "EVERYTHING IMPORTED", which is the setting for a share
    # deploying one operating system. It is a real choice, not a missing value,
    # so it is not an error.
    #
    # A DISABLED UPDATE IS ONE SOMEBODY TOOK OUT OF SERVICE WITHOUT DELETING IT,
    # which is how an update that turned out to break something is withdrawn
    # while the evidence is kept.
    $selected = New-Object -TypeName System.Collections.ArrayList

    foreach ($candidate in $update) {

        $why = ''

        if (-not [string]::IsNullOrWhiteSpace($release) -and [string] $candidate.Release -ne $release) {
            $why = "it is filed under release '{0}' and this step applies '{1}'" -f
                [string] $candidate.Release, $release
        } elseif (-not [bool] $candidate.Enabled) {
            $why = 'it is disabled in the workspace, so somebody took it out of service without deleting it'
        }

        if ($why.Length -eq 0) {
            [void] $selected.Add($candidate)

            Write-HDTLog -Context $Context.Log -Event 'message' -Component 'ApplyUpdates' `
                -Message ("{0} ({1}) is in this pass: {2}, {3} -> {4}" -f
                    [string] $candidate.Kb, [string] $candidate.Release, [string] $candidate.Name,
                    $(if ([string]::IsNullOrWhiteSpace([string] $candidate.BaselineVersion)) { 'any build' } else { [string] $candidate.BaselineVersion }),
                    [string] $candidate.TargetVersion) `
                -Data ([ordered] @{
                    kb              = [string] $candidate.Kb
                    release         = [string] $candidate.Release
                    selected        = $true
                    kind            = [string] $candidate.Kind
                    packageId       = [string] $candidate.PackageId
                    package         = [string] $candidate.FileName
                    baselineVersion = [string] $candidate.BaselineVersion
                    targetVersion   = [string] $candidate.TargetVersion
                })

            continue
        }

        Write-HDTLog -Context $Context.Log -Event 'message' -Component 'ApplyUpdates' `
            -Message ("{0} ({1}) is not in this pass: {2}" -f
                [string] $candidate.Kb, [string] $candidate.Release, $why) `
            -Data ([ordered] @{
                kb       = [string] $candidate.Kb
                release  = [string] $candidate.Release
                selected = $false
                reason   = $why
            })
    }

    $update = @($selected)

    # step.progress AND NOT update.apply, BECAUSE THIS RECORD IS ABOUT NO
    # PARTICULAR UPDATE. update.apply is documented as one update applied, and
    # anything filtering it reads data.kb; a kb-less record in that stream is a
    # blank row in every report that renders one - which is exactly the defect
    # that split var.resolve from var.unresolved.
    Write-HDTLog -Context $Context.Log -Event 'step.progress' -Component 'ApplyUpdates' `
        -Message ("step '{0}' considering {1} of {2} imported update(s) for {3}, into {4}" -f
            $Step.Name, $update.Count, $imported,
            $(if ([string]::IsNullOrWhiteSpace($release)) { 'every release' } else { $release }), $osRoot) `
        -Data ([ordered] @{
            percent    = 0
            release    = $release
            target     = $osRoot
            imported   = $imported
            considered = $update.Count
        })

    if ($update.Count -eq 0) {
        # NOTHING TO DO IS NOT A FAILURE. A sequence that runs before any update
        # has been imported is a sequence somebody is building, and refusing it
        # would make the step impossible to add before its content exists.
        return (New-HDTStepResult -Status Completed `
                -Message ("no Windows update to apply for {0}" -f
                    $(if ([string]::IsNullOrWhiteSpace($release)) { 'this workspace' } else { "release '$release'" })) `
                -Data ([ordered] @{
                    release        = $release
                    target         = $osRoot
                    considered     = 0
                    applied        = 0
                    alreadyPresent = 0
                    notApplicable  = 0
                    failed         = 0
                }))
    }

    # -- apply -------------------------------------------------------------

    $applied = 0
    $alreadyPresent = 0
    $notApplicable = 0
    $failedRow = New-Object -TypeName System.Collections.ArrayList

    $index = 0
    $total = $update.Count

    # THE THREE COMMANDS, RESOLVED HERE RATHER THAN NAMED IN THE CALLBACK BELOW,
    # AND IT IS NOT STYLE. The callback is invoked from INSIDE the image service:
    # the real one is a pscustomobject built in this module, but the fake is a
    # PowerShell CLASS in HDTFakes, and a scriptblock invoked from a class method
    # resolves its commands in the class's module - where
    # ConvertFrom-HDTDismProgressLine, private to Hephaestus, does not exist.
    # That failure lands in the callback's own catch and looks exactly like a
    # dism that printed no percentages, with every other assertion still passing.
    # A CommandInfo invoked with & carries its own module and does not care.
    # Invoke-HDTApplyImageStep learned this first; see its note.
    $parseProgress = Get-Command -Name 'ConvertFrom-HDTDismProgressLine'
    $writeLog = Get-Command -Name 'Write-HDTLog'
    $updateDisplay = Get-Command -Name 'Update-HDTProgressDisplay'

    foreach ($current in $update) {

        $index = $index + 1

        # WHERE THIS PACKAGE'S SLICE OF THE STEP STARTS AND HOW WIDE IT IS.
        #
        # THE BAR BELONGS TO THE STEP, NOT TO THE PACKAGE, and that is the whole
        # decision here. Three cumulative updates each reporting their own
        # 0-100% would drive the bar back to zero twice, and a bar that restarts
        # reads as a deployment that restarted - which is a worse lie than the
        # motionless bar this replaces. So each package's own meter is mapped
        # onto its share of the step: package 2 of 4 at 50% is 37% of the step.
        #
        # AND THE MESSAGE KEEPS THE PACKAGE'S OWN NUMBER, because that is the
        # number dism printed and the one a technician with dism.log open beside
        # this is matching against. The record carries both: data.percent for the
        # bar, data.packagePercent for the reader.
        #
        # A HASHTABLE, NOT TWO VARIABLES. GetNewClosure captures by VALUE, so a
        # closed-over [int] the callback assigned to would be re-read as its
        # original on the next line and every meter line would clear the
        # threshold. The same shape New-HDTStepHeartbeat carries, for the same
        # reason - and it is also how the failure path below can still read how
        # far the package got after the call threw.
        $slice = @{
            Base           = [int] ([math]::Floor((($index - 1) * 100) / $total))
            PackagePercent = 0
        }

        Write-HDTLog -Context $Context.Log -Event 'step.progress' -Component 'ApplyUpdates' `
            -Message ("applying {0} ({1} of {2}) to {3}: {4} -> {5}" -f
                $current.Kb, $index, $total, $osRoot,
                $(if ([string]::IsNullOrWhiteSpace([string] $current.BaselineVersion)) { 'any build' } else { [string] $current.BaselineVersion }),
                [string] $current.TargetVersion) `
            -Data ([ordered] @{
                percent         = $slice['Base']
                kb              = [string] $current.Kb
                release         = [string] $current.Release
                index           = $index
                total           = $total
                target          = $osRoot
                package         = [string] $current.FileName
                baselineVersion = [string] $current.BaselineVersion
                targetVersion   = [string] $current.TargetVersion
            })

        # THE ONLY NUMBER THAT MOVES FOR THE NEXT EIGHT TO TWELVE MINUTES.
        # dism /Add-Package prints a percentage meter - measured on this machine
        # on 2026-09-02, 58 bar lines out of 124 for one WinPE-NetFx.cab - and
        # the adapter hands every line it prints to this.
        #
        # STILL NO SECOND CHANNEL (DESIGN 11.1). This writes a record to the
        # JSONL and asks the display to re-read it; the screen and the log cannot
        # disagree because they are the same facts.
        #
        # EVERY FIVE POINTS OF THE PACKAGE, AND ALWAYS AT A HUNDRED. Throttling
        # on the PACKAGE rather than on the step is deliberate: a five-point
        # STEP stride would give twenty records for a pass of three packages -
        # one every ninety seconds of a half-hour step - where five points of
        # each package gives twenty per package and keeps the stride the same
        # whatever the set size. A hundred is reported whether or not it clears
        # the threshold, because the last thing the log says about a package
        # should be that its meter finished.
        #
        # THE GAP THAT REMAINS, and it is ApplyImage's: a dism that goes silent
        # mid-package reports nothing until it speaks again. Closing it means
        # running dism as a polled process, which is ApplyUnattend's shape and a
        # change to an adapter proven only in tests/integration.
        $onOutput = {
            param([string] $Line)

            # A BAR DOES NOT GET TO FAIL A DEPLOYMENT. This runs part-way through
            # servicing an operating system; a log write that lost its RAM disk
            # or a display whose runspace has died is not a reason to stop
            # building a computer.
            try {
                $percent = & $parseProgress -Line $Line
                if ($null -eq $percent) { return }

                $reported = [int] $slice['PackagePercent']
                if ([int] $percent -le $reported) { return }
                if ([int] $percent -lt ($reported + 5) -and [int] $percent -lt 100) { return }

                $slice['PackagePercent'] = [int] $percent

                # THE STEP'S NUMBER: this package's position plus its own share
                # of one slice. Monotonic across the set by construction, because
                # the package's own meter is monotonic and the base only rises.
                $stepPercent = [int] ([math]::Floor(((($index - 1) * 100) + [int] $percent) / $total))

                & $writeLog -Context $Context.Log -Event 'step.progress' -Component 'ApplyUpdates' `
                    -Message ('applying {0} ({1} of {2}): {3}%' -f $current.Kb, $index, $total, [int] $percent) `
                    -Data ([ordered] @{
                        percent        = $stepPercent
                        packagePercent = [int] $percent
                        kb             = [string] $current.Kb
                        index          = $index
                        total          = $total
                        target         = $osRoot
                    })

                & $updateDisplay -Context $Context
            } catch {
                # Kept where a debugger can reach it rather than thrown away: an
                # empty catch is how a percentage that never appeared stays a
                # mystery.
                $slice['Error'] = [string] $_.Exception.Message
            }
        }.GetNewClosure()

        # AND THEN TELL THE WINDOW TO LOOK. Update-HDTProgressDisplay re-reads
        # the log and hands the host a new snapshot; without this the record
        # above is written and never drawn. The same two lines ApplyImage,
        # ApplyDrivers and InstallApplications use, and it is documented never to
        # fail a deployment.
        #
        # IT MATTERS MORE HERE THAN ALMOST ANYWHERE. A cumulative update is eight
        # to twelve minutes of one frame - measured, 8m35s for KB5094126 and
        # 12m24s for KB5094125 - and this line is the only thing that moves in
        # front of whoever is standing at the machine.
        Update-HDTProgressDisplay -Context $Context

        # WHAT THE IMAGE HAD BEFORE, so "already present" can be told from
        # "applied" - and so a package identity that was there all along is not
        # counted as this step's work.
        $before = @()
        try {
            $before = @($image.GetPackage($osRoot) | ForEach-Object { [string] $_.Name })
        } catch {
            $before = @()
        }

        $wasPresent = $false
        if (-not [string]::IsNullOrWhiteSpace([string] $current.PackageId)) {
            $wasPresent = @($before | Where-Object { Test-HDTUpdatePackageMatch -Installed $_ -PackageId ([string] $current.PackageId) }).Count -gt 0
        }

        if ($wasPresent) {
            $alreadyPresent = $alreadyPresent + 1

            Write-HDTLog -Context $Context.Log -Event 'update.apply' -Component 'ApplyUpdates' `
                -Message ("{0} was already in the image at {1}, so it was not applied again" -f
                    $current.Kb, $osRoot) `
                -Data ([ordered] @{
                    kb                 = [string] $current.Kb
                    release            = [string] $current.Release
                    outcome            = 'AlreadyPresent'
                    packageId          = [string] $current.PackageId
                    package            = [string] $current.FileName
                    target             = $osRoot
                    baselineVersion    = [string] $current.BaselineVersion
                    targetVersion      = [string] $current.TargetVersion
                    packageCountBefore = $before.Count
                })

            continue
        }

        $run = $null
        try {
            $run = $image.AddPackage($osRoot, [string] $current.PackagePath, $onOutput)
        } catch {
            [void] $failedRow.Add([string] $current.Kb)

            Write-HDTLog -Context $Context.Log -Event 'update.apply' -Component 'ApplyUpdates' -Severity Error `
                -Message ("{0} could not be applied: {1}" -f $current.Kb, [string] $_.Exception.Message) `
                -Data ([ordered] @{
                    kb             = [string] $current.Kb
                    release        = [string] $current.Release
                    outcome        = 'Failed'
                    target         = $osRoot
                    package        = [string] $current.FileName

                    # HOW FAR IT GOT BEFORE IT DIED. A package that died at 60%
                    # died somewhere different from one that never started, and
                    # after the call has thrown this is the only record of which.
                    packagePercent = [int] $slice['PackagePercent']
                })

            continue
        }

        $exitCode = [int] $run.ExitCode

        # WHAT THE IMAGE HAS NOW, WHICH IS THE VERDICT. Not the exit code: dism
        # exited 0xC0000409 after an apply that had demonstrably worked and 0
        # after another, so the number is evidence and the image is the truth.
        $after = @()
        try {
            $after = @($image.GetPackage($osRoot) | ForEach-Object { [string] $_.Name })
        } catch {
            $after = @()
        }

        $landed = $false
        if (-not [string]::IsNullOrWhiteSpace([string] $current.PackageId)) {
            $landed = @($after | Where-Object { Test-HDTUpdatePackageMatch -Installed $_ -PackageId ([string] $current.PackageId) }).Count -gt 0
        }

        $outcome = Get-HDTUpdateApplyOutcome -ExitCode $exitCode -Landed $landed `
            -HasPackageId (-not [string]::IsNullOrWhiteSpace([string] $current.PackageId)) `
            -PackageCountChanged ($after.Count -ne $before.Count)

        if ($outcome.Outcome -eq 'Applied') { $applied = $applied + 1 }
        if ($outcome.Outcome -eq 'NotApplicable') { $notApplicable = $notApplicable + 1 }
        if ($outcome.Outcome -eq 'Failed') { [void] $failedRow.Add([string] $current.Kb) }

        Write-HDTLog -Context $Context.Log -Event 'update.apply' -Component 'ApplyUpdates' `
            -Severity $outcome.Severity `
            -Message ("{0} ({1}): {2}. dism exited 0x{3:X8}; the image now carries {4} package(s), it carried {5}." -f
                $current.Kb, $current.Release, $outcome.Message, $exitCode, $after.Count, $before.Count) `
            -Data ([ordered] @{
                kb        = [string] $current.Kb
                release   = [string] $current.Release
                outcome   = [string] $outcome.Outcome
                exitCode  = $exitCode

                # THE SAME NUMBER SPELLED THE WAY THE TOOL SPELLS IT. 0xC0000409
                # is what a technician searches dism.log and the web for;
                # -1073740791 is the same fact in a form nobody can look up.
                exitCodeHex = ('0x{0:X8}' -f $exitCode)

                packageId = [string] $current.PackageId
                package   = [string] $current.FileName
                target    = $osRoot

                # WHAT THIS PACKAGE CLAIMS TO DO TO THE IMAGE. "it patched" is
                # not an answer at three in the morning; 26100.1742 -> 26100.8655
                # is, and it is the build a technician compares winver against.
                baselineVersion = [string] $current.BaselineVersion
                targetVersion   = [string] $current.TargetVersion

                # THE WITNESS ITSELF, IN NUMBERS. 85 packages becoming 159 is
                # what proved the 0xC0000409 apply had worked, and a reader who
                # doubts the verdict wants to see the same evidence it used.
                packageCountBefore = $before.Count
                packageCountAfter  = $after.Count
            })
    }

    $data = [ordered] @{
        release        = $release
        target         = $osRoot
        considered     = $update.Count
        applied        = $applied
        alreadyPresent = $alreadyPresent
        notApplicable  = $notApplicable
        failed         = $failedRow.Count
    }

    if ($failedRow.Count -gt 0) {
        # EVERY PACKAGE WAS TRIED FIRST, AND THE FAILURE NAMES ALL OF THEM. MDT
        # stops at neither, and reports neither; this step does the first half
        # its way and refuses the second.
        $said = "step '{0}': {1} of {2} update(s) could not be applied to {3}: {4}. The others were applied; see the update.apply records for each." -f
            $Step.Name, $failedRow.Count, $update.Count, $osRoot, (@($failedRow) -join ', ')

        # THE COUNTS TRAVEL WITH THE FAILURE, NOT ONLY WITH SUCCESS. "One of two
        # failed" and "both failed" are different machines to walk up to, and a
        # failure result carrying nothing but an errorId makes them look the same
        # in the report - so the same Data the success path returns is returned
        # here, with the errorId added rather than substituted for it.
        $data['errorId'] = 'HDTUpdateError'
        $data['failedKb'] = (@($failedRow) -join ', ')

        Write-HDTLog -Context $Context.Log -Message $said -Severity Error -Event step.fail `
            -Component 'ApplyUpdates' -Data $data

        return (New-HDTStepResult -Status Failed -Message $said -Data $data)
    }

    return (New-HDTStepResult -Status Completed `
            -Message ("{0} update(s) applied to {1}, {2} already present, {3} not applicable" -f
                $applied, $osRoot, $alreadyPresent, $notApplicable) `
            -Data $data)
}
