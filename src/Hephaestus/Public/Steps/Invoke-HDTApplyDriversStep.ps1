function Invoke-HDTApplyDriversStep {
    <#
        .SYNOPSIS
            Injects drivers into the applied operating system.

        .DESCRIPTION
            Injects drivers into an operating system already applied to disk.
            Group match is the primary path and the PnP ranking is the fallback,
            which is the order DESIGN 7 keeps.

            THE GROUP IS A PATH AN ADMINISTRATOR WROTE, NOT A SHAPE HDT IMPOSES.
            A rule sets HDTDriverGroup - 'Win11\%HDTMake%\%HDTModel%' is the
            Total Control layout, and the one New-HDTWorkspace seeds as a
            comment - and this expands it against the live variables. Any
            depth, any folder names. Nothing here discovers, requires or
            creates a Make\Model tree; the store under Drivers\ is whatever
            the administrator built.

            WHEN THE GROUP RESOLVES, THE FOLDER GOES IN WHOLE and the ranking is
            never consulted. That is the point of Total Control: somebody has
            already decided what this model gets, and a ranking that second-
            guessed them would be a worse answer arrived at more slowly.

            THE FALLBACK IS FOR THE MODEL NOBODY WROTE A RULE FOR. It asks the
            machine what it has, ranks the store against those ids, and injects
            the matches. Without it an unrecognised model deploys with whatever
            was inbox in the image - which for a machine needing an OEM NIC or
            storage driver means a computer that cannot see its network or its
            disk.

            INJECTION IS OFFLINE, INTO THE APPLIED VOLUME: Add-WindowsDriver
            against W:\ writes the driver into
            W:\Windows\System32\DriverStore\FileRepository and stages it, and
            WINDOWS binds it to a device on the first boot. Nothing here
            installs a driver onto a running machine, so this step must run
            AFTER ApplyImage and BEFORE the first reboot.

            EVERY DECISION GOES IN THE LOG, AND THAT IS A REQUIREMENT RATHER
            THAN A COURTESY. The group that was resolved and whether it existed;
            that a fallback happened AND that a missing folder is why; how many
            devices the machine reported; per driver the id it matched, at what
            rank, off HardwareID or CompatibleID, and which device earned it;
            and what DISM said came back, which is the name the driver has on
            the machine afterwards. A deployment whose network card does not
            work is diagnosed from this log or it is diagnosed by rebuilding the
            whole deployment.

            NOTHING MATCHING IS NOT A FAILED DEPLOYMENT. A machine with inbox
            drivers still boots, so the step completes with a count of zero and
            says so loudly.

        .PARAMETER Step
            The step, with its type-specific properties: group, profile, mode
            and target.

        .PARAMETER Context
            The execution context, carrying the services and the live variables.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            A New-HDTStepResult. Data carries group, injected, matched and
            durationMs, or errorId on a refusal.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock `
                -Image (New-HDTImageService) -Cim (New-HDTCimProvider)
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{ HDTOSVolume = 'W' }) `
                -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-M4\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'ApplyDrivers' })[0]

            Invoke-HDTApplyDriversStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTApplyDriversStep -Step $step -Context $context
            $result.Data['matched']
            $result.Data['injected']

            How many drivers the machine matched, and how many went in. They differ
            when DISM refused one - and both being zero is a completed step that
            deployed nothing, which is why it is a warning in the log rather than
            a silent success.

        .LINK
            Get-HDTDriverMatch

        .LINK
            Get-HDTPresentDevice
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
            -Component 'ApplyDrivers' -Data $data

        return (New-HDTStepResult -Status Failed -Message $Message -Data $data)
    }

    try {
        $group = Get-HDTStepProperty -Step $Step -Name 'group' -Default '' -Context $Context -Expand -As String
        $profileName = Get-HDTStepProperty -Step $Step -Name 'profile' -Default '' -Context $Context -Expand -As String
        $mode = Get-HDTStepProperty -Step $Step -Name 'mode' -Default 'all' -Context $Context -Expand -As String
        $target = Get-HDTStepProperty -Step $Step -Name 'target' -Default 'primary' -Context $Context -Expand -As String

        # What the author wrote, unexpanded, so a refusal can name the variable
        # that was meant to fill an empty target.
        $targetWritten = Get-HDTStepProperty -Step $Step -Name 'target' -Default 'primary' -As String
    } catch {
        return (& $fail ([string] $_.Exception.Message) 'HDTConfigurationError')
    }

    if ($mode -notin @('all', 'matching')) {
        return (& $fail ("step '{0}': mode '{1}' is not 'all' or 'matching'. MDT's two choices are to install every driver in the selection, or only the ones that match this machine." -f
                $Step.Name, $mode) 'HDTConfigurationError')
    }

    try {
        $imageService = $Context.Service.GetRequired('Image', 'ApplyDrivers')
        $fileSystem = $Context.Service.GetRequired('FileSystem', 'ApplyDrivers')
    } catch {
        return (& $fail ([string] $_.Exception.Message) '')
    }

    # -- where ------------------------------------------------------------

    $letter = $target

    if ($target -eq 'primary') { $letter = [string] $Context.Variable['HDTOSVolume'] }

    if ($null -eq $letter) { $letter = '' }
    $letter = $letter.Trim().TrimEnd('\').TrimEnd(':')

    if ($letter.Length -eq 0) {
        $said = "step '{0}' injects into the primary volume and HDTOSVolume is not set. The partition step publishes it; HDT will not guess a drive letter to write drivers into." -f $Step.Name

        if ($targetWritten -match '^\s*%([^%]+)%\s*$') {
            $said = "step '{0}' injects into %{1}%, which is not set. The partition step publishes it; HDT will not guess a drive letter to write drivers into." -f
                $Step.Name, [string] $Matches[1]
        }

        return (& $fail $said 'HDTConfigurationError')
    }

    if ($letter -notmatch '^[A-Za-z]$') {
        return (& $fail ("step '{0}': target '{1}' is not a drive letter." -f $Step.Name, $target) 'HDTConfigurationError')
    }

    $applyPath = '{0}:\' -f $letter.Substring(0, 1).ToUpperInvariant()

    # -- which folder -----------------------------------------------------

    $driverRoot = Get-HDTWorkspacePath -Root ([string] $Context.WorkspaceRoot) -Kind Drivers

    $groupPath = ''
    $groupFound = $false

    if (-not [string]::IsNullOrWhiteSpace($group)) {
        # [IO.Path]::Combine, not Join-Path, for the reason Get-HDTWorkspacePath
        # records: Join-Path resolves the drive qualifier, so a share on a drive
        # this process has not got - which is every share under a fake, and a
        # mapped Z: that WinPE has not connected yet - throws DriveNotFound
        # instead of composing a string.
        #
        # AND THE GROUP IS TRIMMED OF ITS LEADING SLASH, because a rooted second
        # segment makes Combine discard everything to its left: a rule that set
        # HDTDriverGroup to '\Win11\Dell' would otherwise resolve to \Win11\Dell
        # on the system drive rather than under the share.
        $groupPath = [System.IO.Path]::Combine($driverRoot, $group.TrimStart('\', '/'))
        $groupFound = [bool] $fileSystem.TestPath($groupPath)
    }

    # THE GROUP IS LOGGED WHETHER OR NOT IT RESOLVED, because "which folder did
    # it look in" is the first question asked of a deployment that got no
    # drivers, and a log that only records successes cannot answer it.
    Write-HDTLog -Context $Context.Log -Event 'driver.group' -Component 'ApplyDrivers' `
        -Message ("driver group '{0}' {1}" -f $groupPath, $(if ($groupFound) { 'resolved' } else { 'is not on the share' })) `
        -Data ([ordered] @{
            group   = [string] $groupPath
            written = [string] $group
            found   = [bool] $groupFound
            mode    = [string] $mode
        })

    $clock = $Context.Service.Clock
    $startedUtc = $clock.GetUtcNow()

    $injected = New-Object -TypeName System.Collections.ArrayList
    $matchedCount = 0

    # The published names already reported, so a cumulative answer from DISM is
    # counted once. Ordinal-ignore-case because oem12.inf is a filename.
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList (
        [System.StringComparer]::OrdinalIgnoreCase)

    # RESOLVED HERE, WHERE THIS FUNCTION IS. Invoke-HDTApplyImageStep resolves
    # its own the same way and says why: a CommandInfo invoked with & does not
    # care whose scope it is called from, and a private command looked up from
    # inside a closure later can fail to resolve while every other assertion
    # still passes.
    $updateDisplay = Get-Command -Name 'Update-HDTProgressDisplay'

    $inject = {
        param([string] $Path, [bool] $Recurse)

        $added = @($imageService.AddDriver($applyPath, $Path, $Recurse))

        foreach ($row in $added) {
            # ADD-WINDOWSDRIVER ANSWERS WITH THE IMAGE, NOT WITH THE CALL.
            # Every call returns the drivers now in the store, so the second
            # injection re-reports the first, the third re-reports both, and the
            # step's own count runs away from the machine: 53 matched packages
            # were logged as 'injected 82 driver(s)' on a real deployment whose
            # store held 54 published names. A published name is reported once,
            # the first time it appears, and the count is the number of them.
            if ($seen.Contains([string] $row.Inf)) { continue }
            [void] $seen.Add([string] $row.Inf)

            [void] $injected.Add($row)

            # WHAT DISM SAID CAME BACK, not what was asked of it. Add-WindowsDriver
            # answers with the published name - oem12.inf - and that is the name
            # the driver has in the machine's store afterwards. A log carrying
            # only the request cannot be reconciled against the machine later.
            Write-HDTLog -Context $Context.Log -Event 'driver.injected' -Component 'ApplyDrivers' `
                -Message ('injected {0} ({1} {2})' -f [string] $row.Inf, [string] $row.Provider, [string] $row.Version) `
                -Data ([ordered] @{
                    inf      = [string] $row.Inf
                    provider = [string] $row.Provider
                    version  = [string] $row.Version
                    date     = [string] $row.Date
                    source   = [string] $Path
                })
        }
    }

    try {
        if ($groupFound -and $mode -eq 'all') {
            # THE WHOLE FOLDER, RECURSED - one DISM call, which is what MDT does
            # and what a vendor pack of a hundred and forty .inf files wants.
            & $inject $groupPath $true
        } else {
            if (-not $groupFound) {
                $why = 'no group was named'
                if (-not [string]::IsNullOrWhiteSpace($group)) {
                    $why = "the group folder '{0}' is not on the share" -f $groupPath
                }

                # THE REASON, NOT JUST THE FACT. "It fell back" and "it fell back
                # because somebody's rule built a path that is not there" are
                # different bugs with the same symptom.
                Write-HDTLog -Context $Context.Log -Event 'driver.fallback' -Component 'ApplyDrivers' `
                    -Message ('falling back to PnP match: {0}' -f $why) `
                    -Data ([ordered] @{ reason = [string] $why; group = [string] $groupPath })
            }

            $cim = $Context.Service.GetRequired('Cim', 'ApplyDrivers')
            $device = @(Get-HDTPresentDevice -Cim $cim)

            Write-HDTLog -Context $Context.Log -Event 'driver.enumerate' -Component 'ApplyDrivers' `
                -Message ('{0} devices reported hardware ids' -f $device.Count) `
                -Data ([ordered] @{ deviceCount = [int] $device.Count })

            # SCOPED TO THE GROUP WHEN THERE IS ONE - mode 'matching' over a
            # resolved folder is MDT's "install only matching drivers from the
            # selection profile", and it must not wander into the rest of the
            # store.
            $driverArgument = @{ Root = [string] $Context.WorkspaceRoot; FileSystem = $fileSystem }
            if ($groupFound) { $driverArgument['Path'] = [string] $group }

            $candidate = @(Get-HDTDriver @driverArgument)

            # MDT'S SELECTION PROFILE, NARROWING WHAT IS CONSIDERED. It is
            # filtered by FULL PATH rather than by re-reading each folder,
            # because a profile's include paths are authored share-relative and
            # Get-HDTDriver counts from inside Drivers\ - matching those two
            # spellings against each other is the kind of off-by-one-segment
            # bug that silently scopes to nothing.
            #
            # A PROFILE THAT INCLUDES NOTHING PRESENT IS IGNORED, not obeyed. An
            # empty scope would match no driver at all and report it as "this
            # machine needs nothing", which is indistinguishable from success.
            if (-not [string]::IsNullOrWhiteSpace($profileName)) {
                $include = @(Expand-HDTSelectionProfile -Root ([string] $Context.WorkspaceRoot) `
                        -Id $profileName -FileSystem $fileSystem | Where-Object { $_.Present })

                Write-HDTLog -Context $Context.Log -Event 'driver.fallback' -Component 'ApplyDrivers' `
                    -Message ("selection profile '{0}' includes {1} folder(s) present on the share" -f $profileName, $include.Count) `
                    -Data ([ordered] @{
                        reason  = 'selection profile'
                        profile = [string] $profileName
                        folders = [int] $include.Count
                    })

                if ($include.Count -gt 0) {
                    $scoped = New-Object -TypeName System.Collections.ArrayList

                    foreach ($one in $candidate) {
                        $full = [string] $one.FullPath

                        foreach ($folder in $include) {
                            $prefix = ([string] $folder.FullPath).TrimEnd('\') + '\'

                            if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                                [void] $scoped.Add($one)
                                break
                            }
                        }
                    }

                    $candidate = @($scoped)
                }
            }

            $match = @(Get-HDTDriverMatch -Device $device -Driver $candidate)
            $matchedCount = $match.Count

            # WHAT THE TECHNICIAN SEES WHILE THIS RUNS, and until now that was
            # nothing. On a Latitude 5490 this loop injected 82 drivers in 670
            # seconds - eleven minutes of a progress window showing the same
            # frame, because the elapsed time on it is derived from the FIRST
            # and LAST record in the log and nothing told the display to re-read
            # while the step was working. Somebody sitting in front of it had no
            # way to tell a working machine from a hung one.
            #
            # THE RECORDS WERE ALREADY THERE. Every driver already writes
            # driver.match and driver.injected as it happens; they simply landed
            # in the JSONL with nobody looking. This adds the step.progress the
            # window already knows how to draw, and the nudge that makes it
            # look - exactly what Invoke-HDTApplyImageStep does from its DISM
            # callback.
            #
            # EVERY DRIVER, NOT EVERY FIFTH. ApplyImage throttles because DISM
            # reports a hundred times in a few minutes; this reports 82 times in
            # eleven, and a bar that moves once a driver is the whole point.
            # NOT $injected: THAT NAME IS ALREADY AN ArrayList declared above,
            # which the $inject closure appends every injected package to and
            # which the step's own result counts at the end. Reusing it as a
            # counter turned it into an [int] the first time round the loop, so
            # the closure's .Add() threw and the step reported Failed - six
            # tests, all of them right.
            $progressAt = 0

            foreach ($one in $match) {
                Write-HDTLog -Context $Context.Log -Event 'driver.match' -Component 'ApplyDrivers' `
                    -Message ("{0} matches {1} at rank {2}" -f [string] $one.Driver.InfName, [string] $one.MatchedId, [int] $one.Rank) `
                    -Data ([ordered] @{
                        inf        = [string] $one.Driver.FullPath
                        infName    = [string] $one.Driver.InfName
                        matchedId  = [string] $one.MatchedId
                        rank       = [int] $one.Rank
                        source     = [string] $one.Source
                        deviceName = [string] $one.DeviceName
                        version    = [string] $one.Driver.Version
                        class      = [string] $one.Driver.Class
                    })

                & $inject ([string] $one.Driver.FullPath) $false

                $progressAt++

                $percent = 100
                if ($matchedCount -gt 0) {
                    $percent = [int] [System.Math]::Floor(($progressAt / $matchedCount) * 100)
                }

                Write-HDTLog -Context $Context.Log -Event 'step.progress' -Component 'ApplyDrivers' `
                    -Message ('injecting driver {0} of {1}: {2}' -f $progressAt, $matchedCount, [string] $one.Driver.InfName) `
                    -Data ([ordered] @{
                        infName = [string] $one.Driver.InfName
                        target  = $applyPath
                        done    = $progressAt
                        total   = $matchedCount
                        percent = $percent
                    })

                # AND THEN TELL THE WINDOW TO LOOK. Update-HDTProgressDisplay
                # re-reads the log and hands the host a new snapshot; without
                # this the record above is written and never drawn, which is the
                # state this step has always been in.
                & $updateDisplay -Context $Context
            }
        }
    } catch {
        return (& $fail ("injecting drivers into {0} failed: {1}" -f $applyPath, [string] $_.Exception.Message) '')
    }

    $durationMillisecond = [long] (($clock.GetUtcNow()) - $startedUtc).TotalMilliseconds

    $data = [ordered] @{
        group      = [string] $groupPath
        groupFound = [bool] $groupFound
        mode       = [string] $mode
        target     = [string] $applyPath
        matched    = [int] $matchedCount
        injected   = [int] $injected.Count
        durationMs = [long] $durationMillisecond
    }

    if ($injected.Count -eq 0) {
        # LOUD, AND STILL COMPLETED. The deployment continues on inbox drivers,
        # which is MDT's behaviour - but a technician reading the log has to see
        # that this machine got nothing.
        $message = 'no drivers were injected into {0}. The deployment continues on the drivers inbox in the applied image.' -f $applyPath

        Write-HDTLog -Context $Context.Log -Event 'driver.injected' -Component 'ApplyDrivers' `
            -Severity Warning -Message $message -Data $data

        return (New-HDTStepResult -Status Completed -Message $message -Data $data)
    }

    $message = 'injected {0} driver(s) into {1} in {2} ms.' -f $injected.Count, $applyPath, $durationMillisecond

    Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component 'ApplyDrivers' -Message $message -Data $data

    return (New-HDTStepResult -Status Completed -Message $message -Data $data)
}
